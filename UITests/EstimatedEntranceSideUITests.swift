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
        XCTAssertEqual(app.staticTexts["mini.evidenceStatus"].label, "Estimated")
        XCTAssertFalse(app.staticTexts["mini.entranceSideWarning"].exists)
        expandEvidence()
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
        expandEvidence()
        XCTAssertTrue(warning.label.lowercased().contains("historical"))
        XCTAssertFalse(app.buttons["mini.navigate"].exists)
        app.buttons["mini.prepare"].tap()
        XCTAssertTrue(app.navigationBars["Check Door Pin"].waitForExistence(timeout: 5))
        app.descendants(matching: .any).matching(identifier: "door.evidenceDetails").firstMatch.tap()
        let reviewWarning = app.descendants(matching: .any).matching(identifier: "door.entranceSideWarning").firstMatch
        XCTAssertTrue(reviewWarning.waitForExistence(timeout: 5))
        XCTAssertTrue(reviewWarning.label.lowercased().contains("unverified"))
        XCTAssertFalse(app.buttons["door.confirm"].isEnabled)
        capture("Copper Creek estimates retain exact streets and qualified floors")

        app.terminate()
        open("lyric")
        XCTAssertEqual(app.staticTexts["mini.evidenceStatus"].label, "Estimated shared entry")
        expandEvidence()
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
        XCTAssertEqual(app.staticTexts["mini.evidenceStatus"].label, "Estimated shared entry")
        expandEvidence()
        XCTAssertTrue(shared.waitForExistence(timeout: 5))
        XCTAssertTrue(shared.label.contains("1287/1288"))
        XCTAssertTrue(shared.label.lowercased().contains("unverified"))
        XCTAssertTrue(shared.label.lowercased().contains("uncalibrated"))
        XCTAssertTrue(shared.label.lowercased().contains("floor unknown"))
        let laterSharedPin = app.buttons["mini.pin.4.entrance-estimate:lyric:304-e-silverado-ranch-blvd:unit-1287"]
        XCTAssertTrue(laterSharedPin.waitForExistence(timeout: 5))
        XCTAssertTrue(laterSharedPin.label.contains("Estimated shared entry, units 1287/1288"))
        XCTAssertFalse(laterSharedPin.label.contains("Checked door"))
        XCTAssertEqual(app.buttons["mini.prepare"].label, "Check / correct estimated pin")
        XCTAssertFalse(app.buttons["mini.navigate"].exists)
        capture("Both Lyric shared entry estimates retain unknown floors and unverified doors")
    }

    private func expandEvidence() {
        let details = app.descendants(matching: .any).matching(identifier: "mini.evidenceDetails").firstMatch
        XCTAssertTrue(details.waitForExistence(timeout: 5))
        details.tap()
    }

    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
