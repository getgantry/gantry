import XCTest

/// Walks the accessibility tree of the main window and fails on a button that
/// VoiceOver cannot name. Uses the in-memory fixture host: no host or setting
/// of the installed app changes.
@MainActor
final class AccessibilityLabelsUITests: XCTestCase {
    private let controlTypes: [XCUIElement.ElementType] = [.button, .menuButton, .popUpButton]

    override func setUp() async throws {
        try XCTSkipUnless(Self.automationModeUsable(), "Automation Mode needs user authentication on this Mac")
    }

    /// False when `automationmodetool` says that Automation Mode is off and needs a password.
    private static func automationModeUsable() -> Bool {
        let tool = Process()
        tool.executableURL = URL(fileURLWithPath: "/usr/bin/automationmodetool")
        let pipe = Pipe()
        tool.standardOutput = pipe
        tool.standardError = pipe
        guard (try? tool.run()) != nil else { return true }
        tool.waitUntilExit()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return !(output.contains("is disabled") && output.contains("requires user authentication"))
    }

    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "-ApplePersistenceIgnoreState", "YES",
            "-showDockIcon", "YES",
            "-showMenuBarExtra", "YES",
            "--gantry-test-window-routes", "--gantry-test-in-memory-containers"
        ]
        app.launch()
        app.activate()
        XCTAssertTrue(mainWindow(in: app).waitForExistence(timeout: 10), app.debugDescription)
        return app
    }

    private func mainWindow(in app: XCUIApplication) -> XCUIElement {
        app.windows.containing(.button, identifier: "Add Host…").firstMatch
    }

    /// Descriptions of the buttons in `root` that have neither a label nor a title.
    private func unlabeledControls(in root: XCUIElement) -> [String] {
        var missing: [String] = []
        for type in controlTypes {
            for element in root.descendants(matching: type).allElementsBoundByIndex where element.exists {
                let label = element.label.trimmingCharacters(in: .whitespaces)
                let title = element.title.trimmingCharacters(in: .whitespaces)
                if label.isEmpty && title.isEmpty {
                    missing.append("\(type.rawValue) id=\(element.identifier) frame=\(element.frame)")
                }
            }
        }
        return missing
    }

    private func assertAllLabeled(_ app: XCUIApplication, _ screen: String) {
        let missing = unlabeledControls(in: mainWindow(in: app))
        XCTAssertTrue(missing.isEmpty, "\(screen): buttons without a label:\n" + missing.joined(separator: "\n"))
    }

    private func selectSidebarRow(_ title: String, in app: XCUIApplication) {
        let row = mainWindow(in: app).outlines.firstMatch.staticTexts[title].firstMatch
        guard row.waitForExistence(timeout: 3) else { return }
        row.click()
    }

    func testEveryButtonInMainWindowHasALabel() {
        let app = launch()
        defer { app.terminate() }
        assertAllLabeled(app, "Launch")

        for section in ["Overview", "Containers", "Images", "Volumes", "Networks"] {
            selectSidebarRow(section, in: app)
            assertAllLabeled(app, section)
        }

        // The fixture route opens a container detail view with its tab bar.
        let item = app.statusItems["MenuBarIcon"]
        XCTAssertTrue(item.waitForExistence(timeout: 5), app.debugDescription)
        item.click()
        let button = app.dialogs.firstMatch.buttons["Gantry Fixture A"]
        XCTAssertTrue(button.waitForExistence(timeout: 5), app.debugDescription)
        button.click()
        XCTAssertTrue(
            mainWindow(in: app).staticTexts["Gantry Fixture A"].firstMatch.waitForExistence(timeout: 8),
            app.debugDescription
        )
        assertAllLabeled(app, "Container detail")
    }

    func testHostHeaderExposesNameAndStatus() {
        let app = launch()
        defer { app.terminate() }
        let header = mainWindow(in: app).descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@", "Gantry Fixture Host")).firstMatch
        XCTAssertTrue(header.waitForExistence(timeout: 5), mainWindow(in: app).debugDescription)
        let value = header.value as? String ?? ""
        XCTAssertFalse(value.isEmpty, "The host header has no status value: \(header.debugDescription)")
        let menu = mainWindow(in: app).menuButtons["Host actions for Gantry Fixture Host"]
        XCTAssertTrue(menu.exists, "The host actions menu is not in the accessibility tree")
    }
}
