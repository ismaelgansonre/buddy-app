import Foundation

class SettingsManager {
    static let shared = SettingsManager()

    struct Settings: Codable {
        var activeProvider: ModelProvider = .claudeCLI
        var activeModelId: String = "claude-cli"
        var preferredModels: [String: String] = [:]  // provider rawValue -> modelId
    }

    private(set) var settings = Settings()
    private let queue = DispatchQueue(label: "com.buddy.settings")
    private let settingsURL: URL

    var activeModelConfig: ModelConfig {
        let provider = settings.activeProvider
        let modelId = settings.activeModelId

        let displayName = AvailableModels.all
            .first(where: { $0.id == modelId })?.displayName ?? modelId

        let apiKey = KeychainHelper.apiKey(for: provider)

        return ModelConfig(
            provider: provider,
            modelId: modelId,
            displayName: displayName,
            apiKey: apiKey,
            isSubscription: provider == .buddyProxy
        )
    }

    private init() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let buddyDir = home.appendingPathComponent(".buddy")
        settingsURL = buddyDir.appendingPathComponent("settings.json")

        queue.sync {
            ensureDirectory(buddyDir)
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
        update { s in
            s.activeProvider = provider
            // Restore preferred model for this provider, or use default
            if let preferred = s.preferredModels[provider.rawValue] {
                s.activeModelId = preferred
            } else if let defaultModel = AvailableModels.defaultModel(for: provider) {
                s.activeModelId = defaultModel.id
            }
        }
    }

    func setModel(_ modelId: String) {
        update { s in
            s.activeModelId = modelId
            s.preferredModels[s.activeProvider.rawValue] = modelId
        }
    }

    private func loadFromDisk() {
        let fm = FileManager.default
        guard fm.fileExists(atPath: settingsURL.path),
              let data = fm.contents(atPath: settingsURL.path) else { return }
        do {
            settings = try JSONDecoder().decode(Settings.self, from: data)
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
