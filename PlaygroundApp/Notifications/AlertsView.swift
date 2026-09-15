import SwiftUI
import UserNotifications
import UIKit

struct AlertsView: View {
    @Environment(\.scenePhase) private var scenePhase

    @State private var authStatus: UNAuthorizationStatus?
    @State private var logEntries: [LogEntry] = []

    var body: some View {
        NavigationStack {
            List {
                permissionSection
                testSection
                logSection
            }
            .navigationTitle("Notification Test")
        }
        .task {
            await recheckOnForeground()
        }
        // Returning from Settings resumes from background rather than relaunching,
        // so this is the transition that needs a fresh authorization check.
        .onChange(of: scenePhase) { oldPhase, newPhase in
            if oldPhase == .background, newPhase == .active {
                Task { await recheckOnForeground() }
            }
        }
    }

    private var permissionSection: some View {
        Section("Permission") {
            HStack(spacing: 8) {
                Image(systemName: statusIcon)
                    .foregroundStyle(statusColor)
                Text(statusText)
                    .font(.headline)
            }

            HStack {
                Button("Request Permission") {
                    Task {
                        _ = await NotificationManager.requestPermission()
                        await reload()
                    }
                }
                .disabled(!canRequestPermission)

                Spacer()

                Button("Go to Settings") {
                    openSettings()
                }
                .disabled(!canOpenSettings)
            }
            .buttonStyle(.bordered)

            if authStatus == .denied {
                Text("Permission is denied. iOS will not prompt again, so use Settings to change it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if let authStatus, authStatus != .notDetermined {
                Text("Permission already resolved. Use Settings to change it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var testSection: some View {
        Section("Test Notifications") {
            HStack {
                Button("Schedule +15s") {
                    Task {
                        await NotificationManager.scheduleTestNotification(afterSeconds: 15)
                        await reload()
                    }
                }
                Spacer()
                Button("Schedule +30s") {
                    Task {
                        await NotificationManager.scheduleTestNotification(afterSeconds: 30)
                        await reload()
                    }
                }
            }
            .buttonStyle(.bordered)

            HStack {
                Button("Refresh Status") {
                    Task {
                        await NotificationManager.refreshSnapshot()
                        await reload()
                    }
                }
                Spacer()
                Button("Copy Log") {
                    UIPasteboard.general.string = NotificationLogger.plainText()
                }
            }
            .buttonStyle(.bordered)

            Button("Clear All Test State", role: .destructive) {
                NotificationManager.clearAllTestState()
                Task { await reload() }
            }
            .buttonStyle(.bordered)
        }
    }

    private var logSection: some View {
        Section("Log (newest first)") {
            if logEntries.isEmpty {
                Text("No entries yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(logEntries.reversed()) { entry in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Image(systemName: icon(for: entry.category))
                                .foregroundStyle(color(for: entry.category))
                                .font(.caption)
                            Text(entry.timeString)
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(.secondary)
                            Text(entry.message)
                                .font(.caption)
                                .bold()
                        }
                        ForEach(Array(entry.details.enumerated()), id: \.offset) { _, detail in
                            Text(detail)
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                        .padding(.leading, 20)
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }

    private var statusText: String {
        guard let authStatus else { return "Checking..." }
        return NotificationManager.statusLabel(for: authStatus)
    }

    private var statusIcon: String {
        switch authStatus {
        case .authorized, .provisional: return "checkmark.circle.fill"
        case .ephemeral: return "clock.fill"
        case .denied: return "xmark.circle.fill"
        case .notDetermined: return "questionmark.circle.fill"
        default: return "circle.dotted"
        }
    }

    private var statusColor: Color {
        switch authStatus {
        case .authorized, .provisional: return .green
        case .ephemeral: return .blue
        case .denied: return .red
        case .notDetermined: return .orange
        default: return .secondary
        }
    }

    // iOS only prompts while the status is still undetermined; once denied or
    // granted, requestAuthorization() returns without showing anything.
    private var canRequestPermission: Bool {
        authStatus == .notDetermined
    }

    private var canOpenSettings: Bool {
        authStatus != nil
    }

    private func icon(for category: LogEntry.Category) -> String {
        switch category {
        case .lifecycle: return "power"
        case .permission: return "hand.raised.fill"
        case .schedule: return "calendar.badge.plus"
        case .delivery: return "bell.fill"
        case .snapshot: return "camera.viewfinder"
        case .settings: return "gearshape.fill"
        case .error: return "exclamationmark.triangle.fill"
        }
    }

    private func color(for category: LogEntry.Category) -> Color {
        switch category {
        case .lifecycle: return .gray
        case .permission: return .purple
        case .schedule: return .blue
        case .delivery: return .green
        case .snapshot: return .teal
        case .settings: return .indigo
        case .error: return .red
        }
    }

    private func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else {
            NotificationLogger.log(.error, "Could not build the Settings URL")
            Task { await reload() }
            return
        }
        UIApplication.shared.open(url, options: [:]) { success in
            NotificationLogger.log(.settings, "Opened Settings", details: ["open succeeded: \(success)"])
        }
    }

    private func recheckOnForeground() async {
        await NotificationManager.refreshSnapshot()
        await reload()
    }

    private func reload() async {
        authStatus = await NotificationManager.currentStatus()
        logEntries = NotificationLogger.allEntries()
    }
}

#Preview {
    AlertsView()
}
