import Foundation
import UserNotifications

protocol NotificationScheduling: Sendable {
    func requestAuthorizationIfNeeded() async
    func updateNotifications(for windows: [FastingWindow], leadTime: TimeInterval, referenceDate: Date) async
    func clearScheduledNotifications() async
}

final class NotificationScheduler: @unchecked Sendable, NotificationScheduling {
    static let shared = NotificationScheduler()

    private let center: UNUserNotificationCenter

    private init(center: UNUserNotificationCenter = .current()) {
        self.center = center
    }

    func requestAuthorizationIfNeeded() async {
        let settings = await notificationSettings()
        if settings.authorizationStatus == .notDetermined {
            _ = try? await requestAuthorization()
        }
    }

    func clearScheduledNotifications() async {
        let pending = await pendingRequests()
        let identifiers = pending
            .map(\.identifier)
            .filter { $0.hasPrefix(Self.identifierPrefix) }
        if !identifiers.isEmpty {
            center.removePendingNotificationRequests(withIdentifiers: identifiers)
        }
    }

    func updateNotifications(for windows: [FastingWindow],
                             leadTime: TimeInterval,
                             referenceDate: Date = Date()) async {
        guard !windows.isEmpty else {
            await clearScheduledNotifications()
            return
        }

        await requestAuthorizationIfNeeded()
        let settings = await notificationSettings()
        guard settings.authorizationStatus == .authorized
                || settings.authorizationStatus == .provisional
                || settings.authorizationStatus == .ephemeral else {
            return
        }

        let events = makeEvents(for: windows, leadTime: leadTime, referenceDate: referenceDate)
        guard !events.isEmpty else {
            await clearScheduledNotifications()
            return
        }

        let pending = await pendingRequests()
        let requestedIdentifiers = Set(events.map(\.identifier))
        let obsoleteIdentifiers = pending
            .map(\.identifier)
            .filter { $0.hasPrefix(Self.identifierPrefix) && !requestedIdentifiers.contains($0) }
        if !obsoleteIdentifiers.isEmpty {
            center.removePendingNotificationRequests(withIdentifiers: obsoleteIdentifiers)
        }

        for event in events {
            let content = UNMutableNotificationContent()
            content.title = event.title
            content.body = event.body
            content.sound = .default

            let trigger = UNCalendarNotificationTrigger(dateMatching: calendarComponents(from: event.fireDate),
                                                        repeats: false)
            let request = UNNotificationRequest(identifier: event.identifier,
                                                content: content,
                                                trigger: trigger)
            do {
                try await add(request)
            } catch {
                #if DEBUG
                print("Failed to schedule notification \(event.identifier): \(error)")
                #endif
            }
        }
    }

    // MARK: - Helpers

    private func makeEvents(for windows: [FastingWindow],
                            leadTime: TimeInterval,
                            referenceDate: Date) -> [NotificationEvent] {
        var events: [NotificationEvent] = []
        let cutoff = referenceDate
        let filteredLead = max(leadTime, 0)

        let fastWindows = windows
            .filter { $0.type == .fast }
            .sorted(by: { $0.startDate < $1.startDate })

        for window in fastWindows {
            let start = window.startDate
            let end = window.endDate

            if start > cutoff {
                let startID = Self.identifier(for: window.id, event: .startExact)
                events.append(NotificationEvent(identifier: startID,
                                                fireDate: start,
                                                title: "Start Fasting",
                                                body: "It's time to start your fast."))

                if filteredLead > 0 {
                    let reminderDate = start.addingTimeInterval(-filteredLead)
                    if reminderDate > cutoff {
                        let formatted = DateFormatter.localizedString(from: start,
                                                                      dateStyle: .none,
                                                                      timeStyle: .short)
                        let reminderID = Self.identifier(for: window.id, event: .startReminder)
                        events.append(NotificationEvent(identifier: reminderID,
                                                        fireDate: reminderDate,
                                                        title: "Fast Starting Soon",
                                                        body: "Your fast begins at \(formatted)."))
                    }
                }
            }

            if end > cutoff {
                let endID = Self.identifier(for: window.id, event: .endExact)
                events.append(NotificationEvent(identifier: endID,
                                                fireDate: end,
                                                title: "Stop Fasting",
                                                body: "You can end your fast now."))

                if filteredLead > 0 {
                    let reminderDate = end.addingTimeInterval(-filteredLead)
                    if reminderDate > cutoff {
                        let formatted = DateFormatter.localizedString(from: end,
                                                                      dateStyle: .none,
                                                                      timeStyle: .short)
                        let reminderID = Self.identifier(for: window.id, event: .endReminder)
                        events.append(NotificationEvent(identifier: reminderID,
                                                        fireDate: reminderDate,
                                                        title: "Fast Ending Soon",
                                                        body: "Your fast ends at \(formatted)."))
                    }
                }
            }
        }

        return events.sorted(by: { $0.fireDate < $1.fireDate })
    }

    private func calendarComponents(from date: Date) -> DateComponents {
        let calendar = Calendar.current
        let components: Set<Calendar.Component> = [.year, .month, .day, .hour, .minute, .second]
        return calendar.dateComponents(components, from: date)
    }

    private func notificationSettings() async -> UNNotificationSettings {
        await withCheckedContinuation { continuation in
            center.getNotificationSettings { settings in
                continuation.resume(returning: settings)
            }
        }
    }

    private func pendingRequests() async -> [UNNotificationRequest] {
        await withCheckedContinuation { continuation in
            center.getPendingNotificationRequests { requests in
                continuation.resume(returning: requests)
            }
        }
    }

    private func requestAuthorization() async throws -> Bool {
        try await withCheckedThrowingContinuation { continuation in
            center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: granted)
                }
            }
        }
    }

    private func add(_ request: UNNotificationRequest) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            center.add(request) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: ())
                }
            }
        }
    }

    private static func identifier(for windowID: UUID, event: EventKind) -> String {
        "\(identifierPrefix).\(windowID.uuidString).\(event.rawValue)"
    }

    private static let identifierPrefix = "fasting.switch"

    private enum EventKind: String {
        case startReminder
        case startExact
        case endReminder
        case endExact
    }

    private struct NotificationEvent {
        let identifier: String
        let fireDate: Date
        let title: String
        let body: String
    }
}
