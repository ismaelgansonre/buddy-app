import Foundation

class GeminiSession: AgentSession {
    private let config: ModelConfig
    private var task: URLSessionDataTask?
    private var messages: [[String: Any]] = []
    private var currentResponseText = ""
    private var responseBuffer = ""

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
        guard let apiKey = config.apiKey else {
            onError?("No Gemini API key configured. Add one in Settings.")
            return
        }
        guard !apiKey.isEmpty else {
            onError?("Gemini API key is empty. Update it in Settings.")
            return
        }
        isRunning = true
        DispatchQueue.main.async { self.onSessionReady?() }
    }

    func send(message: String, screenshotBase64: String? = nil) {
        guard isRunning else { return }
        guard let apiKey = config.apiKey, !apiKey.isEmpty else {
            onError?("No API key configured.")
            return
        }
        isBusy = true
        if !message.hasPrefix("<system>") {
            history.append(ChatMessage(role: .user, text: message))
        }

        // Build user content parts
        var parts: [[String: Any]] = []
        if let img = screenshotBase64 {
            parts.append([
                "inline_data": ["mime_type": "image/jpeg", "data": img]
            ])
        }
        parts.append(["text": message])

        messages.append(["role": "user", "parts": parts])

        let body: [String: Any] = [
            "contents": messages,
            "systemInstruction": ["parts": [["text": buildBuddySystemPrompt()]]],
            "generationConfig": ["maxOutputTokens": 1024],
        ]

        guard let bodyData = try? JSONSerialization.data(withJSONObject: body) else {
            onError?("Failed to build request.")
            isBusy = false
            return
        }

        let urlString = "https://generativelanguage.googleapis.com/v1beta/models/\(config.modelId):streamGenerateContent?alt=sse&key=\(apiKey)"
        guard let url = URL(string: urlString) else {
            onError?("Invalid model ID.")
            isBusy = false
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = bodyData

        currentResponseText = ""
        responseBuffer = ""

        let sseParser = SSEParser()
        sseParser.onEvent = { [weak self] json in
            self?.handleSSEEvent(json)
        }

        let session = URLSession(configuration: .default, delegate: GeminiStreamDelegate(parser: sseParser, session: self), delegateQueue: nil)
        task = session.dataTask(with: request)
        task?.resume()
    }

    func terminate() {
        task?.cancel()
        isRunning = false
    }

    private func handleSSEEvent(_ json: [String: Any]) {
        // Gemini streaming response: {"candidates":[{"content":{"parts":[{"text":"..."}]}}]}
        guard let candidates = json["candidates"] as? [[String: Any]],
              let first = candidates.first,
              let content = first["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]] else { return }

        for part in parts {
            if let text = part["text"] as? String {
                currentResponseText += text
                DispatchQueue.main.async { self.onText?(text) }
            }
        }

        // Check if this is the final chunk
        if let finishReason = first["finishReason"] as? String, finishReason == "STOP" {
            finishResponse()
        }
    }

    fileprivate func finishResponse() {
        let finalText = currentResponseText
        if !finalText.isEmpty {
            messages.append(["role": "model", "parts": [["text": finalText]]])
        }
        DispatchQueue.main.async {
            if !finalText.isEmpty {
                self.history.append(ChatMessage(role: .assistant, text: finalText))
            }
            self.isBusy = false
            self.onTurnComplete?()
        }
    }
}

private class GeminiStreamDelegate: NSObject, URLSessionDataDelegate {
    let parser: SSEParser
    weak var geminiSession: GeminiSession?

    init(parser: SSEParser, session: GeminiSession) {
        self.parser = parser
        self.geminiSession = session
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let text = String(data: data, encoding: .utf8) else { return }
        parser.feed(text)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error = error, (error as NSError).code != NSURLErrorCancelled {
            NSLog("[GeminiSession] Connection error: \(error.localizedDescription)")
        }
        // Ensure we finish even if no explicit STOP reason was received
        DispatchQueue.main.async {
            if self.geminiSession?.isBusy == true {
                self.geminiSession?.finishResponse()
            }
        }
    }
}
