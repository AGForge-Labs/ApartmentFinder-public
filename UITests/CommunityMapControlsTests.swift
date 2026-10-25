import XCTest

/// Public community references and invented deliveries. No owner store or actual route is loaded.
final class CommunityMapControlsTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        app = XCUIApplication()
    }

    override func tearDown() {
        if (testRun?.totalFailureCount ?? 0) > 0 {
            mapStateDiagnostics(stage: "tearDown", includeHierarchy: true)
        }
        capture("Community map controls final screen")
        app.terminate()
        super.tearDown()
    }

    private func openRoute(_ id: String, fixture: String) {
        app.launchArguments = ["--uitesting", "--test-store", UUID().uuidString,
            "--reset-test-inbox", fixture, "--synthetic-map-location", "--synthetic-map-direction"]
        app.launch()
        XCTAssertTrue(app.buttons["test.mixed"].waitForExistence(timeout: 25))
        app.buttons["test.mixed"].tap()
        XCTAssertTrue(app.buttons["manifest.import"].waitForExistence(timeout: 10))
        app.buttons["manifest.import"].tap()
        XCTAssertTrue(app.buttons["apartment.\(id)"].waitForExistence(timeout: 10))
        app.buttons["apartment.\(id)"].tap()
        app.buttons["mini.start"].tap()
        XCTAssertTrue(app.maps.firstMatch.waitForExistence(timeout: 8))
        XCTAssertTrue(app.buttons["mini.recenter"].waitForExistence(timeout: 5))
    }

    func testPausedControlsStayCompactAndKeepTheirActions() {
        openRoute("tuscano", fixture: "--tuscano-manifest")
        assertCompactControls()
        app.buttons["Show all stops"].tap()
        // Observe the required state after the asynchronous SwiftUI/AX update;
        // a completed tap alone does not establish the published map mode.
        let paused = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label == %@ AND value BEGINSWITH %@", "Resume following", "Paused"),
            object: app.buttons["mini.recenter"])
        let pausedResult = XCTWaiter.wait(for: [paused], timeout: 5)
        if pausedResult != .completed {
            mapStateDiagnostics(stage: "overview did not expose paused state", includeHierarchy: true)
        }
        XCTAssertEqual(pausedResult, .completed, "Show all stops must expose the paused map state")
        XCTAssertEqual(app.buttons["mini.recenter"].label, "Resume following")
        assertCompactControls()
        capture("Paused controls leave the map clear")
        app.buttons["mini.mapStyle"].tap()
        XCTAssertTrue(app.buttons["Map"].waitForExistence(timeout: 5))
        mapStateDiagnostics(stage: "before Map choice tap")
        app.buttons["Map"].tap()
        let selectedMap = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "Map"),
                                                     object: app.buttons["mini.mapStyle"])
        let selectedMapResult = XCTWaiter.wait(for: [selectedMap], timeout: 5)
        if selectedMapResult != .completed {
            mapStateDiagnostics(stage: "Map choice did not expose selected value", includeHierarchy: true)
        }
        XCTAssertEqual(selectedMapResult, .completed,
                       "The visible map type must update to Map after its action")
        XCTAssertEqual(app.buttons["mini.mapStyle"].value as? String, "Map")
        assertCompactControls()
        app.buttons["mini.focus.3"].tap()
        XCTAssertTrue(app.staticTexts["Unit 2137"].exists)
        app.buttons["mini.recenter"].tap()
        XCTAssertTrue(app.staticTexts["Unit 2137"].exists)
        XCTAssertNotEqual(app.buttons["mini.recenter"].label, "Resume following")
        assertCompactControls()
        capture("Following controls remain compact after map-style and stop changes")
    }

    func testLyricAndTrendShowTheirCommunityAreasWithoutInventingDoors() {
        // Keep the selected test identity while distinguishing current estimates
        // from the deliberately unmapped Trend units in the same fixture.
        for id in ["lyric", "trend"] {
            openRoute(id, fixture: "--community-area-manifest")
            XCTAssertFalse(app.staticTexts["Community location not mapped"].exists)
            if id == "lyric" {
                let pins = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "mini.pin."))
                let first = app.buttons["mini.pin.1.entrance-estimate:lyric:304-e-silverado-ranch-blvd:unit-1193"]
                let second = app.buttons["mini.pin.2.entrance-estimate:lyric:304-e-silverado-ranch-blvd:unit-2171"]
                XCTAssertTrue(first.waitForExistence(timeout: 5))
                XCTAssertTrue(second.exists)
                XCTAssertEqual(pins.count, 2)
                XCTAssertTrue(first.label.contains("building 15"))
                XCTAssertTrue(first.label.contains("Estimated shared entry, units 1193/1194"))
                XCTAssertTrue(second.label.contains("building 13"))
                XCTAssertTrue(second.label.contains("Estimated"))
                XCTAssertFalse(pins.allElementsBoundByIndex.contains { $0.label.contains("Checked door") })
                XCTAssertEqual(app.staticTexts["mini.coverage"].label, "Mapped locations")
                for sequence in [1, 2] {
                    app.buttons["mini.focus.\(sequence)"].tap()
                    expandEvidence()
                    let warning = app.descendants(matching: .any).matching(identifier: "mini.entranceSideWarning").firstMatch
                    XCTAssertTrue(evidenceAppears(warning, timeout: 5))
                    XCTAssertTrue(warning.label.lowercased().contains("unverified"))
                    XCTAssertTrue(warning.label.lowercased().contains("uncalibrated"))
                    XCTAssertTrue(warning.label.lowercased().contains("floor unknown"))
                    XCTAssertEqual(app.buttons["mini.prepare"].label, "Check / correct estimated pin")
                    XCTAssertFalse(app.buttons["mini.navigate"].exists)
                }
                // The estimate view exposes qualified building labels, but not
                // the former operator-association-only fallback. Core tests
                // retain that provenance; this UI path must not claim a door.
                capture("Lyric estimates retain building labels and unverified entry areas")
            } else {
                assertCenter(latitude: 36.01422151644452, longitude: -115.16156023077903)
                XCTAssertTrue(app.staticTexts["mini.communityLocation"].label.contains("Community area"))
                XCTAssertEqual(app.staticTexts["mini.coverage"].label, "2 units not mapped")
                XCTAssertEqual(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "mini.pin.")).count, 0)
                XCTAssertEqual(app.buttons["mini.prepare"].label, "Add door pin on map")
                XCTAssertFalse(app.buttons["mini.navigate"].exists)
                capture("Trend unknown units retain the community area without invented pins")
            }
            app.buttons["Show all stops"].tap()
            if id == "trend" {
                assertCenter(latitude: 36.01422151644452, longitude: -115.16156023077903)
            }
            assertCompactControls()
            app.terminate()
        }
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

    private func assertCompactControls(file: StaticString = #filePath, line: UInt = #line) {
        let controls = [app.buttons["mini.mapStyle"], app.buttons["Show all stops"], app.buttons["mini.recenter"]]
        let layoutTolerance: CGFloat = 1e-6
        var union = CGRect.null
        for control in controls {
            XCTAssertTrue(control.exists && control.isHittable, file: file, line: line)
            let frame = control.frame
            XCTAssertTrue([frame.minX, frame.minY, frame.width, frame.height].allSatisfy(\.isFinite), file: file, line: line)
            XCTAssertGreaterThanOrEqual(frame.width, 44 - layoutTolerance, file: file, line: line)
            XCTAssertGreaterThanOrEqual(frame.height, 44 - layoutTolerance, file: file, line: line)
            XCTAssertLessThanOrEqual(frame.width, 48 + layoutTolerance, "Visible map controls must not expand with the paused label: \(frame)", file: file, line: line)
            XCTAssertLessThanOrEqual(frame.height, 48 + layoutTolerance, file: file, line: line)
            union = union.union(frame)
        }
        XCTAssertLessThanOrEqual(union.width, 56 + layoutTolerance, "The floating controls must remain a narrow column", file: file, line: line)
        XCTAssertLessThanOrEqual(union.height, 172 + layoutTolerance, file: file, line: line)
        print("COMMUNITY-MAP-CONTROLS bounds=\(union), buttonFrames=\(controls.map(\.frame))")
    }

    private func assertCenter(latitude: Double, longitude: Double, file: StaticString = #filePath, line: UInt = #line) {
        let control = app.buttons["mini.recenter"]
        let centered = NSPredicate { _, _ in
            guard let value = control.value as? String,
                  let area = value.components(separatedBy: ", map center ").dropFirst().first else { return false }
            let fields = area.components(separatedBy: ", camera revision ")[0].split(separator: ",")
            guard fields.count == 2, let lat = Double(fields[0]), let lon = Double(fields[1]) else { return false }
            return abs(lat - latitude) < 0.0003 && abs(lon - longitude) < 0.0003
        }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: centered, object: nil)], timeout: 10), .completed,
            "The map must frame the official community area instead of a distant synthetic driver: \(String(describing: control.value))", file: file, line: line)
        print("COMMUNITY-MAP-CENTER expected=\(latitude),\(longitude), camera=\(String(describing: control.value))")
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
        guard app != nil, app.state == .runningForeground else { return }
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
}
