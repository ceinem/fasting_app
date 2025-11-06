import SwiftUI

@main
struct FastingAppApp: App {
    @StateObject private var scheduleViewModel = FastingScheduleViewModel()

    init() {
        NotificationPreferences.registerDefaults()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(scheduleViewModel)
        }
    }
}
