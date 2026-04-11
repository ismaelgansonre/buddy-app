import Foundation

// MARK: - StuckPattern

enum StuckPattern: String, CaseIterable {
    case sameContext       // Same app + similar title for 20+ minutes
    case rapidSwitching    // 3+ app switches in 30 seconds
    case repeatedSearch    // Same search terms appearing multiple times
    case errorVisible      // Error-related keywords in window title
}

// MARK: - StuckDetector

/// Detects when the user appears stuck while working.
///
/// Call `observe(activeApp:windowTitle:)` every ~30 seconds with the current
/// screen state. When a stuck pattern is detected, `onStuckDetected` fires
/// with the pattern type and a human-readable description.
///
/// Design principle: conservative detection. Better to miss a stuck moment
/// than to nag the user.
class StuckDetector {

    // MARK: - Public interface

    /// Callback fired when a stuck pattern is detected.
    /// Parameters: the pattern type and a human-readable description.
    var onStuckDetected: ((StuckPattern, String) -> Void)?

    /// User toggle. When `false`, `observe` is a no-op.
    var isEnabled: Bool = true

    /// Feed current screen state. Expected to be called every ~30 seconds.
    func observe(activeApp: String, windowTitle: String) {
        guard isEnabled else { return }

        let now = Date()
        let entry = Observation(timestamp: now, app: activeApp, title: windowTitle)
        appendObservation(entry)

        // Run detectors (order: cheapest / most obvious first)
        checkErrorVisible(entry)
        checkRapidSwitching(now)
        checkRepeatedSearch()
        checkSameContext(now)
    }

    /// Clear all tracking state. Useful when the user explicitly starts
    /// a new task or dismisses a stuck notification.
    func reset() {
        observations.removeAll()
        lastNotificationDate = .distantPast
    }

    // MARK: - Internal types

    private struct Observation {
        let timestamp: Date
        let app: String
        let title: String
    }

    // MARK: - Configuration (private constants)

    /// Rolling window capacity. At 30-second intervals this is 30 minutes.
    private let maxObservations = 60

    /// Minimum seconds between any two stuck notifications.
    private let cooldownSeconds: TimeInterval = 10 * 60  // 10 minutes

    /// How long in the same context before we flag it.
    private let sameContextThreshold: TimeInterval = 20 * 60  // 20 minutes

    /// Window (seconds) for counting rapid app switches.
    private let rapidSwitchWindow: TimeInterval = 30

    /// Minimum distinct apps within `rapidSwitchWindow` to trigger.
    private let rapidSwitchMinApps = 3

    /// How many times a search term must recur to count as "repeated".
    private let repeatedSearchMinCount = 3

    /// Error keywords (lowercased). Kept intentionally narrow to avoid
    /// false positives from normal window titles.
    private let errorKeywords: Set<String> = [
        "error", "exception", "failed", "crash",
        "undefined", "null", "fatal", "cannot", "denied"
    ]

    // MARK: - State

    private var observations: [Observation] = []
    private var lastNotificationDate: Date = .distantPast

    // MARK: - Observation management

    private func appendObservation(_ entry: Observation) {
        observations.append(entry)
        if observations.count > maxObservations {
            observations.removeFirst(observations.count - maxObservations)
        }
    }

    // MARK: - Detection: errorVisible

    private func checkErrorVisible(_ entry: Observation) {
        let lower = entry.title.lowercased()
        for keyword in errorKeywords {
            if lower.contains(keyword) {
                fire(
                    .errorVisible,
                    "Window title in \(entry.app) contains \"\(keyword)\": \"\(entry.title)\""
                )
                return  // One notification per observation is enough
            }
        }
    }

    // MARK: - Detection: rapidSwitching

    private func checkRapidSwitching(_ now: Date) {
        let cutoff = now.addingTimeInterval(-rapidSwitchWindow)
        let recent = observations.filter { $0.timestamp >= cutoff }

        // Count distinct apps in the window
        var apps = Set<String>()
        for obs in recent {
            apps.insert(obs.app)
        }

        guard apps.count >= rapidSwitchMinApps else { return }

        // Extra guard: require at least 3 actual switches (not just 3 apps
        // sitting in the buffer from earlier). Count consecutive app changes.
        var switches = 0
        for i in 1..<recent.count {
            if recent[i].app != recent[i - 1].app {
                switches += 1
            }
        }
        guard switches >= rapidSwitchMinApps else { return }

        let appList = apps.sorted().joined(separator: ", ")
        fire(
            .rapidSwitching,
            "Switched between \(apps.count) apps in \(Int(rapidSwitchWindow))s (\(appList))"
        )
    }

    // MARK: - Detection: repeatedSearch

    /// Extracts plausible search terms from window titles that look like
    /// browser search results or IDE search panels.
    private func checkRepeatedSearch() {
        // Collect search-like fragments from titles
        var termCounts: [String: Int] = [:]

        for obs in observations {
            let terms = extractSearchTerms(from: obs.title)
            for term in terms {
                termCounts[term, default: 0] += 1
            }
        }

        // Find any term that recurred enough times
        for (term, count) in termCounts where count >= repeatedSearchMinCount {
            fire(
                .repeatedSearch,
                "Search term \"\(term)\" appeared \(count) times in recent window titles"
            )
            return  // One is enough
        }
    }

    /// Simple heuristic: if the title contains a search separator
    /// ("- Google Search", "- Stack Overflow", "- Bing", etc.) grab
    /// the query portion. Also catches "Search: ..." patterns.
    private func extractSearchTerms(from title: String) -> [String] {
        var results: [String] = []

        let searchSuffixes = [
            " - Google Search",
            " - Search",
            " - Bing",
            " - DuckDuckGo",
            " - Stack Overflow",
            " - Google",
            " | Search",
        ]

        let lower = title.lowercased()
        for suffix in searchSuffixes {
            if lower.hasSuffix(suffix.lowercased()) {
                let end = title.index(title.endIndex, offsetBy: -suffix.count)
                let query = String(title[title.startIndex..<end])
                    .trimmingCharacters(in: .whitespaces)
                    .lowercased()
                if !query.isEmpty {
                    results.append(query)
                }
            }
        }

        // "Search: <query>" pattern (some editors, Spotlight, etc.)
        if lower.hasPrefix("search: ") || lower.hasPrefix("search results for ") {
            let separator = lower.hasPrefix("search: ") ? "search: " : "search results for "
            let query = String(title.dropFirst(separator.count))
                .trimmingCharacters(in: .whitespaces)
                .lowercased()
            if !query.isEmpty {
                results.append(query)
            }
        }

        return results
    }

    // MARK: - Detection: sameContext

    private func checkSameContext(_ now: Date) {
        guard observations.count >= 2 else { return }

        // Walk backwards from the newest observation to find how long
        // we have been in the "same context" (same app, similar title).
        let current = observations.last!
        var earliest = current.timestamp

        for obs in observations.reversed().dropFirst() {
            guard obs.app == current.app,
                  titlesAreSimilar(obs.title, current.title) else {
                break
            }
            earliest = obs.timestamp
        }

        let duration = now.timeIntervalSince(earliest)
        guard duration >= sameContextThreshold else { return }

        let minutes = Int(duration / 60)
        fire(
            .sameContext,
            "Been in \(current.app) for \(minutes)+ minutes with no meaningful change"
        )
    }

    /// Two titles are "similar" if they share the same app-level prefix
    /// or differ by very little (e.g. cursor position changed in an IDE
    /// but the file name is the same).
    private func titlesAreSimilar(_ a: String, _ b: String) -> Bool {
        if a == b { return true }

        // Compare the "significant" portion -- everything before the last
        // separator commonly used in window titles.
        let sigA = significantPrefix(of: a)
        let sigB = significantPrefix(of: b)
        if sigA == sigB && !sigA.isEmpty { return true }

        // Fallback: Jaccard similarity on words (threshold 0.7)
        let wordsA = Set(a.lowercased().split(separator: " ").map(String.init))
        let wordsB = Set(b.lowercased().split(separator: " ").map(String.init))
        guard !wordsA.isEmpty, !wordsB.isEmpty else { return false }
        let intersection = wordsA.intersection(wordsB).count
        let union = wordsA.union(wordsB).count
        return Double(intersection) / Double(union) >= 0.7
    }

    /// Returns the portion of a window title before the last " - " or " | "
    /// separator, which usually carries the document/file name.
    private func significantPrefix(of title: String) -> String {
        for sep in [" - ", " | ", " \u{2014} "] {  // dash, pipe, em-dash
            if let range = title.range(of: sep, options: .backwards) {
                return String(title[title.startIndex..<range.lowerBound])
                    .trimmingCharacters(in: .whitespaces)
            }
        }
        return title
    }

    // MARK: - Notification gate

    /// Fires the callback if cooldown has elapsed.
    private func fire(_ pattern: StuckPattern, _ description: String) {
        let now = Date()
        guard now.timeIntervalSince(lastNotificationDate) >= cooldownSeconds else { return }
        lastNotificationDate = now
        onStuckDetected?(pattern, description)
    }
}
