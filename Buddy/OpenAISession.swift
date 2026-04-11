import Foundation

class OpenAISession: AgentSession {
    private let config: ModelConfig
    private let sseParser = SSEParser()
    private var task: URLSessionDataTask?
    private var messages: [[String: Any]] = []
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
        messages = [
            ["role": "system", "content": buildBuddySystemPrompt()]
        ]
        sseParser.onEvent = { [weak self] json in
            self?.handleSSEEvent(json)
        }
    }

    func start() {
        guard let apiKey = config.apiKey else {
            onError?("No OpenAI API key configured. Add one in Settings.")
            return
        }
        guard !apiKey.isEmpty else {
            onError?("OpenAI API key is empty. Update it in Settings.")
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

        // Build content
        var content: [Any] = []
        if let img = screenshotBase64 {
            content.append([
                "type": "image_url",
                "image_url": ["url": "data:image/jpeg;base64,\(img)"]
            ])
        }
        content.append(["type": "text", "text": message])

        messages.append(["role": "user", "content": content])

        let body: [String: Any] = [
            "model": config.modelId,
            "messages": messages,
            "stream": true,
        ]

        guard let bodyData = try? JSONSerialization.data(withJSONObject: body) else {
            onError?("Failed to build request.")
            isBusy = false
            return
        }

        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/chat/completions")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = bodyData

        currentResponseText = ""
        sseParser.reset()

        let session = URLSession(configuration: .default, delegate: OpenAIStreamDelegate(parser: sseParser), delegateQueue: nil)
        task = session.dataTask(with: request)
        task?.resume()
    }

    func terminate() {
        task?.cancel()
        isRunning = false
    }

    private func handleSSEEvent(_ json: [String: Any]) {
        guard let choices = json["choices"] as? [[String: Any]],
              let first = choices.first else { return }

        if let delta = first["delta"] as? [String: Any],
           let text = delta["content"] as? String {
            currentResponseText += text
            DispatchQueue.main.async { self.onText?(text) }
        }

        if let finishReason = first["finish_reason"] as? String, finishReason == "stop" {
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
    }
}

private class OpenAIStreamDelegate: NSObject, URLSessionDataDelegate {
    let parser: SSEParser

    init(parser: SSEParser) {
        self.parser = parser
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let text = String(data: data, encoding: .utf8) else { return }
        parser.feed(text)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error = error, (error as NSError).code != NSURLErrorCancelled {
            NSLog("[OpenAISession] Connection error: \(error.localizedDescription)")
        }
    }
}
