import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var viewModel: FastingScheduleViewModel
    @Namespace private var animation
    @State private var manualAction: ManualSessionAction?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    header
                    ProgressRingView(progress: viewModel.progress, remainingText: viewModel.remainingTimeLabel)
                        .animation(.easeInOut, value: viewModel.progress)

                    Section(header: Text("Today").font(.headline)) {
                        ScheduleView(windows: viewModel.todayWindows,
                                     activeWindowId: viewModel.activeWindow?.id)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    if let nextWindow = viewModel.nextWindowAfterActive {
                        upcomingCard(for: nextWindow)
                    }

                    Section(header: Text("Weekly Overview").font(.headline)) {
                        weekOverview
                    }
                }
                .padding()
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Intermittent Fasting")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    NavigationLink {
                        HistoryView()
                    } label: {
                        Label("History", systemImage: "clock.arrow.circlepath")
                    }
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            manualAction = .start
                        } label: {
                            Label("Start fast at…", systemImage: "clock.badge.plus")
                        }

                        if viewModel.isFasting {
                            Button {
                                manualAction = .stop
                            } label: {
                                Label("Stop fast at…", systemImage: "clock.badge.checkmark")
                            }

                            if let activeFast = viewModel.activeWindow, activeFast.type == .fast {
                                Button {
                                    Task {
                                        if let details = await viewModel.windowDetails(id: activeFast.id) {
                                            await MainActor.run {
                                                manualAction = .edit(details)
                                            }
                                        }
                                    }
                                } label: {
                                    Label("Adjust current fast…", systemImage: "slider.horizontal.3")
                                }
                            }
                        } else if let lastFast = viewModel.lastFastWindow {
                            Button {
                                Task {
                                    if let details = await viewModel.windowDetails(id: lastFast.id) {
                                        await MainActor.run {
                                            manualAction = .edit(details)
                                        }
                                    }
                                }
                            } label: {
                                Label("Adjust last fast…", systemImage: "pencil.circle")
                            }
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }

                    NavigationLink {
                        SettingsView()
                    } label: {
                        Label("Settings", systemImage: "gearshape")
                            .labelStyle(.iconOnly)
                    }

                    Button(viewModel.isFasting ? "End Fast" : "Start Fast") {
                        if viewModel.isFasting {
                            viewModel.stopFastNow()
                        } else {
                            viewModel.startFastNow()
                        }
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
        .task {
            await viewModel.refreshIfNeeded()
        }
        .sheet(item: $manualAction) { action in
            switch action {
            case .start:
                NavigationStack {
                    ManualSessionControlView(mode: .start,
                                             initialDate: Date()) { date in
                        await viewModel.startFast(at: date)
                    }
                }
            case .stop:
                NavigationStack {
                    ManualSessionControlView(mode: .stop,
                                             initialDate: defaultStopDate()) { date in
                        await viewModel.stopFast(at: date)
                    }
                }
            case .edit(let window):
                NavigationStack {
                    FastingWindowEditorView(mode: .edit(existing: window)) { type, start, end in
                        await viewModel.updateWindow(id: window.id,
                                                     type: type,
                                                     startDate: start,
                                                     endDate: end)
                    } onDelete: {
                        _ = await viewModel.deleteWindow(id: window.id)
                    }
                }
            }
        }
    }

    private func defaultStopDate() -> Date {
        guard let activeFast = viewModel.activeWindow, activeFast.type == .fast else {
            return Date()
        }
        return min(Date(), activeFast.endDate)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(viewModel.headline)
                .font(.title2.weight(.semibold))
                .matchedGeometryEffect(id: "headline", in: animation)
            Text(viewModel.subheadline)
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(.thinMaterial)
        .cornerRadius(16)
    }

    private func upcomingCard(for window: FastingWindow) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Next", systemImage: "clock.badge.exclamationmark")
                .font(.headline)
            Text(window.title)
                .font(.title3.weight(.semibold))
            Text(viewModel.intervalDescription(for: window))
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color.accentColor.opacity(0.12))
        .cornerRadius(16)
    }

    private var weekOverview: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 3), spacing: 12) {
            ForEach(viewModel.weeklySummary) { summary in
                VStack(spacing: 6) {
                    Text(summary.weekday)
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text(summary.target)
                        .font(.body.weight(.medium))
                    ProgressView(value: summary.achieved, total: 1)
                        .progressViewStyle(.linear)
                }
                .padding(12)
                .frame(maxWidth: .infinity)
                .background(Color(.secondarySystemGroupedBackground))
                .cornerRadius(12)
            }
        }
    }
}

private enum ManualSessionAction: Identifiable {
    case start
    case stop
    case edit(FastingWindow)

    var id: String {
        switch self {
        case .start:
            return "start"
        case .stop:
            return "stop"
        case .edit(let window):
            return "edit-\(window.id.uuidString)"
        }
    }
}

#Preview {
    ContentView()
        .environmentObject(FastingScheduleViewModel.preview)
}
