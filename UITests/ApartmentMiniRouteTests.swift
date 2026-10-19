import XCTest

final class ApartmentMiniRouteTests: XCTestCase {
    private var app: XCUIApplication!
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["--uitesting", "--test-store", UUID().uuidString, "--reset-test-inbox"]
        let tuscanoTests = [
            "testTappedLaterMapPinCompletesSelectedUnitAndReturnsToFirstPendingStop",
            "testSelectingLaterUnitInPickerDoesNotRequireReturningToCurrentStop",
            "testTuscanoStartOpensMapInsteadOfBlockingDoorForm",
            "testTuscanoPlacedDoorStaysOnMapAndSurvivesRelaunch",
            "testUnmappedUnitsStillStartOnMapAndRequireDeliberatePinPlacement"
        ]
        if tuscanoTests.contains(where: { name.contains($0) }) {
            app.launchArguments.append("--tuscano-manifest")
        }
        if name.contains("testUnmappedUnitsStillStartOnMapAndRequireDeliberatePinPlacement") {
            app.launchArguments.append("--unmapped-units")
        }
        if name.contains("testAmbiguousUnitFitsBothBuildingCandidatesAfterAnotherStopWasFocused") {
            app.launchArguments.append("--ambiguous-manifest")
        }
        app.launch()
        XCTAssertTrue(app.buttons["apartments.import"].waitForExistence(timeout: 20))
        app.launchArguments.removeAll { $0 == "--reset-test-inbox" }
    }
    override func tearDown() {
        let state = app.state
        let status = XCTAttachment(string: "Application state before teardown: \(state.rawValue)")
        status.name = "Mini-route application state"; status.lifetime = .keepAlways; add(status)
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = "Mini-route final screen"; attachment.lifetime = .keepAlways; add(attachment)
        if (testRun?.totalFailureCount ?? 0) > 0,
           state == .runningForeground || state == .runningBackground {
            let tree = XCTAttachment(string: app.debugDescription)
            tree.name = "Mini-route accessibility"; tree.lifetime = .keepAlways; add(tree)
        }
        if state != .notRunning && state != .unknown { app.terminate() }
        super.tearDown()
    }
    private func capture(_ name: String) {
        let image = XCTAttachment(screenshot: app.screenshot())
        image.name = name; image.lifetime = .keepAlways; add(image)
    }
    private func expectMap() {
        XCTAssertTrue(app.maps.firstMatch.waitForExistence(timeout: 8))
        XCTAssertGreaterThan(app.maps.firstMatch.frame.height, 250)
        XCTAssertFalse(app.navigationBars["Check Door Pin"].exists)
    }
    private func importTuscano() {
        app.buttons["test.mixed"].tap()
        XCTAssertTrue(app.buttons["manifest.import"].waitForExistence(timeout: 10))
        app.buttons["manifest.import"].tap()
        XCTAssertTrue(app.buttons["apartment.tuscano"].waitForExistence(timeout: 10))
        app.buttons["apartment.tuscano"].tap()
    }
    private func importMixed() {
        app.buttons["test.mixed"].tap()
        let button = app.buttons["manifest.import"]
        XCTAssertTrue(button.waitForExistence(timeout: 10)); button.tap()
        XCTAssertTrue(app.buttons["apartment.2one5"].waitForExistence(timeout: 10))
    }
    func testTappedLaterMapPinCompletesSelectedUnitAndReturnsToFirstPendingStop() {
        importTuscano()
        app.buttons["mini.start"].tap()
        expectMap()
        let laterPin = app.buttons["mini.pin.3.tuscano-unit-county-2187691-2137"]
        XCTAssertTrue(laterPin.waitForExistence(timeout: 5))
        laterPin.tap()
        XCTAssertTrue(app.staticTexts["Unit 2137"].waitForExistence(timeout: 5))
        let delivered = app.buttons["mini.delivered"]
        XCTAssertTrue(delivered.exists, "The explicitly selected pending unit needs its own Delivered action")
        XCTAssertTrue(delivered.label.contains("2137"), "The action must identify the selected unit")
        capture("Later selected map unit has its own Delivered action")
        delivered.tap()
        XCTAssertTrue(app.staticTexts["Unit 2066"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["mini.next"].label, "Next · Stop 2")
        XCTAssertFalse(app.buttons["mini.focus.2"].label.contains("delivered"))
        XCTAssertTrue(app.buttons["mini.focus.3"].label.contains("delivered"))
        capture("Only the selected later unit is delivered and the first pending unit is focused")
        app.terminate(); app.launch()
        app.buttons["apartment.tuscano"].tap()
        XCTAssertFalse(app.buttons["mini.stop.2"].label.contains("Delivered"))
        XCTAssertTrue(app.buttons["mini.stop.3"].label.contains("Delivered"))
        app.buttons["mini.start"].tap()
        XCTAssertTrue(laterPin.waitForExistence(timeout: 5))
        laterPin.tap()
        let undo = app.buttons["Undo delivered"]
        XCTAssertTrue(undo.waitForExistence(timeout: 5)); undo.tap()
        XCTAssertTrue(app.buttons["mini.delivered"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["mini.focus.3"].label.contains("delivered"))
        XCTAssertEqual(app.staticTexts["mini.next"].label, "Next · Stop 2")
        capture("Undo restores the selected later delivery after relaunch")
    }

    func testSelectingLaterUnitInPickerDoesNotRequireReturningToCurrentStop() {
        importTuscano()
        app.buttons["mini.start"].tap()
        app.buttons["mini.focus.3"].tap()
        app.buttons["mini.focus.2"].tap()
        app.buttons["mini.focus.3"].tap()
        XCTAssertTrue(app.staticTexts["Unit 2137"].waitForExistence(timeout: 5))
        let delivered = app.buttons["mini.delivered"]
        XCTAssertTrue(delivered.exists)
        delivered.tap()
        XCTAssertTrue(app.staticTexts["Unit 2066"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["mini.focus.3"].label.contains("delivered"))
        XCTAssertFalse(app.buttons["mini.focus.2"].label.contains("delivered"))
    }

    func testTuscanoStartOpensMapInsteadOfBlockingDoorForm() {
        importTuscano()
        XCTAssertTrue(app.buttons["mini.stop.2"].label.contains("2066"))
        XCTAssertTrue(app.buttons["mini.stop.3"].label.contains("2137"))
        app.buttons["mini.start"].tap()
        XCTAssertFalse(app.navigationBars["Check Door Pin"].waitForExistence(timeout: 3),
                       "Starting a mini-route must show the route map, not a blocking door form")
        expectMap()
        XCTAssertFalse(app.buttons["door.confirm"].exists)
        let firstPin = app.buttons["mini.pin.2.tuscano-unit-county-2187653-2066"]
        let secondPin = app.buttons["mini.pin.3.tuscano-unit-county-2187691-2137"]
        XCTAssertTrue(firstPin.waitForExistence(timeout: 5))
        XCTAssertTrue(firstPin.label.contains("building 9"))
        XCTAssertTrue(secondPin.exists)
        XCTAssertTrue(secondPin.label.contains("building 19"))
        XCTAssertFalse(app.buttons["mini.navigate"].exists)
        capture("Tuscano starts with researched units 2066 and 2137 on its map")
        app.buttons["mini.notes"].tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label ENDSWITH %@", "Leave the parcel only at the unit door after checking the building number.")).firstMatch.waitForExistence(timeout: 5))
        app.buttons["Done"].tap()
        app.buttons["mini.prepare"].tap()
        XCTAssertTrue(app.maps.firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["door.confirm"].isEnabled, "The researched unit pin can be reviewed without manually creating it")
        app.buttons["Cancel"].tap()
        expectMap()
        XCTAssertEqual(app.staticTexts["mini.next"].label, "Next · Stop 2")
        app.buttons["mini.delivered"].tap()
        expectMap()
        XCTAssertEqual(app.staticTexts["mini.next"].label, "Next · Stop 3")
        capture("Tuscano advances without opening another form")
        app.buttons["mini.delivered"].tap()
        XCTAssertTrue(app.staticTexts["Apartment complete"].waitForExistence(timeout: 5))
        expectMap()
        capture("Tuscano mini-route complete")
    }
    func testTuscanoPlacedDoorStaysOnMapAndSurvivesRelaunch() {
        importTuscano()
        app.buttons["mini.start"].tap()
        expectMap()
        app.buttons["mini.prepare"].tap()
        XCTAssertTrue(app.buttons["door.confirm"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["door.confirm"].isEnabled)
        // Deliberate synthetic tap in this test's isolated temporary store only.
        let map = app.maps.firstMatch
        XCTAssertTrue(map.waitForExistence(timeout: 5))
        map.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.55)).tap()
        XCTAssertTrue(app.buttons["door.confirm"].isEnabled)
        app.buttons["door.confirm"].tap()
        expectMap()
        let pin = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "mini.pin.2.")).firstMatch
        XCTAssertTrue(pin.waitForExistence(timeout: 5))
        XCTAssertTrue(pin.label.contains("2066"))
        XCTAssertTrue(app.buttons["mini.navigate"].exists)
        capture("Synthetic saved door appears as a numbered map pin")
        app.buttons["mini.navigate"].tap()
        let appleMaps = XCUIApplication(bundleIdentifier: "com.apple.Maps")
        XCTAssertTrue(appleMaps.wait(for: .runningForeground, timeout: 10), "Walking handoff must open Apple Maps")
        let handoff = XCTAttachment(screenshot: appleMaps.screenshot())
        handoff.name = "Apple Maps walking handoff from the checked Tuscano test door"
        handoff.lifetime = .keepAlways; add(handoff)
        app.activate()
        expectMap()
        app.buttons["mini.delivered"].tap()
        XCTAssertEqual(app.staticTexts["mini.next"].label, "Next · Stop 3")
        app.terminate(); app.launch()
        app.buttons["apartment.tuscano"].tap()
        XCTAssertTrue(app.buttons["mini.stop.2"].label.contains("Delivered"))
        app.buttons["mini.start"].tap()
        expectMap()
        XCTAssertEqual(app.staticTexts["mini.next"].label, "Next · Stop 3")
        XCTAssertTrue(pin.waitForExistence(timeout: 5))
        capture("Saved Tuscano pin and next stop survive relaunch")
    }
    func testUnmappedUnitsStillStartOnMapAndRequireDeliberatePinPlacement() {
        importTuscano()
        app.buttons["mini.start"].tap()
        expectMap()
        XCTAssertTrue(app.staticTexts["mini.coverage"].label.contains("2 doors not mapped"))
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "mini.pin.")).firstMatch.exists)
        app.buttons["mini.prepare"].tap()
        XCTAssertTrue(app.maps.firstMatch.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["door.confirm"].isEnabled, "The community center is not a door")
        XCTAssertTrue(app.buttons["door.mapStyle"].isHittable)
        app.buttons["door.mapStyle"].tap()
        app.buttons["Map"].tap()
        XCTAssertFalse(app.buttons["door.confirm"].isEnabled, "Choosing a map type must not place a door pin")
        app.buttons["Cancel"].tap()
        expectMap()
        app.buttons["mini.prepare"].tap()
        XCTAssertFalse(app.buttons["door.confirm"].isEnabled)
        app.maps.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(app.buttons["door.confirm"].isEnabled)
        app.buttons["door.confirm"].tap()
        expectMap()
        XCTAssertTrue(app.buttons["mini.navigate"].exists)
        app.buttons["mini.delivered"].tap()
        expectMap()
        XCTAssertEqual(app.staticTexts["mini.next"].label, "Next · Stop 3")
        app.terminate(); app.launch()
        app.buttons["apartment.tuscano"].tap()
        app.buttons["mini.start"].tap()
        expectMap()
        let saved = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "mini.pin.2.")).firstMatch
        XCTAssertTrue(saved.waitForExistence(timeout: 5))
        XCTAssertTrue(saved.label.contains("9998"))
        XCTAssertEqual(app.staticTexts["mini.next"].label, "Next · Stop 3")
        capture("A deliberately placed new door persists without inventing the other door")
    }
    func testAmbiguousUnitFitsBothBuildingCandidatesAfterAnotherStopWasFocused() {
        app.buttons["test.mixed"].tap()
        XCTAssertTrue(app.buttons["manifest.import"].waitForExistence(timeout: 10))
        app.buttons["manifest.import"].tap()
        let afterImportState = XCTAttachment(string: "Application state after import tap: \(app.state.rawValue)")
        afterImportState.name = "Import application state"; afterImportState.lifetime = .keepAlways; add(afterImportState)
        let afterImportScreen = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        afterImportScreen.name = "Import screen before apartment assertion"; afterImportScreen.lifetime = .keepAlways; add(afterImportScreen)
        XCTAssertTrue(app.buttons["apartment.sw"].waitForExistence(timeout: 10))
        app.buttons["apartment.sw"].tap()
        app.buttons["mini.start"].tap()
        expectMap()
        app.buttons["mini.focus.2"].tap()
        app.buttons["mini.focus.1"].tap()
        app.buttons["mini.focus.2"].tap()
        let candidates = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "mini.pin.2."))
        XCTAssertEqual(candidates.count, 2)
        let mapFrame = app.maps.firstMatch.frame
        for candidate in candidates.allElementsBoundByIndex {
            let candidateFrame = candidate.frame
            XCTAssertTrue(mapFrame.contains(CGPoint(x: candidateFrame.midX, y: candidateFrame.midY)))
        }
        XCTAssertEqual(app.buttons["mini.prepare"].label, "Choose building / door")
        XCTAssertFalse(app.buttons["mini.navigate"].exists)
        capture("Ambiguous unit shows both building candidates without choosing a door")
    }
    func testApartmentOnlyListIsOrderedAndUnmatchedStopsStayReviewable() {
        XCTAssertTrue(app.tabBars.buttons["Apartments"].isSelected)
        XCTAssertTrue(app.tabBars.buttons["Finder"].exists)
        XCTAssertFalse(app.tabBars.buttons["My maps"].exists)
        app.buttons["apartments.settings"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
        if !app.buttons["Export personal pins, paths and stops"].exists { app.swipeUp() }
        XCTAssertTrue(app.buttons["Export personal pins, paths and stops"].exists)
        app.buttons["Done"].tap()
        importMixed()
        let pace = app.buttons["apartment.pace"], rafael = app.buttons["apartment.2one5"]
        XCTAssertTrue(pace.exists)
        XCTAssertLessThan(pace.frame.minY, rafael.frame.minY)
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Synthetic House")).firstMatch.exists)
        XCTAssertTrue(app.buttons["apartments.review"].label.contains("2 other stops"))
        rafael.tap()
        let first = app.buttons["mini.stop.3"], second = app.buttons["mini.stop.6"]
        XCTAssertTrue(first.waitForExistence(timeout: 5)); XCTAssertTrue(second.exists)
        XCTAssertLessThan(first.frame.minY, second.frame.minY)
        XCTAssertTrue(first.label.contains("1379")); XCTAssertTrue(second.label.contains("Add unit"))
    }
    func testPinReviewDeliveryAdvanceMissingUnitAndRelaunch() {
        importMixed()
        app.buttons["apartment.2one5"].tap()
        app.buttons["mini.start"].tap()
        expectMap()
        let sourcePin = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "mini.pin.3.")).firstMatch
        XCTAssertTrue(sourcePin.waitForExistence(timeout: 5))
        XCTAssertTrue(sourcePin.label.contains("1379"))
        capture("Mapped apartment starts with a visible numbered unit pin")
        app.buttons["mini.prepare"].tap()
        let confirm = app.buttons["door.confirm"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 10))
        XCTAssertTrue(confirm.isEnabled)
        // Temporary test store only; this simulates the owner's deliberate pin check.
        confirm.tap()
        XCTAssertTrue(app.buttons["mini.navigate"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["mini.navigate"].label.contains("Apple Maps"))
        app.buttons["mini.delivered"].tap()
        expectMap()
        XCTAssertEqual(app.staticTexts["mini.next"].label, "Next · Stop 6")
        app.buttons["mini.prepare"].tap()
        let setUnit = app.buttons["door.setUnit"]
        XCTAssertTrue(setUnit.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["door.confirm"].isEnabled)
        app.textFields["door.unit"].tap(); app.textFields["door.unit"].typeText("1011")
        setUnit.tap()
        XCTAssertTrue(app.buttons["door.confirm"].isEnabled)
        app.buttons["door.confirm"].tap()
        XCTAssertEqual(app.staticTexts["mini.next"].label, "Next · Stop 6")
        app.terminate(); app.launch()
        app.buttons["apartment.2one5"].tap()
        XCTAssertTrue(app.buttons["mini.stop.3"].label.contains("Delivered"))
        app.buttons["mini.start"].tap()
        XCTAssertTrue(app.buttons["mini.navigate"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["mini.next"].label, "Next · Stop 6")
    }
    func testReviewingAHouseKeepsItOffApartmentListAcrossRelaunch() {
        importMixed()
        app.buttons["apartments.review"].tap()
        app.buttons["address.review.1"].tap()
        app.buttons["House or business"].tap()
        app.buttons["address.save"].tap()
        app.terminate(); app.launch()
        XCTAssertTrue(app.buttons["apartments.review"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["apartments.review"].label.contains("1 other stops"))
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "apartment.personal-")).firstMatch.exists)
    }
}
