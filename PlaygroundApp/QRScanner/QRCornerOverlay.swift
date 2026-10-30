import AVFoundation
import SwiftUI

/// Draws a record's stored corner points back over the frame they came from.
///
/// This is the whole point of keeping the corners: if the quad tracks a rotated code and the
/// TL dot sits on the code's real top-left, the normalized → pixel conversion in `QRDetector`
/// is right. If it is 90° out or mirrored, it is not.
struct QRCornerOverlay: View {
    let record: QRCaptureRecord
    var stroke: Color = .green
    var showsLabels: Bool = true
    /// Must match how the underlying image is displayed: `.fit` for the gallery detail,
    /// `.fill` for the live preview, which uses `.resizeAspectFill`.
    var contentMode: ContentMode = .fit

    private var labelledCorners: [(name: String, point: QRCaptureRecord.PixelPoint, color: Color)] {
        [
            ("TL", record.corners.topLeft, .green),
            ("TR", record.corners.topRight, .yellow),
            ("BR", record.corners.bottomRight, .orange),
            ("BL", record.corners.bottomLeft, .cyan),
        ]
    }

    var body: some View {
        GeometryReader { proxy in
            let frame = displayRect(in: proxy.size)

            ZStack {
                Path { path in
                    let points = record.corners.clockwise.map { place($0, in: frame) }
                    guard let first = points.first else { return }
                    path.move(to: first)
                    for point in points.dropFirst() { path.addLine(to: point) }
                    path.closeSubpath()
                }
                .stroke(stroke, style: StrokeStyle(lineWidth: 2.5, lineJoin: .round))

                if showsLabels {
                    ForEach(labelledCorners, id: \.name) { corner in
                        let position = place(corner.point, in: frame)
                        Circle()
                            .fill(corner.color)
                            .frame(width: 10, height: 10)
                            .position(position)
                        Text(corner.name)
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .foregroundStyle(corner.color)
                            .shadow(radius: 2)
                            .position(x: position.x, y: position.y - 14)
                    }
                }
            }
        }
        .allowsHitTesting(false)
    }

    /// Where the image actually lands inside the view. `AVMakeRect` is exactly the
    /// scale-to-fit rectangle, so the fit case needs no hand-rolled arithmetic.
    private func displayRect(in size: CGSize) -> CGRect {
        let bounds = CGRect(origin: .zero, size: size)
        switch contentMode {
        case .fit:
            return AVMakeRect(aspectRatio: record.pixelSize, insideRect: bounds)
        case .fill:
            let scale = max(size.width / record.pixelSize.width, size.height / record.pixelSize.height)
            let scaled = CGSize(
                width: record.pixelSize.width * scale,
                height: record.pixelSize.height * scale
            )
            return CGRect(
                x: (size.width - scaled.width) / 2,
                y: (size.height - scaled.height) / 2,
                width: scaled.width,
                height: scaled.height
            )
        }
    }

    private func place(_ point: QRCaptureRecord.PixelPoint, in frame: CGRect) -> CGPoint {
        CGPoint(
            x: frame.minX + point.x * frame.width / record.pixelSize.width,
            y: frame.minY + point.y * frame.height / record.pixelSize.height
        )
    }
}
