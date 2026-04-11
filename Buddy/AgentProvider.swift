import Foundation

func createAgentSession(config: ModelConfig? = nil) -> AgentSession {
    let resolved = config ?? SettingsManager.shared.activeModelConfig
    switch resolved.provider {
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
