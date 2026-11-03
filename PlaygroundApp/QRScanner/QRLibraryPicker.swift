import PhotosUI
import SwiftUI
import UIKit

/// Photo-library route into the same detection path as the camera, so the whole flow stays
/// exercisable in the Simulator — which has no capture device at all.
///
/// `PHPickerViewController` runs out of process and needs no photo-library usage description.
struct QRLibraryPicker: UIViewControllerRepresentable {
    let onPick: (UIImage, String?) -> Void
    /// Called whether or not something was picked. The sheet is driven by SwiftUI state, so
    /// dismissing the picker here instead would leave that state stuck `true` and every later
    /// "Pick Photo" tap would do nothing — which is what made re-picking the same image fail.
    let onFinish: () -> Void

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var config = PHPickerConfiguration()
        config.filter = .images
        config.selectionLimit = 1

        let picker = PHPickerViewController(configuration: config)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onPick: onPick, onFinish: onFinish)
    }

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        private let onPick: (UIImage, String?) -> Void
        private let onFinish: () -> Void

        init(onPick: @escaping (UIImage, String?) -> Void, onFinish: @escaping () -> Void) {
            self.onPick = onPick
            self.onFinish = onFinish
        }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            guard let provider = results.first?.itemProvider,
                  provider.canLoadObject(ofClass: UIImage.self)
            else {
                onFinish()
                return
            }

            let name = provider.suggestedName
            provider.loadObject(ofClass: UIImage.self) { [onPick, onFinish] object, _ in
                Task { @MainActor in
                    if let image = object as? UIImage { onPick(image, name) }
                    onFinish()
                }
            }
        }
    }
}

nonisolated enum QRLibraryImport {

    enum ImportError: LocalizedError {
        case unreadableImage
        case noQRCode
        case encodingFailed
        case saveFailed(String)

        var errorDescription: String? {
            switch self {
            case .unreadableImage: "Could not read that photo."
            case .noQRCode: "No QR code found in that photo."
            case .encodingFailed: "Could not encode that photo."
            case .saveFailed(let reason): "Could not save the capture: \(reason)"
            }
        }
    }

    /// Runs the picked image through the identical detect → encode → persist path the camera
    /// uses.
    static func makeRecord(from image: UIImage, sourceName: String? = nil) throws -> QRCaptureRecord {
        // Bake any EXIF orientation into the pixels so Vision's `.up` assumption, the stored
        // JPEG and the corner points all agree — exactly as the rotated capture connection
        // does on the camera side.
        guard let upright = upright(image).cgImage else { throw ImportError.unreadableImage }
        let started = ContinuousClock.now
        let detected = QRDetector.detect(in: upright)
        let elapsed = ContinuousClock.now - started
        let milliseconds = Double(elapsed.components.seconds) * 1000
            + Double(elapsed.components.attoseconds) / 1e15
        guard let detection = detected else { throw ImportError.noQRCode }
        // Outside the timed section, and only when a batch run asks for it.
        let arguments = ProcessInfo.processInfo.arguments
        let crosscheck = arguments.contains("-verifyRevision")
            ? QRDetector.crosscheck(detection, in: upright) : nil
        let batchRepeat = arguments.firstIndex(of: "-batchRep")
            .flatMap { arguments.indices.contains($0 + 1) ? Int(arguments[$0 + 1]) : nil }
        guard let jpeg = QRImageEncoder.jpeg(from: upright) else { throw ImportError.encodingFailed }

        let size = CGSize(width: upright.width, height: upright.height)
        let record = QRDetector.record(
            from: detection,
            imagePixelSize: size,
            source: .library,
            detectMilliseconds: milliseconds,
            sourceName: sourceName,
            revisionCrosscheck: crosscheck,
            batchRepeat: batchRepeat
        )
        do {
            return try QRCaptureStore.save(jpeg: jpeg, record: record)
        } catch {
            throw ImportError.saveFailed(error.localizedDescription)
        }
    }

    private static func upright(_ image: UIImage) -> UIImage {
        guard image.imageOrientation != .up else { return image }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: image.size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: image.size))
        }
    }
}
