import Foundation

class HealthReminders {

    // MARK: - Types

    enum ReminderType: String, CaseIterable {
        case water
        case breakTime
        case posture
        case movement
        case eyeRest
    }

    // MARK: - Callback

    /// Fires when a reminder triggers. Passes the type and a friendly message.
    var onReminder: ((ReminderType, String) -> Void)?

    // MARK: - State

    private(set) var waterCount: Int = 0
    private var lastWaterTime: Date = Date()
    private var dailyWaterGoal: Int = 8 // glasses per day
    private var isRunning = false
    private var timers: [ReminderType: Timer] = [:]
    private var lastActivityDate = Date()
    private let context: PersonalContext

    // MARK: - Default Intervals (seconds)

    private static let defaultIntervals: [ReminderType: TimeInterval] = [
        .water:     45 * 60,
        .breakTime: 90 * 60,
        .posture:   30 * 60,
        .movement: 120 * 60,
        .eyeRest:   20 * 60
    ]

    // MARK: - Messages

    private let messages: [ReminderType: [String]] = [
        .water: [
            "Hydration check! Grab some water real quick.",
            "Hey, when's the last time you drank water? Go fix that.",
            "Water break. Your brain literally runs on the stuff.",
            "Quick reminder to drink some water. Future you says thanks.",
            "Hydration time. Even a few sips count."
        ],
        .breakTime: [
            "You've been going hard. Take 5?",
            "Solid work session. Step away for a minute, you've earned it.",
            "Break time. Walk around, grab a snack, stare out a window. Dealer's choice.",
            "Your focus has been locked in. Give your brain a breather.",
            "Time for a real break. Not scrolling your phone -- actually resting."
        ],
        .posture: [
            "Quick posture check! Shoulders down, back straight.",
            "Sit up straight for me. There you go.",
            "Posture reminder. Unclench your jaw while you're at it.",
            "Are you hunching? Yeah, you probably are. Fix it real quick."
        ],
        .movement: [
            "Time to stretch! Your back will thank you.",
            "You've been sitting for a while. Get up, move around a bit.",
            "Movement break. Even a quick walk to the kitchen counts.",
            "Stand up, stretch it out. Your body's been patient long enough.",
            "Get some blood flowing. A couple of stretches go a long way."
        ],
        .eyeRest: [
            "20-20-20: Look at something 20 feet away for 20 seconds.",
            "Eye break. Find something far away to stare at for a bit.",
            "Your eyes need a sec. Look away from the screen, focus on something distant.",
            "Screen break for your eyes. 20 seconds looking at something far away. Go."
        ]
    ]

    // MARK: - Health Facts

    private let healthFacts: [String] = [
        "Sitting for more than 8 hours a day with no physical activity has a similar mortality risk to smoking.",
        "Your brain is about 75% water. Even mild dehydration can affect concentration and mood.",
        "Looking at a screen for long periods reduces your blink rate by about 66%, which is why your eyes feel dry.",
        "Standing up and moving for just 2 minutes every hour can offset the effects of prolonged sitting.",
        "Good posture can improve your breathing efficiency by up to 30%.",
        "Taking regular breaks actually increases productivity. Marathon sessions do the opposite.",
        "Blue light from screens can suppress melatonin production for up to 3 hours after exposure.",
        "A 10-minute walk can boost your energy more effectively than a cup of coffee.",
        "Stretching for 5 minutes a day can reduce muscle tension and lower stress hormones.",
        "Your spine compresses about 1% over the course of a day from sitting. Stretching helps reverse that.",
        "Drinking water before meals can boost your metabolism by about 24-30% for the next hour.",
        "Your wrists and forearms do micro-movements all day while typing. Stretching them prevents repetitive strain."
    ]

    /// Chance (0-1) that a reminder also includes a random health fact.
    private let healthFactChance: Double = 0.2

    // MARK: - Init

    init(context: PersonalContext) {
        self.context = context
    }

    // MARK: - Intervals

    /// Returns the interval for a reminder type, pulling from PersonalContext where available.
    private func interval(for type: ReminderType) -> TimeInterval {
        switch type {
        case .water:
            return TimeInterval(context.profile.waterReminderMinutes) * 60
        case .breakTime:
            return TimeInterval(context.profile.breakReminderMinutes) * 60
        case .posture:
            return Self.defaultIntervals[.posture]!
        case .movement:
            return Self.defaultIntervals[.movement]!
        case .eyeRest:
            return Self.defaultIntervals[.eyeRest]!
        }
    }

    // MARK: - Start / Stop

    func start() {
        guard !isRunning else { return }
        isRunning = true
        lastActivityDate = Date()

        for type in ReminderType.allCases {
            scheduleTimer(for: type)
        }

        NSLog("[HealthReminders] Started all reminders.")
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false

        for (type, timer) in timers {
            timer.invalidate()
            timers.removeValue(forKey: type)
        }

        NSLog("[HealthReminders] Stopped all reminders.")
    }

    // MARK: - Activity Tracking

    /// Call this whenever the user is active. Resets the break timer so it
    /// counts continuous work time, not wall-clock time.
    func trackActivity() {
        lastActivityDate = Date()

        // Restart the break timer from now.
        if isRunning {
            timers[.breakTime]?.invalidate()
            scheduleTimer(for: .breakTime)
        }
    }

    // MARK: - Water Tracking

    /// Increment the daily water count. Call from a menu action or shortcut.
    func logWater() {
        waterCount += 1
        lastWaterTime = Date()
        NSLog("[HealthReminders] Water logged. Total today: \(waterCount)/\(dailyWaterGoal)")
    }

    /// How long since last water intake
    var minutesSinceLastWater: Int {
        Int(Date().timeIntervalSince(lastWaterTime) / 60)
    }

    /// Progress toward daily goal (0.0 to 1.0+)
    var waterProgress: Double {
        Double(waterCount) / Double(dailyWaterGoal)
    }

    // MARK: - Daily Reset

    /// Resets daily counters. Call at midnight or start-of-day.
    func resetDaily() {
        waterCount = 0
        lastActivityDate = Date()
        NSLog("[HealthReminders] Daily counters reset.")
    }

    // MARK: - Private Helpers

    private func scheduleTimer(for type: ReminderType) {
        let seconds = interval(for: type)
        let timer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: true) { [weak self] _ in
            self?.fireReminder(type)
        }
        timer.tolerance = seconds * 0.1  // allow ~10% drift for energy efficiency
        timers[type] = timer
    }

    private func fireReminder(_ type: ReminderType) {
        guard let pool = messages[type], !pool.isEmpty else { return }
        var message = pool.randomElement()!

        // Smart water reminders based on time and intake
        if type == .water {
            let mins = minutesSinceLastWater
            let remaining = dailyWaterGoal - waterCount
            if mins > 90 {
                message = "hey, it's been over \(mins / 60) hour\(mins >= 120 ? "s" : "") since your last water. please drink something!"
            } else if remaining <= 0 {
                message = "you hit your \(dailyWaterGoal)-glass goal today! keep sipping though."
            } else if remaining <= 2 {
                message = "almost there! just \(remaining) more glass\(remaining == 1 ? "" : "es") to hit your daily goal."
            }
            message += " (\(waterCount)/\(dailyWaterGoal) glasses today)"
        }

        // Occasionally append a health fact.
        var fullMessage = message
        if Double.random(in: 0...1) < healthFactChance {
            if let fact = healthFacts.randomElement() {
                fullMessage += "\n\nfun fact: \(fact)"
            }
        }

        NSLog("[HealthReminders] Fired \(type.rawValue): \(message)")
        onReminder?(type, fullMessage)
    }
}
