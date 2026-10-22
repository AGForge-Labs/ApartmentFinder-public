import XCTest

/// Invented deliveries and a fresh test store; no personal route or pins are read.
final class EstimatedEntranceSideUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        app = XCUIApplication()
    }

    override func tearDown() {
        if app.state == .runningForeground { capture("Estimated entrance-side final screen") }
        app.terminate()
        super.tearDown()
    }

    private func open(_ community: String) {
        app.launchArguments = ["--uitesting", "--test-store", UUID().uuidString,
            "--reset-test-inbox", "--estimated-entry-manifest",
            "--synthetic-map-location", "--synthetic-map-direction"]
        app.launch()
        XCTAssertTrue(app.buttons["test.mixed"].waitForExistence(timeout: 25))
        app.buttons["test.mixed"].tap()
        XCTAssertTrue(app.buttons["manifest.import"].waitForExistence(timeout: 10))
        app.buttons["manifest.import"].tap()
        XCTAssertTrue(app.buttons["apartment.\(community)"].waitForExistence(timeout: 10))
        app.buttons["apartment.\(community)"].tap()
        app.buttons["mini.start"].tap()
        XCTAssertTrue(app.maps.firstMatch.waitForExistence(timeout: 10))
    }

    func testEstimatedEntryRegionsKeepStreetFloorAndSharedDoorUncertaintyVisible() {
        open("copper-creek")
        let warning = app.descendants(matching: .any).matching(identifier: "mini.entranceSideWarning").firstMatch
        XCTAssertTrue(warning.waitForExistence(timeout: 10))
        XCTAssertTrue(warning.label.lowercased().contains("unverified"))
        XCTAssertTrue(warning.label.lowercased().contains("uncalibrated"))
        XCTAssertTrue(warning.label.lowercased().contains("floor unknown"))
        XCTAssertFalse(app.buttons["mini.navigate"].exists)
        let first = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "mini.pin.1.")).firstMatch
        XCTAssertTrue(first.waitForExistence(timeout: 5))
        XCTAssertTrue(first.label.contains("126"))
        XCTAssertTrue(first.label.lowercased().contains("estimated"))
        XCTAssertFalse(first.label.contains("Checked door"))
        let frame = first.frame
        XCTAssertTrue([frame.minX, frame.minY, frame.width, frame.height].allSatisfy(\.isFinite))
        XCTAssertTrue(app.maps.firstMatch.frame.intersects(frame))
        app.buttons["mini.focus.2"].tap()
        XCTAssertTrue(app.staticTexts["Unit 1022"].exists)
        XCTAssertTrue(warning.label.lowercased().contains("historical"))
        XCTAssertFalse(app.buttons["mini.navigate"].exists)
        app.buttons["mini.prepare"].tap()
        XCTAssertTrue(app.navigationBars["Check Door Pin"].waitForExistence(timeout: 5))
        let reviewWarning = app.descendants(matching: .any).matching(identifier: "door.entranceSideWarning").firstMatch
        XCTAssertTrue(reviewWarning.waitForExistence(timeout: 5))
        XCTAssertTrue(reviewWarning.label.lowercased().contains("unverified"))
        XCTAssertFalse(app.buttons["door.confirm"].isEnabled)
        capture("Copper Creek estimates retain exact streets and qualified floors")

        app.terminate()
        open("lyric")
        let shared = app.descendants(matching: .any).matching(identifier: "mini.entranceSideWarning").firstMatch
        XCTAssertTrue(shared.waitForExistence(timeout: 10))
        XCTAssertTrue(shared.label.contains("1013/1014"))
        XCTAssertTrue(shared.label.lowercased().contains("shared"))
        XCTAssertTrue(shared.label.lowercased().contains("floor unknown"))
        XCTAssertFalse(app.buttons["mini.navigate"].exists)
        let sharedPin = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "mini.pin.3.")).firstMatch
        XCTAssertTrue(sharedPin.waitForExistence(timeout: 5))
        XCTAssertTrue(sharedPin.label.contains("1013/1014"))
        XCTAssertFalse(sharedPin.label.contains("Checked door"))
        app.buttons["mini.focus.4"].tap()
        XCTAssertTrue(app.staticTexts["Unit 1287"].exists)
        XCTAssertFalse(shared.exists)
        XCTAssertEqual(app.buttons["mini.prepare"].label, "Add door pin on map")
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "mini.pin.4.")).firstMatch.exists)
        capture("Lyric pair remains ambiguous and unit 1287 has no invented point")
    }

    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
