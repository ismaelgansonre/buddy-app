import Foundation

class SettingsManager {
    static let shared = SettingsManager()
    static let modelConfigChanged = Notification.Name("BuddyModelConfigChanged")

    struct Settings: Codable {
        /// Apple's on-device model is the default for a fresh install: it
        /// needs no API key and nothing leaves the Mac.
        var activeProvider: ModelProvider = .appleFoundation
        var activeModelId: String = AvailableModels.appleOnDeviceId
        var preferredModels: [String: String] = [:]  // provider rawValue -> modelId

        // Engines that run on this Mac
        var ollamaBaseURL: String = LocalAI.ollamaDefaultBaseURL
        var localServerBaseURL: String = LocalAI.localServerDefaultBaseURL
        /// Whether the local server can be sent screenshots directly.
        var localServerVision: Bool = true
        /// Context window kept for on-device models, sized for an 8 GB Mac.
        var localContextTokens: Int = 2048
        /// Longest reply an on-device model may produce.
        var localMaxOutputTokens: Int = 256

        init() {}

        /// Decoded by hand so a settings file written by an older version keeps
        /// working after new fields are added.
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let defaults = Settings()

            func decoded<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
                ((try? container.decodeIfPresent(T.self, forKey: key)) ?? nil) ?? fallback
            }

            activeProvider = decoded(.activeProvider, defaults.activeProvider)
            preferredModels = decoded(.preferredModels, defaults.preferredModels)
            ollamaBaseURL = decoded(.ollamaBaseURL, defaults.ollamaBaseURL)
            localServerBaseURL = decoded(.localServerBaseURL, defaults.localServerBaseURL)
            localServerVision = decoded(.localServerVision, defaults.localServerVision)
            localContextTokens = decoded(.localContextTokens, defaults.localContextTokens)
            localMaxOutputTokens = decoded(.localMaxOutputTokens, defaults.localMaxOutputTokens)

            let storedModel: String = decoded(.activeModelId, "")
            if AvailableModels.isKnown(storedModel, for: activeProvider) {
                activeModelId = storedModel
            } else {
                activeModelId = Settings.defaultModelId(for: activeProvider)
            }
        }

        /// The model to use for a provider when none has been chosen yet.
        /// Engines with a dynamic catalogue start empty and wait for a choice.
        static func defaultModelId(for provider: ModelProvider) -> String {
            AvailableModels.defaultModel(for: provider)?.id ?? ""
        }
    }

    private(set) var settings = Settings()
    private let queue = DispatchQueue(label: "com.buddy.settings")
    private let settingsURL: URL

    var activeModelConfig: ModelConfig {
        let provider = settings.activeProvider
        let modelId = settings.activeModelId

        let displayName = AvailableModels.displayName(for: modelId, provider: provider)

        let apiKey = KeychainHelper.apiKey(for: provider)

        return ModelConfig(
            provider: provider,
            modelId: modelId,
            displayName: displayName,
            apiKey: apiKey,
            isSubscription: provider == .buddyProxy
        )
    }

    init(settingsURL: URL? = nil) {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let buddyDir = home.appendingPathComponent(".buddy")
        self.settingsURL = settingsURL ?? buddyDir.appendingPathComponent("settings.json")

        queue.sync {
            ensureDirectory(self.settingsURL.deletingLastPathComponent())
            loadFromDisk()
        }
    }

    func save() {
        queue.sync { saveToDisk() }
    }

    func update(_ block: (inout Settings) -> Void) {
        queue.sync {
            block(&settings)
            saveToDisk()
        }
    }

    func setProvider(_ provider: ModelProvider) {
        let previous = settings
        update { s in
            s.activeProvider = provider
            // Restore preferred model for this provider, or use default
            if let preferred = s.preferredModels[provider.rawValue],
               AvailableModels.models(for: provider).contains(where: { $0.id == preferred }) {
                s.activeModelId = preferred
            } else if let defaultModel = AvailableModels.defaultModel(for: provider) {
                s.activeModelId = defaultModel.id
            }
        }
        if previous.activeProvider != settings.activeProvider || previous.activeModelId != settings.activeModelId {
            NotificationCenter.default.post(name: Self.modelConfigChanged, object: nil)
        }
    }

    func setOllamaBaseURL(_ value: String) {
        update { $0.ollamaBaseURL = value }
    }

    func setLocalServerBaseURL(_ value: String) {
        update { $0.localServerBaseURL = value }
    }

    func setLocalServerVision(_ value: Bool) {
        update { $0.localServerVision = value }
    }

    func setModel(_ modelId: String) {
        guard modelId != settings.activeModelId,
              AvailableModels.isKnown(modelId, for: settings.activeProvider) else { return }
        update { s in
            s.activeModelId = modelId
            s.preferredModels[s.activeProvider.rawValue] = modelId
        }
        NotificationCenter.default.post(name: Self.modelConfigChanged, object: nil)
    }

    private func loadFromDisk() {
        let fm = FileManager.default
        guard fm.fileExists(atPath: settingsURL.path),
              let data = fm.contents(atPath: settingsURL.path) else { return }
        do {
            settings = try JSONDecoder().decode(Settings.self, from: data)
            if !AvailableModels.isKnown(settings.activeModelId, for: settings.activeProvider) {
                settings.activeModelId = Settings.defaultModelId(for: settings.activeProvider)
            }
        } catch {
            NSLog("[SettingsManager] Failed to decode settings: \(error.localizedDescription)")
        }
    }

    private func saveToDisk() {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(settings)
            try data.write(to: settingsURL, options: .atomic)
        } catch {
            NSLog("[SettingsManager] Failed to save settings: \(error.localizedDescription)")
        }
    }

    private func ensureDirectory(_ url: URL) {
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            try? fm.createDirectory(at: url, withIntermediateDirectories: true)
        }
    }
}
