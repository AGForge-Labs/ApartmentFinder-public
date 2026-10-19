import XCTest

final class LocalLookupTests: XCTestCase {
    func testSelectingMissingUnitKeepsOtherUnitPinOnMap() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting", "--test-store", UUID().uuidString, "--reset-test-inbox"]
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.buttons["apartments.import"].waitForExistence(timeout: 20))
        app.buttons["test.mixed"].tap()
        XCTAssertTrue(app.buttons["manifest.import"].waitForExistence(timeout: 10))
        app.buttons["manifest.import"].tap()
        XCTAssertTrue(app.buttons["apartment.2one5"].waitForExistence(timeout: 10))
        app.buttons["apartment.2one5"].tap()
        app.buttons["mini.start"].tap()
        XCTAssertTrue(app.maps.firstMatch.waitForExistence(timeout: 8))
        let pin = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "mini.pin.3.")).firstMatch
        XCTAssertTrue(pin.waitForExistence(timeout: 5))
        XCTAssertTrue(pin.label.contains("1379"))
        app.buttons["mini.focus.6"].tap()
        XCTAssertTrue(app.staticTexts["Add apartment unit"].exists)
        XCTAssertTrue(pin.exists, "Choosing an unmapped stop must not remove the other delivery pins")
        app.buttons["mini.focus.3"].tap()
        XCTAssertTrue(app.staticTexts["Unit 1379"].exists)
        XCTAssertTrue(app.maps.firstMatch.exists)
        let image = XCTAttachment(screenshot: app.screenshot())
        image.name = "Known unit pin stays visible beside a missing unit"; image.lifetime = .keepAlways; add(image)
    }
}
