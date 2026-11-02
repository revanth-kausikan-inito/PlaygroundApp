import SwiftUI

/// Result of the gallery's consistency check: whether every capture is the same image, and
/// whether every capture reports the same QR corners. The two are reported separately,
/// because identical corners from different images means something quite different from
/// identical corners from one repeated image.
struct QRCaptureAuditView: View {
    let records: [QRCaptureRecord]

    @State private var report: QRCaptureAuditReport?
    @State private var exportURL: URL?
    @State private var exportError: String?

    var body: some View {
        Group {
            if let report {
                content(for: report)
            } else {
                ProgressView("Comparing captures…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle("Consistency Check")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if let exportURL {
                    // The share sheet is where AirDrop lives; handing it a file URL is what
                    // makes the other device receive a .json rather than pasted text.
                    ShareLink(item: exportURL) {
                        Label("Export", systemImage: "square.and.arrow.up")
                    }
                }
            }
        }
        .task {
            // Hashing every stored frame is real work — keep it off the main actor.
            let captures = records
            let result = await Task.detached { QRCaptureAudit.run(on: captures) }.value
            report = result
            do {
                exportURL = try result.writeExportFile()
            } catch {
                exportError = error.localizedDescription
            }
        }
    }

    private func content(for report: QRCaptureAuditReport) -> some View {
        List {
            Section {
                verdict(for: report)
            }

            Section {
                checkRow(
                    "Images identical",
                    passed: report.allImagesIdentical,
                    enabled: report.hasSomethingToCompare,
                    detail: "\(report.distinctImageCount) distinct"
                )
                checkRow(
                    "Corners identical",
                    passed: report.allCornersIdentical,
                    enabled: report.hasSomethingToCompare,
                    detail: "\(report.distinctCornerSetCount) distinct"
                )
                checkRow(
                    "Payloads identical",
                    passed: report.allPayloadsIdentical,
                    enabled: report.hasSomethingToCompare,
                    detail: "\(report.distinctPayloadCount) distinct"
                )
                checkRow(
                    "Same device",
                    passed: report.allDevicesIdentical,
                    enabled: report.hasSomethingToCompare,
                    detail: "\(report.distinctDeviceCount) distinct"
                )

                if !report.allCornersIdentical, report.hasSomethingToCompare {
                    row("Max deviation", String(format: "%.4f px", report.maxDeviationPixels))
                }
                if report.unreadableImageCount > 0 {
                    row("Unreadable images", "\(report.unreadableImageCount)")
                }
            } header: {
                Text("Checks")
            } footer: {
                Text("Images are compared on the SHA-256 of the stored JPEG — byte for byte, not by payload or pixel size. Every capture is measured against the oldest one.")
            }

            Section("Captures") {
                ForEach(report.captures) { capture in
                    captureRow(capture, isReference: capture.id == report.referenceCaptureID)
                }
            }

            if let exportError {
                Section {
                    Label(exportError, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .listStyle(.insetGrouped)
        // The tab bar is translucent glass and content runs under it.
        .contentMargins(.bottom, 56, for: .scrollContent)
    }

    private func verdict(for report: QRCaptureAuditReport) -> some View {
        HStack(spacing: 12) {
            Image(systemName: verdictIcon(for: report))
                .font(.title2)
                .foregroundStyle(verdictColor(for: report))

            VStack(alignment: .leading, spacing: 2) {
                Text(report.headline)
                    .font(.headline)
                Text(report.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private func checkRow(
        _ title: String,
        passed: Bool,
        enabled: Bool,
        detail: String
    ) -> some View {
        HStack(spacing: 10) {
            Image(systemName: enabled
                  ? (passed ? "checkmark.circle.fill" : "xmark.circle.fill")
                  : "minus.circle.fill")
                .foregroundStyle(enabled ? (passed ? Color.green : .red) : .secondary)
            Text(title)
            Spacer()
            Text(detail)
                .foregroundStyle(.secondary)
        }
        .font(.subheadline)
    }

    @ViewBuilder
    private func captureRow(_ capture: QRCaptureAuditReport.Capture, isReference: Bool) -> some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 6) {
                cornerList(capture.corners)

                labelled("Image SHA-256") {
                    Text(capture.imageSHA256 ?? "unreadable")
                        .font(.system(size: 10, design: .monospaced))
                        .textSelection(.enabled)
                        .lineLimit(2)
                }

                labelled("Payload") {
                    Text(capture.payload ?? "(binary payload)")
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                }

                if !isReference, !capture.cornersMatchReference {
                    labelled("Corner deviation") {
                        Text(String(format: "%.4f px", capture.deviationPixels))
                            .font(.caption)
                    }
                }
            }
            .padding(.vertical, 2)
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    if isReference {
                        Text("REFERENCE")
                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                            .foregroundStyle(.secondary)
                    } else {
                        badge("Image", passed: capture.imageMatchesReference)
                        badge("Corners", passed: capture.cornersMatchReference)
                    }
                }
                Text(capture.capturedAt.formatted(date: .abbreviated, time: .standard))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("\(capture.imagePixelWidth) × \(capture.imagePixelHeight) px · \(capture.source)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(capture.deviceCode)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func badge(_ title: String, passed: Bool) -> some View {
        HStack(spacing: 3) {
            Image(systemName: passed ? "checkmark" : "xmark")
            Text(title)
        }
        .font(.system(size: 10, weight: .semibold))
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(
            (passed ? Color.green : Color.red).opacity(0.15),
            in: Capsule()
        )
        .foregroundStyle(passed ? Color.green : .red)
    }

    private func cornerList(_ corners: QRCaptureRecord.Corners) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 2) {
            GridRow {
                corner("TL", corners.topLeft, .green)
                corner("TR", corners.topRight, .yellow)
            }
            GridRow {
                corner("BL", corners.bottomLeft, .cyan)
                corner("BR", corners.bottomRight, .orange)
            }
        }
    }

    private func corner(
        _ name: String,
        _ point: QRCaptureRecord.PixelPoint,
        _ color: Color
    ) -> some View {
        HStack(spacing: 4) {
            Text(name).foregroundStyle(color)
            Text(String(format: "%.4f, %.4f", point.x, point.y))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
        .font(.system(size: 10, weight: .medium, design: .monospaced))
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value).foregroundStyle(.secondary)
        }
        .font(.subheadline)
    }

    private func labelled<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title.uppercased())
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
            content()
        }
    }

    private func verdictIcon(for report: QRCaptureAuditReport) -> String {
        guard report.hasSomethingToCompare else { return "questionmark.circle.fill" }
        return report.allIdentical ? "checkmark.seal.fill" : "exclamationmark.triangle.fill"
    }

    private func verdictColor(for report: QRCaptureAuditReport) -> Color {
        guard report.hasSomethingToCompare else { return .secondary }
        return report.allIdentical ? .green : .red
    }
}
