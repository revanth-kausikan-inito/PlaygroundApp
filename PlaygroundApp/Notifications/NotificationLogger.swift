import Foundation

struct LogEntry: Codable, Identifiable {
    enum Category: String, Codable {
        case lifecycle
        case permission
        case schedule
        case delivery
        case snapshot
        case settings
        case error
    }

    let id: UUID
    let date: Date
    let category: Category
    let message: String
    let details: [String]

    init(category: Category, message: String, details: [String]) {
        self.id = UUID()
        self.date = Date()
        self.category = category
        self.message = message
        self.details = details
    }

    var timeString: String {
        LogEntry.timeFormatter.string(from: date)
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()
}

enum NotificationLogger {
    private static let key = "notif_test_log"
    private static let maxEntries = 300
    private static let lock = NSLock()

    static func log(_ category: LogEntry.Category, _ message: String, details: [String] = []) {
        lock.lock()
        defer { lock.unlock() }

        var entries = decodeEntries()
        entries.append(LogEntry(category: category, message: message, details: details))
        if entries.count > maxEntries {
            entries.removeFirst(entries.count - maxEntries)
        }
        if let data = try? JSONEncoder().encode(entries) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    static func allEntries() -> [LogEntry] {
        lock.lock()
        defer { lock.unlock() }
        return decodeEntries()
    }

    static func clear() {
        lock.lock()
        defer { lock.unlock() }
        UserDefaults.standard.removeObject(forKey: key)
    }

    static func plainText() -> String {
        allEntries()
            .map { entry in
                let header = "[\(entry.timeString)] \(entry.category.rawValue.uppercased()): \(entry.message)"
                return ([header] + entry.details.map { "    \($0)" }).joined(separator: "\n")
            }
            .joined(separator: "\n")
    }

    private static func decodeEntries() -> [LogEntry] {
        guard
            let data = UserDefaults.standard.data(forKey: key),
            let entries = try? JSONDecoder().decode([LogEntry].self, from: data)
        else {
            return []
        }
        return entries
    }
}
