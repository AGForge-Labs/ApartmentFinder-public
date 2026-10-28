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
        XCTAssertTrue(app.staticTexts["5 apartments"].waitForExistence(timeout: 10))
        let apartment = app.buttons["apartment.\(id)"]
        let initiallyExists = apartment.exists
        var scrolls = 0
        // SwiftUI's List can leave the fifth group outside the accessibility
        // tree until it scrolls into view. Navigate the real list before
        // asserting the exact group; do not substitute a different fixture.
        for _ in 0..<5 where !apartment.exists || !apartment.isHittable {
            app.swipeUp()
            scrolls += 1
        }
        print("REVIEWED_APARTMENT_NAVIGATION id=\(id);initiallyExists=\(initiallyExists);scrolls=\(scrolls);exists=\(apartment.exists);hittable=\(apartment.isHittable)")
        XCTAssertTrue(apartment.waitForExistence(timeout: 10))
        XCTAssertTrue(apartment.isHittable)
        apartment.tap()
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
        // The current bundle has three individual estimated sectors here. Keep
        // this selected identity and assert their actual public provenance.
        open("destinations-pebble")
        let markers = pins(containing: "directory-unit-sector:destinations-pebble:")
        waitForCount(markers, 3)
        for (sequence, unit, sourceUnit) in [(1, "1000", "1864704"), (2, "1001", "1864705"), (3, "1159", "1864863")] {
            app.buttons["mini.focus.\(sequence)"].tap()
            XCTAssertTrue(app.staticTexts["Unit \(unit)"].exists)
            let pin = app.buttons["mini.pin.\(sequence).directory-unit-sector:destinations-pebble:1450-e-pebble-rd:unit-\(unit)"]
            XCTAssertTrue(pin.waitForExistence(timeout: 5))
            XCTAssertTrue(pin.label.contains("unit \(unit)"))
            XCTAssertTrue(pin.label.contains("Estimated"))
            XCTAssertFalse(pin.label.contains("Checked door"))
            XCTAssertEqual(app.staticTexts["mini.evidenceStatus"].label, "Estimated")
            expandEvidence()
            XCTAssertTrue(app.staticTexts["mini.estimateWarning"].label.contains("May be inaccurate"))
            let notes = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Approximate directory unit sector")).firstMatch
            XCTAssertTrue(notes.waitForExistence(timeout: 5))
            for qualifier in ["not a verified door or entrance", "20 m", "uncalibrated", "not guaranteed accuracy",
                              "Published directory dwelling-floor label: 1", "actual entrance floor remains unknown", "Source unit ID \(sourceUnit)"] {
                XCTAssertTrue(notes.label.contains(qualifier), "Missing current directory qualifier: \(qualifier)")
            }
            XCTAssertEqual(app.buttons["mini.prepare"].label, "Check / correct estimated pin")
            XCTAssertFalse(app.buttons["mini.navigate"].exists)
        }
        // Long, expanded evidence occupies the active map's bottom safe-area
        // inset. Restore its compact state before asserting the map viewport;
        // keep every provenance assertion above and the exact pin count below.
        let details = app.buttons["mini.evidenceDetails"]
        XCTAssertEqual(details.value as? String, "Expanded")
        details.tap()
        let collapsed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "Collapsed"), object: details)
        XCTAssertEqual(XCTWaiter.wait(for: [collapsed], timeout: 5), .completed,
                       "Collapse the evidence panel before checking the physical map viewport")
        waitForCount(markers, 3)
        let camera = app.buttons["mini.recenter"].value as? String ?? ""
        let center = camera.components(separatedBy: ", map center ").last?.components(separatedBy: ", camera revision ").first?.split(separator: ",") ?? []
        XCTAssertEqual(center.count, 2)
        if center.count == 2, let latitude = Double(center[0]), let longitude = Double(center[1]) {
            XCTAssertTrue((36.028...36.032).contains(latitude) && (-115.135 ... -115.131).contains(longitude), "The real map must frame Pebble: \(camera)")
        } else { XCTFail("Missing native camera center: \(camera)") }
        print("89123-PEBBLE camera=\(camera), markers=\(markers.allElementsBoundByIndex.map { ($0.identifier, $0.frame, $0.label) })")
        capture("Pebble three estimated unit sectors retain source floors and uncertainty")
    }

    func testStackedSourceUnitFloorsAndRecoveredSummerLabelsRemainUnverified() {
        open("prosper-150")
        waitForCount(pins(containing: "sightmap:38241:unit:"), 2)
        waitForCount(pins(containing: "entrance-estimate:prosper-150:"), 2)
        for (sequence, unit, sourceID, floor) in [(4, "101", "12804155", "1"), (5, "201", "12804185", "2")] {
            app.buttons["mini.focus.\(sequence)"].tap()
            let source = app.buttons["mini.pin.\(sequence).sightmap:38241:unit:\(sourceID)"]
            let estimateID = "entrance-estimate:prosper-150:8680-ensworth-st:unit-\(unit)"
            let estimate = app.buttons["mini.pin.\(sequence).\(estimateID)"]
            XCTAssertTrue(source.waitForExistence(timeout: 5))
            XCTAssertTrue(source.isHittable); source.tap()
            XCTAssertTrue(source.label.contains("Directory map"))
            XCTAssertTrue(estimate.exists)
            XCTAssertTrue(estimate.label.contains("Estimated"))
            XCTAssertFalse(source.label.contains("Checked door"))
            XCTAssertFalse(estimate.label.contains("Checked door"))
            XCTAssertTrue(app.staticTexts["Unit \(unit)"].exists)
            XCTAssertEqual(app.staticTexts["mini.evidenceStatus"].label, "Choose location")
            expandEvidence()
            XCTAssertTrue(app.staticTexts["mini.sourceUnitWarning"].label.contains("not an entrance or door"))
            let warning = app.descendants(matching: .any).matching(identifier: "mini.entranceSideWarning").firstMatch
            XCTAssertTrue(evidenceAppears(warning, timeout: 5))
            XCTAssertTrue(warning.label.contains("Unit floor \(floor) (source)"))
            XCTAssertTrue(warning.label.lowercased().contains("unverified"))
            XCTAssertTrue(warning.label.lowercased().contains("uncalibrated"))
            XCTAssertFalse(warning.label.contains("Actual entry floor, threshold elevation and accessible approach remain unknown"))
            XCTAssertFalse(app.buttons["mini.navigate"].exists)
            XCTAssertEqual(app.buttons["mini.prepare"].label, "Check / correct estimated pin")
            // Multiple suggestions suppress the single-place header. The real
            // chooser exposes each source's exact floor and provenance instead.
            app.buttons["mini.prepare"].tap()
            let chooser = app.navigationBars["Check Door Pin"]
            XCTAssertTrue(chooser.waitForExistence(timeout: 5))
            let sourceChoice = app.buttons["door.candidate.sightmap:38241:unit:\(sourceID)"]
            let estimateChoice = app.buttons["door.candidate.\(estimateID)"]
            XCTAssertTrue(sourceChoice.waitForExistence(timeout: 5))
            XCTAssertTrue(sourceChoice.label.contains("Floor \(floor)"))
            XCTAssertTrue(sourceChoice.label.contains("Directory map"))
            XCTAssertTrue(estimateChoice.exists)
            XCTAssertTrue(estimateChoice.label.contains("Floor \(floor)"))
            XCTAssertTrue(estimateChoice.label.contains("Estimated"))
            XCTAssertFalse(app.buttons["door.confirm"].isEnabled)
            chooser.buttons["Cancel"].tap()
            XCTAssertTrue(chooser.waitForNonExistence(timeout: 5))
        }
        capture("Prosper source positions and entry estimates keep independent floors and provenance")
        app.terminate(); open("summer-winds")
        waitForCount(pins(containing: "sightmap:369:unit:"), 2)
        for (sequence, unit, sourceID) in [(6, "1041", "108113"), (7, "1044", "108116")] {
            app.buttons["mini.focus.\(sequence)"].tap()
            XCTAssertTrue(app.staticTexts["Unit \(unit)"].exists)
            let source = app.buttons["mini.pin.\(sequence).sightmap:369:unit:\(sourceID)"]
            XCTAssertTrue(source.exists)
            XCTAssertTrue(source.label.contains("Directory map"))
            XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Floor 1")).firstMatch.exists)
            expandEvidence()
            XCTAssertTrue(app.staticTexts["mini.sourceUnitWarning"].label.contains("not an entrance or door"))
            XCTAssertEqual(app.buttons["mini.prepare"].label, "Check suggested pin")
            XCTAssertFalse(app.buttons["mini.navigate"].exists)
        }
        capture("Summer Winds recovered literal units 1041 and 1044 retain source floor 1")
    }

    func testHistoricalAliasAndFloorOnlyReferenceDoNotInventATowerOrDoor() {
        open("octave-apartments")
        let estimate = app.buttons["mini.pin.8.entrance-estimate:octave-apartments:2750-west-wigwam-avenue:unit-1101"]
        XCTAssertTrue(estimate.waitForExistence(timeout: 5))
        waitForCount(pins(containing: "entrance-estimate:octave-apartments:"), 1)
        XCTAssertTrue(estimate.label.contains("Estimated"))
        XCTAssertFalse(estimate.label.contains("Checked door"))
        let mapped = app.buttons["mini.pin.8.octave-apartments:source-unit-area:112686"]
        XCTAssertTrue(mapped.waitForExistence(timeout: 5))
        XCTAssertTrue(mapped.label.contains("Map location"))
        XCTAssertFalse(mapped.label.contains("Checked door"))
        XCTAssertEqual(app.staticTexts["mini.evidenceStatus"].label, "Choose location")
        expandEvidence()
        let warning = app.descendants(matching: .any).matching(identifier: "mini.entranceSideWarning").firstMatch
        XCTAssertTrue(evidenceAppears(warning, timeout: 5))
        for qualifier in ["Door unverified", "Unit floor unknown", "10 m working allowance (uncalibrated)"] {
            XCTAssertTrue(warning.label.contains(qualifier), "Missing current Octave qualifier: \(qualifier)")
        }
        XCTAssertFalse(warning.label.contains("Actual entrance floor, elevation and ground stair approach are unknown"))
        XCTAssertEqual(app.buttons["mini.prepare"].label, "Choose building / door")
        XCTAssertFalse(app.buttons["mini.navigate"].exists)
        // The current estimate summary does not expose the retained historical
        // alias detail. Core tests cover that provenance; this UI check verifies
        // the unknown floor and unverified entrance, not historical-alias display.
        capture("Octave estimate keeps its dwelling floor and entrance unverified")
        app.terminate(); open("one-las-vegas")
        waitForCount(pins(containing: ""), 0)
        expandEvidence()
        XCTAssertTrue(app.staticTexts["mini.floorOnlyReference"].label.contains("County floor 1"))
        XCTAssertTrue(app.staticTexts["mini.floorOnlyReference"].label.contains("tower unknown"))
        XCTAssertTrue(app.staticTexts["mini.communityLocation"].label.contains("unit location unknown"))
        XCTAssertEqual(app.buttons["mini.prepare"].label, "Add door pin on map")
        XCTAssertFalse(app.buttons["mini.navigate"].exists)
        print("89123-ONE-LAS-VEGAS camera=\(String(describing: app.buttons["mini.recenter"].value)); routePins=0; unitTowerJoins=0")
        capture("One Las Vegas tower areas are context only, never a guessed unit destination")
    }

    private func expandEvidence(_ identifier: String = "mini.evidenceDetails",
                                file: StaticString = #filePath, line: UInt = #line) {
        let headers = app.buttons.matching(identifier: identifier)
        let details = headers.firstMatch
        let found = details.waitForExistence(timeout: 5)
        if !found { evidenceDiagnostics(identifier, stage: "header missing") }
        XCTAssertTrue(found, "Evidence header must exist", file: file, line: line)
        guard found else { return }
        let headerCount = headers.count
        if headerCount != 1 { evidenceDiagnostics(identifier, stage: "header is not unique") }
        XCTAssertEqual(headerCount, 1, "Evidence header must be unique", file: file, line: line)
        let hittable = details.isHittable
        if !hittable { evidenceDiagnostics(identifier, stage: "header is not hittable") }
        XCTAssertTrue(hittable, "Evidence header must be hittable", file: file, line: line)
        let initialValue = details.value as? String
        if initialValue != "Collapsed" { evidenceDiagnostics(identifier, stage: "header did not reset to Collapsed") }
        XCTAssertEqual(initialValue, "Collapsed", file: file, line: line)
        details.tap()
        let expanded = XCTWaiter.wait(for: [
            XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "Expanded"), object: details)
        ], timeout: 5)
        if expanded != .completed { evidenceDiagnostics(identifier, stage: "tap did not expand header") }
        XCTAssertEqual(expanded, .completed, "Evidence header must become Expanded after tap", file: file, line: line)
    }

    private func evidenceAppears(_ element: XCUIElement, timeout: TimeInterval,
                                 headerID: String = "mini.evidenceDetails") -> Bool {
        let found = element.waitForExistence(timeout: timeout)
        if !found { evidenceDiagnostics(headerID, stage: "evidence child missing") }
        return found
    }

    private func evidenceDiagnostics(_ identifier: String, stage: String) {
        // Every caller uses an isolated synthetic test store. Never attach an
        // accessibility dump from a production or owner-store launch.
        guard app.launchArguments.contains("--uitesting"),
              app.launchArguments.contains("--test-store") else { return }
        let headerMatches = app.descendants(matching: .any).matching(identifier: identifier)
        let warningID = identifier.hasPrefix("door.") ? "door.entranceSideWarning" : "mini.entranceSideWarning"
        let warnings = app.descendants(matching: .any).matching(identifier: warningID)
        func describe(_ element: XCUIElement) -> String {
            guard element.exists, let snapshot = try? element.snapshot() else { return "missing or unavailable snapshot" }
            return "type=\(snapshot.elementType.rawValue);id=\(snapshot.identifier);value=\(String(describing: snapshot.value));frame=\(snapshot.frame);hittable=\(element.exists && element.isHittable)"
        }
        let headerState = headerMatches.allElementsBoundByIndex.map(describe).joined(separator: "\n")
        let warningState = warnings.allElementsBoundByIndex.map(describe).joined(separator: "\n")
        let diagnostics = String("""
        stage=\(stage);headerID=\(identifier);typedButtons=\(app.buttons.matching(identifier: identifier).count)
        headers=\(headerMatches.count)
        \(headerState)
        warnings=\(warnings.count)
        \(warningState)
        \(app.debugDescription)
        """.prefix(32_768))
        print("PIN-EVIDENCE-DIAGNOSTIC \(diagnostics)")
        let attachment = XCTAttachment(string: diagnostics)
        attachment.name = "Synthetic evidence disclosure diagnostics"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func capture(_ title: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot()); attachment.name = title
        attachment.lifetime = .keepAlways; add(attachment)
    }
}
