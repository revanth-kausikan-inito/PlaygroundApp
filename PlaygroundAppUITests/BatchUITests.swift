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
        app.launchArguments = ["-seedPhotos", "-clearCaptures"]

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

    // One test per repeat, so if the runner process dies partway the remaining repeats still
    // run in a fresh one. Each repeat covers every image once.
    func test2_Rep01() throws { try runRepeat(1) }
    func test2_Rep02() throws { try runRepeat(2) }
    func test2_Rep03() throws { try runRepeat(3) }
    func test2_Rep04() throws { try runRepeat(4) }
    func test2_Rep05() throws { try runRepeat(5) }
    func test2_Rep06() throws { try runRepeat(6) }
    func test2_Rep07() throws { try runRepeat(7) }
    func test2_Rep08() throws { try runRepeat(8) }
    func test2_Rep09() throws { try runRepeat(9) }
    func test2_Rep10() throws { try runRepeat(10) }

    private func runRepeat(_ rep: Int) throws {
        let env = ProcessInfo.processInfo.environment
        let count = Int(env["BATCH_COUNT"] ?? "") ?? 10
        let repeats = Int(env["BATCH_REPEATS"] ?? "") ?? 10
        try XCTSkipIf(rep > repeats, "only \(repeats) repeats requested")

        let app = XCUIApplication(bundleIdentifier: bundleID)
        app.launchArguments = ["-batchRep", "\(rep)", "-verifyRevision"]
        app.launch()

        let pick = app.buttons["pickPhotoButton"]
        XCTAssertTrue(pick.waitForExistence(timeout: 20))
        let status = app.staticTexts["importStatus"]

        var rows = ["repeat,image_index,ui_cycle_ms,outcome"]
        let runStart = ContinuousClock.now

        for index in 0..<count {
            let started = ContinuousClock.now

            pick.tap()
            Thread.sleep(forTimeInterval: 1.5)   // let the picker sheet finish presenting
            tapPickerCell(app, index: index)

            let predicate = NSPredicate(format: "label BEGINSWITH %@", "imports: \(index + 1) |")
            let done = XCTNSPredicateExpectation(predicate: predicate, object: status)
            let result = XCTWaiter().wait(for: [done], timeout: 60)
            let cycle = ContinuousClock.now - started

            let outcome = result == .completed ? status.label : "TIMEOUT"
            rows.append("\(rep),\(index),\(Self.milliseconds(cycle)),\"\(outcome)\"")
        }

        rows.append("total,,\(Self.milliseconds(ContinuousClock.now - runStart)),")

        let attachment = XCTAttachment(string: rows.joined(separator: "\n"))
        attachment.name = String(format: "ui_timings_rep%02d.csv", rep)
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
