import SwiftUI

struct ManualSessionControlView: View {
    enum Mode {
        case start
        case stop
    }

    @Environment(\.dismiss) private var dismiss

    let mode: Mode
    let initialDate: Date
    let onConfirm: (Date) async -> Bool

    @State private var selectedDate: Date
    @State private var isSaving: Bool = false

    init(mode: Mode,
         initialDate: Date,
         onConfirm: @escaping (Date) async -> Bool) {
        self.mode = mode
        self.initialDate = initialDate
        self.onConfirm = onConfirm
        _selectedDate = State(initialValue: initialDate)
    }

    var body: some View {
        Form {
            Section {
                DatePicker("Time",
                           selection: $selectedDate,
                           in: dateRange,
                           displayedComponents: [.date, .hourAndMinute])
                    .datePickerStyle(.graphical)
            }
        }
        .navigationTitle(mode == .start ? "Start Fast" : "Stop Fast")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") {
                    dismiss()
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    Task {
                        guard !isSaving else { return }
                        isSaving = true
                        let success = await onConfirm(selectedDate)
                        isSaving = false
                        if success {
                            dismiss()
                        }
                    }
                }
                .disabled(isSaving)
            }
        }
    }

    private var dateRange: ClosedRange<Date> {
        let upperBound = Date()
        let lowerBound = Calendar.current.date(byAdding: .day, value: -14, to: upperBound) ?? upperBound.addingTimeInterval(-14 * 24 * 3600)
        return lowerBound...upperBound
    }
}

struct FastingWindowEditorView: View {
    enum Mode {
        case create(defaultType: FastingWindow.WindowType, defaultStart: Date, defaultEnd: Date)
        case edit(existing: FastingWindow)

        var isEditing: Bool {
            if case .edit = self { return true }
            return false
        }

        var title: String {
            switch self {
            case .create:
                return "New Entry"
            case .edit:
                return "Edit Entry"
            }
        }
    }

    @Environment(\.dismiss) private var dismiss

    let mode: Mode
    let onSave: (FastingWindow.WindowType, Date, Date) async -> Bool
    let onDelete: (() async -> Void)?

    @State private var selectedType: FastingWindow.WindowType
    @State private var startDate: Date
    @State private var endDate: Date
    @State private var isSaving: Bool = false
    @State private var isDeleting: Bool = false
    @State private var showValidationAlert: Bool = false

    init(mode: Mode,
         onSave: @escaping (FastingWindow.WindowType, Date, Date) async -> Bool,
         onDelete: (() async -> Void)? = nil) {
        self.mode = mode
        self.onSave = onSave
        self.onDelete = onDelete

        switch mode {
        case .create(let defaultType, let defaultStart, let defaultEnd):
            _selectedType = State(initialValue: defaultType)
            _startDate = State(initialValue: defaultStart)
            _endDate = State(initialValue: defaultEnd)
        case .edit(let existing):
            _selectedType = State(initialValue: existing.type)
            _startDate = State(initialValue: existing.startDate)
            _endDate = State(initialValue: existing.endDate)
        }
    }

    var body: some View {
        Form {
            Section("Type") {
                Picker("Window", selection: $selectedType) {
                    Text("Fasting").tag(FastingWindow.WindowType.fast)
                    Text("Eating").tag(FastingWindow.WindowType.eat)
                }
                .pickerStyle(.segmented)
            }

            Section("Timing") {
                DatePicker("Start", selection: $startDate, displayedComponents: [.date, .hourAndMinute])
                DatePicker("End", selection: $endDate, in: startDate...Date().addingTimeInterval(365 * 24 * 3600), displayedComponents: [.date, .hourAndMinute])
                if endDate < startDate {
                    Text("End time must be after start time.")
                        .font(.caption)
                        .foregroundColor(.red)
                }
            }

            if mode.isEditing, onDelete != nil {
                Section {
                    Button(role: .destructive) {
                        Task {
                            guard !isDeleting else { return }
                            isDeleting = true
                            await onDelete?()
                            isDeleting = false
                            dismiss()
                        }
                    } label: {
                        Label("Delete Entry", systemImage: "trash")
                    }
                }
            }
        }
        .navigationTitle(mode.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") {
                    dismiss()
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    Task {
                        guard !isSaving else { return }
                        guard endDate >= startDate else {
                            showValidationAlert = true
                            return
                        }
                        isSaving = true
                        let success = await onSave(selectedType, startDate, endDate)
                        isSaving = false
                        if success {
                            dismiss()
                        }
                    }
                }
                .disabled(isSaving)
            }
        }
        .alert("Please check the times", isPresented: $showValidationAlert) {
            Button("OK", role: .cancel) { }
        } message: {
            Text("The end time must be later than the start time.")
        }
    }
}

