import Foundation
import Observation
import Photos

/// Test-automation support. Copies the images in `Documents/BatchInput/` into the Photos
/// library so the Pick Photo flow can be driven by a UI test, which can only choose what the
/// picker shows.
///
/// Triggered by the `-seedPhotos` launch argument; nothing runs otherwise.
@MainActor @Observable final class BatchSeeder {

    static let shared = BatchSeeder()

    /// Shown on the Scan tab with an accessibility identifier, which is how the UI test knows
    /// seeding has finished.
    private(set) var status: String?

    private static let seededKey = "BatchSeeder.seededNames"
    private static let baseKey = "BatchSeeder.baseDate"

    static var inputDirectory: URL {
        URL.documentsDirectory.appending(path: "BatchInput", directoryHint: .isDirectory)
    }

    func runIfRequested() {
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("-clearCaptures") {
            QRCaptureStore.deleteAll()
        }
        if arguments.contains("-resetSeed") {
            UserDefaults.standard.removeObject(forKey: Self.seededKey)
        }
        guard arguments.contains("-seedPhotos") else { return }
        status = "seed: running"
        Task { await seed() }
    }

    private func seed() async {
        guard await PHPhotoLibrary.requestAuthorization(for: .addOnly) == .authorized
            || PHPhotoLibrary.authorizationStatus(for: .addOnly) == .limited
        else {
            status = "seed: denied"
            return
        }

        let names = (try? FileManager.default.contentsOfDirectory(atPath: Self.inputDirectory.path(percentEncoded: false)))?
            .filter { ["png", "jpg", "jpeg", "heic"].contains(($0 as NSString).pathExtension.lowercased()) }
            .sorted() ?? []
        var seeded = Set(UserDefaults.standard.stringArray(forKey: Self.seededKey) ?? [])
        let pending = names.filter { !seeded.contains($0) }

        // The picker lists newest first, so earlier names get later dates: cell k in the
        // picker is then input file k. The base date is stored so images added by a later
        // seeding slot in below the earlier ones instead of jumping to the front. Seeds from
        // before the base was tracked are assumed to be within the last ten minutes.
        let base: Date
        if let stored = UserDefaults.standard.object(forKey: Self.baseKey) as? Date {
            base = stored
        } else {
            base = seeded.isEmpty ? Date() : Date().addingTimeInterval(-600)
            UserDefaults.standard.set(base, forKey: Self.baseKey)
        }
        for (index, name) in names.enumerated() where pending.contains(name) {
            let url = Self.inputDirectory.appending(path: name, directoryHint: .notDirectory)
            do {
                try await PHPhotoLibrary.shared().performChanges {
                    let options = PHAssetResourceCreationOptions()
                    options.originalFilename = name
                    let request = PHAssetCreationRequest.forAsset()
                    request.addResource(with: .photo, fileURL: url, options: options)
                    request.creationDate = base.addingTimeInterval(-Double(index))
                }
                seeded.insert(name)
            } catch {
                status = "seed: failed \(name): \(error.localizedDescription)"
                return
            }
        }
        UserDefaults.standard.set(Array(seeded), forKey: Self.seededKey)
        status = "seed: done \(names.count)"
    }
}
