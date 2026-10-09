import Foundation

enum ModelProvider: String, Codable, CaseIterable {
    // Engines that run on this Mac.
    case appleFoundation
    case ollama
    case localServer

    // Engines reached over the network.
    case claudeCLI
    case claudeAPI
    case openAI
    case gemini
    case buddyProxy

    /// True when the engine runs on this Mac and needs no API key.
    var isLocal: Bool {
        switch self {
        case .appleFoundation, .ollama, .localServer: return true
        case .claudeCLI, .claudeAPI, .openAI, .gemini, .buddyProxy: return false
        }
    }

    /// Keychain entry for this provider, or nil when the engine needs no
    /// credentials, which is every engine that runs on this Mac.
    var apiKeyService: String? {
        switch self {
        case .claudeAPI: return KeychainHelper.claudeAPIKey
        case .openAI: return KeychainHelper.openAIAPIKey
        case .gemini: return KeychainHelper.geminiAPIKey
        case .appleFoundation, .ollama, .localServer, .claudeCLI, .buddyProxy: return nil
        }
    }

    /// True when the provider needs a key stored in the Keychain.
    var requiresAPIKey: Bool { apiKeyService != nil }

    /// True when the model list comes from the running engine instead of
    /// being fixed in `AvailableModels`.
    var hasDynamicModels: Bool {
        switch self {
        case .ollama, .localServer: return true
        default: return false
        }
    }

    var displayName: String {
        switch self {
        case .appleFoundation: return "Apple Intelligence"
        case .ollama: return "Ollama"
        case .localServer: return "Local server"
        case .claudeCLI: return "Claude CLI"
        case .claudeAPI: return "Claude API"
        case .openAI: return "OpenAI"
        case .gemini: return "Gemini"
        case .buddyProxy: return "Buddy Proxy"
        }
    }

    /// Shown under the provider picker in Settings.
    var settingsSummary: String {
        switch self {
        case .appleFoundation: return "Runs on this Mac. No API key, nothing leaves your computer."
        case .ollama: return "Talks to Ollama on this Mac. Start Ollama and pick a model."
        case .localServer: return "Talks to an OpenAI-compatible server on this Mac, such as LM Studio or llama.cpp."
        case .claudeCLI: return "Uses the Claude CLI already installed on this Mac."
        case .claudeAPI: return "Sends messages to Anthropic. Needs an API key."
        case .openAI: return "Sends messages to OpenAI. Needs an API key."
        case .gemini: return "Sends messages to Google. Needs an API key."
        case .buddyProxy: return "Uses the Buddy subscription proxy."
        }
    }
}

struct ModelConfig: Codable {
    var provider: ModelProvider
    var modelId: String
    var displayName: String
    var apiKey: String?
    var isSubscription: Bool

    init(provider: ModelProvider, modelId: String, displayName: String, apiKey: String? = nil, isSubscription: Bool = false) {
        self.provider = provider
        self.modelId = modelId
        self.displayName = displayName
        self.apiKey = apiKey
        self.isSubscription = isSubscription
    }
}

struct AvailableModels {
    struct ModelInfo {
        let id: String
        let displayName: String
        let provider: ModelProvider
    }

    /// Identifier for the model Apple exposes through Foundation Models.
    static let appleOnDeviceId = "apple-on-device"

    static let all: [ModelInfo] = [
        // Apple Intelligence (on-device, no key, no download)
        ModelInfo(id: appleOnDeviceId, displayName: "Apple Intelligence (on-device)", provider: .appleFoundation),

        // Claude CLI (uses whatever model the CLI is configured with)
        ModelInfo(id: "claude-cli", displayName: "Claude CLI", provider: .claudeCLI),

        // Claude API
        ModelInfo(id: "claude-sonnet-4-20250514", displayName: "Claude Sonnet 4", provider: .claudeAPI),
        ModelInfo(id: "claude-haiku-4-5-20251001", displayName: "Claude Haiku 4.5", provider: .claudeAPI),

        // OpenAI
        ModelInfo(id: "gpt-4o", displayName: "GPT-4o", provider: .openAI),
        ModelInfo(id: "gpt-4o-mini", displayName: "GPT-4o Mini", provider: .openAI),
        ModelInfo(id: "gpt-4.1", displayName: "GPT-4.1", provider: .openAI),
        ModelInfo(id: "gpt-4.1-mini", displayName: "GPT-4.1 Mini", provider: .openAI),

        // Gemini
        ModelInfo(id: "gemini-2.5-pro", displayName: "Gemini 2.5 Pro", provider: .gemini),
        ModelInfo(id: "gemini-2.5-flash", displayName: "Gemini 2.5 Flash", provider: .gemini),
    ]

    static func models(for provider: ModelProvider) -> [ModelInfo] {
        // Use the Claude catalog for the Claude-style proxy.
        if provider == .buddyProxy {
            return all.filter { $0.provider == .claudeAPI }.map {
                ModelInfo(id: $0.id, displayName: $0.displayName, provider: .buddyProxy)
            }
        }
        return all.filter { $0.provider == provider }
    }

    static func defaultModel(for provider: ModelProvider) -> ModelInfo? {
        models(for: provider).first
    }

    /// True when the id is one of the models Buddy offers for this provider.
    /// Engines with a dynamic catalogue accept whatever they report.
    static func isKnown(_ modelId: String, for provider: ModelProvider) -> Bool {
        guard !modelId.isEmpty else { return false }
        if provider.hasDynamicModels { return true }
        return models(for: provider).contains { $0.id == modelId }
    }

    static func displayName(for modelId: String, provider: ModelProvider) -> String {
        if let match = all.first(where: { $0.provider == provider && $0.id == modelId }) {
            return match.displayName
        }
        if modelId.isEmpty {
            return "No model selected"
        }
        return modelId
    }
}
