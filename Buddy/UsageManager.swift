import Foundation

class UsageManager {
    static let shared = UsageManager()
    static let usageUpdatedNotification = Notification.Name("BuddyUsageUpdated")
    static let limitReachedNotification = Notification.Name("BuddyUsageLimitReached")

    private static let baseURL = "https://buddy.artiphik.com/api"

    // Free tier: 100K tokens/day (~50-80 messages)
    static let freeTierDailyTokens = 100_000
    static let contactMessage = "You've hit your daily free limit. Resets tomorrow.\nNeed more? Email hello@artiphik.com"

    struct Usage {
        var totalRequests: Int = 0
        var totalInputTokens: Int = 0
        var totalOutputTokens: Int = 0
        var totalTokens: Int { totalInputTokens + totalOutputTokens }
        var periodStart: Date?
        var lastFetched: Date?
    }

    private(set) var usage = Usage()
    private(set) var isFetching = false
    private var fetchTimer: Timer?

    var isOverLimit: Bool {
        usage.totalTokens >= Self.freeTierDailyTokens
    }

    var remainingTokens: Int {
        max(0, Self.freeTierDailyTokens - usage.totalTokens)
    }

    var usagePercent: Double {
        min(1.0, Double(usage.totalTokens) / Double(Self.freeTierDailyTokens))
    }

    var usageSummary: String {
        let used = formatTokens(usage.totalTokens)
        let limit = formatTokens(Self.freeTierDailyTokens)
        return "\(used) / \(limit) tokens today"
    }

    private init() {}

    // MARK: - Check Before Sending

    /// Returns true if the user can send a message, false if over limit
    func canSendMessage() -> Bool {
        if !AuthManager.shared.isSignedIn { return false }
        // If we haven't fetched yet, allow (will check server-side too)
        guard usage.lastFetched != nil else { return true }
        return !isOverLimit
    }

    // MARK: - Fetch Usage

    func fetchUsage() {
        guard let jwt = AuthManager.shared.accessToken else { return }
        guard !isFetching else { return }
        isFetching = true

        guard let url = URL(string: "\(Self.baseURL)/usage") else {
            isFetching = false
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(jwt)", forHTTPHeaderField: "Authorization")

        URLSession.shared.dataTask(with: request) { [weak self] data, response, _ in
            defer { DispatchQueue.main.async { self?.isFetching = false } }

            let httpStatus = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard httpStatus == 200,
                  let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }

            DispatchQueue.main.async {
                self?.usage.totalRequests = json["total_requests"] as? Int ?? 0
                self?.usage.totalInputTokens = json["total_input_tokens"] as? Int ?? 0
                self?.usage.totalOutputTokens = json["total_output_tokens"] as? Int ?? 0
                self?.usage.lastFetched = Date()

                if let start = json["period_start"] as? String {
                    let formatter = ISO8601DateFormatter()
                    self?.usage.periodStart = formatter.date(from: start)
                }

                NotificationCenter.default.post(name: UsageManager.usageUpdatedNotification, object: nil)

                if self?.isOverLimit == true {
                    NotificationCenter.default.post(name: UsageManager.limitReachedNotification, object: nil)
                }
            }
        }.resume()
    }

    // MARK: - Auto Refresh

    func startPeriodicRefresh() {
        fetchUsage()
        fetchTimer?.invalidate()
        fetchTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            self?.fetchUsage()
        }
    }

    func stopPeriodicRefresh() {
        fetchTimer?.invalidate()
        fetchTimer = nil
    }

    // MARK: - Increment Local (optimistic update after each message)

    func recordLocalUsage(inputTokens: Int, outputTokens: Int) {
        usage.totalRequests += 1
        usage.totalInputTokens += inputTokens
        usage.totalOutputTokens += outputTokens
        NotificationCenter.default.post(name: UsageManager.usageUpdatedNotification, object: nil)

        if isOverLimit {
            NotificationCenter.default.post(name: UsageManager.limitReachedNotification, object: nil)
        }
    }

    // MARK: - Reset (for testing / new day)

    func resetLocal() {
        usage = Usage()
        NotificationCenter.default.post(name: UsageManager.usageUpdatedNotification, object: nil)
    }

    // MARK: - Helpers

    private func formatTokens(_ count: Int) -> String {
        if count >= 1_000_000 {
            return String(format: "%.1fM", Double(count) / 1_000_000)
        } else if count >= 1_000 {
            return String(format: "%.1fK", Double(count) / 1_000)
        }
        return "\(count)"
    }
}
