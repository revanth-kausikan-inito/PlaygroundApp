import UserNotifications

final class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationDelegate()

    private override init() {
        super.init()
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        NotificationLogger.log(
            .delivery,
            "Fired while app running: \(notification.request.identifier)",
            details: [NotificationManager.deltaDescription(for: notification)]
        )
        return [.banner, .sound, .list]
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let notification = response.notification
        NotificationLogger.log(
            .delivery,
            "Tapped: \(notification.request.identifier)",
            details: [NotificationManager.deltaDescription(for: notification)]
        )
    }
}
