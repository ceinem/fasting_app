import SwiftUI

struct ProgressRingView: View {
    let progress: Double
    let remainingText: String

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color(.tertiarySystemFill), lineWidth: 16)
            Circle()
                .trim(from: 0.0, to: min(progress, 1.0))
                .stroke(style: StrokeStyle(lineWidth: 16, lineCap: .round))
                .foregroundColor(.accentColor)
                .rotationEffect(.degrees(-90))
                .animation(.easeInOut(duration: 0.6), value: progress)

            VStack(spacing: 8) {
                Text(String(format: "%.0f%%", min(progress, 1.0) * 100))
                    .font(.system(size: 36, weight: .bold, design: .rounded))
                Text(remainingText)
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }
        }
        .frame(width: 200, height: 200)
        .padding(20)
        .background(Color(.secondarySystemGroupedBackground))
        .cornerRadius(20)
        .frame(maxWidth: .infinity)
    }
}

#Preview {
    ProgressRingView(progress: 0.65, remainingText: "6h 30m remaining")
}
