import XCTest

final class WidgetUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testDemoRingAndDetailsAreAccessible() {
        let application = XCUIApplication()
        application.launchArguments = ["--demo"]
        application.launch()

        let ring = application.buttons["usage-ring"]
        XCTAssertTrue(ring.waitForExistence(timeout: 8))
        ring.click()
        XCTAssertTrue(application.groups["usage-details"].waitForExistence(timeout: 3))
        XCTAssertTrue(application.staticTexts["usage-status"].exists)
        application.typeKey(.escape, modifierFlags: [])
        XCTAssertFalse(application.groups["usage-details"].waitForExistence(timeout: 1))
    }
}
