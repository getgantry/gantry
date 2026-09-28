import XCTest

@MainActor
final class BlankSheetUITests: XCTestCase {
    private func launch(_ scenario: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            scenario,
            "-ApplePersistenceIgnoreState", "YES",
            "-showMenuBarExtra", "YES",
            "-showDockIcon", "YES"
        ]
        if scenario.contains("host-key") || scenario.contains("credential") {
            app.launchArguments.append("--gantry-test-no-container-check")
        }
        // Discovery honors this path before standard locations. It cannot
        // execute any installed CLI or mutate tooling state.
        app.launchEnvironment["GANTRY_APPLE_CONTAINER_CLI"] =
            "/tmp/gantry-ui-missing-container-\(UUID().uuidString)"
        app.launch()
        app.activate()
        let main = mainWindow(in: app)
        if !main.waitForExistence(timeout: 3) {
            let item = app.statusItems["MenuBarIcon"]
            XCTAssertTrue(item.waitForExistence(timeout: 5))
            item.click()
            let openButton = app.dialogs.firstMatch.buttons["Open Gantry"]
            XCTAssertTrue(openButton.waitForExistence(timeout: 5))
            openButton.click()
            XCTAssertTrue(main.waitForExistence(timeout: 5), app.debugDescription)
        }
        return app
    }

    private func mainWindow(in app: XCUIApplication) -> XCUIElement {
        app.windows.containing(.button, identifier: "Add Host…").firstMatch
    }

    private func closeMainWindow(in app: XCUIApplication) {
        let main = mainWindow(in: app)
        XCTAssertTrue(main.waitForExistence(timeout: 5))
        main.click()
        app.typeKey("w", modifierFlags: .command)
        assertDisappears(main, within: 3)
    }

    private func assertDisappears(_ element: XCUIElement, within seconds: TimeInterval) {
        let gone = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [gone], timeout: seconds), .completed)
    }

    /// A populated request becomes absent while presented. The old Boolean
    /// presenter could remain true and leave an empty 100x80 modal.
    func testClearedSetupPayloadDismissesSheetAndWindowCloses() {
        let app = launch("--gantry-test-clear-container-setup")
        defer { app.terminate() }
        let sheet = app.sheets.firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: 5))
        XCTAssertTrue(sheet.buttons["Later"].exists)
        assertDisappears(sheet, within: 15)
        closeMainWindow(in: app)
    }

    private func checkToolingPrompt(_ scenario: String, title: String) {
        let app = launch(scenario)
        defer { app.terminate() }
        let sheet = app.sheets.firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(sheet.staticTexts[title].exists)
        sheet.buttons["Later"].click()
        assertDisappears(sheet, within: 3)
        closeMainWindow(in: app)
    }

    func testMissingToolingShowsPopulatedSetup() {
        checkToolingPrompt("--gantry-test-container-missing", title: "Install apple/container")
    }

    func testOutdatedToolingShowsPopulatedSetup() {
        checkToolingPrompt("--gantry-test-container-outdated", title: "Update apple/container")
    }

    func testCurrentToolingHasNoSetupAndWindowReopens() {
        let app = launch("--gantry-test-container-current")
        defer { app.terminate() }
        XCTAssertFalse(app.sheets.firstMatch.waitForExistence(timeout: 2))
        closeMainWindow(in: app)

        let item = app.statusItems["MenuBarIcon"]
        XCTAssertTrue(item.waitForExistence(timeout: 5))
        item.click()
        let openButton = app.dialogs.firstMatch.buttons["Open Gantry"]
        XCTAssertTrue(openButton.waitForExistence(timeout: 5))
        openButton.click()
        XCTAssertTrue(mainWindow(in: app).waitForExistence(timeout: 5))
        closeMainWindow(in: app)
    }

    func testAddHostInstallTransitionsToPopulatedSetupSheet() {
        let app = launch("--gantry-test-no-container-check")
        defer { app.terminate() }
        let mainWindow = mainWindow(in: app)
        let addButton = mainWindow.buttons["Add Host…"]
        XCTAssertTrue(addButton.waitForExistence(timeout: 5))
        addButton.click()

        let addHost = app.sheets.firstMatch
        XCTAssertTrue(addHost.waitForExistence(timeout: 5))
        let appleChoice = addHost.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@", "Apple Container")).firstMatch
        XCTAssertTrue(appleChoice.waitForExistence(timeout: 5), addHost.debugDescription)
        appleChoice.click()
        let installLink = addHost.buttons["Install apple/container…"]
        XCTAssertTrue(installLink.waitForExistence(timeout: 5))
        installLink.click()

        let setup = app.sheets.firstMatch
        XCTAssertTrue(setup.waitForExistence(timeout: 5))
        XCTAssertTrue(setup.buttons["Later"].exists)
        XCTAssertFalse(setup.buttons["Cancel"].exists, "Add Host must be dismissed")
        setup.buttons["Later"].click()
        assertDisappears(setup, within: 3)
        closeMainWindow(in: app)
    }

    private func checkClearedPrompt(_ scenario: String, title: String) {
        let app = launch(scenario)
        defer { app.terminate() }
        let sheet = app.sheets.firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(sheet.staticTexts[title].exists, sheet.debugDescription)
        assertDisappears(sheet, within: 10)
        closeMainWindow(in: app)
    }

    func testHostKeyPayloadClearDismissesSheet() {
        checkClearedPrompt("--gantry-test-clear-host-key", title: "Verify Host Key")
    }

    func testCredentialPayloadClearDismissesSheet() {
        checkClearedPrompt("--gantry-test-clear-credential", title: "SSH Password")
    }
}
