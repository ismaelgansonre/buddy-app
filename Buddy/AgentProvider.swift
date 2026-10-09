import Foundation

func createAgentSession(config: ModelConfig? = nil) -> AgentSession {
    let resolved = config ?? SettingsManager.shared.activeModelConfig
    switch resolved.provider {
    case .appleFoundation:
        return makeAppleFoundationSession(config: resolved)
    case .ollama:
        return OllamaSession(config: resolved)
    case .localServer:
        return LocalServerSession(config: resolved)
    case .claudeCLI:
        return ClaudeSession()
    case .claudeAPI:
        return ClaudeAPISession(config: resolved)
    case .openAI:
        return OpenAISession(config: resolved)
    case .gemini:
        return GeminiSession(config: resolved)
    case .buddyProxy:
        return ProxySession(config: resolved)
    }
}

/// Session used when a provider cannot run on this Mac or is not configured.
/// It reports one actionable message instead of failing silently.
final class UnavailableSession: AgentSession {
    private let reason: String

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

    init(reason: String) {
        self.reason = reason
    }

    func start() {
        DispatchQueue.main.async { self.onError?(self.reason) }
    }

    func send(message: String, screenshotBase64: String? = nil) {
        DispatchQueue.main.async {
            self.onError?(self.reason)
            self.onTurnComplete?()
        }
    }

    func terminate() {}
}

protocol AgentSession: AnyObject {
    var isRunning: Bool { get }
    var isBusy: Bool { get }
    var history: [ChatMessage] { get set }

    var onText: ((String) -> Void)? { get set }
    var onError: ((String) -> Void)? { get set }
    var onToolUse: ((String, [String: Any]) -> Void)? { get set }
    var onToolResult: ((String, Bool) -> Void)? { get set }
    var onSessionReady: (() -> Void)? { get set }
    var onTurnComplete: (() -> Void)? { get set }
    var onProcessExit: (() -> Void)? { get set }

    func start()
    func send(message: String, screenshotBase64: String?)
    func terminate()
}
