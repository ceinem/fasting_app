import SwiftUI

struct ScheduleView: View {
    let windows: [FastingWindow]
    let activeWindowId: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(windows) { window in
                HStack(alignment: .center, spacing: 16) {
                    Circle()
                        .fill(window.type == .fast ? Color.accentColor : Color.green.opacity(0.8))
                        .frame(width: 12, height: 12)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(window.title)
                            .font(.body.weight(window.id == activeWindowId ? .semibold : .regular))
                        Text(window.formattedInterval)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    Text(window.durationLabel)
                        .font(.caption2)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color(.tertiarySystemFill))
                        .clipShape(Capsule())
                }
                .padding(12)
                .background(window.id == activeWindowId ? Color.accentColor.opacity(0.15) : Color(.secondarySystemGroupedBackground))
                .cornerRadius(12)
            }
        }
    }
}

#Preview {
    ScheduleView(windows: FastingScheduleViewModel.preview.todayWindows,
                 activeWindowId: FastingScheduleViewModel.preview.activeWindow?.id)
    .padding()
    .background(Color(.systemGroupedBackground))
}
