import Foundation

class PersonalContext {
    static let shared = PersonalContext()

    enum WorkStyle: String, Codable {
        case deepFocus, meetings, creative, mixed
    }

    struct Profile: Codable {
        var name: String = ""
        var role: String = ""
        var workDescription: String = ""
        var healthGoals: [String] = []
        var workStyle: WorkStyle = .mixed
        var waterReminderMinutes: Int = 45
        var breakReminderMinutes: Int = 90
        var wakeTime: String = "09:00"
        var sleepTime: String = "23:00"
        var excludedApps: [String] = []
        var appUsage: [String: Int] = [:]
    }

    private(set) var profile = Profile()
    private let queue = DispatchQueue(label: "com.buddy.personalcontext")
    private let profileURL: URL

    var isOnboarded: Bool {
        !profile.name.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private init() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let buddyDir = home.appendingPathComponent(".buddy")
        profileURL = buddyDir.appendingPathComponent("profile.json")

        queue.sync {
            ensureDirectory(buddyDir)
            loadFromDisk()
        }
    }

    // MARK: - Persistence

    func load() {
        queue.sync { loadFromDisk() }
    }

    func save() {
        queue.sync { saveToDisk() }
    }

    private func loadFromDisk() {
        let fm = FileManager.default
        guard fm.fileExists(atPath: profileURL.path),
              let data = fm.contents(atPath: profileURL.path) else { return }
        do {
            profile = try JSONDecoder().decode(Profile.self, from: data)
        } catch {
            NSLog("[PersonalContext] Failed to decode profile: \(error.localizedDescription)")
        }
    }

    private func saveToDisk() {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(profile)
            try data.write(to: profileURL, options: .atomic)
        } catch {
            NSLog("[PersonalContext] Failed to save profile: \(error.localizedDescription)")
        }
    }

    private func ensureDirectory(_ url: URL) {
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            try? fm.createDirectory(at: url, withIntermediateDirectories: true)
        }
    }

    // MARK: - Profile Updates

    func update(_ block: (inout Profile) -> Void) {
        queue.sync {
            block(&profile)
            saveToDisk()
        }
    }

    func updateWorkPatterns(activeApp: String) {
        let app = activeApp.trimmingCharacters(in: .whitespaces)
        guard !app.isEmpty else { return }
        queue.sync {
            profile.appUsage[app, default: 0] += 1
            saveToDisk()
        }
    }

    // MARK: - System Prompt

    func generateSystemPromptContext() -> String {
        guard isOnboarded else { return "" }

        var parts: [String] = []
        parts.append("The user is \(profile.name)")

        if !profile.role.isEmpty {
            parts.append("who works as \(profile.role)")
        }

        if !profile.workDescription.isEmpty {
            parts.append("and describes their work as: \(profile.workDescription)")
        }

        let styleDesc: String
        switch profile.workStyle {
        case .deepFocus: styleDesc = "deep focus sessions with minimal interruptions"
        case .meetings: styleDesc = "a meeting-heavy schedule"
        case .creative: styleDesc = "creative work that benefits from flexible timing"
        case .mixed: styleDesc = "a mix of focused work, meetings, and creative tasks"
        }
        parts.append("Their typical work style involves \(styleDesc).")

        if !profile.healthGoals.isEmpty {
            parts.append("Their health goals include: \(profile.healthGoals.joined(separator: ", ")).")
        }

        parts.append("They prefer water reminders every \(profile.waterReminderMinutes) minutes and break reminders every \(profile.breakReminderMinutes) minutes.")
        parts.append("Their usual schedule is \(profile.wakeTime) to \(profile.sleepTime).")

        if !profile.appUsage.isEmpty {
            let topApps = profile.appUsage
                .sorted { $0.value > $1.value }
                .prefix(5)
                .map { $0.key }
            parts.append("Their most-used apps are: \(topApps.joined(separator: ", ")).")
        }

        return parts.joined(separator: " ")
    }
}
