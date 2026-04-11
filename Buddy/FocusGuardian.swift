import Foundation

// MARK: - FocusSessionSummary

struct FocusSessionSummary {
    let task: String
    let startTime: Date
    let endTime: Date
    let totalMinutes: Int
    let focusedMinutes: Int
    let topApps: [String: Int] // app name -> minutes spent
    let distractionCount: Int
    let plannedDurationMinutes: Int
}

// MARK: - ActiveSession

struct ActiveSession {
    let task: String
    let startTime: Date
    let durationMinutes: Int

    var remainingTime: TimeInterval {
        let elapsed = Date().timeIntervalSince(startTime)
        let total = TimeInterval(durationMinutes * 60)
        return max(0, total - elapsed)
    }

    var remainingMinutes: Int {
        Int(ceil(remainingTime / 60))
    }

    var elapsedMinutes: Int {
        Int(Date().timeIntervalSince(startTime) / 60)
    }
}

// MARK: - FocusGuardian

final class FocusGuardian {

    static let shared = FocusGuardian()

    // MARK: - Defaults Keys

    private enum DefaultsKey {
        static let lastSessionDate = "FocusGuardian.lastSessionDate"
        static let currentStreak = "FocusGuardian.currentStreak"
    }

    // MARK: - Callbacks

    /// Called when the user has been in a distraction app for 2+ minutes during focus.
    /// Parameters: (app name, minutes elapsed in session).
    var onDistraction: ((String, Int) -> Void)?

    /// Called when a session ends (either manually or when time runs out).
    var onSessionEnd: ((FocusSessionSummary) -> Void)?

    // MARK: - Configurable distraction list

    var distractionApps: Set<String> = [
        "Twitter", "X",
        "YouTube",
        "Reddit",
        "Instagram",
        "TikTok",
        "Facebook",
        "Netflix",
        "Hulu",
        "Discord"
    ]

    // MARK: - Session state

    private var activeSessionInfo: ActiveSession?
    private var appUsageSeconds: [String: TimeInterval] = [:]
    private var lastObservedApp: String?
    private var lastObserveTime: Date?
    private var distractionStartTime: Date?
    private var currentDistractionApp: String?
    private var distractionAlertFired: Bool = false
    private var distractionCount: Int = 0
    private var sessionEndTimer: Timer?

    // MARK: - Today's completed sessions (in-memory)

    private(set) var todaySessions: [FocusSessionSummary] = []

    // MARK: - Computed properties

    var isInSession: Bool {
        activeSessionInfo != nil
    }

    var currentSession: ActiveSession? {
        activeSessionInfo
    }

    var totalFocusMinutesToday: Int {
        todaySessions.reduce(0) { $0 + $1.focusedMinutes }
    }

    /// Consecutive days with at least one completed focus session.
    var currentStreak: Int {
        get { UserDefaults.standard.integer(forKey: DefaultsKey.currentStreak) }
        set { UserDefaults.standard.set(newValue, forKey: DefaultsKey.currentStreak) }
    }

    // MARK: - Init

    init() {
        // If the stored streak date is not today or yesterday, the streak may need resetting.
        // We validate on first access / session completion.
    }

    // MARK: - Session lifecycle

    /// Start a new focus session.
    func startSession(task: String, durationMinutes: Int) {
        guard !isInSession else { return }

        let now = Date()
        activeSessionInfo = ActiveSession(
            task: task,
            startTime: now,
            durationMinutes: durationMinutes
        )
        appUsageSeconds = [:]
        lastObservedApp = nil
        lastObserveTime = nil
        distractionStartTime = nil
        currentDistractionApp = nil
        distractionAlertFired = false
        distractionCount = 0

        // Schedule automatic end when duration expires.
        sessionEndTimer?.invalidate()
        sessionEndTimer = Timer.scheduledTimer(
            withTimeInterval: TimeInterval(durationMinutes * 60),
            repeats: false
        ) { [weak self] _ in
            self?.autoEnd()
        }
    }

    /// End the current session manually. Returns a summary, or nil if no session is active.
    @discardableResult
    func endSession() -> FocusSessionSummary? {
        guard let session = activeSessionInfo else { return nil }

        sessionEndTimer?.invalidate()
        sessionEndTimer = nil

        // Record any remaining time for the last observed app.
        flushCurrentAppTime()

        let endTime = Date()
        let totalSeconds = endTime.timeIntervalSince(session.startTime)
        let totalMinutes = Int(totalSeconds / 60)

        // Calculate focused minutes (total minus distraction app time).
        let distractionSeconds = appUsageSeconds
            .filter { isDistraction($0.key) }
            .values
            .reduce(0, +)
        let focusedSeconds = max(0, totalSeconds - distractionSeconds)
        let focusedMinutes = Int(focusedSeconds / 60)

        // Build top apps dictionary (seconds -> minutes, drop zero).
        var topApps: [String: Int] = [:]
        for (app, seconds) in appUsageSeconds {
            let minutes = Int(seconds / 60)
            if minutes > 0 {
                topApps[app] = minutes
            }
        }

        let summary = FocusSessionSummary(
            task: session.task,
            startTime: session.startTime,
            endTime: endTime,
            totalMinutes: totalMinutes,
            focusedMinutes: focusedMinutes,
            topApps: topApps,
            distractionCount: distractionCount,
            plannedDurationMinutes: session.durationMinutes
        )

        // Store for today.
        todaySessions.append(summary)

        // Update streak.
        updateStreak()

        // Reset state.
        activeSessionInfo = nil
        appUsageSeconds = [:]
        lastObservedApp = nil
        lastObserveTime = nil
        distractionStartTime = nil
        currentDistractionApp = nil
        distractionAlertFired = false
        distractionCount = 0

        onSessionEnd?(summary)

        return summary
    }

    // MARK: - App observation

    /// Call this regularly (e.g., every few seconds) with the currently active app name.
    func observe(activeApp: String) {
        guard isInSession else { return }

        let now = Date()

        // Accumulate time for the previous app.
        if let lastApp = lastObservedApp, let lastTime = lastObserveTime {
            let elapsed = now.timeIntervalSince(lastTime)
            appUsageSeconds[lastApp, default: 0] += elapsed
        }

        // Distraction detection.
        if isDistraction(activeApp) {
            if currentDistractionApp == activeApp {
                // Still on the same distraction app -- check if 2 minutes have passed.
                if !distractionAlertFired,
                   let start = distractionStartTime,
                   now.timeIntervalSince(start) >= 120 {
                    distractionAlertFired = true
                    distractionCount += 1
                    let sessionMinutes = activeSessionInfo?.elapsedMinutes ?? 0
                    onDistraction?(activeApp, sessionMinutes)
                }
            } else {
                // Switched to a different distraction app (or first distraction).
                currentDistractionApp = activeApp
                distractionStartTime = now
                distractionAlertFired = false
            }
        } else {
            // Not a distraction app -- reset distraction tracking.
            currentDistractionApp = nil
            distractionStartTime = nil
            distractionAlertFired = false
        }

        lastObservedApp = activeApp
        lastObserveTime = now
    }

    // MARK: - Gentle distraction message

    /// Returns a gentle, non-judgmental reminder message for a distraction.
    static func gentleReminder(task: String, distractionApp: String, minutesInSession: Int) -> String {
        let timeDescription: String
        if minutesInSession < 1 {
            timeDescription = "just started"
        } else if minutesInSession == 1 {
            timeDescription = "1 min into"
        } else {
            timeDescription = "\(minutesInSession) min into"
        }

        let appLower = distractionApp.lowercased()

        let messages = [
            "you're \(timeDescription) your \(task) focus. still want to be on \(appLower)?",
            "hey, you've been on \(appLower) for a couple minutes. your \(task) session is still running.",
            "gentle nudge -- \(appLower) pulled you away from \(task). want to come back?",
            "no judgment, but \(appLower) has had you for 2 min now. \(task) is waiting whenever you're ready.",
            "your \(task) focus is still going. \(appLower) can wait if you want it to."
        ]

        // Deterministic pick based on minutes so it varies across a session
        // but stays stable for the same observation window.
        let index = minutesInSession % messages.count
        return messages[index]
    }

    // MARK: - Private helpers

    private func isDistraction(_ appName: String) -> Bool {
        let normalized = appName.lowercased()
        return distractionApps.contains { $0.lowercased() == normalized }
    }

    private func flushCurrentAppTime() {
        guard let lastApp = lastObservedApp, let lastTime = lastObserveTime else { return }
        let elapsed = Date().timeIntervalSince(lastTime)
        appUsageSeconds[lastApp, default: 0] += elapsed
        lastObserveTime = Date()
    }

    private func autoEnd() {
        guard isInSession else { return }
        _ = endSession()
    }

    private func updateStreak() {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())

        if let lastDateRaw = UserDefaults.standard.object(forKey: DefaultsKey.lastSessionDate) as? Date {
            let lastDate = calendar.startOfDay(for: lastDateRaw)

            if lastDate == today {
                // Already recorded today -- streak stays the same.
                return
            }

            let yesterday = calendar.date(byAdding: .day, value: -1, to: today)!
            if lastDate == yesterday {
                // Consecutive day -- increment streak.
                currentStreak += 1
            } else {
                // Gap in days -- reset streak to 1.
                currentStreak = 1
            }
        } else {
            // First ever session.
            currentStreak = 1
        }

        UserDefaults.standard.set(today, forKey: DefaultsKey.lastSessionDate)
    }
}
