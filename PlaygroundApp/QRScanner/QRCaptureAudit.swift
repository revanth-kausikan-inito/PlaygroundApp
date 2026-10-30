import CoreGraphics
import CryptoKit
import Foundation

/// Checks every stored capture against one reference capture and answers two separate
/// questions:
///
/// 1. Are all the **images** identical? Decided on the SHA-256 of the stored JPEG bytes, not
///    on payload or pixel dimensions — two different photos can share both.
/// 2. Are all the **QR corner values** identical?
///
/// There is no grouping: a single reference (the oldest capture) is compared against every
/// other capture, so the verdict covers the whole gallery rather than passing because each
/// subset happened to agree with itself.
nonisolated enum QRCaptureAudit {

    static func run(on records: [QRCaptureRecord]) -> QRCaptureAuditReport {
        let ordered = records.sorted { $0.date < $1.date }

        guard let reference = ordered.first else {
            return .empty
        }

        let referenceHash = sha256(of: reference)
        let entries = ordered.map { record -> QRCaptureAuditReport.Capture in
            let hash = record.id == reference.id ? referenceHash : sha256(of: record)
            let deviation = maxCornerDistance(reference.corners, record.corners)

            return QRCaptureAuditReport.Capture(
                id: record.id,
                capturedAt: record.date,
                imageFileName: record.imageFileName,
                // nil means the file could not be read — treated as a failure below rather
                // than quietly passing.
                imageSHA256: hash,
                imagePixelWidth: record.imagePixelWidth,
                imagePixelHeight: record.imagePixelHeight,
                payload: record.payload,
                source: record.source.rawValue,
                corners: record.corners,
                imageMatchesReference: hash != nil && hash == referenceHash,
                cornersMatchReference: deviation == 0,
                deviationPixels: deviation
            )
        }

        let others = entries.filter { $0.id != reference.id }
        let allImagesIdentical = referenceHash != nil && others.allSatisfy(\.imageMatchesReference)
        let allCornersIdentical = others.allSatisfy(\.cornersMatchReference)

        return QRCaptureAuditReport(
            generatedAt: Date(),
            captureCount: entries.count,
            comparedCount: others.count,
            referenceCaptureID: reference.id,
            allImagesIdentical: allImagesIdentical,
            distinctImageCount: Set(entries.compactMap(\.imageSHA256)).count
                + entries.filter { $0.imageSHA256 == nil }.count,
            unreadableImageCount: entries.filter { $0.imageSHA256 == nil }.count,
            allCornersIdentical: allCornersIdentical,
            distinctCornerSetCount: Set(entries.map(\.cornerFingerprint)).count,
            maxDeviationPixels: others.map(\.deviationPixels).max() ?? 0,
            allPayloadsIdentical: Set(entries.map { $0.payload ?? "<binary>" }).count <= 1,
            distinctPayloadCount: Set(entries.map { $0.payload ?? "<binary>" }).count,
            captures: entries
        )
    }

    /// Hashes the file on disk rather than anything derived, so this is a true
    /// byte-for-byte image comparison. Memory-mapped, since captures are full-resolution
    /// frames and there may be a couple of hundred of them.
    private static func sha256(of record: QRCaptureRecord) -> String? {
        let url = QRCaptureStore.imageURL(for: record)
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Largest distance between any pair of matching corners, in image pixels.
    private static func maxCornerDistance(
        _ lhs: QRCaptureRecord.Corners,
        _ rhs: QRCaptureRecord.Corners
    ) -> Double {
        zip(lhs.clockwise, rhs.clockwise)
            .map { hypot($0.x - $1.x, $0.y - $1.y) }
            .max() ?? 0
    }
}

struct QRCaptureAuditReport: Codable, Sendable {

    struct Capture: Codable, Sendable, Identifiable {
        let id: UUID
        let capturedAt: Date
        let imageFileName: String
        let imageSHA256: String?
        let imagePixelWidth: Int
        let imagePixelHeight: Int
        let payload: String?
        let source: String
        let corners: QRCaptureRecord.Corners
        let imageMatchesReference: Bool
        let cornersMatchReference: Bool
        let deviationPixels: Double

        /// Exact-value key used to count how many distinct corner sets exist.
        var cornerFingerprint: String {
            corners.clockwise.map { "\($0.x),\($0.y)" }.joined(separator: ";")
        }
    }

    let generatedAt: Date
    let captureCount: Int
    /// Captures measured against the reference — everything but the reference itself.
    let comparedCount: Int
    let referenceCaptureID: UUID?

    let allImagesIdentical: Bool
    let distinctImageCount: Int
    let unreadableImageCount: Int

    let allCornersIdentical: Bool
    let distinctCornerSetCount: Int
    let maxDeviationPixels: Double

    let allPayloadsIdentical: Bool
    let distinctPayloadCount: Int

    let captures: [Capture]

    /// The headline answer: every capture is the same image *and* reports the same corners.
    var allIdentical: Bool {
        allImagesIdentical && allCornersIdentical
    }

    var hasSomethingToCompare: Bool {
        comparedCount > 0
    }

    var headline: String {
        guard hasSomethingToCompare else { return "Nothing to compare yet" }
        if allIdentical { return "All identical" }
        if !allImagesIdentical && !allCornersIdentical { return "Images and corners differ" }
        return allImagesIdentical ? "Corners differ" : "Images differ"
    }

    var detail: String {
        guard hasSomethingToCompare else {
            return "Capture the same image at least twice and this page will compare them."
        }
        if allIdentical {
            return "All \(captureCount) captures are the same image byte for byte and report the same four corners."
        }
        return "Compared \(comparedCount) capture\(comparedCount == 1 ? "" : "s") against the oldest one."
    }

    static let empty = QRCaptureAuditReport(
        generatedAt: Date(),
        captureCount: 0,
        comparedCount: 0,
        referenceCaptureID: nil,
        allImagesIdentical: false,
        distinctImageCount: 0,
        unreadableImageCount: 0,
        allCornersIdentical: false,
        distinctCornerSetCount: 0,
        maxDeviationPixels: 0,
        allPayloadsIdentical: false,
        distinctPayloadCount: 0,
        captures: []
    )

    /// Pretty-printed and ISO-8601 dated, to be read by eye after AirDropping it off.
    func jsonData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }

    /// Writes the report where the share sheet can pick it up. A real file on disk is what
    /// makes AirDrop send a `.json` the other device can save, rather than a blob of text.
    func writeExportFile() throws -> URL {
        let stamp = QRCaptureAuditReport.filenameFormatter.string(from: generatedAt)
        let url = FileManager.default.temporaryDirectory
            .appending(path: "qr-capture-audit-\(stamp).json", directoryHint: .notDirectory)
        try jsonData().write(to: url, options: .atomic)
        return url
    }

    // Colons are legal in a file name but render as "/" in Finder, so keep it plain.
    private static let filenameFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f
    }()
}
