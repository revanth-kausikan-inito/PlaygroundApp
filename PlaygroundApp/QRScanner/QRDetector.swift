import CoreGraphics
import CoreImage
import CoreVideo
import ImageIO
import Synchronization
import Vision

/// The one place QR detection and corner-coordinate conversion happen, so the live-camera
/// path and the photo-library path provably run identical code.
///
/// `nonisolated` because detection runs on the capture engine's video queue.
nonisolated enum QRDetector {

    /// Both callers hand Vision an already-upright image, so the orientation is always `.up`
    /// and Vision's normalized space maps 1:1 onto the pixels being saved as JPEG. The camera
    /// achieves that by rotating its capture connection rather than by passing `.right` here —
    /// one coordinate space instead of two.
    static func detect(in pixelBuffer: CVPixelBuffer) -> VNBarcodeObservation? {
        perform { VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up, options: [:]) }
    }

    static func detect(in cgImage: CGImage) -> VNBarcodeObservation? {
        perform { VNImageRequestHandler(cgImage: cgImage, orientation: .up, options: [:]) }
    }

    /// Newest revision that actually ran, so the fallback search below happens once rather
    /// than on every frame.
    private static let workingRevision = Mutex<Int?>(nil)

    /// The revision that last ran successfully, for reporting.
    static var revisionInUse: Int? { workingRevision.withLock { $0 } }

    /// Vision's newest barcode revisions are ML-backed, and creating their inference context
    /// fails outright on some hosts — the iOS Simulator throws
    /// `VNErrorDomain` code 9, "Could not create inference context". The older revisions use
    /// the classic detector and work everywhere, and they report corners in the same
    /// normalized space, so falling back costs nothing but accuracy on hard codes.
    private static func perform(_ makeHandler: () -> VNImageRequestHandler) -> VNBarcodeObservation? {
        for revision in revisionsToTry() {
            let request = VNDetectBarcodesRequest()
            request.revision = revision
            // Set after the revision: both the symbology filter and the main speed lever,
            // since Vision then skips every other barcode detector.
            request.symbologies = [.qr]

            do {
                try makeHandler().perform([request])
            } catch {
                continue
            }

            workingRevision.withLock { $0 = revision }
            return (request.results ?? []).first { $0.symbology == .qr }
        }
        return nil
    }

    private static func revisionsToTry() -> [Int] {
        if let known = workingRevision.withLock({ $0 }) { return [known] }
        return VNDetectBarcodesRequest.supportedRevisions.sorted(by: >)
    }

    /// Vision reports corners normalized to `[0, 1]` with a **bottom-left origin, y up**,
    /// named relative to the upright image. Images, Core Graphics and SwiftUI all use a
    /// top-left origin with y down, so the y axis is flipped on the way out.
    ///
    /// `VNImagePointForNormalizedPoint` deliberately isn't used: it only scales and leaves the
    /// origin convention implicit, which is how overlays end up vertically mirrored.
    static func corners(
        from observation: VNBarcodeObservation,
        imagePixelSize size: CGSize
    ) -> QRCaptureRecord.Corners {
        func pixel(_ point: CGPoint) -> QRCaptureRecord.PixelPoint {
            QRCaptureRecord.PixelPoint(
                x: Double(point.x * size.width),
                y: Double((1 - point.y) * size.height)
            )
        }

        return QRCaptureRecord.Corners(
            topLeft: pixel(observation.topLeft),
            topRight: pixel(observation.topRight),
            bottomRight: pixel(observation.bottomRight),
            bottomLeft: pixel(observation.bottomLeft)
        )
    }

    static func record(
        from observation: VNBarcodeObservation,
        imagePixelSize size: CGSize,
        source: QRCaptureRecord.Source,
        detectMilliseconds: Double? = nil,
        sourceName: String? = nil
    ) -> QRCaptureRecord {
        QRCaptureRecord(
            imagePixelWidth: Int(size.width),
            imagePixelHeight: Int(size.height),
            payload: observation.payloadStringValue,
            symbology: observation.symbology.rawValue,
            confidence: observation.confidence,
            source: source,
            corners: corners(from: observation, imagePixelSize: size),
            detectMilliseconds: detectMilliseconds,
            visionRevision: revisionInUse,
            sourceName: sourceName
        )
    }
}

/// Shared JPEG encoder. `CIContext` is expensive to build and thread-safe to use, so exactly
/// one is kept for the lifetime of the process — building one per frame costs tens of
/// milliseconds each and collapses the capture frame rate.
nonisolated enum QRImageEncoder {

    private static let context = CIContext(options: [.useSoftwareRenderer: false])

    static func jpeg(from pixelBuffer: CVPixelBuffer, quality: Double = 0.85) -> Data? {
        jpeg(from: CIImage(cvPixelBuffer: pixelBuffer), quality: quality)
    }

    static func jpeg(from cgImage: CGImage, quality: Double = 0.85) -> Data? {
        jpeg(from: CIImage(cgImage: cgImage), quality: quality)
    }

    private static func jpeg(from image: CIImage, quality: Double) -> Data? {
        context.jpegRepresentation(
            of: image,
            colorSpace: CGColorSpaceCreateDeviceRGB(),
            options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: quality]
        )
    }
}
