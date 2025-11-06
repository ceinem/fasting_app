import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @EnvironmentObject private var scheduleViewModel: FastingScheduleViewModel
    @StateObject private var viewModel = SettingsViewModel()
    @State private var isPresentingForm = false
    @State private var editingRegimen: FastingRegimen?
    @State private var defaultActiveSelection: Bool = false
    @AppStorage(NotificationPreferences.preSwitchLeadTimeKey)
    private var preSwitchLeadTimeSeconds: Double = NotificationPreferences.defaultLeadTime
    @State private var isExporting = false
    @State private var exportDocument: SQLiteDocument?
    @State private var isImporting = false
    @State private var isConfirmingReset = false
    @State private var isPerformingDatabaseOperation = false

    var body: some View {
        List {
            regimenSection
            addRegimenSection
            notificationSection
            dataManagementSection
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Settings")
        .task {
            await viewModel.loadRegimens()
        }
        .sheet(isPresented: $isPresentingForm) {
            NavigationStack {
                RegimenFormView(regimen: editingRegimen,
                                defaultActive: defaultActiveSelection,
                                onSave: { name, fastHours, feedHours, setActive in
                                    await handleSave(name: name,
                                                     fastHours: fastHours,
                                                     feedHours: feedHours,
                                                     setActive: setActive)
                                },
                                onCancel: {
                                    editingRegimen = nil
                                })
            }
        }
        .fileExporter(isPresented: $isExporting,
                      document: exportDocument ?? SQLiteDocument(data: Data(), fileName: defaultExportFilename()),
                      contentType: sqliteContentType,
                      defaultFilename: exportDocument?.fileName ?? defaultExportFilename()) { result in
            if case .failure(let error) = result {
                viewModel.errorMessage = error.localizedDescription
            }
            exportDocument = nil
        }
        .fileImporter(isPresented: $isImporting,
                      allowedContentTypes: [sqliteContentType, .data]) { result in
            switch result {
            case .success(let url):
                handleImport(from: url)
            case .failure(let error):
                viewModel.errorMessage = error.localizedDescription
            }
        }
        .confirmationDialog("Reset Database?",
                             isPresented: $isConfirmingReset,
                             titleVisibility: .visible) {
            Button("Reset", role: .destructive) {
                handleReset()
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This removes all saved fasting history and regimens. This action cannot be undone.")
        }
        .alert("Something went wrong",
               isPresented: Binding(get: { viewModel.errorMessage != nil },
                                    set: { if !$0 { viewModel.errorMessage = nil } })) {
            Button("OK", role: .cancel) {
                viewModel.errorMessage = nil
            }
        } message: {
            Text(viewModel.errorMessage ?? "")
        }
    }

    private func handleSave(name: String,
                            fastHours: Double,
                            feedHours: Double,
                            setActive: Bool) async -> Bool {
        let success = await viewModel.saveRegimen(existing: editingRegimen,
                                                  name: name,
                                                  fastHours: fastHours,
                                                  feedHours: feedHours,
                                                  setActive: setActive)
        if success {
            await scheduleViewModel.refreshState()
            editingRegimen = nil
            defaultActiveSelection = false
        }
        return success
    }

    private func regimenRow(for regimen: FastingRegimen) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(regimen.name)
                    .font(.headline)
                Text(cycleDescription(for: regimen))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Spacer()
            if regimen.isActive {
                Label("Active", systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .labelStyle(.iconOnly)
                    .foregroundColor(.accentColor)
            }
        }
        .padding(.vertical, 4)
    }

    private func cycleDescription(for regimen: FastingRegimen) -> String {
        let fastString = hourSummary(regimen.fastDuration)
        if regimen.feedDuration > 0 {
            let feedString = hourSummary(regimen.feedDuration)
            return "Fast \(fastString) · Eat \(feedString)"
        } else {
            return "Fast \(fastString)"
        }
    }

    private func hourSummary(_ duration: TimeInterval) -> String {
        let hours = duration / 3600
        if hours >= 24 {
            let days = hours / 24
            if abs(days.rounded(.towardZero) - days) < 0.001 {
                return "\(Int(hours))h (\(Int(days))d)"
            } else {
                return String(format: "%.0fh (%.1fd)", hours, days)
            }
        } else {
            return "\(Int(hours))h"
        }
    }

    @ViewBuilder
    private var regimenSection: some View {
        Section {
            if viewModel.regimens.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("No regimens yet")
                        .font(.headline)
                    Text("Create your first fasting schedule to get started.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 8)
            } else {
                ForEach(viewModel.regimens) { regimen in
                    Button {
                        Task {
                            await viewModel.setActiveRegimen(regimen)
                            await scheduleViewModel.refreshState()
                        }
                    } label: {
                        regimenRow(for: regimen)
                    }
                    .buttonStyle(.plain)
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            Task {
                                await viewModel.deleteRegimen(regimen)
                                await scheduleViewModel.refreshState()
                            }
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }

                        Button {
                            editingRegimen = regimen
                            defaultActiveSelection = regimen.isActive
                            isPresentingForm = true
                        } label: {
                            Label("Edit", systemImage: "pencil")
                        }
                        .tint(.blue)
                    }
                }
            }
        } header: {
            Text("Fasting Regimens")
        }
    }

    @ViewBuilder
    private var addRegimenSection: some View {
        Section {
            Button {
                editingRegimen = nil
                defaultActiveSelection = viewModel.regimens.isEmpty
                isPresentingForm = true
            } label: {
                Label("Add Regimen", systemImage: "plus")
            }
        } footer: {
            Text("Define fasting and eating windows, including multi-day fasts, and switch between them as your goals evolve.")
        }
    }

    @ViewBuilder
    private var notificationSection: some View {
        Section {
            Stepper(value: leadTimeBinding, in: 0...180, step: 5) {
                HStack {
                    Text("Reminder Lead Time")
                    Spacer()
                    Text(leadTimeSummary)
                        .foregroundColor(.secondary)
                }
            }

            Text("We'll remind you before and at the exact time you're due to switch between fasting and eating.")
                .font(.footnote)
                .foregroundColor(.secondary)
        } header: {
            Text("Notifications")
        }
    }

    @ViewBuilder
    private var dataManagementSection: some View {
        Section {
            Button("Export Database") {
                handleExport()
            }
            .disabled(isPerformingDatabaseOperation)

            Button("Import Database") {
                isImporting = true
            }
            .disabled(isPerformingDatabaseOperation)

            Button(role: .destructive) {
                isConfirmingReset = true
            } label: {
                Text("Reset Database")
            }
            .disabled(isPerformingDatabaseOperation)
        } header: {
            Text("Data Management")
        } footer: {
            Text("Export creates a backup of your fasting data. Import replaces the current database, and reset removes all stored fasting history and regimens.")
                .font(.footnote)
                .foregroundColor(.secondary)
        }
    }

    private var leadTimeMinutes: Int {
        max(Int((preSwitchLeadTimeSeconds / 60).rounded()), 0)
    }

    private var leadTimeSummary: String {
        switch leadTimeMinutes {
        case 0:
            return "Off"
        case 1:
            return "1 minute"
        default:
            return "\(leadTimeMinutes) minutes"
        }
    }

    private var leadTimeBinding: Binding<Int> {
        Binding {
            leadTimeMinutes
        } set: { newValue in
            let clamped = max(0, min(newValue, 180))
            preSwitchLeadTimeSeconds = Double(clamped) * 60
            Task {
                await scheduleViewModel.refreshScheduledNotifications()
            }
        }
    }

    private var sqliteContentType: UTType {
        UTType(filenameExtension: "sqlite") ?? .data
    }

    private func handleExport() {
        guard !isPerformingDatabaseOperation else { return }
        isPerformingDatabaseOperation = true
        Task {
            let data = await viewModel.exportDatabase()
            await MainActor.run {
                if let data {
                    let filename = defaultExportFilename()
                    exportDocument = SQLiteDocument(data: data, fileName: filename)
                    isExporting = true
                }
                isPerformingDatabaseOperation = false
            }
        }
    }

    private func handleImport(from url: URL) {
        guard !isPerformingDatabaseOperation else { return }
        isPerformingDatabaseOperation = true
        let accessed = url.startAccessingSecurityScopedResource()
        Task {
            defer {
                if accessed {
                    url.stopAccessingSecurityScopedResource()
                }
            }
            let success = await viewModel.importDatabase(from: url)
            if success {
                await scheduleViewModel.refreshState()
            }
            await MainActor.run {
                isPerformingDatabaseOperation = false
            }
        }
    }

    private func handleReset() {
        guard !isPerformingDatabaseOperation else { return }
        isConfirmingReset = false
        isPerformingDatabaseOperation = true
        Task {
            let success = await viewModel.resetDatabase()
            if success {
                await scheduleViewModel.refreshState()
            }
            await MainActor.run {
                isPerformingDatabaseOperation = false
            }
        }
    }

    private func defaultExportFilename() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmm"
        return "FastingApp-\(formatter.string(from: Date())).sqlite"
    }
}

private struct RegimenFormView: View {
    @Environment(\.dismiss) private var dismiss

    let regimen: FastingRegimen?
    let defaultActive: Bool
    let onSave: (String, Double, Double, Bool) async -> Bool
    let onCancel: () -> Void

    @State private var name: String
    @State private var fastHours: Double
    @State private var feedHours: Double
    @State private var setActive: Bool
    @State private var isSaving = false

    init(regimen: FastingRegimen?,
         defaultActive: Bool,
         onSave: @escaping (String, Double, Double, Bool) async -> Bool,
         onCancel: @escaping () -> Void) {
        self.regimen = regimen
        self.defaultActive = defaultActive
        self.onSave = onSave
        self.onCancel = onCancel
        _name = State(initialValue: regimen?.name ?? "")
        _fastHours = State(initialValue: max(regimen?.fastHours ?? 16, 1))
        _feedHours = State(initialValue: max(regimen?.feedHours ?? 8, 0))
        _setActive = State(initialValue: regimen?.isActive ?? defaultActive)
    }

    var body: some View {
        Form {
            Section("Details") {
                TextField("Name", text: $name)
                    .textInputAutocapitalization(.words)
                    .disableAutocorrection(true)
            }

            Section("Cycle") {
                Stepper(value: $fastHours, in: 1...240, step: 1) {
                    HStack {
                        Text("Fasting window")
                        Spacer()
                        Text(stepperLabel(for: fastHours))
                            .foregroundColor(.secondary)
                    }
                }
                Stepper(value: $feedHours, in: 0...240, step: 1) {
                    HStack {
                        Text("Eating window")
                        Spacer()
                        Text(stepperLabel(for: feedHours))
                            .foregroundColor(.secondary)
                    }
                }
                if feedHours == 0 {
                    Text("Set the eating window to zero for extended or multi-day fasts without a defined refeed period.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            Section {
                Toggle(regimen?.isActive == true ? "Keep active" : "Set as active", isOn: $setActive)
                    .disabled(regimen?.isActive == true)
            }
        }
        .navigationTitle(regimen == nil ? "New Regimen" : "Edit Regimen")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") {
                    onCancel()
                    dismiss()
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    Task {
                        guard !isSaving else { return }
                        isSaving = true
                        let success = await onSave(name.trimmingCharacters(in: .whitespacesAndNewlines),
                                                   fastHours,
                                                   feedHours,
                                                   setActive)
                        isSaving = false
                        if success {
                            dismiss()
                        }
                    }
                }
                .disabled(!canSave)
            }
        }
    }

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && fastHours >= 1
    }

    private func stepperLabel(for hours: Double) -> String {
        if hours >= 24 {
            let days = hours / 24
            if abs(days.rounded(.towardZero) - days) < 0.001 {
                return "\(Int(hours))h (\(Int(days))d)"
            } else {
                return String(format: "%.0fh (%.1fd)", hours, days)
            }
        } else {
            return "\(Int(hours))h"
        }
    }
}

#Preview {
    NavigationStack {
        SettingsView()
            .environmentObject(FastingScheduleViewModel.preview)
    }
}
