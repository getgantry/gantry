import AppKit
import XCTest

@MainActor
final class SingleMainWindowUITests: XCTestCase {
    private let bundleID = "com.andrewkomkov.Gantry"

    private func mainWindows(in app: XCUIApplication) -> XCUIElementQuery {
        app.windows.containing(.button, identifier: "Add Host…")
    }

    private func waitForMainCount(_ expected: Int, in app: XCUIApplication, timeout: TimeInterval = 5) {
        let predicate = NSPredicate { _, _ in self.mainWindows(in: app).count == expected }
        XCTAssertEqual(
            XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: nil)], timeout: timeout),
            .completed, app.debugDescription
        )
    }

    private func waitForRenderedContainer(_ name: String, image: String, in app: XCUIApplication) {
        let main = mainWindows(in: app).firstMatch
        for text in [name, image] {
            let predicate = NSPredicate { _, _ in
                main.staticTexts.matching(
                    NSPredicate(format: "label == %@ OR value == %@", text, text)
                ).allElementsBoundByIndex.contains {
                    $0.frame.minX > main.frame.minX + 500
                }
            }
            XCTAssertEqual(
                XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: nil)], timeout: 8),
                .completed, main.debugDescription
            )
        }
    }

    private func launch(menuOnly: Bool = false, routeFixtures: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "-ApplePersistenceIgnoreState", "YES",
            "-showDockIcon", menuOnly ? "NO" : "YES",
            "-showMenuBarExtra", "YES"
        ]
        if routeFixtures {
            app.launchArguments += ["--gantry-test-window-routes", "--gantry-test-in-memory-containers"]
        }
        app.launch()
        app.activate()
        XCTAssertTrue(mainWindows(in: app).firstMatch.waitForExistence(timeout: 10), app.debugDescription)
        return app
    }

    private func openFromMenuBar(in app: XCUIApplication) {
        clickMenuButton("Open Gantry", in: app)
    }

    private func clickMenuButton(_ title: String, in app: XCUIApplication) {
        let item = app.statusItems["MenuBarIcon"]
        XCTAssertTrue(item.waitForExistence(timeout: 5), app.debugDescription)
        let button = app.dialogs.firstMatch.buttons[title]
        // A window-style MenuBarExtra may remain open after its button runs.
        // Clicking its status item again would close the panel, not open it.
        if !button.exists { item.click() }
        XCTAssertTrue(button.waitForExistence(timeout: 5), app.debugDescription)
        button.click()
    }

    func testRepeatedRealMenuOpenKeepsOneMainWindowAndProcess() {
        let app = launch()
        defer { app.terminate() }
        XCTAssertEqual(mainWindows(in: app).count, 1)

        for attempt in 1...3 {
            openFromMenuBar(in: app)
            let processCount = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).count
            print("MENU_OPEN_\(attempt) mainWindows=\(mainWindows(in: app).count) processes=\(processCount)")
            XCTAssertEqual(
                mainWindows(in: app).count, 1,
                "Menu open \(attempt) created another Health window: \(app.debugDescription)"
            )
            XCTAssertEqual(processCount, 1)
        }
    }

    func testBurstMenuActionsKeepOneMainWindow() {
        let app = launch()
        defer { app.terminate() }
        let item = app.statusItems["MenuBarIcon"]
        XCTAssertTrue(item.waitForExistence(timeout: 5))
        item.click()
        let button = app.dialogs.firstMatch.buttons["Open Gantry"]
        XCTAssertTrue(button.waitForExistence(timeout: 5))

        // The window-style panel remains open after an action. Deliver a
        // burst through that same real button, without menu toggles or sleeps.
        for attempt in 1...4 {
            XCTAssertTrue(button.exists, "Open Gantry panel closed before burst action \(attempt)")
            button.click()
            let processCount = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).count
            print("BURST_OPEN_\(attempt) mainWindows=\(mainWindows(in: app).count) processes=\(processCount)")
            XCTAssertEqual(mainWindows(in: app).count, 1)
            XCTAssertEqual(processCount, 1)
        }
    }

    func testCloseThenMenuReopenKeepsProcessAndOneWindow() {
        let app = launch()
        defer { app.terminate() }
        let main = mainWindows(in: app).firstMatch
        main.click()
        app.typeKey("w", modifierFlags: .command)
        XCTAssertEqual(mainWindows(in: app).count, 0)
        XCTAssertEqual(NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).count, 1)
        openFromMenuBar(in: app)
        XCTAssertTrue(mainWindows(in: app).firstMatch.waitForExistence(timeout: 5))
        XCTAssertEqual(mainWindows(in: app).count, 1)
    }

    func testMenuOnlyCloseAndReopen() {
        let app = launch(menuOnly: true)
        defer { app.terminate() }
        mainWindows(in: app).firstMatch.click()
        app.typeKey("w", modifierFlags: .command)
        waitForMainCount(0, in: app)
        XCTAssertEqual(NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).count, 1)
        openFromMenuBar(in: app)
        XCTAssertTrue(mainWindows(in: app).firstMatch.waitForExistence(timeout: 5))
        XCTAssertEqual(mainWindows(in: app).count, 1)
    }

    func testActivationDoesNotDuplicateMainWindow() {
        let app = launch()
        defer { app.terminate() }
        for _ in 0..<3 { app.activate() }
        XCTAssertEqual(mainWindows(in: app).count, 1)
        XCTAssertEqual(NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).count, 1)
    }

    private func checkFinderFileOpenAfterMainClose(filename: String, contents: String, sheetTitle: String) throws {
        let app = launch()
        defer { app.terminate() }
        let bundleURL = try XCTUnwrap(
            NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first?.bundleURL
        )
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("gantry-single-file-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent(filename)
        try contents.write(to: file, atomically: true, encoding: .utf8)

        mainWindows(in: app).firstMatch.click()
        app.typeKey("w", modifierFlags: .command)
        waitForMainCount(0, in: app)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-a", bundleURL.path, file.path]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)

        XCTAssertTrue(mainWindows(in: app).firstMatch.waitForExistence(timeout: 8), app.debugDescription)
        XCTAssertEqual(mainWindows(in: app).count, 1)
        XCTAssertTrue(app.sheets.firstMatch.staticTexts[sheetTitle].waitForExistence(timeout: 8), app.debugDescription)
    }

    func testFinderComposeOpenAfterMainClose() throws {
        try checkFinderFileOpenAfterMainClose(
            filename: "compose.yml", contents: "services: {}\n", sheetTitle: "Run Compose Project"
        )
    }

    func testFinderDockerfileOpenAfterMainClose() throws {
        try checkFinderFileOpenAfterMainClose(
            filename: "Dockerfile.yaml", contents: "FROM scratch\n", sheetTitle: "Build Image"
        )
    }

    func testRapidContainerRequestsAfterCloseShowLatestDetail() {
        let app = launch(routeFixtures: true)
        defer { app.terminate() }
        mainWindows(in: app).firstMatch.click()
        app.typeKey("w", modifierFlags: .command)
        waitForMainCount(0, in: app)

        clickMenuButton("Gantry Fixture A", in: app)
        waitForMainCount(1, in: app)
        waitForRenderedContainer("Gantry Fixture A", image: "fixture-a:1", in: app)
        XCTAssertEqual(NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).count, 1)
        clickMenuButton("Gantry Fixture B", in: app)
        waitForMainCount(1, in: app)
        waitForRenderedContainer("Gantry Fixture B", image: "fixture-b:1", in: app)
        XCTAssertEqual(NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).count, 1)
    }

    func testNotificationClickReopensClosedMainAndSelectsContainer() {
        let app = launch(routeFixtures: true)
        defer { app.terminate() }
        mainWindows(in: app).firstMatch.click()
        app.typeKey("w", modifierFlags: .command)
        waitForMainCount(0, in: app)
        clickMenuButton("Simulate fixture notification", in: app)
        XCTAssertTrue(mainWindows(in: app).firstMatch.waitForExistence(timeout: 8), app.debugDescription)
        waitForMainCount(1, in: app)
        waitForRenderedContainer("Gantry Fixture B", image: "fixture-b:1", in: app)
    }

    func testHostTerminalWindowsRemainIndependent() {
        let app = launch(routeFixtures: true)
        defer { app.terminate() }
        clickMenuButton("Open fixture terminal", in: app)
        clickMenuButton("Open fixture terminal", in: app)
        XCTAssertEqual(mainWindows(in: app).count, 1)
        XCTAssertEqual(app.windows.containing(.staticText, identifier: "Host Unavailable").count, 2)
        XCTAssertEqual(NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).count, 1)
    }

    func testSettingsWindowRemainsSeparate() {
        let app = launch()
        defer { app.terminate() }
        app.typeKey(",", modifierFlags: .command)
        XCTAssertTrue(
            app.windows["com_apple_SwiftUI_Settings_window"].waitForExistence(timeout: 5),
            app.debugDescription
        )
        XCTAssertEqual(mainWindows(in: app).count, 1)
    }

    func testRelaunchAndActivationKeepOneMainWindowAndProcess() {
        let app = launch()
        XCTAssertEqual(mainWindows(in: app).count, 1)
        app.terminate()
        app.launch()
        app.activate()
        XCTAssertTrue(mainWindows(in: app).firstMatch.waitForExistence(timeout: 8))
        XCTAssertEqual(mainWindows(in: app).count, 1)
        XCTAssertEqual(NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).count, 1)
        app.terminate()
    }
}
