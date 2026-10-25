import XCTest

final class FinderTabTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        app = XCUIApplication()
        let replacement = name.contains("testFinderSelectionAndDestinationSurviveManifestImportReplacementCompletionAndUndo")
        app.launchArguments = ["--uitesting", "--test-store", UUID().uuidString,
                               "--reset-test-inbox", replacement ? "--replacement-manifest" : "--tuscano-manifest",
                               "--synthetic-map-location"]
        app.launch()
        XCTAssertTrue(app.buttons["apartments.import"].waitForExistence(timeout: 20))
        app.launchArguments.removeAll { $0 == "--reset-test-inbox" }
    }

    override func tearDown() {
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Finder tab final screen"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        app.terminate()
        super.tearDown()
    }

    func testDefaultApartmentsAndBothTabsRetainStateAfterDeliveryCompletion() {
        XCTAssertTrue(app.tabBars.buttons["Apartments"].isSelected)
        XCTAssertTrue(app.tabBars.buttons["Finder"].exists)
        importTuscano()
        app.buttons["apartment.tuscano"].tap()
        app.buttons["mini.start"].tap()
        XCTAssertTrue(app.staticTexts["mini.next"].waitForExistence(timeout: 8))
        let nextBefore = app.staticTexts["mini.next"].label

        openFinder()
        search(address: "6355 S Riley St", unit: "105")
        let chosenID = "alcove-unit-10839724"
        let result = app.buttons["finder.result.\(chosenID)"]
        XCTAssertTrue(result.waitForExistence(timeout: 5))
        screenshot("Finder ambiguous results before page scroll")
        expectHittable(result)
        screenshot("Finder ambiguous result after page scroll")
        result.tap()
        let correction = app.buttons["finder.correct.\(chosenID)"]
        XCTAssertTrue(correction.waitForExistence(timeout: 5))
        expectHittable(correction)

        app.tabBars.buttons["Apartments"].tap()
        XCTAssertTrue(app.buttons["mini.delivered"].waitForExistence(timeout: 5),
                      "Apartments must retain its active mini-route when switching tabs")
        XCTAssertEqual(app.staticTexts["mini.next"].label, nextBefore)
        app.buttons["mini.delivered"].tap()
        expectation(for: NSPredicate(format: "label != %@", nextBefore),
                    evaluatedWith: app.staticTexts["mini.next"])
        waitForExpectations(timeout: 5)

        openFinder()
        XCTAssertTrue(correction.waitForExistence(timeout: 5),
                      "Completing a delivery must not rerun an ambiguous Finder search and clear its selection")
        XCTAssertEqual(app.textFields["finder.address"].value as? String, "6355 S Riley St")
        XCTAssertEqual(app.textFields["finder.unit"].value as? String, "105")
        screenshot("Finder retains selected unit after Delivered and tab return")
    }

    func testClubsFollowupEstimatesStayQualifiedWithoutManifest() {
        XCTAssertFalse(app.staticTexts["apartments.manifest-name"].exists)
        openFinder()
        for unit in ["1094", "2095"] {
            search(address: "8975 W Warm Springs Rd", unit: unit)
            let id = "clubs-rhodes-ranch-unit-estimate-b14-\(unit)-\(unit)"
            expectHittable(app.buttons["finder.correct.\(id)"])
            XCTAssertEqual(app.staticTexts["finder.matchCount"].label, "1 saved match")
            XCTAssertTrue(app.staticTexts["Unit \(unit)"].exists)
            XCTAssertTrue(app.staticTexts["Building 14"].firstMatch.exists)
            XCTAssertFalse(app.staticTexts["Floor 1"].exists)
            XCTAssertFalse(app.staticTexts["Floor 2"].exists)
            XCTAssertTrue(app.staticTexts["Estimated"].exists)
            XCTAssertFalse(app.staticTexts["Field verified"].exists)
            screenshot("Clubs estimated unit \(unit) with unknown floor")
        }
    }

    func testFinderCommunityPickerKeepsSpanishWellsReachable() {
        openFinder()
        app.buttons["finder.community"].tap()
        XCTAssertTrue(app.navigationBars["Communities"].waitForExistence(timeout: 5))
        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText("89118")
        let spanishWells = app.buttons["finder.community.spanish-wells"]
        XCTAssertTrue(spanishWells.waitForExistence(timeout: 5))
        spanishWells.tap()
        XCTAssertTrue(app.buttons["finder.community"].label.contains("Spanish Wells"))
        XCTAssertEqual(app.textFields["finder.address"].value as? String, "5355 S Rainbow Blvd")
        screenshot("Spanish Wells remains reachable in the restored Finder")
    }

    func testSpanishRidgeSectionsRemainDistinctAndDisputedBuildingStaysUnknown() {
        openFinder()
        app.buttons["finder.community"].tap()
        XCTAssertTrue(app.navigationBars["Communities"].waitForExistence(timeout: 5))
        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText("Spanish Ridge")
        let small = app.buttons["finder.community.spanish-ridge-7380"]
        let large = app.buttons["finder.community.spanish-ridge"]
        XCTAssertTrue(small.waitForExistence(timeout: 5))
        XCTAssertTrue(large.waitForExistence(timeout: 5))
        XCTAssertTrue(small.label.contains("7380 W Russell Rd"))
        XCTAssertTrue(large.label.contains("7340 W Russell Rd"))
        small.tap()
        XCTAssertEqual(app.textFields["finder.address"].value as? String, "7380 W Russell Rd")

        search(address: "7380 W Russell Rd", unit: "105")
        expectHittable(app.buttons["finder.correct.spanish-ridge-7380-unit-county-2179552-105"])
        XCTAssertEqual(app.staticTexts["finder.matchCount"].label, "1 saved match")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format:
            "label CONTAINS %@ AND label CONTAINS %@", "Building B", "Floor unknown")).firstMatch.exists)
        XCTAssertFalse(app.staticTexts["Field verified"].exists)
        screenshot("7380 Russell unit 105 is a source position in building B")

        search(address: "7380 W Russell Rd", unit: "201")
        expectHittable(app.buttons["finder.correct.spanish-ridge-7380-unit-county-2179616-201"])
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format:
            "label CONTAINS %@ AND label CONTAINS %@", "Building unknown", "Floor unknown")).firstMatch.exists)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format:
            "label CONTAINS %@", "Building A for 201 is not asserted")).firstMatch.exists)
        XCTAssertFalse(app.staticTexts["Field verified"].exists)
        screenshot("7380 Russell unit 201 retains the unresolved official map conflict")

        search(address: "7380 W Russell Rd", unit: "211")
        expectHittable(app.buttons["finder.correct.spanish-ridge-7380-unit-county-2179565-211"])
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format:
            "label CONTAINS %@", "Building C")).firstMatch.exists)

        search(address: "7340 W Russell Rd", unit: "1005")
        expectHittable(app.buttons["finder.correct.spanish-ridge-unit-county-2179726-1005"])
        XCTAssertEqual(app.staticTexts["finder.matchCount"].label, "1 saved match")
        XCTAssertFalse(app.buttons["finder.correct.spanish-ridge-7380-unit-county-2179552-105"].exists)
        screenshot("7340 Russell keeps its original separate four digit unit section")
        search(address: "7380 W Russell Rd", unit: "1005")
        XCTAssertEqual(app.staticTexts["finder.matchCount"].label, "No saved match")
        XCTAssertFalse(app.buttons["finder.correct.spanish-ridge-unit-county-2179726-1005"].exists)
    }

    func test7380PartialQueriesAndPostalFilterKeepDisputed201Qualified() {
        openFinder()
        for query in ["7380", "7380 Russell", "7380 W Russell"] {
            search(address: query, unit: "105")
            expectHittable(app.buttons["finder.correct.spanish-ridge-7380-unit-county-2179552-105"])
            XCTAssertEqual(app.staticTexts["finder.matchCount"].label, "1 saved match")
        }
        screenshot("7380 partial address queries reveal the separate smaller Russell section")
        search(address: "7380 Russell", unit: "201")
        expectHittable(app.buttons["finder.correct.spanish-ridge-7380-unit-county-2179616-201"])
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format:
            "label CONTAINS %@", "Building A for 201 is not asserted")).firstMatch.exists)
        screenshot("Partial Finder query keeps unit 201 building uncertainty visible")
        search(address: "7380 Russell 89148", unit: "105")
        XCTAssertEqual(app.staticTexts["finder.matchCount"].label, "No saved match")
    }

    func testFinderAutomaticallyReacquiresGPSAfterTabSwitchAndForeground() {
        openFinder()
        expectFinderGPS()
        app.tabBars.buttons["Apartments"].tap()
        openFinder()
        expectFinderGPS()

        XCUIDevice.shared.press(.home)
        XCTAssertTrue(app.wait(for: .runningBackground, timeout: 5) || app.state == .runningBackgroundSuspended)
        app.activate()
        expectFinderGPS()
    }

    func testFinderUsesPersonalPinCorrectionAfterRelaunch() {
        openFinder()
        search(address: "7255 W Sunset Rd", unit: "2066")
        let correction = app.buttons["finder.correct.tuscano-unit-county-2187653-2066"]
        XCTAssertTrue(correction.waitForExistence(timeout: 5))
        expectHittable(correction)
        correction.tap()
        XCTAssertTrue(app.navigationBars["Correct a location"].waitForExistence(timeout: 5))
        let building = app.textFields["Building"]
        revealFormField(building, in: app.collectionViews.firstMatch)
        replace(building, with: "Synthetic Finder building")
        app.navigationBars["Correct a location"].buttons["Save"].tap()
        XCTAssertTrue(correction.waitForExistence(timeout: 5))

        app.terminate()
        app.launch()
        XCTAssertTrue(app.buttons["apartments.import"].waitForExistence(timeout: 20))
        openFinder()
        search(address: "7255 W Sunset Rd", unit: "2066")
        XCTAssertTrue(correction.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@",
            "Building Synthetic Finder building")).firstMatch.exists)
        screenshot("Finder personal correction survives relaunch")
    }

    func testRepeatedSearchesRevealAmbiguousSingleAndMissingMatchesWithoutManifest() {
        XCTAssertTrue(app.staticTexts["Your apartment deliveries"].exists)
        XCTAssertFalse(app.staticTexts["apartments.manifest-name"].exists)
        openFinder()
        let first = app.buttons["finder.result.alcove-unit-10839724"]
        let second = app.buttons["finder.result.alcove-unit-10839885"]
        let selected = app.buttons["finder.correct.alcove-unit-10839724"]

        search(address: "6355 S Riley St", unit: "105")
        XCTAssertEqual(app.staticTexts["finder.matchCount"].label, "2 saved matches")
        expectHittable(first)
        expectHittable(second)
        XCTAssertTrue(first.label.contains("Building 5"))
        XCTAssertTrue(second.label.contains("Building 7"))
        XCTAssertFalse(selected.exists)
        screenshot("Finder search reveals both ambiguous buildings without a manifest")
        first.tap()
        expectHittable(selected)

        editSearch()
        XCTAssertEqual(app.textFields["finder.address"].value as? String, "6355 S Riley St")
        XCTAssertEqual(app.textFields["finder.unit"].value as? String, "105")
        screenshot("Finder Edit search returns to the existing query")
        submitSearch()
        expectHittable(first)
        expectHittable(second)
        XCTAssertFalse(selected.exists)
        editSearch()
        submitSearch()
        expectHittable(first)
        expectHittable(second)

        let single = app.buttons["finder.correct.tuscano-unit-county-2187653-2066"]
        search(address: "7255 W Sunset Rd", unit: "2066")
        expectHittable(single)
        editSearch()
        submitSearch()
        expectHittable(single)

        search(address: "6355 S Riley St", unit: "99999")
        XCTAssertEqual(app.staticTexts["finder.matchCount"].label, "No saved match")
        expectHittable(app.buttons["finder.onlineLookup"])
        XCTAssertFalse(first.exists)
        XCTAssertFalse(single.exists)
        editSearch()
        submitSearch()
        expectHittable(app.buttons["finder.onlineLookup"])
        screenshot("Finder repeated missing-unit search reveals the mapping explanation")
    }

    func testFinderSelectionAndDestinationSurviveManifestImportReplacementCompletionAndUndo() {
        XCTAssertTrue(app.buttons["apartments.import"].waitForExistence(timeout: 20))
        XCTAssertTrue(app.staticTexts["Your apartment deliveries"].exists)
        openFinder()
        search(address: "6355 S Riley St", unit: "105")
        let result = app.buttons["finder.result.alcove-unit-10839724"]
        expectHittable(result)
        result.tap()
        expectFinderSelectionAndDestination()

        app.tabBars.buttons["Apartments"].tap()
        importTuscano()
        XCTAssertEqual(app.staticTexts["apartments.manifest-name"].label, "Previous-day.csv")
        openFinder()
        expectFinderSelectionAndDestination()

        app.tabBars.buttons["Apartments"].tap()
        app.buttons["apartment.tuscano"].tap()
        app.buttons["mini.start"].tap()
        XCTAssertTrue(app.staticTexts["mini.next"].waitForExistence(timeout: 8))
        app.buttons["test.mixed"].tap()
        XCTAssertTrue(app.buttons["manifest.import"].waitForExistence(timeout: 10))
        app.buttons["manifest.import"].tap()
        XCTAssertTrue(app.buttons["apartment.tuscano"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.staticTexts["apartments.manifest-name"].label, "New-day.csv")
        XCTAssertTrue(app.buttons["apartment.tango-bay"].label.contains("1 of 1 deliveries left"))
        openFinder()
        expectFinderSelectionAndDestination()
        screenshot("Finder selection stays independent after manifest replacement")

        app.tabBars.buttons["Apartments"].tap()
        app.buttons["apartment.tuscano"].tap()
        app.buttons["mini.start"].tap()
        let complete = app.buttons["mini.completeRoute"]
        expectHittable(complete)
        XCTAssertTrue(complete.label.contains("2 remaining stops"))
        complete.tap()
        XCTAssertTrue(app.staticTexts["Apartment complete"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.alerts.firstMatch.exists)
        XCTAssertFalse(app.sheets.firstMatch.exists)
        openFinder()
        expectFinderSelectionAndDestination()

        app.tabBars.buttons["Apartments"].tap()
        let undo = app.buttons["mini.undoRoute"]
        expectHittable(undo)
        expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: undo)
        waitForExpectations(timeout: 5)
        undo.tap()
        let next = app.staticTexts["mini.next"]
        XCTAssertTrue(next.waitForExistence(timeout: 5))
        XCTAssertTrue(next.label.hasSuffix("Stop 1"))
        app.navigationBars.buttons["Apartments"].tap()
        XCTAssertTrue(app.buttons["apartment.tuscano"].label.contains("2 of 2 deliveries left"))
        XCTAssertTrue(app.buttons["apartment.tango-bay"].label.contains("1 of 1 deliveries left"))
        openFinder()
        expectFinderSelectionAndDestination()
        editSearch()
        XCTAssertEqual(app.textFields["finder.address"].value as? String, "6355 S Riley St")
        XCTAssertEqual(app.textFields["finder.unit"].value as? String, "105")
        screenshot("Finder query survives mini-route completion and Undo")
    }

    private func expectFinderSelectionAndDestination() {
        let chosenID = "alcove-unit-10839724"
        expectHittable(app.buttons["finder.correct.\(chosenID)"])
        XCTAssertTrue(app.buttons["finder.community"].label.contains("Alcove"))
        XCTAssertEqual(app.textFields["finder.address"].value as? String, "6355 S Riley St")
        XCTAssertEqual(app.textFields["finder.unit"].value as? String, "105")
        app.buttons["finder.localRoute.\(chosenID)"].tap()
        XCTAssertTrue(app.navigationBars["Inside the community"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Unit 105"].exists)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Building 5")).firstMatch.exists)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@",
            "The destination has no confirmed graph connection.")).firstMatch.exists)
        app.navigationBars["Inside the community"].buttons["Close"].tap()
        expectHittable(app.buttons["finder.correct.\(chosenID)"])
    }

    private func importTuscano() {
        app.buttons["test.mixed"].tap()
        XCTAssertTrue(app.buttons["manifest.import"].waitForExistence(timeout: 10))
        app.buttons["manifest.import"].tap()
        XCTAssertTrue(app.buttons["apartment.tuscano"].waitForExistence(timeout: 10))
    }

    private func openFinder() {
        let tab = app.tabBars.buttons["Finder"]
        XCTAssertTrue(tab.waitForExistence(timeout: 5))
        tab.tap()
        XCTAssertTrue(app.buttons["finder.community"].waitForExistence(timeout: 5))
    }

    private func search(address: String, unit: String) {
        editSearch()
        replace(app.textFields["finder.address"], with: address)
        replace(app.textFields["finder.unit"], with: unit)
        submitSearch()
    }

    private func editSearch() {
        let edit = app.buttons["finder.editSearch"]
        expectHittable(edit)
        edit.tap()
        expectHittable(app.textFields["finder.address"])
        expectHittable(app.textFields["finder.unit"])
        expectHittable(app.buttons["finder.search"])
    }

    private func submitSearch() {
        expectHittable(app.buttons["finder.search"])
        app.buttons["finder.search"].tap()
        XCTAssertTrue(app.staticTexts["finder.matchCount"].waitForExistence(timeout: 5))
    }

    private func replace(_ field: XCUIElement, with value: String) {
        guard field.value as? String != value else { return }
        expectHittable(field)
        field.tap()
        let current = field.value as? String ?? ""
        if !current.isEmpty && current != field.placeholderValue {
            // Select the whole live value instead of assuming a tap puts the caret at the end.
            field.press(forDuration: 1.1)
            let selectAll = app.menuItems["Select All"].firstMatch
            guard selectAll.waitForExistence(timeout: 3) else {
                XCTFail("Finder fixture replacement requires the native Select All action")
                return
            }
            selectAll.tap()
            field.typeText(XCUIKeyboardKey.delete.rawValue)
            let empty = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                let text = field.value as? String ?? ""
                return text.isEmpty || text == field.placeholderValue
            }, object: nil)
            guard XCTWaiter.wait(for: [empty], timeout: 3) == .completed else {
                XCTFail("Finder test input must be cleared before entering the fixture")
                return
            }
        }
        field.typeText(value)
        let entered = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", value), object: field)
        XCTAssertEqual(XCTWaiter.wait(for: [entered], timeout: 3), .completed)
        XCTAssertEqual(field.value as? String, value, "Finder test input must match the requested fixture")
    }

    private func expectFinderGPS() {
        let status = app.staticTexts["finder.locationStatus"]
        XCTAssertTrue(status.waitForExistence(timeout: 8))
        let acquired = NSPredicate(format: "label BEGINSWITH %@", "GPS")
        expectation(for: acquired, evaluatedWith: status)
        waitForExpectations(timeout: 8)
    }

    private func expectHittable(_ element: XCUIElement) {
        let visible = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hittable == true"), object: element)
        let result = XCTWaiter.wait(for: [visible], timeout: 5)
        if result != .completed {
            let hierarchy = XCTAttachment(string: app.debugDescription)
            hierarchy.name = "Finder reveal failure hierarchy"
            hierarchy.lifetime = .keepAlways
            add(hierarchy)
        }
        XCTAssertEqual(result, .completed, "Expected automatic Finder reveal or visible control: \(element)")
        XCTAssertTrue(element.isHittable, "Expected Finder control to be visible: \(element)")
    }

    private func revealFormField(_ element: XCUIElement, in container: XCUIElement) {
        for _ in 0..<8 where !element.isHittable { container.swipeUp() }
        expectHittable(element)
    }

    private func screenshot(_ name: String) {
        let image = XCTAttachment(screenshot: app.screenshot())
        image.name = name
        image.lifetime = .keepAlways
        add(image)
    }
}
