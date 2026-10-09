import AppKit
import Foundation

#if canImport(FoundationModels)
import FoundationModels
#endif

// MARK: - Availability

/// Why the on-device Apple model can or cannot be used right now.
enum AppleIntelligenceAvailability: Equatable {
    case available
    /// macOS is older than the version that ships Foundation Models.
    case requiresNewerMacOS
    case deviceNotEligible
    case intelligenceDisabled
    case modelNotReady
    case unknown

    var isAvailable: Bool { self == .available }

    /// One-line explanation shown in Settings and in chat errors.
    var message: String {
        switch self {
        case .available:
            return "Apple Intelligence ready — runs on this Mac, no API key"
        case .requiresNewerMacOS:
            return "Requires macOS 26 or later"
        case .deviceNotEligible:
            return "This Mac does not support Apple Intelligence"
        case .intelligenceDisabled:
            return "Turn on Apple Intelligence in System Settings"
        case .modelNotReady:
            return "Apple Intelligence is still preparing — try again shortly"
        case .unknown:
            return "Apple Intelligence is unavailable right now"
        }
    }

    /// Whether opening System Settings is a useful next step.
    var canOpenSettings: Bool {
        self == .intelligenceDisabled || self == .modelNotReady
    }
}

/// Central place for everything Apple's on-device model.
enum AppleIntelligence {
    /// True when the running macOS is new enough to link Foundation Models.
    static var isSupportedOS: Bool {
        if #available(macOS 26.0, *) { return true }
        return false
    }

    /// Current availability, resolved without requiring a session.
    static func availability() -> AppleIntelligenceAvailability {
        guard #available(macOS 26.0, *) else { return .requiresNewerMacOS }
        #if canImport(FoundationModels)
        switch SystemLanguageModel.default.availability {
        case .available:
            return .available
        case .unavailable(let reason):
            switch reason {
            case .deviceNotEligible: return .deviceNotEligible
            case .appleIntelligenceNotEnabled: return .intelligenceDisabled
            case .modelNotReady: return .modelNotReady
            @unknown default: return .unknown
            }
        @unknown default:
            return .unknown
        }
        #else
        return .requiresNewerMacOS
        #endif
    }

    /// Opens the System Settings pane that controls Apple Intelligence.
    static func openSystemSettings() {
        let candidates = [
            "x-apple.systempreferences:com.apple.Siri-Settings.extension",
            "x-apple.systempreferences:com.apple.AppleIntelligence-Settings.extension",
        ]
        for candidate in candidates {
            if let url = URL(string: candidate), NSWorkspace.shared.open(url) { return }
        }
    }
}

// MARK: - Session

#if canImport(FoundationModels)

/// Buddy conversation backed by the on-device Apple foundation model.
///
/// Nothing leaves the Mac. The model has a small context window, so overflowing
/// conversations are retried once with the older turns dropped instead of
/// failing outright.
@available(macOS 26.0, *)
final class AppleFoundationSession: AgentSession {
    private let config: ModelConfig
    private var session: LanguageModelSession?
    private var generation: Task<Void, Never>?
    /// Marks the active generation so late callbacks from a replaced one are ignored.
    private var generationID = UUID()
    private var lastEmittedLength = 0
    private var currentResponseText = ""

    var isRunning = false
    var isBusy = false
    var history: [ChatMessage] = []

    var onText: ((String) -> Void)?
    var onError: ((String) -> Void)?
    var onToolUse: ((String, [String: Any]) -> Void)?
    var onToolResult: ((String, Bool) -> Void)?
    var onSessionReady: (() -> Void)?
    var onTurnComplete: (() -> Void)?
    var onProcessExit: (() -> Void)?

    init(config: ModelConfig) {
        self.config = config
    }

    func start() {
        let availability = AppleIntelligence.availability()
        guard availability.isAvailable else {
            isRunning = false
            DispatchQueue.main.async { self.onError?(availability.message) }
            return
        }
        makeSession()
        isRunning = true
        DispatchQueue.main.async { self.onSessionReady?() }
    }

    func send(message: String, screenshotBase64: String? = nil) {
        guard isRunning else { return }
        if isBusy { return }

        isBusy = true
        if !message.hasPrefix("<system>") {
            history.append(ChatMessage(role: .user, text: message))
        }

        // Apple's on-device model takes text only, so screen context arrives as
        // text that Buddy read locally.
        let prompt = localPrompt(message: message, screenshotBase64: screenshotBase64, vision: .textOnly)
        currentResponseText = ""
        lastEmittedLength = 0

        let id = UUID()
        generationID = id
        generation?.cancel()
        generation = Task { [weak self] in
            await self?.respond(to: prompt, droppingHistoryOnOverflow: true, id: id)
        }
    }

    func terminate() {
        generation?.cancel()
        generation = nil
        session = nil
        isRunning = false
        isBusy = false
    }

    // MARK: - Generation

    private func makeSession() {
        session = LanguageModelSession(instructions: buildBuddySystemPrompt())
    }

    private func respond(to prompt: String, droppingHistoryOnOverflow: Bool, id: UUID) async {
        guard let session else {
            finishFailure("Local model session ended. Reopen the chat to continue.", id: id, keepsRunning: false)
            return
        }

        do {
            for try await snapshot in session.streamResponse(to: prompt) {
                emit(snapshot.content, id: id)
            }
            finishTurn(id: id)
        } catch is CancellationError {
            // Replaced or terminated mid-answer; nothing to report.
        } catch {
            if isContextOverflow(error), droppingHistoryOnOverflow {
                NSLog("[AppleFoundationSession] Context window exceeded, retrying without earlier turns")
                makeSession()
                lastEmittedLength = 0
                currentResponseText = ""
                await respond(to: prompt, droppingHistoryOnOverflow: false, id: id)
            } else if isContextOverflow(error) {
                finishFailure(
                    "That message is too long for the on-device model. Try a shorter one.", id: id)
            } else {
                finishFailure(friendlyMessage(for: error), id: id)
            }
        }
    }

    /// The snapshot is cumulative, so only the new suffix is forwarded.
    private func emit(_ text: String, id: UUID) {
        guard id == generationID else { return }
        guard text.count >= lastEmittedLength else {
            lastEmittedLength = 0
            currentResponseText = ""
            return
        }
        let start = text.index(text.startIndex, offsetBy: lastEmittedLength)
        let delta = String(text[start...])
        guard !delta.isEmpty else { return }
        lastEmittedLength = text.count
        currentResponseText = text
        DispatchQueue.main.async { self.onText?(delta) }
    }

    private func finishTurn(id: UUID) {
        guard id == generationID else { return }
        let finalText = currentResponseText
        DispatchQueue.main.async {
            if !finalText.isEmpty {
                self.history.append(ChatMessage(role: .assistant, text: finalText))
            }
            self.isBusy = false
            self.onTurnComplete?()
        }
    }

    private func finishFailure(_ message: String, id: UUID, keepsRunning: Bool = true) {
        guard id == generationID else { return }
        DispatchQueue.main.async {
            self.isBusy = false
            if !keepsRunning {
                self.isRunning = false
            }
            self.onError?(message)
            self.onTurnComplete?()
        }
    }

    // MARK: - Errors

    private func isContextOverflow(_ error: Error) -> Bool {
        if let generationError = error as? LanguageModelSession.GenerationError {
            if case .exceededContextWindowSize = generationError { return true }
        }
        #if compiler(>=6.2)
        if #available(macOS 27.0, *) {
            if let modelError = error as? LanguageModelError {
                if case .contextSizeExceeded = modelError { return true }
            }
        }
        #endif
        return false
    }

    /// Turn framework errors into something a person can act on.
    private func friendlyMessage(for error: Error) -> String {
        if let generationError = error as? LanguageModelSession.GenerationError {
            switch generationError {
            case .guardrailViolation:
                return "The on-device model declined that request."
            case .unsupportedLanguageOrLocale:
                return "The on-device model does not support this language yet."
            case .assetsUnavailable:
                return "Apple Intelligence is not ready yet. Try again in a moment."
            case .rateLimited:
                return "The local model is busy. Try again in a moment."
            case .concurrentRequests:
                return "Buddy is already waiting on the local model."
            default:
                break
            }
        }
        #if compiler(>=6.2)
        if #available(macOS 27.0, *) {
            if let modelError = error as? LanguageModelError {
                switch modelError {
                case .guardrailViolation, .refusal:
                    return "The on-device model declined that request."
                case .unsupportedLanguageOrLocale:
                    return "The on-device model does not support this language yet."
                case .rateLimited:
                    return "The local model is busy. Try again in a moment."
                case .timeout:
                    return "The local model took too long. Try again."
                default:
                    break
                }
            }
        }
        #endif
        return error.localizedDescription
    }
}

/// Returns the on-device session when this Mac can run it, otherwise a session
/// that explains what is missing.
func makeAppleFoundationSession(config: ModelConfig) -> AgentSession {
    if #available(macOS 26.0, *) {
        return AppleFoundationSession(config: config)
    }
    return UnavailableSession(reason: AppleIntelligenceAvailability.requiresNewerMacOS.message)
}

#else

func makeAppleFoundationSession(config: ModelConfig) -> AgentSession {
    UnavailableSession(reason: AppleIntelligenceAvailability.requiresNewerMacOS.message)
}

#endif
