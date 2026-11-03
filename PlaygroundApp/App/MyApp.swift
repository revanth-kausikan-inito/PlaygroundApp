import SwiftUI
import UserNotifications

@main struct MyApp: App {
    init() {
        UNUserNotificationCenter.current().delegate = NotificationDelegate.shared
        NotificationLogger.log(.lifecycle, "Cold launch")
        BatchSeeder.shared.runIfRequested()
    }

    var body: some Scene {
        WindowGroup {
            GlassTabBarScreen()
                .ignoresSafeArea()
        }
    }
}
