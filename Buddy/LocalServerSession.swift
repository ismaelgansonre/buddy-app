import Foundation

/// Buddy conversation served by an OpenAI-compatible server running on this Mac
/// (LM Studio, llama.cpp's `llama-server`, or similar).
final class LocalServerSession: AgentSession {
    private let config: ModelConfig
    /// Replaced for every attempt so a cancelled one cannot feed its successor.
    private var sseParser = SSEParser()
    private var task: URLSessionDataTask?
    private var messages: [[String: Any]] = []
    private var currentResponseText = ""
    private var pendingUserEntry: [String: Any]?
    private var supportsImages: Bool?
    private var lastScreenshotBase64: String?
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
        guard
            LocalAI.normalizedBaseURL(
                SettingsManager.shared.settings.localServerBaseURL,
                fallback: LocalAI.localServerDefaultBaseURL) != nil
        else {
            onError?(LocalAI.nonLoopbackMessage)
            return
        }
        supportsImages = SettingsManager.shared.settings.localServerVision
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
        isRunning = false
        isBusy = false
    }

    // MARK: - Request

    private func performSend(prompt: String, screenshotBase64: String?, isRetry: Bool) {
        let attempt = UUID()
        attemptID = attempt
        let settings = SettingsManager.shared.settings
        guard
            let base = LocalAI.normalizedBaseURL(
                settings.localServerBaseURL, fallback: LocalAI.localServerDefaultBaseURL)
        else {
            fail(LocalAI.nonLoopbackMessage)
            return
        }

        var content: [Any] = []
        if let image = screenshotBase64 {
            content.append([
                "type": "image_url",
                "image_url": ["url": "data:image/jpeg;base64,\(image)"],
            ])
        }
        content.append(["type": "text", "text": prompt])
        let userEntry: [String: Any] = ["role": "user", "content": content]
        pendingUserEntry = userEntry

        let body: [String: Any] = [
            "model": config.modelId,
            "messages": messages + [userEntry],
            "stream": true,
            "max_tokens": settings.localMaxOutputTokens,
        ]

        guard let bodyData = try? JSONSerialization.data(withJSONObject: body) else {
            fail("Failed to build the request for the local server.")
            return
        }

        var request = URLRequest(url: base.appendingPathComponent("chat/completions"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = bodyData

        let parser = SSEParser()
        parser.onEvent = { [weak self] json in
            guard self?.attemptID == attempt else { return }
            self?.handleSSEEvent(json)
        }
        sseParser = parser

        let delegate = LocalServerStreamDelegate(
            parser: parser,
            onStatus: { [weak self] status, body in
                guard self?.attemptID == attempt else { return }
                self?.handleHTTPStatus(status, body: body, isRetry: isRetry)
            },
            onComplete: { [weak self] error in
                guard self?.attemptID == attempt else { return }
                self?.handleStreamEnd(error)
            }
        )

        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        task = session.dataTask(with: request)
        task?.resume()
    }

    private func handleHTTPStatus(_ status: Int, body: String, isRetry: Bool) {
        guard status >= 400 else { return }
        task?.cancel()

        if !isRetry, pendingUserEntry != nil, screenshotWasSent, LocalServerStreamDelegate.looksLikeImageRejection(body) {
            NSLog("[LocalServerSession] Server rejected the image, retrying with local OCR")
            supportsImages = false
            let originalMessage = history.last(where: { $0.role == .user })?.text ?? ""
            let retryPrompt = localPrompt(
                message: originalMessage,
                screenshotBase64: lastScreenshotBase64,
                vision: .textOnly)
            performSend(prompt: retryPrompt, screenshotBase64: nil, isRetry: true)
            return
        }

        let detail = LocalServerStreamDelegate.shortMessage(from: body)
        fail("Local server error \(status)\(detail.isEmpty ? "" : ": \(detail)")")
    }

    private var screenshotWasSent = false

    private func handleSSEEvent(_ json: [String: Any]) {
        if let error = json["error"] as? [String: Any],
            let message = error["message"] as? String
        {
            fail("Local server error: \(message)")
            return
        }

        guard let choices = json["choices"] as? [[String: Any]], let first = choices.first else { return }

        if let delta = first["delta"] as? [String: Any], let text = delta["content"] as? String, !text.isEmpty {
            commitUserEntryIfNeeded()
            currentResponseText += text
            DispatchQueue.main.async { self.onText?(text) }
        }

        if let finish = first["finish_reason"] as? String, !finish.isEmpty {
            finishTurn()
        }
    }

    private func handleStreamEnd(_ error: Error?) {
        if isCancelled { return }
        if let error {
            fail("Lost connection to the local server: \(error.localizedDescription)")
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

private final class LocalServerStreamDelegate: NSObject, URLSessionDataDelegate {
    private let parser: SSEParser
    private let onStatus: (Int, String) -> Void
    private let onComplete: (Error?) -> Void
    private var errorBody = ""
    private var statusHandled = false

    init(
        parser: SSEParser,
        onStatus: @escaping (Int, String) -> Void,
        onComplete: @escaping (Error?) -> Void
    ) {
        self.parser = parser
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
            errorBody += text
            let status = (dataTask.response as? HTTPURLResponse)?.statusCode ?? 0
            onStatus(status, errorBody)
            session.invalidateAndCancel()
            return
        }
        parser.feed(text)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error, (error as NSError).code == NSURLErrorCancelled {
            onComplete(nil)
            return
        }
        onComplete(error)
    }

    static func looksLikeImageRejection(_ body: String) -> Bool {
        let lowered = body.lowercased()
        let mentionsImage =
            lowered.contains("image") || lowered.contains("vision") || lowered.contains("multimodal")
            || lowered.contains("mmproj")
        let isRejection =
            lowered.contains("does not support") || lowered.contains("not support")
            || lowered.contains("unsupported") || lowered.contains("only support")
        return mentionsImage && isRejection
    }

    static func shortMessage(from body: String) -> String {
        guard let data = body.data(using: .utf8),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return String(body.prefix(160)) }

        if let error = json["error"] as? [String: Any], let message = error["message"] as? String {
            return message
        }
        if let error = json["error"] as? String {
            return error
        }
        return String(body.prefix(160))
    }
}
