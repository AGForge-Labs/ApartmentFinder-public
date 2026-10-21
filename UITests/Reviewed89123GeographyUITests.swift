import XCTest

/// Invented deliveries against reviewed public facts. No personal store is read.
final class Reviewed89123GeographyUITests: XCTestCase {
    private var app: XCUIApplication!
    override func setUp() { super.setUp(); continueAfterFailure = false; app = XCUIApplication() }
    override func tearDown() {
        if app.state == .runningForeground { capture("Reviewed 89123 final screen") }
        app.terminate(); super.tearDown()
    }
    private func open(_ id: String) {
        app.launchArguments = ["--uitesting", "--test-store", UUID().uuidString, "--reset-test-inbox",
            "--reviewed-89123-manifest", "--synthetic-map-location", "--synthetic-map-direction"]
        app.launch()
        XCTAssertTrue(app.buttons["test.mixed"].waitForExistence(timeout: 25))
        let requestStart = Date()
        app.buttons["test.mixed"].tap()
        let originalPreviewFound = app.buttons["manifest.import"].waitForExistence(timeout: 10)
        if !originalPreviewFound {
            // Observe only after saving the original result; diagnostics cannot
            // convert a late preview into a successful setup assertion.
            let raw = app.buttons["test.import"].value as? String ?? ""
            let pattern = #"\AmixedAttempts=[0-9]+;importAttempts=[0-9]+;shareAttempts=[0-9]+;lastAction=(none|mixed|manifestImport|share|productionImport);fixtureReady=(true|false);loading=(true|false);documents=[0-9]+;errorPresent=(true|false)\z"#
            let status = raw.count <= 300 && raw.range(of: pattern, options: .regularExpression) != nil ? raw : "unavailable"
            print("REVIEWED_IMPORT_SETUP originalPreview=false;\(status);previewSheet=\(app.navigationBars["Preview manifest"].exists);alert=\(app.alerts["ApartmentFinder"].exists)")
        }
        XCTAssertTrue(originalPreviewFound)
        guard originalPreviewFound else { return }
        print("REVIEWED_IMPORT_SETUP originalPreview=true;requestToPreviewMilliseconds=\(Date().timeIntervalSince(requestStart) * 1000)")
        app.buttons["manifest.import"].tap()
        XCTAssertTrue(app.buttons["apartment.\(id)"].waitForExistence(timeout: 10)); app.buttons["apartment.\(id)"].tap()
        app.buttons["mini.start"].tap()
        XCTAssertTrue(app.maps.firstMatch.waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["mini.recenter"].waitForExistence(timeout: 10))
    }
    private func pins(containing id: String) -> XCUIElementQuery {
        if id.isEmpty { return app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "mini.pin.")) }
        return app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND identifier CONTAINS %@", "mini.pin.", id))
    }
    private func waitForCount(_ query: XCUIElementQuery, _ count: Int, file: StaticString = #filePath, line: UInt = #line) {
        let expected = NSPredicate { _, _ in query.count == count }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: expected, object: nil)], timeout: 12), .completed,
            "Expected \(count) physical map annotations; found \(query.count)", file: file, line: line)
    }
    func testPebbleUsesOneApproximateMarkerPerBuildingAndRetainsUnitFloorSelection() {
        open("destinations-pebble")
        let markers = pins(containing: "destinations-pebble:building:")
        waitForCount(markers, 2)
        XCTAssertTrue(markers.allElementsBoundByIndex.allSatisfy { $0.label.contains("Approximate operator building area") && $0.label.contains("not a door") })
        XCTAssertTrue(app.staticTexts["mini.buildingReferenceWarning"].label.contains("20 m"))
        XCTAssertTrue(app.staticTexts["mini.buildingReferenceWarning"].label.contains("not guaranteed"))
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Map floor 1")).firstMatch.exists)
        XCTAssertEqual(app.buttons["mini.prepare"].label, "Add door pin on map")
        app.buttons["mini.focus.2"].tap()
        XCTAssertTrue(app.staticTexts["Unit 1001"].exists)
        waitForCount(markers, 2)
        XCTAssertTrue(markers.matching(NSPredicate(format: "label CONTAINS %@", "unit 1001")).firstMatch.exists)
        app.buttons["mini.focus.3"].tap()
        XCTAssertTrue(app.staticTexts["Unit 1159"].exists)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Operator map building 10")).firstMatch.exists)
        XCTAssertFalse(app.staticTexts["Community location not mapped"].exists)
        let camera = app.buttons["mini.recenter"].value as? String ?? ""
        let center = camera.components(separatedBy: ", map center ").last?.components(separatedBy: ", camera revision ").first?.split(separator: ",") ?? []
        XCTAssertEqual(center.count, 2)
        if center.count == 2, let latitude = Double(center[0]), let longitude = Double(center[1]) {
            XCTAssertTrue((36.028...36.032).contains(latitude) && (-115.135 ... -115.131).contains(longitude), "The real map must frame Pebble: \(camera)")
        } else { XCTFail("Missing native camera center: \(camera)") }
        print("89123-PEBBLE camera=\(camera), markers=\(markers.allElementsBoundByIndex.map { ($0.identifier, $0.frame, $0.label) })")
        capture("Pebble two approximate building areas, three selected source units")
    }
    func testStackedSourceUnitFloorsAndRecoveredSummerLabelsRemainUnverified() {
        open("prosper-150")
        waitForCount(pins(containing: "sightmap:38241:unit:"), 2)
        XCTAssertTrue(app.staticTexts["Unit 101"].exists)
        XCTAssertTrue(app.staticTexts["mini.sourceUnitWarning"].label.contains("not an entrance or door"))
        let ground = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "mini.pin.4.")).firstMatch
        XCTAssertTrue(ground.isHittable)
        ground.tap()
        XCTAssertTrue(app.staticTexts["Unit 101"].exists)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Floor 1")).firstMatch.exists)
        app.buttons["mini.focus.5"].tap()
        XCTAssertTrue(app.staticTexts["Unit 201"].exists)
        let upper = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "mini.pin.5.")).firstMatch
        XCTAssertTrue(upper.isHittable)
        upper.tap()
        XCTAssertTrue(app.staticTexts["Unit 201"].exists)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Floor 2")).firstMatch.exists)
        XCTAssertEqual(app.buttons["mini.prepare"].label, "Check suggested pin")
        capture("Prosper overlapping source positions retain independent floor selection")
        app.terminate(); open("summer-winds")
        waitForCount(pins(containing: "sightmap:369:unit:"), 2)
        XCTAssertTrue(app.staticTexts["Unit 1041"].exists)
        app.buttons["mini.focus.7"].tap(); XCTAssertTrue(app.staticTexts["Unit 1044"].exists)
        XCTAssertTrue(app.staticTexts["mini.sourceUnitWarning"].label.contains("not an entrance or door"))
        capture("Summer Winds recovered literal units 1041 and 1044")
    }
    func testHistoricalAliasAndFloorOnlyReferenceDoNotInventATowerOrDoor() {
        open("octave-apartments")
        waitForCount(pins(containing: "octave-building-1"), 1)
        XCTAssertTrue(app.staticTexts["mini.historicalAliasWarning"].label.contains("Historical legal alias"))
        XCTAssertTrue(app.staticTexts["mini.historicalAliasWarning"].label.contains("current signage unverified"))
        XCTAssertEqual(app.buttons["mini.prepare"].label, "Add door pin on map")
        capture("Octave historical legal alias is qualified")
        app.terminate(); open("one-las-vegas")
        waitForCount(pins(containing: ""), 0)
        XCTAssertTrue(app.staticTexts["mini.floorOnlyReference"].label.contains("County floor 1"))
        XCTAssertTrue(app.staticTexts["mini.floorOnlyReference"].label.contains("tower unknown"))
        XCTAssertTrue(app.staticTexts["mini.communityLocation"].label.contains("unit location unknown"))
        XCTAssertEqual(app.buttons["mini.prepare"].label, "Add door pin on map")
        print("89123-ONE-LAS-VEGAS camera=\(String(describing: app.buttons["mini.recenter"].value)); routePins=0; unitTowerJoins=0")
        capture("One Las Vegas tower areas are context only, never a guessed unit destination")
    }
    private func capture(_ title: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot()); attachment.name = title
        attachment.lifetime = .keepAlways; add(attachment)
    }
}
