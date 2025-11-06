import Foundation
import SwiftUI

@MainActor
final class FastingScheduleViewModel: ObservableObject {
    struct DaySummary: Identifiable {
        let id = UUID()
        let weekday: String
        let target: String
        let achieved: Double
    }

    struct HistorySection: Identifiable {
        let id: Date
        let date: Date
        let title: String
        let entries: [HistoryEntry]
    }

    struct HistoryEntry: Identifiable {
        let id: UUID
        let type: FastingWindow.WindowType
        let startDate: Date
        let endDate: Date

        init(windowID: UUID, type: FastingWindow.WindowType, startDate: Date, endDate: Date) {
            self.type = type
            self.startDate = startDate
            self.endDate = endDate
            self.id = windowID
        }

        var duration: TimeInterval {
            max(endDate.timeIntervalSince(startDate), 0)
        }
    }

    @Published private(set) var todayWindows: [FastingWindow] = []
    @Published private(set) var weeklySummary: [DaySummary] = []
    @Published private(set) var activeWindow: FastingWindow?
    @Published private(set) var isFasting: Bool = false
    @Published private(set) var recentHistory: [HistorySection] = []
    @Published private(set) var activeRegimen: FastingRegimen?
    @Published private(set) var lastFastWindow: FastingWindow?

    var progress: Double {
        guard let activeWindow else { return 0 }
        let total = activeWindow.duration
        guard total > 0 else { return 0 }
        let elapsed = min(max(nowProvider().timeIntervalSince(activeWindow.startDate), 0), total)
        return elapsed / total
    }

    var remainingTimeLabel: String {
        guard let activeWindow else { return "No session in progress" }
        let now = nowProvider()
        guard now < activeWindow.endDate else { return "Window complete" }
        let remaining = activeWindow.endDate.timeIntervalSince(now)
        return Self.timeFormatter.string(from: remaining) ?? ""
    }

    var headline: String {
        isFasting ? "You're fasting" : "Feeding window"
    }

    var subheadline: String {
        guard let activeWindow else { return "Tap start to begin tracking." }
        return intervalDescription(for: activeWindow)
    }

    var nextWindowAfterActive: FastingWindow? {
        guard let activeWindow,
              let index = todayWindows.firstIndex(of: activeWindow),
              todayWindows.indices.contains(index + 1) else {
            return nil
        }
        return todayWindows[index + 1]
    }

    static let preview: FastingScheduleViewModel = {
        let now = Date()
        let windows = [
            FastingWindow(type: .fast,
                          startDate: now.addingTimeInterval(-4 * 3600),
                          endDate: now.addingTimeInterval(12 * 3600)),
            FastingWindow(type: .eat,
                          startDate: now.addingTimeInterval(12 * 3600),
                          endDate: now.addingTimeInterval(20 * 3600))
        ]
        let regimen = FastingRegimen(name: "16 · 8",
                                     fastDuration: 16 * 3600,
                                     feedDuration: 8 * 3600,
                                     isActive: true)
        let store = InMemoryFastingWindowStore(windows: windows, regimens: [regimen])
        let viewModel = FastingScheduleViewModel(store: store)
        Task { await viewModel.refreshState() }
        return viewModel
    }()

    private let calendar: Calendar
    private let nowProvider: () -> Date
    private let store: any FastingWindowStoreProtocol
    private let notificationScheduler: NotificationScheduling

    private var configuredFastDuration: TimeInterval {
        max(activeRegimen?.fastDuration ?? Self.fallbackFastingDuration, 0)
    }

    private var configuredFeedDuration: TimeInterval {
        max(activeRegimen?.feedDuration ?? Self.fallbackFeedDuration, 0)
    }

    init(calendar: Calendar = .current,
         now: @escaping () -> Date = Date.init,
         store: any FastingWindowStoreProtocol = FastingWindowStore.shared,
         notificationScheduler: NotificationScheduling = NotificationScheduler.shared) {
        self.calendar = calendar
        self.nowProvider = now
        self.store = store
        self.notificationScheduler = notificationScheduler

        let now = nowProvider()
        todayWindows = defaultDailySchedule(anchor: now)
        activeWindow = todayWindows.first(where: { $0.contains(now) })
        isFasting = activeWindow?.type == .fast

        Task {
            await refreshState()
        }
    }

    func intervalDescription(for window: FastingWindow) -> String {
        let start = Self.timeOfDayFormatter.string(from: window.startDate)
        let end = Self.timeOfDayFormatter.string(from: window.endDate)
        switch window.type {
        case .fast:
            return "Fasting from \(start) to \(end)"
        case .eat:
            return "Eating between \(start) and \(end)"
        }
    }

    func historyTitle(for entry: HistoryEntry) -> String {
        switch entry.type {
        case .fast:
            return "Fasting Window"
        case .eat:
            return "Eating Window"
        }
    }

    func historyDetail(for entry: HistoryEntry) -> String {
        let start = Self.timeOfDayFormatter.string(from: entry.startDate)
        let end = Self.timeOfDayFormatter.string(from: entry.endDate)
        if entry.duration > 0,
           let durationString = Self.timeFormatter.string(from: entry.duration) {
            return "\(start) – \(end) • \(durationString)"
        } else {
            return "\(start) – \(end)"
        }
    }

    func historyIcon(for entry: HistoryEntry) -> String {
        entry.type == .fast ? "moon.stars.fill" : "fork.knife"
    }

    func startFastNow() {
        Task { _ = await startFast(at: nowProvider()) }
    }

    func stopFastNow() {
        Task { _ = await stopFast(at: nowProvider()) }
    }

    @discardableResult
    func startFast(at startTime: Date) async -> Bool {
        let fastDuration = max(configuredFastDuration, 0)
        let feedDuration = configuredFeedDuration
        let adjustedStart = startTime

        do {
            if let active = try await store.fetchActiveWindow(at: adjustedStart) {
                switch active.type {
                case .fast:
                    if adjustedStart < active.startDate {
                        let updated = FastingWindow(id: active.id,
                                                    type: .fast,
                                                    startDate: adjustedStart,
                                                    endDate: max(active.endDate, adjustedStart.addingTimeInterval(fastDuration)))
                        try await store.save(window: updated, source: .user)
                        await refreshState()
                    }
                    return true
                case .eat:
                    let updatedEat = FastingWindow(id: active.id,
                                                   type: .eat,
                                                   startDate: active.startDate,
                                                   endDate: max(adjustedStart, active.startDate))
                    try await store.save(window: updatedEat, source: .user)
                }
            } else if let recentEat = try await store.fetchMostRecentWindow(before: adjustedStart, type: .eat),
                      recentEat.endDate > adjustedStart {
                let trimmedEat = FastingWindow(id: recentEat.id,
                                               type: .eat,
                                               startDate: recentEat.startDate,
                                               endDate: adjustedStart)
                try await store.save(window: trimmedEat, source: .user)
            }

            if let upcomingPlaceholder = try await store.fetchNextWindow(after: adjustedStart.addingTimeInterval(-3600), type: .fast),
               upcomingPlaceholder.startDate <= adjustedStart.addingTimeInterval(600) {
                let updated = FastingWindow(id: upcomingPlaceholder.id,
                                            type: .fast,
                                            startDate: adjustedStart,
                                            endDate: fastDuration > 0 ? adjustedStart.addingTimeInterval(fastDuration) : adjustedStart)
                try await store.save(window: updated, source: .user)
            } else {
                let fastWindow = FastingWindow(type: .fast,
                                               startDate: adjustedStart,
                                               endDate: fastDuration > 0 ? adjustedStart.addingTimeInterval(fastDuration) : adjustedStart)
                try await store.save(window: fastWindow, source: .user)
            }

            if feedDuration > 0 {
                try await ensurePlannedEatingWindow(afterFastStart: adjustedStart,
                                                    expectedEnd: fastDuration > 0 ? adjustedStart.addingTimeInterval(fastDuration) : adjustedStart,
                                                    feedDuration: feedDuration)
            } else {
                if let placeholderEat = try await store.fetchNextWindow(after: adjustedStart, type: .eat),
                   placeholderEat.startDate >= adjustedStart {
                    try await store.deleteWindow(id: placeholderEat.id)
                }
            }

            if fastDuration > 0,
               let overlappingFast = try await store.fetchNextWindow(after: adjustedStart.addingTimeInterval(1), type: .fast),
               overlappingFast.startDate < adjustedStart.addingTimeInterval(fastDuration) {
                try await store.deleteWindow(id: overlappingFast.id)
            }

            await refreshState()
            return true
        } catch {
            print("Failed to start fast: \(error)")
            return false
        }
    }

    @discardableResult
    func stopFast(at stopTime: Date) async -> Bool {
        let now = stopTime
        let feedDuration = configuredFeedDuration
        let fastDuration = max(configuredFastDuration, 0)

        do {
            if let fallbackFast = activeWindow, fallbackFast.type == .fast {
                let synthesizedFast = FastingWindow(id: fallbackFast.id,
                                                    type: .fast,
                                                    startDate: fallbackFast.startDate,
                                                    endDate: max(now, fallbackFast.startDate))
                try await store.save(window: synthesizedFast, source: .user)
                try await trimOverlappingFasts(at: now, keeping: synthesizedFast.id)
                try await finalizeEatingWindow(afterFast: synthesizedFast, feedDuration: feedDuration, nextFastDuration: fastDuration)
                activeWindow = nil
                isFasting = false
                await refreshState()
                return true
            }

            if let activeFast = try await store.fetchActiveWindow(at: now), activeFast.type == .fast {
                let updatedFast = FastingWindow(id: activeFast.id,
                                                type: .fast,
                                                startDate: activeFast.startDate,
                                                endDate: max(now, activeFast.startDate))
                try await store.save(window: updatedFast, source: .user)
                try await trimOverlappingFasts(at: now, keeping: updatedFast.id)
                try await finalizeEatingWindow(afterFast: updatedFast, feedDuration: feedDuration, nextFastDuration: fastDuration)
                activeWindow = nil
                isFasting = false
                await refreshState()
                return true
            }

            if let recentFast = try await store.fetchMostRecentWindow(before: now, type: .fast) {
                let updatedFast = FastingWindow(id: recentFast.id,
                                                type: .fast,
                                                startDate: recentFast.startDate,
                                                endDate: max(now, recentFast.startDate))
                try await store.save(window: updatedFast, source: .user)
                try await trimOverlappingFasts(at: now, keeping: updatedFast.id)
                try await finalizeEatingWindow(afterFast: updatedFast, feedDuration: feedDuration, nextFastDuration: fastDuration)
                activeWindow = nil
                isFasting = false
                await refreshState()
                return true
            }
            return false
        } catch {
            print("Failed to stop fast: \(error)")
            return false
        }
    }

    func updateWindow(id: UUID,
                      type: FastingWindow.WindowType,
                      startDate: Date,
                      endDate: Date) async -> Bool {
        guard endDate >= startDate else {
            return false
        }
        do {
            let updated = FastingWindow(id: id,
                                        type: type,
                                        startDate: startDate,
                                        endDate: endDate)
            try await store.save(window: updated, source: .user)
            await refreshState()
            return true
        } catch {
            print("Failed to update window: \(error)")
            return false
        }
    }

    func deleteWindow(id: UUID) async -> Bool {
        do {
            try await store.deleteWindow(id: id)
            await refreshState()
            return true
        } catch {
            print("Failed to delete window: \(error)")
            return false
        }
    }

    func createWindow(type: FastingWindow.WindowType,
                      startDate: Date,
                      endDate: Date) async -> Bool {
        guard endDate >= startDate else { return false }
        do {
            let window = FastingWindow(type: type,
                                       startDate: startDate,
                                       endDate: endDate)
            try await store.save(window: window, source: .user)
            await refreshState()
            return true
        } catch {
            print("Failed to create window: \(error)")
            return false
        }
    }

    func windowDetails(id: UUID) async -> FastingWindow? {
        do {
            return try await store.fetchWindow(id: id)
        } catch {
            print("Failed to fetch window: \(error)")
            return nil
        }
    }

    func refreshIfNeeded() async {
        await refreshState()
    }

    func refreshState() async {
        let now = nowProvider()
        let todayInterval = dayInterval(containing: now)
        async let regimenTask = loadActiveRegimen()
        var schedule = await fetchStoredWindows(in: todayInterval)
        let regimen = await regimenTask
        activeRegimen = regimen

        let fastDuration = max(regimen?.fastDuration ?? Self.fallbackFastingDuration, 0)
        let feedDuration = max(regimen?.feedDuration ?? Self.fallbackFeedDuration, 0)

        if schedule.isEmpty {
            schedule = defaultDailySchedule(anchor: now,
                                            fastDuration: fastDuration,
                                            feedDuration: feedDuration)
        }

        schedule.sort(by: { $0.startDate < $1.startDate })

        let fallbackSchedule = schedule

        async let active = fetchActiveWindow(at: now, fallback: fallbackSchedule)
        async let summary = makeWeekSummary(anchor: now,
                                            fastDuration: fastDuration,
                                            feedDuration: feedDuration)
        async let history = makeHistory(anchor: now)
        async let latestFast = fetchLatestFast(before: now)

        let resolvedActive = await active
        todayWindows = schedule
        activeWindow = resolvedActive
        isFasting = resolvedActive?.type == .fast
        weeklySummary = await summary
        recentHistory = await history
        lastFastWindow = await latestFast

        let notificationWindows = await notificationCandidates(from: schedule,
                                                               activeWindow: resolvedActive,
                                                               referenceDate: now)
        await notificationScheduler.updateNotifications(for: notificationWindows,
                                                        leadTime: NotificationPreferences.preSwitchLeadTime,
                                                        referenceDate: now)
    }

    func refreshScheduledNotifications() async {
        let now = nowProvider()
        let notificationWindows = await notificationCandidates(from: todayWindows,
                                                               activeWindow: activeWindow,
                                                               referenceDate: now)
        await notificationScheduler.updateNotifications(for: notificationWindows,
                                                        leadTime: NotificationPreferences.preSwitchLeadTime,
                                                        referenceDate: now)
    }

    // MARK: - Private

    private func handleToggleFast() async {
        let now = nowProvider()
        let fastDuration = max(configuredFastDuration, 60)
        let feedDuration = configuredFeedDuration
        do {
            if let active = try await store.fetchActiveWindow(at: now) {
                switch active.type {
                case .fast:
                    var updatedFast = active
                    updatedFast.endDate = max(now, updatedFast.startDate)
                    try await store.save(window: updatedFast, source: .user)
                    if feedDuration > 0 {
                        let eatingWindow = FastingWindow(type: .eat,
                                                         startDate: now,
                                                         endDate: now.addingTimeInterval(feedDuration))
                        try await store.save(window: eatingWindow, source: .user)
                    }
                case .eat:
                    var updatedEat = active
                    updatedEat.endDate = max(now, updatedEat.startDate)
                    try await store.save(window: updatedEat, source: .user)
                    let fastingWindow = FastingWindow(type: .fast,
                                                      startDate: now,
                                                      endDate: now.addingTimeInterval(fastDuration))
                    try await store.save(window: fastingWindow, source: .user)
                }
            } else {
                let fastingWindow = FastingWindow(type: .fast,
                                                  startDate: now,
                                                  endDate: now.addingTimeInterval(fastDuration))
                try await store.save(window: fastingWindow, source: .user)
            }
            await refreshState()
        } catch {
            print("Failed to toggle fast: \(error)")
        }
    }

    private func loadActiveRegimen() async -> FastingRegimen? {
        do {
            return try await store.fetchActiveRegimen()
        } catch {
            print("Failed to fetch active regimen: \(error)")
            return activeRegimen
        }
    }

    private func fetchActiveWindow(at date: Date, fallback schedule: [FastingWindow]) async -> FastingWindow? {
        if let storedActive = try? await store.fetchActiveWindow(at: date) {
            return storedActive
        }
        return schedule.first(where: { $0.contains(date) })
    }

    private func fetchStoredWindows(in interval: DateInterval) async -> [FastingWindow] {
        do {
            return try await store.fetchWindows(in: interval)
        } catch {
            print("Failed to fetch stored windows: \(error)")
            return []
        }
    }

    private func fetchLatestFast(before date: Date) async -> FastingWindow? {
        do {
            return try await store.fetchMostRecentWindow(before: date, type: .fast)
        } catch {
            print("Failed to fetch latest fast: \(error)")
            return nil
        }
    }

    private func ensurePlannedEatingWindow(afterFastStart start: Date,
                                           expectedEnd: Date,
                                           feedDuration: TimeInterval) async throws {
        guard feedDuration > 0 else { return }
        if let existingEat = try await store.fetchNextWindow(after: start, type: .eat),
           existingEat.startDate <= expectedEnd.addingTimeInterval(600) {
            let updatedEat = FastingWindow(id: existingEat.id,
                                           type: .eat,
                                           startDate: expectedEnd,
                                           endDate: expectedEnd.addingTimeInterval(feedDuration))
            try await store.save(window: updatedEat, source: .system)
        } else {
            let placeholder = FastingWindow(type: .eat,
                                            startDate: expectedEnd,
                                            endDate: expectedEnd.addingTimeInterval(feedDuration))
            try await store.save(window: placeholder, source: .system)
        }
    }

    private func finalizeEatingWindow(afterFast fastWindow: FastingWindow,
                                      feedDuration: TimeInterval,
                                      nextFastDuration: TimeInterval) async throws {
        let fastEnd = fastWindow.endDate
        if feedDuration > 0 {
            if let existingEat = try await store.fetchNextWindow(after: fastWindow.startDate, type: .eat),
               existingEat.startDate <= fastEnd.addingTimeInterval(600) {
                let updatedEat = FastingWindow(id: existingEat.id,
                                               type: .eat,
                                               startDate: fastEnd,
                                               endDate: fastEnd.addingTimeInterval(feedDuration))
                try await store.save(window: updatedEat, source: .user)
                try await ensureUpcomingFast(after: updatedEat.endDate, fastDuration: nextFastDuration)
                if let extraEat = try await store.fetchNextWindow(after: fastEnd.addingTimeInterval(1), type: .eat),
                   extraEat.id != updatedEat.id,
                   extraEat.startDate < updatedEat.endDate {
                    try await store.deleteWindow(id: extraEat.id)
                }
            } else {
                let eatWindow = FastingWindow(type: .eat,
                                              startDate: fastEnd,
                                              endDate: fastEnd.addingTimeInterval(feedDuration))
                try await store.save(window: eatWindow, source: .user)
                try await ensureUpcomingFast(after: eatWindow.endDate, fastDuration: nextFastDuration)
                if let extraEat = try await store.fetchNextWindow(after: fastEnd.addingTimeInterval(1), type: .eat),
                   extraEat.id != eatWindow.id,
                   extraEat.startDate < eatWindow.endDate {
                    try await store.deleteWindow(id: extraEat.id)
                }
            }
        } else {
            if let existingEat = try await store.fetchNextWindow(after: fastWindow.startDate, type: .eat) {
                try await store.deleteWindow(id: existingEat.id)
            }
            try await ensureUpcomingFast(after: fastEnd, fastDuration: nextFastDuration)
        }
    }

    private func ensureUpcomingFast(after start: Date, fastDuration: TimeInterval) async throws {
        guard fastDuration > 0 else { return }
        if let existingFast = try await store.fetchNextWindow(after: start.addingTimeInterval(-3600), type: .fast),
           existingFast.startDate <= start.addingTimeInterval(600) {
            let updatedFast = FastingWindow(id: existingFast.id,
                                            type: .fast,
                                            startDate: start,
                                            endDate: start.addingTimeInterval(fastDuration))
            try await store.save(window: updatedFast, source: .system)
        } else {
            let placeholderFast = FastingWindow(type: .fast,
                                                startDate: start,
                                                endDate: start.addingTimeInterval(fastDuration))
            try await store.save(window: placeholderFast, source: .system)
        }
    }

    private func trimOverlappingFasts(at date: Date, keeping identifier: UUID) async throws {
        let lookback = max(configuredFastDuration, 0) + 3600
        let window = DateInterval(start: date.addingTimeInterval(-lookback), end: date.addingTimeInterval(1))
        let overlapping = try await store.fetchWindows(in: window)
            .filter { $0.type == .fast && $0.id != identifier && $0.endDate > date }

        for fast in overlapping {
            if fast.startDate < date {
                let shortened = FastingWindow(id: fast.id,
                                              type: .fast,
                                              startDate: fast.startDate,
                                              endDate: date)
                try await store.save(window: shortened, source: .user)
            } else {
                try await store.deleteWindow(id: fast.id)
            }
        }
    }

    private func makeWeekSummary(anchor: Date,
                                 fastDuration: TimeInterval,
                                 feedDuration: TimeInterval) async -> [DaySummary] {
        let weekdays = calendar.shortStandaloneWeekdaySymbols
        let todayIndex = calendar.component(.weekday, from: anchor) - 1
        let startOfToday = calendar.startOfDay(for: anchor)
        guard let startOfWeek = calendar.date(byAdding: .day, value: -todayIndex, to: startOfToday),
              let endOfWeek = calendar.date(byAdding: .day, value: 7, to: startOfWeek) else {
            return []
        }

        let weekInterval = DateInterval(start: startOfWeek, end: endOfWeek)
        let fastingWindows = (try? await store.fetchWindows(in: weekInterval))?.filter { $0.type == .fast } ?? []
        let targetDuration = fastDuration > 0 ? fastDuration : Self.fallbackFastingDuration
        let targetLabel = regimenTargetLabel(fastDuration: fastDuration, feedDuration: feedDuration)

        return weekdays.enumerated().compactMap { index, symbol in
            guard let dayStart = calendar.date(byAdding: .day, value: index, to: startOfWeek),
                  let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) else {
                return nil
            }
            let interval = DateInterval(start: dayStart, end: dayEnd)
            let total = fastingWindows.reduce(0) { partial, window in
                partial + window.overlapDuration(with: interval)
            }
            let achieved: Double
            if targetDuration > 0 {
                achieved = min(max(total / targetDuration, 0), 1)
            } else {
                achieved = 0
            }
            return DaySummary(weekday: symbol,
                              target: targetLabel,
                              achieved: achieved)
        }
    }

    private func makeHistory(anchor: Date, days: Int = 7) async -> [HistorySection] {
        let clampedDays = max(days, 1)
        let startOfToday = calendar.startOfDay(for: anchor)
        guard let historyStart = calendar.date(byAdding: .day, value: -(clampedDays - 1), to: startOfToday),
              let historyEnd = calendar.date(byAdding: .day, value: 1, to: startOfToday) else {
            return []
        }

        let historyInterval = DateInterval(start: historyStart, end: historyEnd)
        let windows = (try? await store.fetchWindows(in: historyInterval)) ?? []

        let grouped = Dictionary(grouping: windows) { window in
            calendar.startOfDay(for: window.startDate)
        }

        let sortedDays = grouped.keys.sorted(by: { $0 > $1 })
        return sortedDays.map { dayStart in
            let entries = (grouped[dayStart] ?? [])
                .sorted(by: { $0.startDate < $1.startDate })
                .map { window in
                    HistoryEntry(windowID: window.id,
                                 type: window.type,
                                 startDate: window.startDate,
                                 endDate: window.endDate)
                }
            let title = Self.historyDateFormatter.string(from: dayStart)
            return HistorySection(id: dayStart,
                                  date: dayStart,
                                  title: title,
                                  entries: entries)
        }
    }

    private func regimenTargetLabel(fastDuration: TimeInterval, feedDuration: TimeInterval) -> String {
        let fastLabel = Self.hoursFormatter.string(from: max(fastDuration, 0)) ?? "--"
        guard feedDuration > 0 else {
            return fastLabel
        }
        let feedLabel = Self.hoursFormatter.string(from: feedDuration) ?? "--"
        return "\(fastLabel) · \(feedLabel)"
    }

    private func defaultDailySchedule(anchor: Date,
                                      fastDuration: TimeInterval? = nil,
                                      feedDuration: TimeInterval? = nil) -> [FastingWindow] {
        let startOfDay = calendar.startOfDay(for: anchor)
        let fastingEnd = calendar.date(bySettingHour: 12, minute: 0, second: 0, of: startOfDay) ?? startOfDay.addingTimeInterval(12 * 3600)
        let resolvedFastDuration = max(fastDuration ?? Self.fallbackFastingDuration, 0)
        let resolvedFeedDuration = max(feedDuration ?? Self.fallbackFeedDuration, 0)

        let fastStart = fastingEnd.addingTimeInterval(-resolvedFastDuration)
        var windows: [FastingWindow] = [
            FastingWindow(type: .fast, startDate: fastStart, endDate: fastingEnd)
        ]

        if resolvedFeedDuration > 0 {
            let eatingEnd = fastingEnd.addingTimeInterval(resolvedFeedDuration)
            windows.append(FastingWindow(type: .eat, startDate: fastingEnd, endDate: eatingEnd))
        }

        return windows
    }

    private func dayInterval(containing date: Date) -> DateInterval {
        let start = calendar.startOfDay(for: date)
        let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start
        return DateInterval(start: start, end: end)
    }

    private static let fallbackFastingDuration: TimeInterval = 16 * 3600
    private static let fallbackFeedDuration: TimeInterval = 8 * 3600

    private static let timeFormatter: DateComponentsFormatter = {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.hour, .minute]
        formatter.unitsStyle = .abbreviated
        return formatter
    }()

    private static let timeOfDayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        return formatter
    }()

    private static let hoursFormatter: DateComponentsFormatter = {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.hour]
        formatter.unitsStyle = .abbreviated
        return formatter
    }()

    private static let historyDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()

    private func notificationCandidates(from schedule: [FastingWindow],
                                        activeWindow: FastingWindow?,
                                        referenceDate: Date,
                                        limit: Int = 6) async -> [FastingWindow] {
        var candidates: [UUID: FastingWindow] = [:]

        if let activeWindow, activeWindow.type == .fast {
            candidates[activeWindow.id] = activeWindow
        }

        for window in schedule where window.type == .fast {
            candidates[window.id] = window
        }

        var cursor = referenceDate
        var attempts = 0
        while candidates.count < limit && attempts < limit * 2 {
            guard let nextFast = try? await store.fetchNextWindow(after: cursor, type: .fast) else {
                break
            }
            if candidates[nextFast.id] == nil {
                candidates[nextFast.id] = nextFast
            }
            cursor = nextFast.endDate.addingTimeInterval(1)
            attempts += 1
        }

        return candidates.values.sorted(by: { $0.startDate < $1.startDate })
    }
}

actor InMemoryFastingWindowStore: FastingWindowStoreProtocol {
    private var windowStorage: [UUID: (window: FastingWindow, note: String?, source: FastingWindowSource)]
    private var regimenStorage: [UUID: FastingRegimen]

    init(windows: [FastingWindow] = [], regimens: [FastingRegimen]? = nil) {
        self.windowStorage = Dictionary(uniqueKeysWithValues: windows.map { ($0.id, ($0, nil, .user)) })

        if let regimens, !regimens.isEmpty {
            var storage: [UUID: FastingRegimen] = [:]
            var hasActive = false
            for regimen in regimens {
                storage[regimen.id] = regimen
                hasActive = hasActive || regimen.isActive
            }
            if !hasActive, var first = regimens.first {
                first.isActive = true
                first.updatedAt = Date()
                storage[first.id] = first
            }
            self.regimenStorage = storage
        } else {
            let defaultRegimen = FastingRegimen(name: "Standard 16 · 8",
                                                fastDuration: 16 * 3600,
                                                feedDuration: 8 * 3600,
                                                isActive: true)
            self.regimenStorage = [defaultRegimen.id: defaultRegimen]
        }
    }

    func fetchWindows(in interval: DateInterval) async throws -> [FastingWindow] {
        windowStorage.values
            .map(\.window)
            .filter { $0.interval.intersects(interval) }
            .sorted(by: { $0.startDate < $1.startDate })
    }

    func fetchActiveWindow(at date: Date) async throws -> FastingWindow? {
        windowStorage.values
            .map(\.window)
            .first(where: { $0.contains(date) })
    }

    func fetchWindow(id: UUID) async throws -> FastingWindow? {
        windowStorage[id]?.window
    }

    func fetchMostRecentWindow(before date: Date, type: FastingWindow.WindowType?) async throws -> FastingWindow? {
        windowStorage.values
            .map(\.window)
            .filter { type == nil || $0.type == type }
            .filter { $0.startDate <= date }
            .sorted(by: { $0.startDate > $1.startDate })
            .first
    }

    func fetchNextWindow(after date: Date, type: FastingWindow.WindowType?) async throws -> FastingWindow? {
        windowStorage.values
            .map(\.window)
            .filter { $0.startDate >= date }
            .filter { type == nil || $0.type == type }
            .sorted(by: { $0.startDate < $1.startDate })
            .first
    }

    func save(window: FastingWindow, note: String?, source: FastingWindowSource) async throws {
        windowStorage[window.id] = (window, note, source)
    }

    func deleteWindow(id: UUID) async throws {
        windowStorage.removeValue(forKey: id)
    }

    func exportDatabaseData() async throws -> Data {
        Data()
    }

    func importDatabase(from url: URL) async throws {
        // No-op for the in-memory store.
    }

    func resetDatabase() async throws {
        windowStorage.removeAll()
        regimenStorage.removeAll()
        let defaultRegimen = FastingRegimen(name: "Standard 16 · 8",
                                            fastDuration: 16 * 3600,
                                            feedDuration: 8 * 3600,
                                            isActive: true)
        regimenStorage[defaultRegimen.id] = defaultRegimen
    }

    func fetchRegimens() async throws -> [FastingRegimen] {
        regimenStorage.values.sorted(by: { $0.createdAt < $1.createdAt })
    }

    func fetchActiveRegimen() async throws -> FastingRegimen? {
        if let active = regimenStorage.values.first(where: { $0.isActive }) {
            return active
        }
        if var first = regimenStorage.values.sorted(by: { $0.createdAt < $1.createdAt }).first {
            first.isActive = true
            first.updatedAt = Date()
            regimenStorage[first.id] = first
            return first
        }
        let defaultRegimen = FastingRegimen(name: "Standard 16 · 8",
                                            fastDuration: 16 * 3600,
                                            feedDuration: 8 * 3600,
                                            isActive: true)
        regimenStorage[defaultRegimen.id] = defaultRegimen
        return defaultRegimen
    }

    func save(regimen: FastingRegimen) async throws {
        regimenStorage[regimen.id] = regimen
        if regimen.isActive {
            try await setActiveRegimen(id: regimen.id)
        }
    }

    func deleteRegimen(id: UUID) async throws {
        regimenStorage.removeValue(forKey: id)
        if regimenStorage.isEmpty {
            let defaultRegimen = FastingRegimen(name: "Standard 16 · 8",
                                                fastDuration: 16 * 3600,
                                                feedDuration: 8 * 3600,
                                                isActive: true)
            regimenStorage[defaultRegimen.id] = defaultRegimen
        }
        if regimenStorage.values.contains(where: { $0.isActive }) == false {
            if let first = regimenStorage.values.sorted(by: { $0.createdAt < $1.createdAt }).first {
                try await setActiveRegimen(id: first.id)
            }
        }
    }

    func setActiveRegimen(id: UUID?) async throws {
        let now = Date()
        if let id, regimenStorage[id] == nil {
            return
        }
        var updatedStorage: [UUID: FastingRegimen] = [:]
        for (key, var regimen) in regimenStorage {
            regimen.isActive = (id != nil && key == id)
            regimen.updatedAt = now
            updatedStorage[key] = regimen
        }
        regimenStorage = updatedStorage

        if let id {
            if var regimen = regimenStorage[id] {
                regimen.isActive = true
                regimen.updatedAt = now
                regimenStorage[id] = regimen
            }
        } else if let first = regimenStorage.values.sorted(by: { $0.createdAt < $1.createdAt }).first {
            var updated = first
            updated.isActive = true
            updated.updatedAt = now
            regimenStorage[updated.id] = updated
        }
    }
}
