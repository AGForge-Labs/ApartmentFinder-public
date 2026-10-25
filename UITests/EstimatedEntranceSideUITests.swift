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
        if (testRun?.totalFailureCount ?? 0) > 0 {
            mapStateDiagnostics(stage: "tearDown", targetID: "mini.pin.4.entrance-estimate:lyric:304-e-silverado-ranch-blvd:unit-1287", includeHierarchy: true)
        }
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
        XCTAssertTrue(evidenceAppears(warning, timeout: 10))
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
        expandEvidence("door.evidenceDetails")
        let reviewWarning = app.descendants(matching: .any).matching(identifier: "door.entranceSideWarning").firstMatch
        XCTAssertTrue(evidenceAppears(reviewWarning, timeout: 5, headerID: "door.evidenceDetails"))
        XCTAssertTrue(reviewWarning.label.lowercased().contains("unverified"))
        XCTAssertFalse(app.buttons["door.confirm"].isEnabled)
        capture("Copper Creek estimates retain exact streets and qualified floors")

        app.terminate()
        open("lyric")
        XCTAssertEqual(app.staticTexts["mini.evidenceStatus"].label, "Estimated shared entry")
        expandEvidence()
        let shared = app.descendants(matching: .any).matching(identifier: "mini.entranceSideWarning").firstMatch
        XCTAssertTrue(evidenceAppears(shared, timeout: 10))
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
        mapStateDiagnostics(stage: "Lyric stop 4 selected, evidence collapsed", targetID: "mini.pin.4.entrance-estimate:lyric:304-e-silverado-ranch-blvd:unit-1287")
        expandEvidence()
        XCTAssertTrue(evidenceAppears(shared, timeout: 5))
        XCTAssertTrue(shared.label.contains("1287/1288"))
        XCTAssertTrue(shared.label.lowercased().contains("unverified"))
        XCTAssertTrue(shared.label.lowercased().contains("uncalibrated"))
        XCTAssertTrue(shared.label.lowercased().contains("floor unknown"))
        let laterSharedPin = app.buttons["mini.pin.4.entrance-estimate:lyric:304-e-silverado-ranch-blvd:unit-1287"]
        mapStateDiagnostics(stage: "Lyric stop 4 evidence expanded", targetID: "mini.pin.4.entrance-estimate:lyric:304-e-silverado-ranch-blvd:unit-1287")
        let laterSharedPinAppeared = laterSharedPin.waitForExistence(timeout: 5)
        if !laterSharedPinAppeared {
            mapStateDiagnostics(stage: "Lyric stop 4 pin missing after evidence expansion", targetID: "mini.pin.4.entrance-estimate:lyric:304-e-silverado-ranch-blvd:unit-1287", includeHierarchy: true)
        }
        XCTAssertTrue(laterSharedPinAppeared)
        XCTAssertTrue(laterSharedPin.label.contains("Estimated shared entry, units 1287/1288"))
        XCTAssertFalse(laterSharedPin.label.contains("Checked door"))
        XCTAssertEqual(app.buttons["mini.prepare"].label, "Check / correct estimated pin")
        XCTAssertFalse(app.buttons["mini.navigate"].exists)
        capture("Both Lyric shared entry estimates retain unknown floors and unverified doors")
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
        let diagnostics = """
        stage=\(stage);headerID=\(identifier);typedButtons=\(app.buttons.matching(identifier: identifier).count)
        headers=\(headerMatches.count)
        \(headerState)
        warnings=\(warnings.count)
        \(warningState)
        \(app.debugDescription)
        """
        let payload = "PIN-EVIDENCE-DIAGNOSTIC \(diagnostics)"
        // A clipped UTF-8 scalar can expand by at most two replacement bytes.
        // Reserve four bytes so print\'s newline stays within 32,768 bytes.
        let boundedPayload = String(decoding: payload.utf8.prefix(32_764), as: UTF8.self)
        print(boundedPayload)
        let attachment = XCTAttachment(string: boundedPayload)
        attachment.name = "Synthetic evidence disclosure diagnostics"
        attachment.lifetime = .keepAlways
        add(attachment)
    }


    private func mapStateDiagnostics(stage: String, targetID: String = "",
                                     includeHierarchy: Bool = false) {
        guard app != nil, app.launchArguments.contains("--uitesting"),
              app.launchArguments.contains("--test-store"),
              app.state == .runningForeground else { return }
        func describe(_ element: XCUIElement) -> String {
            guard element.exists, let snapshot = try? element.snapshot() else {
                return "missing or unavailable snapshot"
            }
            let frame = snapshot.frame
            let finite = [frame.minX, frame.minY, frame.width, frame.height].allSatisfy { $0.isFinite }
            // Do not query isHittable or frame directly on a possibly missing target.
            return "type=\(snapshot.elementType.rawValue);id=\(snapshot.identifier);label=\(snapshot.label);value=\(String(describing: snapshot.value));frame=\(frame);finite=\(finite)"
        }
        let pins = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "mini.pin."))
        let pinState = pins.allElementsBoundByIndex.map(describe).joined(separator: "\n")
        let choices = app.buttons.matching(NSPredicate(format: "label == %@ OR label == %@", "Map", "Satellite"))
        let choiceState = choices.allElementsBoundByIndex.map(describe).joined(separator: "\n")
        let target = targetID.isEmpty ? "not requested" : describe(app.buttons[targetID])
        let hierarchy = includeHierarchy ? app.debugDescription : "omitted for routine state observation"
        let diagnostics = """
        stage=\(stage);targetID=\(targetID)
        window=\(describe(app.windows.firstMatch))
        mapAXFrame=\(describe(app.maps.firstMatch))
        nextCard=\(describe(app.staticTexts["mini.next"]))
        mapStyle=\(describe(app.buttons["mini.mapStyle"]))
        camera=\(describe(app.buttons["mini.recenter"]))
        evidenceHeader=\(describe(app.buttons["mini.evidenceDetails"]))
        choices=\(choices.count);sheets=\(app.sheets.count);alerts=\(app.alerts.count)
        \(choiceState)
        target=\(target)
        pinCount=\(pins.count)
        \(pinState)
        \(hierarchy)
        """
        let payload = "MINI-MAP-STATE-DIAGNOSTIC \(diagnostics)"
        // A clipped UTF-8 scalar can expand by at most two replacement bytes.
        // Reserve four bytes so print\'s newline stays within 32,768 bytes.
        let boundedPayload = String(decoding: payload.utf8.prefix(32_764), as: UTF8.self)
        print(boundedPayload)
        if includeHierarchy {
            let attachment = XCTAttachment(string: boundedPayload)
            attachment.name = "Synthetic mini-map state"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }

    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
