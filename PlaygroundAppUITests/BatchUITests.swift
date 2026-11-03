import XCTest

/// Drives the real Scan tab: Pick Photo -> choose the nth image in the picker -> wait for the
/// import to finish, timing each cycle. Detection results themselves are read back from the
/// app's `Documents/QRCaptures` sidecars after the run (see `scripts/run_batch.sh`), so this
/// test only records what the UI can see: wall time and the outcome line.
///
/// Configure through `TEST_RUNNER_BATCH_COUNT` and `TEST_RUNNER_BATCH_REPEATS`.
final class BatchUITests: XCTestCase {

    private let bundleID = "com.Inito.PlaygroundApp"

    override func setUp() {
        continueAfterFailure = false
    }

    /// Copies the images in the app's `Documents/BatchInput` into Photos.
    func test1_SeedPhotos() throws {
        let app = XCUIApplication(bundleIdentifier: bundleID)
        app.launchArguments = ["-seedPhotos"]

        addUIInterruptionMonitor(withDescription: "Photos permission") { alert in
            for title in ["Allow Full Access", "Allow", "OK"] where alert.buttons[title].firstMatch.exists {
                alert.buttons[title].firstMatch.tap()
                return true
            }
            return false
        }

        app.launch()
        app.tap()   // lets the interruption monitor see the permission alert

        let status = app.staticTexts["seedStatus"]
        XCTAssertTrue(status.waitForExistence(timeout: 30), "seed status never appeared")

        let deadline = Date().addingTimeInterval(120)
        while Date() < deadline, !status.label.hasPrefix("seed: done"), !status.label.contains("denied"),
              !status.label.contains("failed") {
            app.tap()
            Thread.sleep(forTimeInterval: 1)
        }
        XCTAssertTrue(status.label.hasPrefix("seed: done"), "seeding ended with: \(status.label)")
    }

    /// Diagnostic: attaches the accessibility tree with the picker open.
    func test1b_DumpPicker() throws {
        let app = XCUIApplication(bundleIdentifier: bundleID)
        app.launch()
        app.buttons["pickPhotoButton"].tap()
        Thread.sleep(forTimeInterval: 4)
        // Dismiss the "Private Access to Photos" banner so the grid sits at a fixed position.
        app.coordinate(withNormalizedOffset: CGVector(dx: 843.0 / 921, dy: 341.0 / 2000)).tap()
        Thread.sleep(forTimeInterval: 2)
        let dump = XCTAttachment(string: app.debugDescription)
        dump.name = "picker_tree.txt"
        dump.lifetime = .keepAlways
        add(dump)
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.lifetime = .keepAlways
        add(shot)
    }

    func test2_Batch() throws {
        let env = ProcessInfo.processInfo.environment
        let count = Int(env["BATCH_COUNT"] ?? "") ?? 10
        let repeats = Int(env["BATCH_REPEATS"] ?? "") ?? 3

        let app = XCUIApplication(bundleIdentifier: bundleID)
        app.launchArguments = ["-clearCaptures"]
        app.launch()

        let pick = app.buttons["pickPhotoButton"]
        XCTAssertTrue(pick.waitForExistence(timeout: 20))
        let status = app.staticTexts["importStatus"]

        var rows = ["repeat,image_index,ui_cycle_ms,outcome"]
        let runStart = ContinuousClock.now

        for rep in 1...repeats {
            for index in 0..<count {
                let started = ContinuousClock.now
                let expected = "imports: \(rows.count - 1) |"

                pick.tap()
                Thread.sleep(forTimeInterval: 1.5)   // let the picker sheet finish presenting
                tapPickerCell(app, index: index)

                let predicate = NSPredicate(format: "label BEGINSWITH %@", "imports: \(rows.count) |")
                let done = XCTNSPredicateExpectation(predicate: predicate, object: status)
                let result = XCTWaiter().wait(for: [done], timeout: 60)
                let cycle = ContinuousClock.now - started

                let outcome = result == .completed ? status.label : "TIMEOUT (\(expected))"
                rows.append("\(rep),\(index),\(Self.milliseconds(cycle)),\"\(outcome)\"")
            }
        }

        let total = ContinuousClock.now - runStart
        rows.append("total,,\(Self.milliseconds(total)),")

        let attachment = XCTAttachment(string: rows.joined(separator: "\n"))
        attachment.name = "ui_timings.csv"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// The picker runs out of process and its cells are not in the app's accessibility tree, so
    /// cells are tapped by position. Layout measured on a 440 x 956 pt screen with the "Private
    /// Access to Photos" banner dismissed: three square columns, first row starting 15.1% down,
    /// rows ~15.4% of the screen height apart. The grid is newest first, which is why the seeder
    /// dates files in reverse. The source name in each outcome line is the check that the right
    /// cell was hit.
    private func tapPickerCell(_ app: XCUIApplication, index: Int) {
        let column = index % 3
        let row = index / 3
        let dx = (Double(column) + 0.5) / 3
        let dy = 0.151 + 0.154 * Double(row) + 0.076
        app.coordinate(withNormalizedOffset: CGVector(dx: dx, dy: dy)).tap()
    }

    private static func milliseconds(_ duration: Duration) -> Int {
        Int(duration.components.seconds * 1000 + duration.components.attoseconds / 1_000_000_000_000_000)
    }
}
