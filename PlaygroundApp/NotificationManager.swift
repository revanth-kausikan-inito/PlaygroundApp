import UserNotifications

enum NotificationManager {
    private static let intendedFireDateKey = "intendedFireDate"
    private static let isoFormatter = ISO8601DateFormatter()
    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    static func currentStatus() async -> UNAuthorizationStatus {
        await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    static func requestPermission() async -> Bool {
        let center = UNUserNotificationCenter.current()
        let before = await currentStatus()
        do {
            let granted = try await center.requestAuthorization(options: [.alert, .sound, .badge])
            let after = await currentStatus()
            NotificationLogger.log(
                .permission,
                "requestAuthorization returned \(granted ? "granted" : "not granted")",
                details: ["status \(statusLabel(for: before)) -> \(statusLabel(for: after))"]
            )
            return granted
        } catch {
            NotificationLogger.log(.error, "requestAuthorization threw", details: [error.localizedDescription])
            return false
        }
    }

    static func scheduleTestNotification(afterSeconds: TimeInterval) async {
        let center = UNUserNotificationCenter.current()
        let status = await currentStatus()

        let intendedFireDate = Date().addingTimeInterval(afterSeconds)
        let identifier = "test-\(timeFormatter.string(from: Date()))"

        let content = UNMutableNotificationContent()
        content.title = "Test Notification"
        content.body = "Intended for \(timeFormatter.string(from: intendedFireDate))"
        content.sound = .default
        content.userInfo = [intendedFireDateKey: isoFormatter.string(from: intendedFireDate)]

        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: afterSeconds, repeats: false)
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: trigger)

        var details: [String] = [
            "requested fire time \(timeFormatter.string(from: intendedFireDate)) (+\(Int(afterSeconds))s)",
            "authorizationStatus at add() time: \(statusLabel(for: status))",
        ]

        var addFailed = false
        do {
            // Intentionally unconditional: no authorization guard before add().
            try await center.add(request)
            details.append("add() returned without error")
        } catch {
            addFailed = true
            details.append("add() threw: \(error.localizedDescription)")
        }

        // Read the queue back from the notification daemon instead of inferring
        // anything from add() not throwing.
        let pending = await center.pendingNotificationRequests()
        let queued = pending.first { $0.identifier == identifier }
        details.append("identifier in getPendingNotificationRequests(): \(queued != nil)")
        if let nextTriggerDate = (queued?.trigger as? UNTimeIntervalNotificationTrigger)?.nextTriggerDate() {
            details.append("daemon reports nextTriggerDate \(timeFormatter.string(from: nextTriggerDate))")
        }
        details.append("getPendingNotificationRequests() count: \(pending.count)")

        NotificationLogger.log(
            addFailed ? .error : .schedule,
            "add() \(identifier)",
            details: details
        )
    }

    static func refreshSnapshot() async {
        let center = UNUserNotificationCenter.current()
        let status = await currentStatus()
        let pending = await center.pendingNotificationRequests()
        let delivered = await center.deliveredNotifications()

        var details: [String] = ["getNotificationSettings(): \(statusLabel(for: status))"]

        details.append("getPendingNotificationRequests() -> \(pending.count)")
        for request in pending {
            let fireTime = (request.trigger as? UNTimeIntervalNotificationTrigger)?
                .nextTriggerDate()
                .map { timeFormatter.string(from: $0) } ?? "no nextTriggerDate"
            details.append("  \(request.identifier) -> \(fireTime)")
        }

        details.append("getDeliveredNotifications() -> \(delivered.count)")
        for notification in delivered {
            details.append("  \(notification.request.identifier)")
            details.append("    \(deltaDescription(for: notification))")
        }

        NotificationLogger.log(
            .snapshot,
            "\(statusLabel(for: status)) - pending \(pending.count), delivered \(delivered.count)",
            details: details
        )
    }

    static func clearAllTestState() {
        let center = UNUserNotificationCenter.current()
        center.removeAllPendingNotificationRequests()
        center.removeAllDeliveredNotifications()
        NotificationLogger.clear()
        NotificationLogger.log(.lifecycle, "Cleared pending, delivered and log")
    }

    static func deltaDescription(for notification: UNNotification) -> String {
        let actual = timeFormatter.string(from: notification.date)
        guard
            let intendedString = notification.request.content.userInfo[intendedFireDateKey] as? String,
            let intendedDate = isoFormatter.date(from: intendedString)
        else {
            return "actual \(actual) (no intended time recorded)"
        }
        let delta = notification.date.timeIntervalSince(intendedDate)
        let sign = delta >= 0 ? "+" : ""
        return "intended \(timeFormatter.string(from: intendedDate)) - actual \(actual) - delta \(sign)\(String(format: "%.1f", delta))s"
    }

    static func statusLabel(for status: UNAuthorizationStatus) -> String {
        switch status {
        case .notDetermined: return "Not Determined"
        case .denied: return "Denied"
        case .authorized: return "Authorized"
        case .provisional: return "Provisional"
        case .ephemeral: return "Ephemeral"
        @unknown default: return "Unknown (\(status.rawValue))"
        }
    }
}
