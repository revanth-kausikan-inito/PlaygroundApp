import CoreGraphics
import Foundation

/// One QR detection: the frame that was captured, and where the code sat inside it.
///
/// Corner points are stored in **image pixel coordinates with a top-left origin** — the same
/// space as the JPEG sitting next to this record on disk — so nothing downstream has to know
/// about Vision's normalized, bottom-left-origin convention.
///
/// `nonisolated` because records are built on the capture engine's video queue; the target
/// builds with `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, so without it this type and all
/// its members would be main-actor-bound.
nonisolated struct QRCaptureRecord: Codable, Identifiable, Sendable {

    struct PixelPoint: Codable, Sendable {
        let x: Double
        let y: Double

        var cgPoint: CGPoint { CGPoint(x: x, y: y) }
    }

    struct Corners: Codable, Sendable {
        let topLeft: PixelPoint
        let topRight: PixelPoint
        let bottomRight: PixelPoint
        let bottomLeft: PixelPoint

        /// Clockwise from the top-left, which is also the winding order for the overlay path.
        var clockwise: [PixelPoint] { [topLeft, topRight, bottomRight, bottomLeft] }
    }

    enum Source: String, Codable, Sendable {
        case camera
        case library
    }

    let id: UUID
    let date: Date
    /// File name only — never an absolute URL. The container path changes on reinstall and
    /// across OS updates, so a persisted absolute path is a guaranteed future bug.
    let imageFileName: String
    let imagePixelWidth: Int
    let imagePixelHeight: Int
    /// `nil` when the code carries binary rather than UTF-8 text.
    let payload: String?
    let symbology: String
    let confidence: Float
    let source: Source
    let corners: Corners
    /// Hardware model identifier of the device that took the capture, e.g. `iPhone17,1`.
    ///
    /// Optional only so that sidecars written before this field existed still decode — a
    /// synthesized `decode` uses `decodeIfPresent` for optionals, so an old capture reads
    /// back as `nil` instead of vanishing from the gallery. Read it through
    /// `deviceCodeDisplay` rather than unwrapping it at each call site.
    let deviceCode: String?

    init(
        id: UUID = UUID(),
        date: Date = Date(),
        imagePixelWidth: Int,
        imagePixelHeight: Int,
        payload: String?,
        symbology: String,
        confidence: Float,
        source: Source,
        corners: Corners,
        deviceCode: String = QRDeviceInfo.modelCode
    ) {
        self.id = id
        self.date = date
        self.imageFileName = "\(id.uuidString).jpg"
        self.imagePixelWidth = imagePixelWidth
        self.imagePixelHeight = imagePixelHeight
        self.payload = payload
        self.symbology = symbology
        self.confidence = confidence
        self.source = source
        self.corners = corners
        self.deviceCode = deviceCode
    }

    /// What to show for captures saved before the device code was recorded.
    var deviceCodeDisplay: String { deviceCode ?? "unknown device" }

    var pixelSize: CGSize {
        CGSize(width: imagePixelWidth, height: imagePixelHeight)
    }

    var timeString: String {
        QRCaptureRecord.timeFormatter.string(from: date)
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "d MMM, HH:mm:ss"
        return f
    }()
}
