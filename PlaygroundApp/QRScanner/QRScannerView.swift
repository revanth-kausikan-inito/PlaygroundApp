import AVFoundation
import SwiftUI
import UIKit

/// Root of the Scan tab: camera permission, live preview with auto-capture, and the way in
/// to the gallery. Brings its own `NavigationStack`, so `GlassTabBarController` must not wrap
/// it in a `UINavigationController` as well.
struct QRScannerView: View {
    @Environment(\.scenePhase) private var scenePhase

    @State private var engine = QRCaptureEngine()
    @State private var authStatus: AVAuthorizationStatus?
    @State private var lastCapture: QRCaptureRecord?
    @State private var flashCapture: QRCaptureRecord?
    @State private var lastPayload: String?
    @State private var isPickingFromLibrary = false
    @State private var libraryMessage: String?
    @State private var importCount = 0
    @State private var lastImportOutcome = "none"
    private let seeder = BatchSeeder.shared

    /// How long the detected quad stays on screen before scanning resumes.
    private static let rearmDelay = Duration.milliseconds(1500)

    private var hasCamera: Bool { QRCaptureEngine.hasCamera }

    var body: some View {
        NavigationStack {
            ZStack {
                if authStatus == .authorized, hasCamera {
                    cameraLayer
                } else {
                    Color(.systemBackground)
                }

                VStack(spacing: 0) {
                    Spacer()
                    controlPanel
                }
            }
            .navigationTitle("Scan")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink {
                        QRGalleryView()
                    } label: {
                        Label("Gallery", systemImage: "photo.on.rectangle.angled")
                    }
                }
            }
        }
        .sheet(isPresented: $isPickingFromLibrary) {
            QRLibraryPicker(
                onPick: { image, name in Task { await importFromLibrary(image, name: name) } },
                onFinish: { isPickingFromLibrary = false }
            )
            .ignoresSafeArea()
        }
        .task {
            refreshAuthorization()
            for await record in engine.captureStream() {
                await handle(record)
            }
        }
        // Returning from Settings resumes from background rather than relaunching, so this is
        // the transition that needs a fresh authorization check.
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                refreshAuthorization()
            } else {
                engine.stop()
            }
        }
        .onDisappear { engine.stop() }
    }

    // MARK: - Camera

    private var cameraLayer: some View {
        QRCameraPreview(session: engine.session)
            .ignoresSafeArea()
            .overlay {
                if let flashCapture {
                    QRCornerOverlay(record: flashCapture, stroke: .green, showsLabels: false, contentMode: .fill)
                        .transition(.opacity)
                }
            }
            .overlay(alignment: .top) {
                Text(flashCapture == nil ? "Point at a QR code" : "Captured")
                    .font(.footnote.weight(.medium))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(.top, 8)
            }
    }

    // MARK: - Controls
    //
    // Everything here stays inside the safe area: the tab bar is translucent glass and
    // `MyApp` lets content run under it, so controls placed outside would sit beneath the bar.

    private var controlPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            permissionRow

            if authStatus != .authorized {
                HStack(spacing: 12) {
                    Button("Allow Camera") {
                        Task {
                            _ = await AVCaptureDevice.requestAccess(for: .video)
                            refreshAuthorization()
                        }
                    }
                    .disabled(!canRequestPermission)

                    Button("Settings", action: openSettings)
                        .disabled(!canOpenSettings)
                }
                .buttonStyle(.bordered)
            }

            if authStatus == .denied {
                Text("iOS only prompts once. Enable the camera in Settings to scan.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if !hasCamera {
                Text("No camera on this device — pick a photo to run the same detection.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 12) {
                Button {
                    isPickingFromLibrary = true
                } label: {
                    Label("Pick Photo", systemImage: "photo")
                }
                .accessibilityIdentifier("pickPhotoButton")

                if authStatus == .authorized, hasCamera {
                    Button {
                        flashCapture = nil
                        lastPayload = nil
                        engine.arm()
                    } label: {
                        Label("Scan Again", systemImage: "arrow.clockwise")
                    }
                }
            }
            .buttonStyle(.bordered)

            if let message = libraryMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // Machine-readable outcome of the latest import, for the batch UI test.
            Text("imports: \(importCount) | \(lastImportOutcome)")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("importStatus")

            if let seedStatus = seeder.status {
                Text(seedStatus)
                    .font(.caption2)
                    .accessibilityIdentifier("seedStatus")
            }

            if let lastCapture {
                lastCaptureRow(lastCapture)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    private var permissionRow: some View {
        HStack(spacing: 8) {
            Image(systemName: statusIcon)
                .foregroundStyle(statusColor)
            Text(statusText)
                .font(.headline)
        }
    }

    private func lastCaptureRow(_ record: QRCaptureRecord) -> some View {
        NavigationLink {
            QRCaptureDetailView(record: record)
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(record.payload ?? "(binary payload)")
                    .font(.system(.footnote, design: .monospaced))
                    .lineLimit(2)
                Text("\(record.timeString) · tap for corners")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Capture handling

    private func handle(_ record: QRCaptureRecord) async {
        // The same code sitting in frame would otherwise be saved over and over.
        guard record.payload == nil || record.payload != lastPayload else {
            try? await Task.sleep(for: Self.rearmDelay)
            engine.arm()
            return
        }

        lastPayload = record.payload
        lastCapture = record
        withAnimation(.easeOut(duration: 0.2)) { flashCapture = record }

        try? await Task.sleep(for: Self.rearmDelay)

        withAnimation(.easeIn(duration: 0.2)) { flashCapture = nil }
        engine.arm()
    }

    private func importFromLibrary(_ image: UIImage, name: String?) async {
        libraryMessage = nil

        let result = await Task.detached {
            Result { try QRLibraryImport.makeRecord(from: image, sourceName: name) }
        }.value
        defer { importCount += 1 }

        switch result {
        case .success(let record):
            lastCapture = record
            lastImportOutcome = "ok \(record.id.uuidString) \(name ?? "-")"
            // Re-importing the same photo is how the gallery's corner check gets something
            // to compare, so make the repeat visible rather than looking like a no-op.
            let sameImageCount = QRCaptureStore.allRecords().filter {
                $0.payload == record.payload && $0.pixelSize == record.pixelSize
            }.count
            libraryMessage = sameImageCount > 1
                ? "Saved — \(sameImageCount) captures of this code so far."
                : nil
        case .failure(let error):
            libraryMessage = error.localizedDescription
            lastImportOutcome = "fail \(name ?? "-") \(error.localizedDescription)"
        }
    }

    // MARK: - Authorization

    private func refreshAuthorization() {
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        authStatus = status

        if status == .authorized, hasCamera {
            engine.start()
        } else {
            engine.stop()
        }
    }

    // iOS only prompts while the status is still undetermined; once denied or granted,
    // requestAccess() returns without showing anything.
    private var canRequestPermission: Bool {
        authStatus == .notDetermined
    }

    private var canOpenSettings: Bool {
        authStatus != nil
    }

    private var statusText: String {
        switch authStatus {
        case .authorized: "Camera authorized"
        case .denied: "Camera denied"
        case .restricted: "Camera restricted"
        case .notDetermined: "Camera not requested"
        case .none: "Checking…"
        @unknown default: "Unknown status"
        }
    }

    private var statusIcon: String {
        switch authStatus {
        case .authorized: "checkmark.circle.fill"
        case .denied: "xmark.circle.fill"
        case .restricted: "lock.circle.fill"
        case .notDetermined: "questionmark.circle.fill"
        case .none: "circle.dotted"
        @unknown default: "circle.dotted"
        }
    }

    private var statusColor: Color {
        switch authStatus {
        case .authorized: .green
        case .denied: .red
        case .restricted, .notDetermined: .orange
        default: .secondary
        }
    }

    private func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}
