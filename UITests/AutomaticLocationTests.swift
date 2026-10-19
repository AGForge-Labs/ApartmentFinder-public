import XCTest

final class AutomaticLocationTests: XCTestCase {
    private var app: XCUIApplication!
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["--uitesting", "--test-store", UUID().uuidString, "--reset-test-inbox", "--tuscano-manifest"]
    }
    override func tearDown() {
        app.terminate()
        super.tearDown()
    }
    private func openRoute() {
        app.launch()
        XCTAssertTrue(app.buttons["test.mixed"].waitForExistence(timeout: 20))
        app.buttons["test.mixed"].tap()
        XCTAssertTrue(app.buttons["manifest.import"].waitForExistence(timeout: 10))
        app.buttons["manifest.import"].tap()
        XCTAssertTrue(app.buttons["apartment.tuscano"].waitForExistence(timeout: 10))
        app.buttons["apartment.tuscano"].tap()
        app.buttons["mini.start"].tap()
        XCTAssertTrue(app.maps.firstMatch.waitForExistence(timeout: 8))
    }
    func testSyntheticLocationAppearsWithoutArrowAndReturnsAfterCorrectionAndForeground() {
        app.launchArguments.append("--synthetic-map-location")
        openRoute()
        let dot = app.descendants(matching: .any).matching(identifier: "mini.userLocation").firstMatch
        XCTAssertTrue(dot.waitForExistence(timeout: 8), "The synthetic GPS dot must appear without tapping recenter")
        let pin = app.buttons["mini.pin.2.tuscano-unit-county-2187653-2066"]
        XCTAssertTrue(pin.exists)
        let mapFrame = app.maps.firstMatch.frame
        XCTAssertTrue(mapFrame.contains(CGPoint(x: dot.frame.midX, y: dot.frame.midY)))
        XCTAssertTrue(mapFrame.contains(CGPoint(x: pin.frame.midX, y: pin.frame.midY)))
        let image = XCTAttachment(screenshot: app.screenshot())
        image.name = "Synthetic location appears automatically with Tuscano door pins"
        image.lifetime = .keepAlways; add(image)

        app.buttons["mini.prepare"].tap()
        let doorDot = app.descendants(matching: .any).matching(identifier: "door.userLocation").firstMatch
        XCTAssertTrue(doorDot.waitForExistence(timeout: 8))
        let correctionMap = app.maps.firstMatch
        XCTAssertTrue(correctionMap.frame.contains(CGPoint(x: doorDot.frame.midX, y: doorDot.frame.midY)))
        app.buttons["Cancel"].tap()
        XCTAssertTrue(dot.waitForExistence(timeout: 8))

        XCUIDevice.shared.press(.home)
        XCTAssertTrue(app.wait(for: .runningBackground, timeout: 5) || app.state == .runningBackgroundSuspended)
        app.activate()
        XCTAssertTrue(dot.waitForExistence(timeout: 8), "Returning to the app must reacquire automatically")
        XCTAssertTrue(app.staticTexts["mini.locationStatus"].label.contains("GPS"))
    }
    func testDeniedLocationStillShowsDoorsAndExplainsPermission() {
        openRoute()
        let status = app.staticTexts["mini.locationStatus"]
        XCTAssertTrue(status.waitForExistence(timeout: 8))
        XCTAssertTrue(status.label.contains("Settings"))
        XCTAssertFalse(app.descendants(matching: .any).matching(identifier: "mini.userLocation").firstMatch.exists)
        let pin=app.buttons["mini.pin.2.tuscano-unit-county-2187653-2066"]
        XCTAssertTrue(pin.isHittable)
        let mapFrame=app.maps.firstMatch.frame
        XCTAssertTrue(mapFrame.contains(CGPoint(x:pin.frame.midX,y:pin.frame.midY)))
        let image=XCTAttachment(screenshot:app.screenshot())
        image.name="Denied GPS mini-route initially frames apartment pins with control padding"
        image.lifetime = .keepAlways;add(image)
    }
}
