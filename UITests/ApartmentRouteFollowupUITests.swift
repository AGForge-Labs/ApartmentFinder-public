import XCTest

final class ApartmentRouteFollowupUITests: XCTestCase {
    private var app: XCUIApplication!
    override func setUp() {
        super.setUp(); continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["--uitesting", "--test-store", UUID().uuidString, "--reset-test-inbox"]
    }
    override func tearDown() {
        if app.state == .runningForeground { screenshot("Follow-up final screen") }
        app.terminate(); super.tearDown()
    }
    private func launchAndImport(tuscano: Bool = false, gps: Bool = false) {
        if tuscano { app.launchArguments.append("--tuscano-manifest") }
        if gps { app.launchArguments.append("--synthetic-map-location") }
        app.launch()
        XCTAssertTrue(app.buttons["apartments.import"].waitForExistence(timeout: 20))
        app.launchArguments.removeAll { $0 == "--reset-test-inbox" }
        app.buttons["test.mixed"].tap()
        XCTAssertTrue(app.buttons["manifest.import"].waitForExistence(timeout: 10))
        app.buttons["manifest.import"].tap()
        XCTAssertTrue(app.buttons[tuscano ? "apartment.tuscano" : "apartment.2one5"].waitForExistence(timeout: 10))
    }
    private func start(_ id: String) {
        app.buttons["apartment.\(id)"].tap()
        app.buttons["mini.start"].tap()
        XCTAssertTrue(app.maps.firstMatch.waitForExistence(timeout: 8))
    }
    func testAddingUnknownUnitKeepsSelectedStopAndProgressAcrossDeliveryAndRelaunch() {
        launchAndImport(tuscano: true, gps: true)
        start("tuscano")
        app.buttons["mini.focus.3"].tap()
        XCTAssertTrue(app.staticTexts["Unit 2137"].waitForExistence(timeout: 5))
        app.buttons["mini.add"].tap()
        let unit = app.textFields["mini.add.unit"]
        XCTAssertTrue(unit.waitForExistence(timeout: 5)); unit.tap(); unit.typeText("99999")
        let number = app.textFields["mini.add.number"]
        number.tap(); number.typeText("44")
        XCTAssertTrue(app.staticTexts["mini.add.pinStatus"].label.contains("Add door pin"))
        screenshot("Add unit clearly keeps an unknown location unpinned")
        app.buttons["mini.add.save"].tap()
        XCTAssertTrue(app.staticTexts["Unit 2137"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.maps.firstMatch.exists)
        XCTAssertEqual(app.staticTexts["mini.next"].label, "Next · Stop 2")
        XCTAssertTrue(app.buttons["mini.focus.4"].exists)
        screenshot("Added unit keeps the active map and selected later stop")
        app.buttons["mini.delivered"].tap()
        XCTAssertTrue(app.staticTexts["Unit 2066"].waitForExistence(timeout: 5))
        app.terminate(); app.launch()
        XCTAssertTrue(app.buttons["apartment.tuscano"].waitForExistence(timeout: 20))
        app.buttons["apartment.tuscano"].tap()
        XCTAssertTrue(app.buttons["mini.stop.3"].label.contains("Delivered"))
        XCTAssertFalse(app.buttons["mini.stop.2"].label.contains("Delivered"))
        XCTAssertTrue(app.buttons["mini.stop.4"].label.contains("44"))
        app.buttons["mini.stop.4"].tap()
        XCTAssertTrue(app.staticTexts["Unit 99999"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["mini.navigate"].exists)
        screenshot("Added unknown unit and separate progress survive relaunch")
    }
    func testNextApartmentUsesGPSWithoutCompletingEitherUnfinishedRoute() {
        launchAndImport(gps: true)
        start("2one5")
        let next = app.buttons["mini.nextApartment"]
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", "m away"), object: next)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 8), .completed)
        next.doubleTap()
        XCTAssertTrue(app.staticTexts["mini.next"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["mini.next"].label, "Next · Stop 2")
        XCTAssertTrue(app.maps.firstMatch.exists)
        screenshot("Nearest other apartment opens while both routes stay pending")
        app.navigationBars.buttons["Apartments"].tap()
        XCTAssertTrue(app.buttons["apartment.2one5"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["apartment.2one5"].label.contains("2 of 2 deliveries left"))
        XCTAssertTrue(app.buttons["apartment.pace"].label.contains("2 of 2 deliveries left"))
        app.terminate(); app.launch()
        XCTAssertTrue(app.buttons["apartment.2one5"].waitForExistence(timeout: 20))
        XCTAssertTrue(app.buttons["apartment.2one5"].label.contains("2 of 2 deliveries left"))
        XCTAssertTrue(app.buttons["apartment.pace"].label.contains("2 of 2 deliveries left"))
    }
    func testDeniedGPSNamesManifestOrderFallbackWhileKeepingCurrentRouteUnfinished() {
        launchAndImport()
        start("2one5")
        let next = app.buttons["mini.nextApartment"]
        XCTAssertTrue(next.waitForExistence(timeout: 5))
        XCTAssertTrue(next.label.contains("GPS unavailable"))
        XCTAssertTrue(next.label.hasPrefix("Next in manifest"))
        screenshot("Unavailable GPS explicitly uses manifest order")
        next.tap()
        XCTAssertEqual(app.staticTexts["mini.next"].label, "Next · Stop 2")
        XCTAssertTrue(app.buttons["mini.delivered"].exists)
    }
    private func screenshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
}
