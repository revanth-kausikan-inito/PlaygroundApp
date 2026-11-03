import AVFoundation
import Foundation
import Synchronization

/// Owns the capture session and runs QR detection on live video frames, publishing each
/// saved capture through an `AsyncStream`.
///
/// This is the only type in the flow that lives off the main actor. The target builds with
/// `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, so the class is marked `nonisolated` as a
/// whole: `captureOutput(_:didOutput:from:)` is a `nonisolated` protocol requirement that a
/// main-actor method cannot satisfy, and marking only that method would lock it out of the
/// class's own stored properties.
///
/// `@unchecked Sendable` holds because every mutable field is either confined to
/// `sessionQueue`, confined to `videoQueue`, or guarded by `isArmed`.
nonisolated final class QRCaptureEngine: NSObject,
                                         AVCaptureVideoDataOutputSampleBufferDelegate,
                                         @unchecked Sendable {

    enum StartError: Error {
        /// No capture device — the iOS Simulator always lands here.
        case noCamera
        case configurationFailed
    }

    let session = AVCaptureSession()

    /// Live only while a view is iterating `captureStream()`.
    private let continuation = Mutex<AsyncStream<QRCaptureRecord>.Continuation?>(nil)
    private let sessionQueue = DispatchQueue(label: "com.Inito.PlaygroundApp.qr.session")
    private let videoQueue = DispatchQueue(label: "com.Inito.PlaygroundApp.qr.video", qos: .userInitiated)
    private let videoOutput = AVCaptureVideoDataOutput()

    /// Frames are serialized on `videoQueue`, but arming happens on the main actor — so this
    /// flag is the one genuinely shared piece of state, and `Mutex` keeps the value
    /// unreachable outside the lock.
    private let isArmed = Mutex(false)

    /// `sessionQueue` only.
    private var isConfigured = false

    /// A fresh stream per call, because an `AsyncStream` can only be iterated once — and the
    /// scanner's `.task` is cancelled and restarted every time the tab is left and returned
    /// to, which would otherwise silently stop delivering captures the second time around.
    func captureStream() -> AsyncStream<QRCaptureRecord> {
        let (stream, newContinuation) = AsyncStream.makeStream(
            of: QRCaptureRecord.self,
            bufferingPolicy: .bufferingNewest(1)
        )
        continuation.withLock { existing in
            existing?.finish()
            existing = newContinuation
        }
        return stream
    }

    deinit {
        continuation.withLock { $0?.finish() }
    }

    // MARK: - Lifecycle

    /// Deliberately not `async`: `SWIFT_APPROACHABLE_CONCURRENCY` makes a `nonisolated async`
    /// function run on the *caller's* executor, which would park `startRunning()` — up to a
    /// second of work — on the main thread.
    func start() {
        sessionQueue.async { [self] in
            do {
                try configureIfNeeded()
            } catch {
                return
            }
            guard !session.isRunning else { return }
            session.startRunning()
            isArmed.withLock { $0 = true }
        }
    }

    func stop() {
        isArmed.withLock { $0 = false }
        sessionQueue.async { [self] in
            guard session.isRunning else { return }
            session.stopRunning()
        }
    }

    /// Re-enables capture after the cool-down that follows a detection.
    func arm() {
        isArmed.withLock { $0 = true }
    }

    func disarm() {
        isArmed.withLock { $0 = false }
    }

    static var hasCamera: Bool {
        AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) != nil
    }

    // MARK: - Configuration

    private func configureIfNeeded() throws {
        guard !isConfigured else { return }

        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else {
            throw StartError.noCamera
        }

        session.beginConfiguration()
        defer { session.commitConfiguration() }

        session.sessionPreset = .hd1920x1080

        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else { throw StartError.configurationFailed }
        session.addInput(input)

        videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        // Holding on to late frames stalls the whole capture pipeline.
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.setSampleBufferDelegate(self, queue: videoQueue)
        guard session.canAddOutput(videoOutput) else { throw StartError.configurationFailed }
        session.addOutput(videoOutput)

        // Rotating the connection means the buffer arrives portrait-upright, so Vision can be
        // handed `.up` and its normalized space lines up with the JPEG that gets saved.
        if let connection = videoOutput.connection(with: .video),
           connection.isVideoRotationAngleSupported(90) {
            connection.videoRotationAngle = 90
        }

        // QR codes are usually held close.
        if (try? device.lockForConfiguration()) != nil {
            if device.isAutoFocusRangeRestrictionSupported {
                device.autoFocusRangeRestriction = .near
            }
            device.unlockForConfiguration()
        }

        isConfigured = true
    }

    // MARK: - Frame handling

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard isArmed.withLock({ $0 }) else { return }
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        guard let detection = QRDetector.detect(in: pixelBuffer) else { return }

        // Test-and-clear under one lock, so exactly one frame per arming gets through even if
        // detection succeeds on several frames before the main actor reacts.
        let claimed = isArmed.withLock { armed -> Bool in
            guard armed else { return false }
            armed = false
            return true
        }
        guard claimed else { return }

        let size = CGSize(
            width: CVPixelBufferGetWidth(pixelBuffer),
            height: CVPixelBufferGetHeight(pixelBuffer)
        )

        // All synchronous, so the sample buffer is never retained past this callback.
        guard let jpeg = QRImageEncoder.jpeg(from: pixelBuffer) else { return }
        let record = QRDetector.record(from: detection, imagePixelSize: size, source: .camera)
        guard (try? QRCaptureStore.save(jpeg: jpeg, record: record)) != nil else { return }

        continuation.withLock { $0?.yield(record) }
    }
}
