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

    /// A detection plus the evidence for which Vision revision produced it.
    struct Detection {
        let observation: VNBarcodeObservation
        /// The revision set on the request that ran.
        let requestedRevision: Int
        /// Every revision this OS supports, newest first — shows whether the newest one ran.
        let supportedRevisions: [Int]

        /// The revision Vision itself stamped on the result. This is the authoritative value:
        /// it comes from the observation, not from what this code asked for.
        var observedRevision: Int { observation.requestRevision }
    }

    /// Both callers hand Vision an already-upright image, so the orientation is always `.up`
    /// and Vision's normalized space maps 1:1 onto the pixels being saved as JPEG. The camera
    /// achieves that by rotating its capture connection rather than by passing `.right` here —
    /// one coordinate space instead of two.
    static func detect(in pixelBuffer: CVPixelBuffer) -> Detection? {
        perform { VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up, options: [:]) }
    }

    static func detect(in cgImage: CGImage, forcingRevision revision: Int? = nil) -> Detection? {
        perform(forcing: revision) { VNImageRequestHandler(cgImage: cgImage, orientation: .up, options: [:]) }
    }

    /// Independent check of the reported revision: runs the same image again with the request
    /// pinned to the revision the first run reported, and requires the same payload and the
    /// same four corners to the last bit. If the reported revision were not the one that
    /// actually ran, the pinned re-run would be a different detector and would not match.
    static func crosscheck(_ first: Detection, in cgImage: CGImage) -> Bool {
        guard let again = detect(in: cgImage, forcingRevision: first.observedRevision),
              again.observedRevision == first.observedRevision
        else { return false }
        let a = first.observation, b = again.observation
        return a.payloadStringValue == b.payloadStringValue
            && a.topLeft == b.topLeft && a.topRight == b.topRight
            && a.bottomRight == b.bottomRight && a.bottomLeft == b.bottomLeft
    }

    /// Newest revision that actually ran, so the fallback search below happens once rather
    /// than on every frame.
    private static let workingRevision = Mutex<Int?>(nil)

    /// Vision's newest barcode revisions are ML-backed, and creating their inference context
    /// fails outright on some hosts — the iOS Simulator throws
    /// `VNErrorDomain` code 9, "Could not create inference context". The older revisions use
    /// the classic detector and work everywhere, and they report corners in the same
    /// normalized space, so falling back costs nothing but accuracy on hard codes.
    private static func perform(
        forcing forced: Int? = nil,
        _ makeHandler: () -> VNImageRequestHandler
    ) -> Detection? {
        let supported = VNDetectBarcodesRequest.supportedRevisions.sorted(by: >)
        for revision in forced.map({ [$0] }) ?? revisionsToTry(supported) {
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

            if forced == nil { workingRevision.withLock { $0 = revision } }
            guard let observation = (request.results ?? []).first(where: { $0.symbology == .qr }) else {
                return nil
            }
            return Detection(observation: observation, requestedRevision: revision, supportedRevisions: supported)
        }
        return nil
    }

    private static func revisionsToTry(_ supported: [Int]) -> [Int] {
        if let known = workingRevision.withLock({ $0 }) { return [known] }
        return supported
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
        from detection: Detection,
        imagePixelSize size: CGSize,
        source: QRCaptureRecord.Source,
        detectMilliseconds: Double? = nil,
        sourceName: String? = nil,
        revisionCrosscheck: Bool? = nil,
        batchRepeat: Int? = nil
    ) -> QRCaptureRecord {
        let observation = detection.observation
        return QRCaptureRecord(
            imagePixelWidth: Int(size.width),
            imagePixelHeight: Int(size.height),
            payload: observation.payloadStringValue,
            symbology: observation.symbology.rawValue,
            confidence: observation.confidence,
            source: source,
            corners: corners(from: observation, imagePixelSize: size),
            detectMilliseconds: detectMilliseconds,
            visionRevision: detection.observedRevision,
            sourceName: sourceName,
            visionRequestedRevision: detection.requestedRevision,
            visionSupportedRevisions: detection.supportedRevisions,
            visionRevisionCrosscheck: revisionCrosscheck,
            batchRepeat: batchRepeat
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
