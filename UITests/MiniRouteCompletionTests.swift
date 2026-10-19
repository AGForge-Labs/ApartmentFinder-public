import XCTest

final class MiniRouteCompletionTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["--uitesting", "--test-store", UUID().uuidString,
                               "--reset-test-inbox", "--synthetic-map-location"]
        app.launch()
        XCTAssertTrue(app.buttons["apartments.import"].waitForExistence(timeout: 20))
        app.launchArguments.removeAll { $0 == "--reset-test-inbox" }
        app.buttons["test.mixed"].tap()
        XCTAssertTrue(app.buttons["manifest.import"].waitForExistence(timeout: 10))
        app.buttons["manifest.import"].tap()
        XCTAssertTrue(app.buttons["apartment.2one5"].waitForExistence(timeout: 10))
    }

    override func tearDown() {
        let image = XCTAttachment(screenshot: app.screenshot())
        image.name = "Scoped completion final screen"
        image.lifetime = .keepAlways
        add(image)
        app.terminate()
        super.tearDown()
    }

    func testOneTapCompletesOnlyTheActiveMiniRouteWithoutConfirmation() {
        openMiniRoute()
        let complete = app.buttons["mini.completeRoute"]
        XCTAssertTrue(complete.label.contains("2 remaining stops"))
        screenshot("Active mini-route scoped completion control")
        complete.tap()
        expectComplete()
        screenshot("Completed mini-route with persisted Undo control")
        XCTAssertFalse(app.alerts.firstMatch.exists)
        XCTAssertFalse(app.sheets.firstMatch.exists)
        returnToApartments()
        XCTAssertTrue(app.buttons["apartment.2one5"].label.contains("Complete"))
        XCTAssertTrue(app.buttons["apartment.pace"].label.contains("2 of 2 deliveries left"))
        XCTAssertTrue(app.buttons["apartments.review"].label.contains("2 other stops"))
        app.buttons["apartment.pace"].tap()
        XCTAssertFalse(app.buttons["mini.undoRoute"].exists)
        app.buttons["mini.start"].tap()
        expectNext(sequence: "2")
    }

    func testPersistedBatchUndoKeepsPreviouslyDeliveredStopAcrossRelaunch() {
        openMiniRoute()
        app.buttons["mini.delivered"].tap()
        expectNext(sequence: "6")
        expectEnabled(app.buttons["mini.completeRoute"])
        XCTAssertTrue(app.buttons["mini.completeRoute"].label.contains("1 remaining stop"))
        app.buttons["mini.completeRoute"].tap()
        expectComplete()
        expectEnabled(app.buttons["mini.undoRoute"])

        app.terminate()
        app.launch()
        XCTAssertTrue(app.buttons["apartment.2one5"].waitForExistence(timeout: 20))
        XCTAssertTrue(app.buttons["apartment.pace"].label.contains("2 of 2 deliveries left"))
        openMiniRoute()
        expectComplete()
        let undo = app.buttons["mini.undoRoute"]
        expectEnabled(undo)
        undo.tap()
        expectNext(sequence: "6")
        screenshot("Batch Undo preserves the previously delivered stop")
        expectEnabled(app.buttons["mini.delivered"])
        XCTAssertFalse(app.buttons["mini.undoRoute"].exists)

        app.terminate()
        app.launch()
        XCTAssertTrue(app.buttons["apartment.2one5"].waitForExistence(timeout: 20))
        app.buttons["apartment.2one5"].tap()
        XCTAssertTrue(app.buttons["mini.stop.3"].label.contains("Delivered"))
        XCTAssertFalse(app.buttons["mini.stop.6"].label.contains("Delivered"))
        app.buttons["mini.start"].tap()
        expectNext(sequence: "6")
    }

    private func openMiniRoute() {
        app.buttons["apartment.2one5"].tap()
        XCTAssertTrue(app.buttons["mini.start"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["mini.completeRoute"].exists,
                       "Batch completion is available only on the active mini-route map")
        app.buttons["mini.start"].tap()
        XCTAssertTrue(app.maps.firstMatch.waitForExistence(timeout: 8))
    }

    private func returnToApartments() {
        app.navigationBars.buttons["Apartments"].tap()
        XCTAssertTrue(app.buttons["apartment.2one5"].waitForExistence(timeout: 5))
    }

    private func expectComplete() {
        XCTAssertTrue(app.staticTexts["Apartment complete"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.maps.firstMatch.exists)
        expectEnabled(app.buttons["mini.undoRoute"])
    }

    private func expectNext(sequence: String) {
        let next = app.staticTexts["mini.next"]
        XCTAssertTrue(next.waitForExistence(timeout: 5))
        expectation(for: NSPredicate(format: "label ENDSWITH %@", "Stop \(sequence)"), evaluatedWith: next)
        waitForExpectations(timeout: 5)
    }

    private func expectEnabled(_ button: XCUIElement) {
        XCTAssertTrue(button.waitForExistence(timeout: 5))
        expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: button)
        waitForExpectations(timeout: 5)
    }

    private func screenshot(_ name: String) {
        let image = XCTAttachment(screenshot: app.screenshot())
        image.name = name
        image.lifetime = .keepAlways
        add(image)
    }
}
