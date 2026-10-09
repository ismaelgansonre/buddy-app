import Foundation

/// A model offered by a local engine.
struct LocalModelInfo: Equatable {
    /// Value sent to the engine (e.g. `qwen3.5:2b` or a path-like id).
    let id: String
    /// Label shown in Settings.
    let displayName: String
}

/// Lists the models a local engine currently serves.
///
/// Results are cached briefly so opening Settings does not hammer a server that
/// may not be running.
enum LocalModelDiscovery {
    private enum CacheKind {
        case ollama
        case openAICompatible
    }

    private static let cacheLock = NSLock()
    private static var ollamaCache: (models: [LocalModelInfo], date: Date)?
    private static var serverCache: (models: [LocalModelInfo], date: Date)?
    private static let cacheLifetime: TimeInterval = 20

    /// Ollama exposes its installed models on `/api/tags`.
    static func listOllama(
        baseURL: URL = LocalAI.ollamaBaseURL(),
        completion: @escaping (Result<[LocalModelInfo], Error>) -> Void
    ) {
        if let cached = cachedValue(.ollama) {
            completion(.success(cached))
            return
        }

        let url = baseURL.appendingPathComponent("api/tags")
        fetchJSON(url: url) { result in
            switch result {
            case .failure(let error):
                completion(.failure(error))
            case .success(let json):
                let raw = (json["models"] as? [[String: Any]]) ?? []
                let models = raw.compactMap { entry -> LocalModelInfo? in
                    guard let name = entry["name"] as? String, !name.isEmpty else { return nil }
                    return LocalModelInfo(id: name, displayName: name)
                }
                .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
                store(.ollama, models)
                completion(.success(models))
            }
        }
    }

    /// LM Studio, llama.cpp and friends expose OpenAI's `/models`.
    static func listOpenAICompatible(
        baseURL: URL = LocalAI.localServerBaseURL(),
        completion: @escaping (Result<[LocalModelInfo], Error>) -> Void
    ) {
        if let cached = cachedValue(.openAICompatible) {
            completion(.success(cached))
            return
        }

        let url = baseURL.appendingPathComponent("models")
        fetchJSON(url: url) { result in
            switch result {
            case .failure(let error):
                completion(.failure(error))
            case .success(let json):
                let raw = (json["data"] as? [[String: Any]]) ?? []
                let models = raw.compactMap { entry -> LocalModelInfo? in
                    guard let id = entry["id"] as? String, !id.isEmpty else { return nil }
                    return LocalModelInfo(id: id, displayName: id)
                }
                .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
                store(.openAICompatible, models)
                completion(.success(models))
            }
        }
    }

    static func invalidateCaches() {
        cacheLock.lock()
        ollamaCache = nil
        serverCache = nil
        cacheLock.unlock()
    }

    // MARK: - Internals

    private static func cachedValue(_ kind: CacheKind) -> [LocalModelInfo]? {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        let entry = kind == .ollama ? ollamaCache : serverCache
        guard let entry, Date().timeIntervalSince(entry.date) < cacheLifetime else { return nil }
        return entry.models
    }

    private static func store(_ kind: CacheKind, _ models: [LocalModelInfo]) {
        cacheLock.lock()
        let value = (models: models, date: Date())
        switch kind {
        case .ollama: ollamaCache = value
        case .openAICompatible: serverCache = value
        }
        cacheLock.unlock()
    }

    private static func fetchJSON(url: URL, completion: @escaping (Result<[String: Any], Error>) -> Void) {
        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        request.httpMethod = "GET"

        URLSession.shared.dataTask(with: request) { data, response, error in
            DispatchQueue.main.async {
                if let error {
                    completion(.failure(error))
                    return
                }
                if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                    completion(.failure(LocalEngineError.badStatus(http.statusCode)))
                    return
                }
                guard let data,
                    let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                else {
                    completion(.failure(LocalEngineError.unreadableResponse))
                    return
                }
                completion(.success(json))
            }
        }.resume()
    }
}

enum LocalEngineError: LocalizedError {
    case badStatus(Int)
    case unreadableResponse
    case notLoopback
    case noModelSelected

    var errorDescription: String? {
        switch self {
        case .badStatus(let code):
            return "The local engine replied with status \(code)."
        case .unreadableResponse:
            return "The local engine sent an unexpected response."
        case .notLoopback:
            return LocalAI.nonLoopbackMessage
        case .noModelSelected:
            return "Pick a local model in Settings first."
        }
    }
}
