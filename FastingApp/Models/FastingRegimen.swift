import Foundation

struct FastingRegimen: Identifiable, Hashable, Sendable {
    let id: UUID
    var name: String
    var fastDuration: TimeInterval
    var feedDuration: TimeInterval
    var isActive: Bool
    var createdAt: Date
    var updatedAt: Date

    init(id: UUID = UUID(),
         name: String,
         fastDuration: TimeInterval,
         feedDuration: TimeInterval,
         isActive: Bool = false,
         createdAt: Date = .init(),
         updatedAt: Date = .init()) {
        self.id = id
        self.name = name
        self.fastDuration = fastDuration
        self.feedDuration = feedDuration
        self.isActive = isActive
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    var fastHours: Double {
        fastDuration / 3600
    }

    var feedHours: Double {
        feedDuration / 3600
    }

    var formattedSummary: String {
        let fast = Self.hourFormatter.string(from: fastDuration) ?? "--"
        let feed = Self.hourFormatter.string(from: feedDuration) ?? "--"
        return "\(fast) • \(feed)"
    }

    private static let hourFormatter: DateComponentsFormatter = {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.hour]
        formatter.unitsStyle = .abbreviated
        return formatter
    }()
}

