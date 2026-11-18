import Foundation
import Observation
import UIKit

/// Test-automation support. Runs every image in `Documents/BatchInput/` through the same
/// detection as the photo picker (`QRLibraryImport.detect`), N times each, without going
/// through the picker. One tap starts the whole batch, and results are appended to
/// `Documents/BatchOutput/results.jsonl` one line per run.
///
/// Appending per run, and skipping runs already on disk, makes the batch resumable: if the app
/// or the phone dies partway, starting it again carries on instead of starting over.
///
/// Only reachable when launched with `-batchTools`.
@MainActor @Observable final class BatchFolderRunner {

    static let shared = BatchFolderRunner()

    /// Shown with an accessibility identifier; the UI test waits on its `folder: done` prefix.
    private(set) var status = "folder: idle"
    private(set) var isRunning = false

    static var isEnabled: Bool { ProcessInfo.processInfo.arguments.contains("-batchTools") }

    nonisolated static var inputDirectory: URL { BatchSeeder.inputDirectory }
    nonisolated static var outputDirectory: URL {
        URL.documentsDirectory.appending(path: "BatchOutput", directoryHint: .isDirectory)
    }
    nonisolated static var resultsURL: URL {
        outputDirectory.appending(path: "results.jsonl", directoryHint: .notDirectory)
    }

    /// One line in `results.jsonl` for a run that found no QR code. Successful runs are written
    /// as plain `QRCaptureRecord` JSON, so both kinds can be told apart by the `failed` key.
    private nonisolated struct Failure: Encodable {
        let failed = true
        let sourceName: String
        let batchRepeat: Int
        let error: String
        let date: Date
        let deviceName: String
        let deviceCode: String
        let osVersion: String

        enum CodingKeys: String, CodingKey {
            case failed, sourceName, batchRepeat, error, date, deviceName, deviceCode, osVersion
        }
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        let arguments = ProcessInfo.processInfo.arguments
        let repeats = arguments.firstIndex(of: "-batchRepeats")
            .flatMap { arguments.indices.contains($0 + 1) ? Int(arguments[$0 + 1]) : nil } ?? 10
        let verify = arguments.contains("-verifyRevision")
        let fresh = arguments.contains("-clearBatchOutput")

        // The phone must not lock mid-batch.
        UIApplication.shared.isIdleTimerDisabled = true
        status = "folder: running 0/0"

        Task.detached(priority: .userInitiated) { [weak self] in
            let outcome = await Self.run(repeats: repeats, verify: verify, fresh: fresh) { done, total in
                await MainActor.run { self?.status = "folder: running \(done)/\(total)" }
            }
            await MainActor.run {
                self?.status = outcome
                self?.isRunning = false
                UIApplication.shared.isIdleTimerDisabled = false
            }
        }
    }

    private nonisolated static func run(
        repeats: Int,
        verify: Bool,
        fresh: Bool,
        progress: (Int, Int) async -> Void
    ) async -> String {
        let fm = FileManager.default
        if fresh { try? fm.removeItem(at: outputDirectory) }
        do {
            try fm.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        } catch {
            return "folder: failed \(error.localizedDescription)"
        }
        if !fm.fileExists(atPath: resultsURL.path(percentEncoded: false)) {
            fm.createFile(atPath: resultsURL.path(percentEncoded: false), contents: nil)
        }

        let names = ((try? fm.contentsOfDirectory(atPath: inputDirectory.path(percentEncoded: false))) ?? [])
            .filter { ["png", "jpg", "jpeg", "heic"].contains(($0 as NSString).pathExtension.lowercased()) }
            .sorted()
        guard !names.isEmpty else { return "folder: failed no images in BatchInput" }

        let alreadyDone = completedRuns()
        let total = names.count * repeats
        var done = alreadyDone.count
        let started = ContinuousClock.now

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]

        guard let handle = try? FileHandle(forWritingTo: resultsURL) else {
            return "folder: failed cannot open results file"
        }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()

        for name in names {
            let stem = (name as NSString).deletingPathExtension
            let pending = (1...repeats).filter { !alreadyDone.contains("\(stem)|\($0)") }
            guard !pending.isEmpty else { continue }

            // Loaded once per image: the repeats are runs of the same pixels.
            let path = inputDirectory.appending(path: name, directoryHint: .notDirectory).path(percentEncoded: false)
            let image = UIImage(contentsOfFile: path)

            for repeatIndex in pending {
                let line: Data?
                if let image, let result = try? QRLibraryImport.detect(
                    image, sourceName: stem, batchRepeat: repeatIndex, verifyRevision: verify
                ) {
                    line = try? encoder.encode(result.record)
                } else {
                    let reason = image == nil ? "unreadable image" : "no QR code found"
                    line = try? encoder.encode(Failure(
                        sourceName: stem, batchRepeat: repeatIndex, error: reason, date: Date(),
                        deviceName: QRDeviceInfo.marketingName, deviceCode: QRDeviceInfo.modelCode,
                        osVersion: QRDeviceInfo.osVersion
                    ))
                }
                if let line {
                    try? handle.write(contentsOf: line + Data("\n".utf8))
                }
                done += 1
                if done % 25 == 0 { await progress(done, total) }
            }
        }

        try? handle.synchronize()
        let elapsed = ContinuousClock.now - started
        let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        return "folder: done \(done)/\(total) in \(String(format: "%.1f", seconds))s"
    }

    /// `sourceName|repeat` for every run already on disk, so a restart resumes.
    private nonisolated static func completedRuns() -> Set<String> {
        guard let text = try? String(contentsOf: resultsURL, encoding: .utf8) else { return [] }
        var keys = Set<String>()
        for line in text.split(separator: "\n") {
            guard let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let name = object["sourceName"] as? String,
                  let repeatIndex = object["batchRepeat"] as? Int
            else { continue }
            keys.insert("\(name)|\(repeatIndex)")
        }
        return keys
    }
}
