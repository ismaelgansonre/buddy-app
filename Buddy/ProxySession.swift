import Foundation

class ProxySession: AgentSession {
    private let config: ModelConfig
    private let sseParser = SSEParser()
    private var task: URLSessionDataTask?
    private var messages: [[String: Any]] = []
    private var currentResponseText = ""

    private static let proxyBaseURL = "https://buddy.artiphik.com/api/proxy"

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
        sseParser.onEvent = { [weak self] json in
            self?.handleSSEEvent(json)
        }
    }

    func start() {
        let jwt = KeychainHelper.loadToken(key: KeychainHelper.authJWT)
        guard jwt != nil else {
            onError?("Sign in to use Buddy. Go to Settings > Account.")
            return
        }
        isRunning = true
        DispatchQueue.main.async { self.onSessionReady?() }
    }

    func send(message: String, screenshotBase64: String? = nil) {
        guard isRunning else { return }
        guard let jwt = KeychainHelper.loadToken(key: KeychainHelper.authJWT) else {
            onError?("Not signed in. Go to Settings > Account to sign in.")
            return
        }

        // Check usage limit before sending
        if !UsageManager.shared.canSendMessage() {
            onError?(UsageManager.contactMessage)
            return
        }
        isBusy = true
        if !message.hasPrefix("<system>") {
            history.append(ChatMessage(role: .user, text: message))
        }

        var content: [Any] = []
        if let img = screenshotBase64 {
            content.append(["type": "image", "data": img])
        }
        content.append(["type": "text", "text": message])

        messages.append(["role": "user", "content": content])

        let body: [String: Any] = [
            "model": config.modelId,
            "system": buildBuddySystemPrompt(),
            "messages": messages,
            "stream": true,
        ]

        guard let bodyData = try? JSONSerialization.data(withJSONObject: body) else {
            onError?("Failed to build request.")
            isBusy = false
            return
        }

        var request = URLRequest(url: URL(string: "\(Self.proxyBaseURL)/chat")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(jwt)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = bodyData

        currentResponseText = ""
        sseParser.reset()

        let session = URLSession(configuration: .default, delegate: ProxyStreamDelegate(parser: sseParser), delegateQueue: nil)
        task = session.dataTask(with: request)
        task?.resume()
    }

    func terminate() {
        task?.cancel()
        isRunning = false
    }

    private func handleSSEEvent(_ json: [String: Any]) {
        let eventType = json["type"] as? String ?? ""
        switch eventType {
        case "content_block_delta":
            if let delta = json["delta"] as? [String: Any],
               let text = delta["text"] as? String {
                currentResponseText += text
                DispatchQueue.main.async { self.onText?(text) }
            }

        case "delta":
            // OpenAI-style response from proxy
            if let choices = json["choices"] as? [[String: Any]],
               let first = choices.first,
               let delta = first["delta"] as? [String: Any],
               let text = delta["content"] as? String {
                currentResponseText += text
                DispatchQueue.main.async { self.onText?(text) }
            }

        case "message_stop", "done":
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

        case "error":
            let errorObj = json["error"] as? [String: Any]
            let errMsg = errorObj?["message"] as? String ?? json["error"] as? String ?? "Something went wrong. Try again."
            DispatchQueue.main.async {
                self.onError?(errMsg)
                self.isBusy = false
                self.onTurnComplete?()
            }

        default:
            break
        }
    }
}

private class ProxyStreamDelegate: NSObject, URLSessionDataDelegate {
    let parser: SSEParser
    private var httpStatus: Int = 200
    private var errorBuffer = Data()

    init(parser: SSEParser) {
        self.parser = parser
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        httpStatus = (response as? HTTPURLResponse)?.statusCode ?? 200
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        if httpStatus >= 400 {
            // Non-streaming error response (e.g., 429 usage limit)
            errorBuffer.append(data)
            return
        }
        guard let text = String(data: data, encoding: .utf8) else { return }
        parser.feed(text)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if httpStatus >= 400, !errorBuffer.isEmpty {
            // Parse the error JSON and feed it as an SSE error event
            if let json = try? JSONSerialization.jsonObject(with: errorBuffer) as? [String: Any],
               let errMsg = json["error"] as? String {
                let errorEvent: [String: Any] = ["type": "error", "error": errMsg]
                DispatchQueue.main.async {
                    self.parser.onEvent?(errorEvent)
                }
            }
            return
        }
        if let error = error, (error as NSError).code != NSURLErrorCancelled {
            NSLog("[ProxySession] Connection error: \(error.localizedDescription)")
        }
    }
}
