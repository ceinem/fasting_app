import Foundation

enum NotificationPreferences {
    static let preSwitchLeadTimeKey = "notifications.preSwitchLeadTime"
    static let defaultLeadTime: TimeInterval = 30 * 60

    private static var defaults: UserDefaults {
        UserDefaults.standard
    }

    static func registerDefaults() {
        defaults.register(defaults: [preSwitchLeadTimeKey: defaultLeadTime])
    }

    static var preSwitchLeadTime: TimeInterval {
        get {
            let stored = defaults.double(forKey: preSwitchLeadTimeKey)
            return stored > 0 ? stored : defaultLeadTime
        }
        set {
            defaults.set(max(newValue, 0), forKey: preSwitchLeadTimeKey)
        }
    }
}
