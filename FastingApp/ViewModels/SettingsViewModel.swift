import Foundation

@MainActor
final class SettingsViewModel: ObservableObject {
    @Published private(set) var regimens: [FastingRegimen] = []
    @Published var errorMessage: String?

    private let store: any FastingWindowStoreProtocol

    init(store: any FastingWindowStoreProtocol = FastingWindowStore.shared) {
        self.store = store
        Task {
            await loadRegimens()
        }
    }

    func loadRegimens() async {
        do {
            regimens = try await store.fetchRegimens()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func saveRegimen(existing: FastingRegimen?,
                     name: String,
                     fastHours: Double,
                     feedHours: Double,
                     setActive: Bool) async -> Bool {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            errorMessage = "Please provide a name for the regimen."
            return false
        }

        let now = Date()
        let fastDuration = max(fastHours, 0) * 3600
        let feedDuration = max(feedHours, 0) * 3600
        let shouldActivate = setActive || (existing?.isActive ?? false)

        let regimen = FastingRegimen(id: existing?.id ?? UUID(),
                                     name: trimmedName,
                                     fastDuration: fastDuration,
                                     feedDuration: feedDuration,
                                     isActive: shouldActivate,
                                     createdAt: existing?.createdAt ?? now,
                                     updatedAt: now)

        do {
            try await store.save(regimen: regimen)
            if shouldActivate {
                try await store.setActiveRegimen(id: regimen.id)
            }
            await loadRegimens()
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func setActiveRegimen(_ regimen: FastingRegimen) async {
        do {
            try await store.setActiveRegimen(id: regimen.id)
            await loadRegimens()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func deleteRegimen(_ regimen: FastingRegimen) async {
        do {
            try await store.deleteRegimen(id: regimen.id)
            await loadRegimens()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func exportDatabase() async -> Data? {
        do {
            return try await store.exportDatabaseData()
        } catch {
            errorMessage = "Failed to export database: \(error.localizedDescription)"
            return nil
        }
    }

    func importDatabase(from url: URL) async -> Bool {
        do {
            try await store.importDatabase(from: url)
            await loadRegimens()
            return true
        } catch {
            errorMessage = "Failed to import database: \(error.localizedDescription)"
            return false
        }
    }

    func resetDatabase() async -> Bool {
        do {
            try await store.resetDatabase()
            await loadRegimens()
            return true
        } catch {
            errorMessage = "Failed to reset database: \(error.localizedDescription)"
            return false
        }
    }
}
