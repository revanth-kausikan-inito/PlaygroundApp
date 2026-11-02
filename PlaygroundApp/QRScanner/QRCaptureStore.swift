import Foundation

/// On-disk home for QR captures: `Documents/QRCaptures/<uuid>.jpg` plus a `<uuid>.json`
/// sidecar holding the matching `QRCaptureRecord`.
///
/// Sidecars rather than the `UserDefaults`-array shape `NotificationLogger` uses: the gallery
/// is then literally the directory listing, so there is no index that can drift out of sync
/// with the files, and each capture exports as a self-contained image + JSON pair.
///
/// `nonisolated` because `save(jpeg:record:)` runs on the capture engine's video queue.
nonisolated enum QRCaptureStore {

    /// Mirrors `NotificationLogger.maxEntries` in spirit — bounded growth without asking the
    /// user to prune by hand. These are ~200 KB JPEGs, so the cap is lower.
    private static let maxCaptures = 200

    static var directoryURL: URL {
        let documents = URL.documentsDirectory
        return documents.appending(path: "QRCaptures", directoryHint: .isDirectory)
    }

    static func imageURL(for record: QRCaptureRecord) -> URL {
        directoryURL.appending(path: record.imageFileName, directoryHint: .notDirectory)
    }

    static func jsonURL(for record: QRCaptureRecord) -> URL {
        directoryURL.appending(path: "\(record.id.uuidString).json", directoryHint: .notDirectory)
    }

    /// Writes the JPEG first and the sidecar second, both atomically, so a reader never sees
    /// a record whose image is missing or half-written.
    @discardableResult
    static func save(jpeg: Data, record: QRCaptureRecord) throws -> QRCaptureRecord {
        try createDirectoryIfNeeded()
        try jpeg.write(to: imageURL(for: record), options: .atomic)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(record).write(to: jsonURL(for: record), options: .atomic)

        pruneToMostRecent(maxCaptures)
        return record
    }

    /// Newest first. Sidecars whose JPEG is missing are skipped rather than surfaced.
    static func allRecords() -> [QRCaptureRecord] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let urls = (try? FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: nil
        )) ?? []

        return urls
            .filter { $0.pathExtension == "json" }
            .compactMap { url -> QRCaptureRecord? in
                guard
                    let data = try? Data(contentsOf: url),
                    let record = try? decoder.decode(QRCaptureRecord.self, from: data),
                    FileManager.default.fileExists(atPath: imageURL(for: record).path(percentEncoded: false))
                else {
                    return nil
                }
                return record
            }
            .sorted { $0.date > $1.date }
    }

    static func delete(_ record: QRCaptureRecord) {
        try? FileManager.default.removeItem(at: imageURL(for: record))
        try? FileManager.default.removeItem(at: jsonURL(for: record))
    }

    /// Removes the whole directory rather than each pair in turn, so nothing is left behind
    /// by a sidecar that failed to decode or a JPEG whose sidecar went missing. It is
    /// recreated on the next save.
    static func deleteAll() {
        try? FileManager.default.removeItem(at: directoryURL)
    }

    private static func createDirectoryIfNeeded() throws {
        let url = directoryURL
        guard !FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else { return }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)

        // Documents/ is included in iCloud backups; a few hundred 1080p frames would bloat
        // the user's backup for no benefit, since these are throwaway test captures.
        var mutable = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? mutable.setResourceValues(values)
    }

    private static func pruneToMostRecent(_ limit: Int) {
        let records = allRecords()
        guard records.count > limit else { return }
        for record in records.dropFirst(limit) {
            delete(record)
        }
    }
}
