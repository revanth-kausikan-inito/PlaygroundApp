import AVFoundation
import SwiftUI
import UIKit

/// Live camera preview for the scanner.
struct QRCameraPreview: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill

        // The preview connection does not inherit the app's portrait lock, so it needs the
        // same rotation the capture connection gets.
        if view.previewLayer.connection?.isVideoRotationAngleSupported(90) == true {
            view.previewLayer.connection?.videoRotationAngle = 90
        }
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {}
}

/// Backing the view with `AVCaptureVideoPreviewLayer` directly means the layer tracks the
/// view's bounds for free — no `layoutSubviews` frame-syncing.
final class PreviewView: UIView {
    override static var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }

    var previewLayer: AVCaptureVideoPreviewLayer {
        layer as! AVCaptureVideoPreviewLayer
    }
}
