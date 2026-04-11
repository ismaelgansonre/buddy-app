import Foundation
import Security

struct KeychainHelper {
    private static let bundlePrefix = "com.artiphik.buddy"

    // MARK: - Keychain (for API keys only)

    static func save(_ value: String, service: String) -> Bool {
        guard let data = value.data(using: .utf8) else { return false }
        delete(service: service)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "\(bundlePrefix).\(service)",
            kSecValueData as String: data,
        ]
        return SecItemAdd(query as CFDictionary, nil) == errSecSuccess
    }

    static func load(service: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "\(bundlePrefix).\(service)",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let string = String(data: data, encoding: .utf8) else { return nil }
        return string
    }

    @discardableResult
    static func delete(service: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "\(bundlePrefix).\(service)",
        ]
        return SecItemDelete(query as CFDictionary) == errSecSuccess
    }

    // MARK: - UserDefaults (for auth tokens — no Keychain permission dialog)

    static func saveToken(_ value: String, key: String) {
        UserDefaults.standard.set(value, forKey: "\(bundlePrefix).\(key)")
    }

    static func loadToken(key: String) -> String? {
        UserDefaults.standard.string(forKey: "\(bundlePrefix).\(key)")
    }

    static func deleteToken(key: String) {
        UserDefaults.standard.removeObject(forKey: "\(bundlePrefix).\(key)")
    }

    // Convenience keys for each provider
    static let claudeAPIKey = "apikey.claude"
    static let openAIAPIKey = "apikey.openai"
    static let geminiAPIKey = "apikey.gemini"
    static let authJWT = "auth.jwt"
    static let authRefreshToken = "auth.refresh"

    static func apiKey(for provider: ModelProvider) -> String? {
        switch provider {
        case .claudeAPI: return load(service: claudeAPIKey)
        case .openAI: return load(service: openAIAPIKey)
        case .gemini: return load(service: geminiAPIKey)
        case .claudeCLI, .buddyProxy: return nil
        }
    }

    static func saveAPIKey(_ key: String, for provider: ModelProvider) -> Bool {
        switch provider {
        case .claudeAPI: return save(key, service: claudeAPIKey)
        case .openAI: return save(key, service: openAIAPIKey)
        case .gemini: return save(key, service: geminiAPIKey)
        case .claudeCLI, .buddyProxy: return false
        }
    }

    static func deleteAPIKey(for provider: ModelProvider) -> Bool {
        switch provider {
        case .claudeAPI: return delete(service: claudeAPIKey)
        case .openAI: return delete(service: openAIAPIKey)
        case .gemini: return delete(service: geminiAPIKey)
        case .claudeCLI, .buddyProxy: return false
        }
    }
}
