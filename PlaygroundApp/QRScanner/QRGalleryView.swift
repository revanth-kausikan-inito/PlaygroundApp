import SwiftUI
import UIKit

/// Every stored capture, newest first, with the corner-consistency check on top.
struct QRGalleryView: View {
    @State private var records: [QRCaptureRecord] = []

    var body: some View {
        List {
            ForEach(records) { record in
                NavigationLink {
                    QRCaptureDetailView(record: record)
                } label: {
                    QRCaptureRow(record: record)
                }
            }
            .onDelete(perform: delete)
        }
        .listStyle(.plain)
        // The tab bar is translucent glass and content runs under it.
        .contentMargins(.bottom, 56, for: .scrollContent)
        .navigationTitle("Captures")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink {
                    QRCaptureAuditView(records: records)
                } label: {
                    Label("Check All", systemImage: "checklist")
                }
                .disabled(records.isEmpty)
            }
        }
        .overlay {
            if records.isEmpty {
                ContentUnavailableView(
                    "No Captures",
                    systemImage: "qrcode.viewfinder",
                    description: Text("Scanned QR codes are saved here with their corner points.")
                )
            }
        }
        .onAppear { records = QRCaptureStore.allRecords() }
    }

    /// Removes the JPEG and its sidecar, not just the row.
    private func delete(at offsets: IndexSet) {
        for index in offsets {
            QRCaptureStore.delete(records[index])
        }
        records.remove(atOffsets: offsets)
    }
}

private struct QRCaptureRow: View {
    let record: QRCaptureRecord

    @State private var image: UIImage?

    var body: some View {
        HStack(spacing: 12) {
            thumbnail

            VStack(alignment: .leading, spacing: 3) {
                Text(record.payload ?? "(binary payload)")
                    .font(.system(.subheadline, design: .monospaced))
                    .lineLimit(1)

                Text("\(record.timeString) · \(record.imagePixelWidth) × \(record.imagePixelHeight) px · \(record.source.rawValue)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                corners
            }
        }
        .padding(.vertical, 4)
        .task(id: record.id) {
            let url = QRCaptureStore.imageURL(for: record)
            image = await Task.detached {
                QRThumbnailLoader.thumbnail(for: url, maxPixel: 160)
            }.value
        }
    }

    /// The stored corner points, laid out the way they sit on the image and monospaced so the
    /// digits line up column-wise between rows — which is what lets repeat captures of one
    /// code be compared by eye without opening each of them.
    private var corners: some View {
        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 1) {
            GridRow {
                corner("TL", record.corners.topLeft, .green)
                corner("TR", record.corners.topRight, .yellow)
            }
            GridRow {
                corner("BL", record.corners.bottomLeft, .cyan)
                corner("BR", record.corners.bottomRight, .orange)
            }
        }
        .padding(.top, 1)
    }

    /// Same colour per corner as the detail view's overlay.
    private func corner(
        _ name: String,
        _ point: QRCaptureRecord.PixelPoint,
        _ color: Color
    ) -> some View {
        HStack(spacing: 4) {
            Text(name)
                .foregroundStyle(color)
            Text(String(format: "%.1f, %.1f", point.x, point.y))
                .foregroundStyle(.secondary)
        }
        .font(.system(size: 10, weight: .medium, design: .monospaced))
    }

    private var thumbnail: some View {
        Color(.secondarySystemBackground)
            .frame(width: 44, height: 60)
            .overlay {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    ProgressView()
                }
            }
            .clipped()
            .clipShape(RoundedRectangle(cornerRadius: 5))
            // Captures are mostly white, so without an edge the thumbnail vanishes.
            .overlay {
                RoundedRectangle(cornerRadius: 5)
                    .strokeBorder(Color(.separator), lineWidth: 0.5)
            }
    }
}
