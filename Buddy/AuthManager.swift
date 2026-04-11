import Foundation
import AppKit

class AuthManager {
    static let shared = AuthManager()

    static let stateChangedNotification = Notification.Name("BuddyAuthStateChanged")

    private static let baseURL = "https://buddy.artiphik.com/api"

    enum SubscriptionStatus { case none, active, expired }

    private(set) var isSignedIn = false
    private(set) var userEmail: String?
    private(set) var userId: String?
    private(set) var subscriptionStatus: SubscriptionStatus = .none

    private init() {
        restoreSession()
    }

    // MARK: - Session

    var accessToken: String? {
        KeychainHelper.loadToken(key: KeychainHelper.authJWT)
    }

    private func restoreSession() {
        guard let jwt = KeychainHelper.loadToken(key: KeychainHelper.authJWT) else {
            isSignedIn = false
            return
        }
        // Decode JWT payload to get email and check expiry
        if let payload = decodeJWTPayload(jwt) {
            let exp = payload["exp"] as? TimeInterval ?? 0
            if Date().timeIntervalSince1970 < exp {
                isSignedIn = true
                userEmail = payload["email"] as? String
                userId = payload["sub"] as? String
                checkSubscription()
            } else {
                // Token expired — try refresh
                refreshToken()
            }
        }
    }

    // MARK: - Email/Password Sign Up

    func signUp(email: String, password: String, completion: @escaping (Result<Void, AuthError>) -> Void) {
        guard let url = URL(string: "\(Self.baseURL)/auth/signup") else {
            completion(.failure(.invalidURL))
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "email": email.lowercased().trimmingCharacters(in: .whitespaces),
            "password": password,
        ])

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            if let error = error {
                DispatchQueue.main.async { completion(.failure(.serverError(error.localizedDescription))) }
                return
            }
            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                DispatchQueue.main.async { completion(.failure(.signUpFailed)) }
                return
            }

            let httpStatus = (response as? HTTPURLResponse)?.statusCode ?? 0

            // Check for error response
            if httpStatus >= 400 {
                let msg = json["error"] as? String ?? "Signup failed"
                // Make error messages more user-friendly
                let friendlyMsg: String
                if msg.lowercased().contains("already") || httpStatus == 409 {
                    friendlyMsg = "An account with this email already exists. Try signing in instead."
                } else {
                    friendlyMsg = msg
                }
                DispatchQueue.main.async { completion(.failure(.serverError(friendlyMsg))) }
                return
            }

            // Check if email confirmation is needed
            if json["needs_confirmation"] as? Bool == true {
                DispatchQueue.main.async { completion(.failure(.serverError("Check your email to confirm your account."))) }
                return
            }

            // Account created but needs manual sign-in
            if json["needs_signin"] as? Bool == true {
                DispatchQueue.main.async { completion(.failure(.serverError("Account created! Please sign in."))) }
                return
            }

            // Got tokens — save and sign in
            if let accessToken = json["access_token"] as? String {
                KeychainHelper.saveToken(accessToken, key: KeychainHelper.authJWT)
                if let refresh = json["refresh_token"] as? String {
                    KeychainHelper.saveToken(refresh, key: KeychainHelper.authRefreshToken)
                }
                DispatchQueue.main.async {
                    if let payload = self?.decodeJWTPayload(accessToken) {
                        self?.userEmail = payload["email"] as? String
                        self?.userId = payload["sub"] as? String
                    }
                    self?.isSignedIn = true
                    NotificationCenter.default.post(name: AuthManager.stateChangedNotification, object: nil)
                    completion(.success(()))
                }
                return
            }

            DispatchQueue.main.async { completion(.success(())) }
        }.resume()
    }

    // MARK: - Email/Password Sign In

    func signIn(email: String, password: String, completion: @escaping (Result<Void, AuthError>) -> Void) {
        guard let url = URL(string: "\(Self.baseURL)/auth/signin") else {
            completion(.failure(.invalidURL))
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "email": email.lowercased().trimmingCharacters(in: .whitespaces),
            "password": password,
        ])

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            if let error = error {
                DispatchQueue.main.async { completion(.failure(.serverError(error.localizedDescription))) }
                return
            }
            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                DispatchQueue.main.async { completion(.failure(.signInFailed)) }
                return
            }

            let httpStatus = (response as? HTTPURLResponse)?.statusCode ?? 0

            if httpStatus >= 400 {
                let msg = json["error"] as? String ?? "Invalid email or password"
                // Make Supabase error messages more user-friendly
                let friendlyMsg: String
                if msg.lowercased().contains("invalid login credentials") || msg.lowercased().contains("invalid email or password") {
                    friendlyMsg = "Invalid email or password."
                } else {
                    friendlyMsg = msg
                }
                DispatchQueue.main.async { completion(.failure(.serverError(friendlyMsg))) }
                return
            }

            guard let accessToken = json["access_token"] as? String else {
                DispatchQueue.main.async { completion(.failure(.signInFailed)) }
                return
            }

            KeychainHelper.saveToken(accessToken, key: KeychainHelper.authJWT)
            if let refresh = json["refresh_token"] as? String {
                KeychainHelper.saveToken(refresh, key: KeychainHelper.authRefreshToken)
            }

            DispatchQueue.main.async {
                if let payload = self?.decodeJWTPayload(accessToken) {
                    self?.userEmail = payload["email"] as? String
                    self?.userId = payload["sub"] as? String
                }
                self?.isSignedIn = true
                NotificationCenter.default.post(name: AuthManager.stateChangedNotification, object: nil)
                completion(.success(()))
            }
        }.resume()
    }

    // MARK: - Browser Sign In (legacy)

    func signIn() {
        guard let url = URL(string: "https://buddy.artiphik.com/auth?source=app") else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: - URL Callback

    func handleCallback(url: URL) {
        // buddy://auth/callback?access_token=...&refresh_token=...
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return }
        let params = Dictionary(
            uniqueKeysWithValues: (components.queryItems ?? []).compactMap { item in
                item.value.map { (item.name, $0) }
            }
        )

        if let token = params["access_token"] {
            KeychainHelper.saveToken(token, key: KeychainHelper.authJWT)
            if let refresh = params["refresh_token"] {
                KeychainHelper.saveToken(refresh, key: KeychainHelper.authRefreshToken)
            }
            if let payload = decodeJWTPayload(token) {
                userEmail = payload["email"] as? String
                userId = payload["sub"] as? String
            }
            isSignedIn = true
            checkSubscription()
            NotificationCenter.default.post(name: Self.stateChangedNotification, object: nil)
        } else if let token = params["token"] {
            // Magic link token — need to verify
            verifyToken(token)
        }
    }

    private func verifyToken(_ token: String) {
        guard let url = URL(string: "\(Self.baseURL)/auth/verify") else { return }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["token": token])

        URLSession.shared.dataTask(with: request) { [weak self] data, _, _ in
            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let accessToken = json["access_token"] as? String else { return }

            KeychainHelper.saveToken(accessToken, key: KeychainHelper.authJWT)
            if let refresh = json["refresh_token"] as? String {
                KeychainHelper.saveToken(refresh, key: KeychainHelper.authRefreshToken)
            }

            DispatchQueue.main.async {
                if let payload = self?.decodeJWTPayload(accessToken) {
                    self?.userEmail = payload["email"] as? String
                    self?.userId = payload["sub"] as? String
                }
                self?.isSignedIn = true
                NotificationCenter.default.post(name: AuthManager.stateChangedNotification, object: nil)
            }
        }.resume()
    }

    // MARK: - Refresh

    func refreshToken() {
        guard let refreshToken = KeychainHelper.loadToken(key: KeychainHelper.authRefreshToken) else {
            signOut()
            return
        }

        guard let url = URL(string: "\(Self.baseURL)/auth/refresh") else { return }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["refresh_token": refreshToken])

        URLSession.shared.dataTask(with: request) { [weak self] data, _, _ in
            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let newAccess = json["access_token"] as? String else {
                DispatchQueue.main.async { self?.signOut() }
                return
            }

            KeychainHelper.saveToken(newAccess, key: KeychainHelper.authJWT)
            if let newRefresh = json["refresh_token"] as? String {
                KeychainHelper.saveToken(newRefresh, key: KeychainHelper.authRefreshToken)
            }

            DispatchQueue.main.async {
                if let payload = self?.decodeJWTPayload(newAccess) {
                    self?.userEmail = payload["email"] as? String
                    self?.userId = payload["sub"] as? String
                }
                self?.isSignedIn = true
                NotificationCenter.default.post(name: AuthManager.stateChangedNotification, object: nil)
            }
        }.resume()
    }

    // MARK: - Sign Out

    func signOut() {
        KeychainHelper.deleteToken(key: KeychainHelper.authJWT)
        KeychainHelper.deleteToken(key: KeychainHelper.authRefreshToken)
        isSignedIn = false
        userEmail = nil
        userId = nil
        subscriptionStatus = .none
        NotificationCenter.default.post(name: Self.stateChangedNotification, object: nil)
    }

    // MARK: - Subscription Check

    func checkSubscription() {
        guard let jwt = accessToken else {
            subscriptionStatus = .none
            return
        }

        guard let url = URL(string: "\(Self.baseURL)/auth/status") else { return }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(jwt)", forHTTPHeaderField: "Authorization")

        URLSession.shared.dataTask(with: request) { [weak self] data, response, _ in
            let httpResponse = response as? HTTPURLResponse
            DispatchQueue.main.async {
                guard httpResponse?.statusCode == 200,
                      let data = data,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let hasSubscription = json["has_subscription"] as? Bool else {
                    self?.subscriptionStatus = .none
                    NotificationCenter.default.post(name: AuthManager.stateChangedNotification, object: nil)
                    return
                }
                self?.subscriptionStatus = hasSubscription ? .active : .none
                NotificationCenter.default.post(name: AuthManager.stateChangedNotification, object: nil)
            }
        }.resume()
    }

    // MARK: - Subscription Polling

    private var subscriptionPollTimer: Timer?

    func startSubscriptionPolling() {
        subscriptionPollTimer?.invalidate()
        var attempts = 0
        subscriptionPollTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] timer in
            attempts += 1
            if attempts > 60 { timer.invalidate(); return }
            self?.checkSubscription()
            if self?.subscriptionStatus == .active {
                timer.invalidate()
            }
        }
    }

    func stopSubscriptionPolling() {
        subscriptionPollTimer?.invalidate()
        subscriptionPollTimer = nil
    }

    // MARK: - JWT Decode

    private func decodeJWTPayload(_ jwt: String) -> [String: Any]? {
        let parts = jwt.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var base64 = String(parts[1])
        // Pad base64
        while base64.count % 4 != 0 { base64 += "=" }
        base64 = base64.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        guard let data = Data(base64Encoded: base64),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return json
    }

    // MARK: - Errors

    enum AuthError: LocalizedError {
        case invalidURL
        case signInFailed
        case signUpFailed
        case serverError(String)

        var errorDescription: String? {
            switch self {
            case .invalidURL: return "Unable to connect. Try again."
            case .signInFailed: return "Invalid email or password."
            case .signUpFailed: return "Unable to create account. Try again."
            case .serverError(let msg): return msg
            }
        }
    }
}
