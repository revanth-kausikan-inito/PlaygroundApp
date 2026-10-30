import SwiftUI
import UIKit

/// One capture: the stored frame with its corner quad drawn back on top, plus the metadata
/// that went into the sidecar JSON.
struct QRCaptureDetailView: View {
    let record: QRCaptureRecord

    @State private var image: UIImage?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                imageWithOverlay
                metadata
                jsonSection
            }
            .padding(16)
            // The tab bar is translucent glass and content runs under it.
            .padding(.bottom, 56)
        }
        .navigationTitle(record.timeString)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            let url = QRCaptureStore.imageURL(for: record)
            image = await Task.detached { QRThumbnailLoader.fullImage(for: url) }.value
        }
    }

    private var imageWithOverlay: some View {
        Color(.secondarySystemBackground)
            .aspectRatio(record.pixelSize, contentMode: .fit)
            .overlay {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .overlay { QRCornerOverlay(record: record) }
                } else {
                    ProgressView()
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color(.separator), lineWidth: 0.5)
            }
    }

    private var metadata: some View {
        VStack(alignment: .leading, spacing: 10) {
            labelled("Payload") {
                Text(record.payload ?? "(binary — not UTF-8 text)")
                    .font(.system(.footnote, design: .monospaced))
                    .textSelection(.enabled)
            }

            HStack(spacing: 16) {
                labelled("Symbology") { Text(record.symbology).font(.footnote) }
                labelled("Confidence") {
                    Text(String(format: "%.2f", record.confidence)).font(.footnote)
                }
                labelled("Source") { Text(record.source.rawValue).font(.footnote) }
            }

            labelled("Image") {
                Text("\(record.imagePixelWidth) × \(record.imagePixelHeight) px")
                    .font(.footnote)
            }

            Button {
                UIPasteboard.general.string = record.payload
            } label: {
                Label("Copy Payload", systemImage: "doc.on.doc")
            }
            .buttonStyle(.bordered)
            .disabled(record.payload == nil)
        }
    }

    private var jsonSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("CORNERS (IMAGE PIXELS, TOP-LEFT ORIGIN)")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)

            ForEach(cornerRows, id: \.name) { row in
                HStack(spacing: 8) {
                    Circle().fill(row.color).frame(width: 8, height: 8)
                    Text(row.name)
                        .font(.system(.caption, design: .monospaced).weight(.semibold))
                        .frame(width: 24, alignment: .leading)
                    Text(String(format: "%.1f, %.1f", row.point.x, row.point.y))
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                }
            }

            Text("Sidecar: \(record.id.uuidString).json")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
    }

    private var cornerRows: [(name: String, point: QRCaptureRecord.PixelPoint, color: Color)] {
        [
            ("TL", record.corners.topLeft, .green),
            ("TR", record.corners.topRight, .yellow),
            ("BR", record.corners.bottomRight, .orange),
            ("BL", record.corners.bottomLeft, .cyan),
        ]
    }

    private func labelled<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            content()
        }
    }
}
