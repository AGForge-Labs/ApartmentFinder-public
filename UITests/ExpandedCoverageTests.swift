import XCTest

final class ExpandedCoverageTests: XCTestCase {
    private func simulate(_ community: String, units: [String], buildings: [String]? = nil) {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting", "--test-store", UUID().uuidString,
                               "--reset-test-inbox", "--coverage-" + community]
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.buttons["test.mixed"].waitForExistence(timeout: 20))
        app.buttons["test.mixed"].tap()
        XCTAssertTrue(app.buttons["manifest.import"].waitForExistence(timeout: 10))
        app.buttons["manifest.import"].tap()
        XCTAssertTrue(app.buttons["apartment." + community].waitForExistence(timeout: 10))
        app.buttons["apartment." + community].tap()
        app.buttons["mini.start"].tap()
        XCTAssertTrue(app.maps.firstMatch.waitForExistence(timeout: 8))
        XCTAssertFalse(app.navigationBars["Check Door Pin"].exists)
        XCTAssertFalse(app.staticTexts["mini.coverage"].label.contains("not mapped"))
        for index in units.indices {
            let pins = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "mini.pin.\(index + 1)."))
            XCTAssertTrue(pins.firstMatch.waitForExistence(timeout: 5))
            XCTAssertEqual(pins.count, 1, "Each address and unit must resolve to one pin")
            XCTAssertTrue(pins.firstMatch.label.contains(units[index]))
            if let buildings { XCTAssertTrue(pins.firstMatch.label.contains("building " + buildings[index])) }
        }
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = community + " imported units on mini-route map"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        XCTAssertEqual(app.staticTexts["mini.next"].label, "Next · Stop 1")
        app.buttons["mini.delivered"].tap()
        XCTAssertEqual(app.staticTexts["mini.next"].label, "Next · Stop 2")
        XCTAssertTrue(app.maps.firstMatch.exists)
        app.buttons["mini.delivered"].tap()
        XCTAssertTrue(app.staticTexts["Apartment complete"].waitForExistence(timeout: 5))
    }

    func testSanTropezNewManifestHasUnitPinsAndAdvances() {
        simulate("san-tropez", units: ["1001", "1043"], buildings: ["1", "6"])
    }
    func testTangoBayNewManifestHasUnitPinsAndAdvances() {
        simulate("tango-bay", units: ["101", "107"], buildings: ["1", "2"])
    }
    func testVistanaRepeatedUnitAtDifferentStreetNumbersHasCorrectPins() {
        simulate("vistana", units: ["102", "102"], buildings: ["1", "16"])
    }
    func testSouthBeachNewManifestHasUnitPinsAndAdvances() {
        simulate("south-beach", units: ["2001", "2002"], buildings: ["1", "1"])
    }
}
