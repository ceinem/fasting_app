import SwiftUI

struct HistoryView: View {
    @EnvironmentObject private var viewModel: FastingScheduleViewModel
    @State private var editorMode: WindowEditorMode?

    var body: some View {
        content
            .navigationTitle("History")
            .task {
                await viewModel.refreshIfNeeded()
            }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button {
                            presentCreateWindow(of: .fast)
                        } label: {
                            Label("Add Fast Entry", systemImage: "moon.stars")
                        }

                        Button {
                            presentCreateWindow(of: .eat)
                        } label: {
                            Label("Add Eating Entry", systemImage: "fork.knife")
                        }
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .sheet(item: $editorMode) { mode in
                NavigationStack {
                    switch mode {
                    case .edit(let window):
                        FastingWindowEditorView(mode: .edit(existing: window)) { type, start, end in
                            await viewModel.updateWindow(id: window.id,
                                                          type: type,
                                                          startDate: start,
                                                          endDate: end)
                        } onDelete: {
                            await viewModel.deleteWindow(id: window.id)
                        }
                    case .create(let type, let start, let end):
                        FastingWindowEditorView(mode: .create(defaultType: type,
                                                              defaultStart: start,
                                                              defaultEnd: end)) { newType, newStart, newEnd in
                            await viewModel.createWindow(type: newType,
                                                         startDate: newStart,
                                                         endDate: newEnd)
                        }
                    }
                }
            }
    }

    @ViewBuilder
    private var content: some View {
        if viewModel.recentHistory.isEmpty {
            VStack(spacing: 12) {
                Image(systemName: "calendar.badge.clock")
                    .font(.largeTitle)
                    .foregroundColor(.secondary)
                Text("No history yet")
                    .font(.headline)
                Text("Start a fast to see your recent fasting pattern here.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(.systemGroupedBackground))
        } else {
            List {
                ForEach(viewModel.recentHistory) { section in
                    Section(section.title) {
                        ForEach(section.entries) { entry in
                            historyRow(for: entry)
                                .contextMenu {
                                    Button {
                                        openEditor(for: entry)
                                    } label: {
                                        Label("Edit", systemImage: "pencil")
                                    }

                                    Button(role: .destructive) {
                                        Task {
                                            _ = await viewModel.deleteWindow(id: entry.id)
                                        }
                                    } label: {
                                        Label("Delete", systemImage: "trash")
                                    }
                                }
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
        }
    }

    private func historyRow(for entry: FastingScheduleViewModel.HistoryEntry) -> some View {
        HStack(spacing: 12) {
            Image(systemName: viewModel.historyIcon(for: entry))
                .foregroundColor(symbolColor(for: entry))
                .frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 4) {
                Text(viewModel.historyTitle(for: entry))
                    .font(.headline)
                Text(viewModel.historyDetail(for: entry))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private func symbolColor(for entry: FastingScheduleViewModel.HistoryEntry) -> Color {
        entry.type == .fast ? .purple : .orange
    }

    private func openEditor(for entry: FastingScheduleViewModel.HistoryEntry) {
        Task {
            if let window = await viewModel.windowDetails(id: entry.id) {
                await MainActor.run {
                    editorMode = .edit(window)
                }
            }
        }
    }

    private func presentCreateWindow(of type: FastingWindow.WindowType) {
        let defaults = defaultWindowDates(for: type)
        editorMode = .create(type, defaults.start, defaults.end)
    }

    private func defaultWindowDates(for type: FastingWindow.WindowType) -> (start: Date, end: Date) {
        let now = Date()
        switch type {
        case .fast:
            let duration = max(viewModel.activeRegimen?.fastDuration ?? 16 * 3600, 3600)
            let start = now.addingTimeInterval(-duration)
            return (start, now)
        case .eat:
            let duration = max(viewModel.activeRegimen?.feedDuration ?? 8 * 3600, 1800)
            let start = now.addingTimeInterval(-duration)
            return (start, now)
        }
    }
}

private enum WindowEditorMode: Identifiable {
    case edit(FastingWindow)
    case create(FastingWindow.WindowType, Date, Date)

    var id: String {
        switch self {
        case .edit(let window):
            return "edit-\(window.id.uuidString)"
        case .create(let type, let start, _):
            return "create-\(type.rawValue)-\(start.timeIntervalSince1970)"
        }
    }
}

#Preview {
    NavigationStack {
        HistoryView()
            .environmentObject(FastingScheduleViewModel.preview)
    }
}
