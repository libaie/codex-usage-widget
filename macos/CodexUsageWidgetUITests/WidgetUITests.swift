import Foundation
import XCTest

final class WidgetUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testDemoRingAndDetailsAreAccessible() throws {
        let application = XCUIApplication()
        application.launchArguments = ["--demo"]
        application.launch()

        let ring = application.buttons["usage-ring"]
        XCTAssertTrue(ring.waitForExistence(timeout: 8))
        try saveScreenshot(ring, name: "widget-ring-macos.png")
        ring.click()
        let details = application.groups["usage-details"]
        XCTAssertTrue(details.waitForExistence(timeout: 3))
        XCTAssertTrue(application.staticTexts["usage-status"].exists)
        try saveScreenshot(details, name: "widget-details-macos.png")
        application.typeKey(.escape, modifierFlags: [])
        XCTAssertFalse(application.groups["usage-details"].waitForExistence(timeout: 1))
    }

    private func saveScreenshot(_ element: XCUIElement, name: String) throws {
        let directory = ProcessInfo.processInfo.environment["CODEX_SCREENSHOT_DIR"] ?? "/tmp/codex-widget-screenshots"
        let output = URL(fileURLWithPath: directory, isDirectory: true).appendingPathComponent(name)
        try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        try element.screenshot().pngRepresentation.write(to: output, options: .atomic)
    }
}
