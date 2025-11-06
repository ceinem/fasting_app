import Foundation

struct FastingWindow: Identifiable, Hashable, Sendable {
    enum WindowType: String {
        case fast
        case eat
    }

    let id: UUID
    let type: WindowType
    var startDate: Date
    var endDate: Date

    init(id: UUID = UUID(), type: WindowType, startDate: Date, endDate: Date) {
        self.id = id
        self.type = type
        self.startDate = startDate
        self.endDate = endDate
    }

    var title: String {
        switch type {
        case .fast:
            return "Fasting Window"
        case .eat:
            return "Eating Window"
        }
    }

    var formattedInterval: String {
        let start = Self.timeFormatter.string(from: startDate)
        let end = Self.timeFormatter.string(from: endDate)
        return "\(start) – \(end)"
    }

    var durationLabel: String {
        guard duration > 0, let value = Self.durationFormatter.string(from: duration) else {
            return "--"
        }
        return value
    }

    var duration: TimeInterval {
        max(endDate.timeIntervalSince(startDate), 0)
    }

    var interval: DateInterval {
        DateInterval(start: startDate, end: startDate.addingTimeInterval(duration))
    }

    func overlapDuration(with range: DateInterval) -> TimeInterval {
        interval.intersection(with: range)?.duration ?? 0
    }

    func contains(_ date: Date) -> Bool {
        startDate <= date && date < endDate
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter
    }()

    private static let durationFormatter: DateComponentsFormatter = {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.hour, .minute]
        formatter.unitsStyle = .abbreviated
        return formatter
    }()
}
