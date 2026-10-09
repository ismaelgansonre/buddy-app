import Foundation

/// Buddy conversation served by a local Ollama instance.
///
/// Requests only ever go to a loopback address, and if the chosen model turns
/// out not to accept images the screenshot is re-sent as locally read text.
final class OllamaSession: AgentSession {
    private let config: ModelConfig
    private var task: URLSessionDataTask?
    private var messages: [[String: Any]] = []
    private var streamDelegate: OllamaStreamDelegate?
    private var currentResponseText = ""
    /// Committed to `messages` once a turn has actually started.
    private var pendingUserEntry: [String: Any]?
    /// nil until the engine tells us whether this model accepts images.
    private var supportsImages: Bool?
    private var isCancelled = false
    /// Identifies the attempt in flight, so the cancelled attempt of a retry
    /// cannot end the turn that replaced it.
    private var attemptID = UUID()

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
        messages = [["role": "system", "content": buildBuddySystemPrompt()]]
    }

    func start() {
        guard !config.modelId.isEmpty else {
            onError?(LocalEngineError.noModelSelected.errorDescription ?? "No model selected.")
            return
        }
        guard LocalAI.normalizedBaseURL(
            SettingsManager.shared.settings.ollamaBaseURL, fallback: LocalAI.ollamaDefaultBaseURL) != nil
        else {
            onError?(LocalAI.nonLoopbackMessage)
            return
        }
        isRunning = true
        DispatchQueue.main.async { self.onSessionReady?() }
    }

    func send(message: String, screenshotBase64: String? = nil) {
        guard isRunning else { return }
        if isBusy { return }

        isBusy = true
        isCancelled = false
        if !message.hasPrefix("<system>") {
            history.append(ChatMessage(role: .user, text: message))
        }
        currentResponseText = ""
        pendingUserEntry = nil
        lastScreenshotBase64 = screenshotBase64

        let includeImage = (supportsImages ?? true) && screenshotBase64 != nil
        let prompt = includeImage
            ? message
            : localPrompt(message: message, screenshotBase64: screenshotBase64, vision: .textOnly)
        performSend(prompt: prompt, screenshotBase64: includeImage ? screenshotBase64 : nil, isRetry: false)
    }

    func terminate() {
        isCancelled = true
        task?.cancel()
        task = nil
        streamDelegate = nil
        isRunning = false
        isBusy = false
    }

    // MARK: - Request

    private func performSend(prompt: String, screenshotBase64: String?, isRetry: Bool) {
        let attempt = UUID()
        attemptID = attempt
        let settings = SettingsManager.shared.settings
        guard let base = LocalAI.normalizedBaseURL(settings.ollamaBaseURL, fallback: LocalAI.ollamaDefaultBaseURL)
        else {
            fail(LocalAI.nonLoopbackMessage)
            return
        }

        var userEntry: [String: Any] = ["role": "user", "content": prompt]
        if let image = screenshotBase64 {
            userEntry["images"] = [image]
        }
        pendingUserEntry = userEntry

        let body: [String: Any] = [
            "model": config.modelId,
            "messages": messages + [userEntry],
            "stream": true,
            "keep_alive": "5m",
            "options": [
                "num_ctx": settings.localContextTokens,
                "num_predict": settings.localMaxOutputTokens,
            ],
        ]

        guard let bodyData = try? JSONSerialization.data(withJSONObject: body) else {
            fail("Failed to build the request for the local model.")
            return
        }

        var request = URLRequest(url: base.appendingPathComponent("api/chat"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = bodyData

        let delegate = OllamaStreamDelegate(
            onLine: { [weak self] json in
                guard self?.attemptID == attempt else { return }
                self?.handleLine(json)
            },
            onStatus: { [weak self] status, body in
                guard self?.attemptID == attempt else { return }
                self?.handleHTTPStatus(status, body: body, prompt: prompt, isRetry: isRetry)
            },
            onComplete: { [weak self] error in
                guard self?.attemptID == attempt else { return }
                self?.handleStreamEnd(error)
            }
        )
        streamDelegate = delegate

        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        task = session.dataTask(with: request)
        task?.resume()
    }

    private func handleHTTPStatus(_ status: Int, body: String, prompt: String, isRetry: Bool) {
        guard status >= 400 else { return }
        task?.cancel()

        // A text-only model rejects the image: drop it and read the screen locally.
        if !isRetry, pendingUserEntry?["images"] != nil, OllamaStreamDelegate.looksLikeImageRejection(body) {
            NSLog("[OllamaSession] Model does not accept images, retrying with local OCR")
            supportsImages = false
            let originalMessage = history.last(where: { $0.role == .user })?.text ?? prompt
            let retryPrompt = localPrompt(
                message: originalMessage,
                screenshotBase64: lastScreenshotBase64,
                vision: .textOnly)
            performSend(prompt: retryPrompt, screenshotBase64: nil, isRetry: true)
            return
        }

        let detail = OllamaStreamDelegate.shortMessage(from: body)
        fail("Ollama error \(status)\(detail.isEmpty ? "" : ": \(detail)")")
    }

    /// Kept so a retry can still turn the screenshot into text.
    private var lastScreenshotBase64: String?

    private func handleLine(_ json: [String: Any]) {
        if let error = json["error"] as? String, !error.isEmpty {
            fail("Ollama error: \(error)")
            return
        }

        if let message = json["message"] as? [String: Any],
            let content = message["content"] as? String,
            !content.isEmpty
        {
            commitUserEntryIfNeeded()
            currentResponseText += content
            DispatchQueue.main.async { self.onText?(content) }
        }

        if let done = json["done"] as? Bool, done {
            finishTurn()
        }
    }

    private func handleStreamEnd(_ error: Error?) {
        if isCancelled { return }
        if let error {
            fail("Lost connection to Ollama: \(error.localizedDescription)")
            return
        }
        if isBusy {
            finishTurn()
        }
    }

    // MARK: - Turn lifecycle

    private func commitUserEntryIfNeeded() {
        guard let entry = pendingUserEntry else { return }
        messages.append(entry)
        pendingUserEntry = nil
    }

    private func finishTurn() {
        commitUserEntryIfNeeded()
        let finalText = currentResponseText
        if !finalText.isEmpty {
            messages.append(["role": "assistant", "content": finalText])
        }
        DispatchQueue.main.async {
            if !finalText.isEmpty {
                self.history.append(ChatMessage(role: .assistant, text: finalText))
            }
            self.isBusy = false
            self.onTurnComplete?()
        }
    }

    private func fail(_ message: String) {
        task?.cancel()
        DispatchQueue.main.async {
            self.isBusy = false
            self.onError?(message)
            self.onTurnComplete?()
        }
    }
}

// MARK: - Streaming

final class OllamaStreamDelegate: NSObject, URLSessionDataDelegate {
    private let onLine: ([String: Any]) -> Void
    private let onStatus: (Int, String) -> Void
    private let onComplete: (Error?) -> Void
    private var buffer = ""
    private var statusHandled = false

    init(
        onLine: @escaping ([String: Any]) -> Void,
        onStatus: @escaping (Int, String) -> Void,
        onComplete: @escaping (Error?) -> Void
    ) {
        self.onLine = onLine
        self.onStatus = onStatus
        self.onComplete = onComplete
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            statusHandled = true
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let text = String(data: data, encoding: .utf8) else { return }

        if statusHandled {
            // Error bodies are small; report the first chunk.
            let status = (dataTask.response as? HTTPURLResponse)?.statusCode ?? 0
            onStatus(status, text)
            statusHandled = false
            session.invalidateAndCancel()
            return
        }

        buffer += text
        while let newline = buffer.firstIndex(of: "\n") {
            let line = String(buffer[buffer.startIndex..<newline])
            buffer = String(buffer[buffer.index(after: newline)...])
            parse(line)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if !buffer.isEmpty {
            parse(buffer)
            buffer = ""
        }
        if let error, (error as NSError).code == NSURLErrorCancelled {
            onComplete(nil)
            return
        }
        onComplete(error)
    }

    private func parse(_ line: String) {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return }
        onLine(json)
    }

    /// True when the engine complained about images rather than something else.
    static func looksLikeImageRejection(_ body: String) -> Bool {
        let lowered = body.lowercased()
        let mentionsImage = lowered.contains("image") || lowered.contains("vision") || lowered.contains("multimodal")
        let isRejection =
            lowered.contains("does not support") || lowered.contains("not support")
            || lowered.contains("unsupported") || lowered.contains("no image")
        return mentionsImage && isRejection
    }

    /// Pull a compact human-readable message out of an error body.
    static func shortMessage(from body: String) -> String {
        guard let data = body.data(using: .utf8),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let error = json["error"] as? String
        else {
            return String(body.prefix(160))
        }
        return error
    }
}
