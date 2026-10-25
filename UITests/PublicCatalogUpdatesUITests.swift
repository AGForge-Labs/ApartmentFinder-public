import XCTest

final class PublicCatalogUpdatesUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["--uitesting", "--test-store", UUID().uuidString,
                               "--reset-test-inbox", "--catalog-refresh-offline",
                               "--synthetic-map-location"]
        app.launch()
        XCTAssertTrue(app.buttons["apartments.import"].waitForExistence(timeout: 20))
    }

    override func tearDown() {
        guard let app else { super.tearDown(); return }
        if (testRun?.totalFailureCount ?? 0) > 0 {
            catalogReadinessDiagnostics(stage: "tearDown after failure")
        }
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Public pin data offline refresh final screen"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        app.terminate()
        super.tearDown()
    }

    func testOfflineRefreshKeepsCatalogSelectionAndPinEditingAvailable() {
        XCTAssertTrue(app.tabBars.buttons["Apartments"].isSelected)
        app.tabBars.buttons["Finder"].tap()
        XCTAssertTrue(app.buttons["finder.community"].waitForExistence(timeout: 5))
        // Navigate the production community list without search-field focus or
        // keyboard replacement; retain the identical Tuscano unit fixture.
        app.buttons["finder.community"].tap()
        XCTAssertTrue(app.navigationBars["Communities"].waitForExistence(timeout: 5))
        let tuscano = app.buttons["finder.community.tuscano"]
        for _ in 0..<16 {
            if tuscano.exists && tuscano.isHittable { break }
            app.swipeUp()
        }
        XCTAssertTrue(tuscano.waitForExistence(timeout: 5))
        XCTAssertTrue(tuscano.isHittable)
        tuscano.tap()
        // The Finder button also exists behind this sheet; its existence is not
        // a dismissal signal. Wait for the actual presentation boundary.
        let picker = app.navigationBars["Communities"]
        let pickerClosed = picker.waitForNonExistence(timeout: 5)
        if !pickerClosed {
            print("PublicCatalogPickerFailure pickerExists=\(picker.exists) selectedCommunity=\(app.buttons["finder.community"].label) address=\(String(reflecting: app.textFields["finder.address"].value as? String))")
        }
        XCTAssertTrue(pickerClosed, "Selecting the community must dismiss its picker before entering a unit")
        XCTAssertTrue(app.buttons["finder.community"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.navigationBars["Communities"].exists)
        XCTAssertTrue(app.buttons["finder.community"].label.contains("Tuscano"))
        XCTAssertEqual(app.textFields["finder.address"].value as? String, "7255 W Sunset Rd")
        // Reveal the search card through its production toolbar control. The
        // community button can be visible while the fields above it are not.
        let editSearch = app.buttons["finder.editSearch"]
        expectHittable(editSearch)
        editSearch.tap()
        let unit = app.textFields["finder.unit"]
        expectHittable(unit)
        let initialUnit = unit.value as? String
        XCTAssertNotNil(initialUnit)
        XCTAssertTrue(initialUnit == "" || initialUnit == unit.placeholderValue,
                      "The isolated Finder fixture must start with an empty unit field")
        unit.tap()
        unit.typeText("2066")
        let entered = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "2066"), object: unit)
        let entryWaitResult = XCTWaiter.wait(for: [entered], timeout: 3)
        if entryWaitResult != .completed {
            // Observe only after the original wait has failed. A late value must
            // never turn this failed setup into a passing acceptance result.
            let observedAt = ProcessInfo.processInfo.systemUptime
            let observedValue = unit.value as? String
            let valueQuerySeconds = ProcessInfo.processInfo.systemUptime - observedAt
            print("PublicCatalogInputFailure wait=\(entryWaitResult.rawValue) value=\(String(reflecting: observedValue)) valueQuerySeconds=\(valueQuerySeconds)")
            print("PublicCatalogInputFailure placeholder=\(String(reflecting: unit.placeholderValue)) exists=\(unit.exists) keyboardExists=\(app.keyboards.firstMatch.exists)")
            catalogReadinessDiagnostics(stage: "typed unit value wait failed")
            print("PublicCatalogInputFailure field=\(unit.debugDescription)")
        }
        XCTAssertEqual(entryWaitResult, .completed)
        XCTAssertEqual(unit.value as? String, "2066")
        // Use the production control to end editing and reveal the search card
        // before requiring a hit point for its Search button.
        expectHittable(editSearch)
        editSearch.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5),
                      "Ending input must dismiss the keyboard before tapping Search")
        XCTAssertEqual(unit.value as? String, "2066", "Revealing search must preserve the entered unit")
        expectHittable(app.buttons["finder.search"])
        app.buttons["finder.search"].tap()
        let correction = app.buttons["finder.correct.tuscano-unit-county-2187653-2066"]
        expectHittable(correction)
        XCTAssertEqual(app.staticTexts["finder.matchCount"].label, "1 saved match")
        XCTAssertTrue(app.buttons["finder.community"].label.contains("Tuscano"))

        app.buttons["catalogUpdates.open"].tap()
        let revision = app.staticTexts["catalogUpdates.revision"]
        XCTAssertTrue(revision.waitForExistence(timeout: 5))
        let installedRevision = revision.label
        XCTAssertFalse(installedRevision.isEmpty)
        app.buttons["catalogUpdates.refresh"].tap()
        let status = app.staticTexts["catalogUpdates.status"]
        let offline = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label BEGINSWITH[c] %@", "Offline or unable to connect."), object: status)
        XCTAssertEqual(XCTWaiter.wait(for: [offline], timeout: 10), .completed)
        XCTAssertEqual(revision.label, installedRevision, "An offline check must keep the installed public revision")
        XCTAssertTrue(app.buttons["catalogUpdates.refresh"].isEnabled)
        XCTAssertFalse(app.alerts.firstMatch.exists, "An offline refresh result must not block ordinary pin editing")
        let offlineScreen = XCTAttachment(screenshot: app.screenshot())
        offlineScreen.name = "Offline pin data refresh retains installed revision"
        offlineScreen.lifetime = .keepAlways
        add(offlineScreen)
        app.buttons["catalogUpdates.close"].tap()

        expectHittable(correction)
        XCTAssertEqual(app.staticTexts["finder.matchCount"].label, "1 saved match")
        XCTAssertTrue(app.buttons["finder.community"].label.contains("Tuscano"))
        correction.tap()
        expectPinEditor()
        app.navigationBars["Correct a location"].buttons["Cancel"].tap()

        let addPin = app.buttons["finder.addPin"]
        reveal(addPin)
        addPin.tap()
        expectPinEditor()
        app.navigationBars["Correct a location"].buttons["Cancel"].tap()

        app.tabBars.buttons["Apartments"].tap()
        XCTAssertTrue(app.buttons["apartments.import"].waitForExistence(timeout: 5))
        app.buttons["catalogUpdates.open"].tap()
        XCTAssertTrue(revision.waitForExistence(timeout: 5))
        XCTAssertEqual(revision.label, installedRevision, "Both tabs must show the same retained public data")
        XCTAssertTrue(status.label.localizedCaseInsensitiveContains("offline"))
        app.buttons["catalogUpdates.close"].tap()
        XCTAssertTrue(app.buttons["apartments.import"].isEnabled)
    }

    private func expectPinEditor() {
        let editor = app.navigationBars["Correct a location"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        XCTAssertTrue(editor.buttons["Save"].isEnabled, "Local pin editing must remain available after a public refresh fails")
        XCTAssertTrue(editor.buttons["Cancel"].isHittable)
        XCTAssertFalse(app.alerts.firstMatch.exists)
    }

    private func expectHittable(_ element: XCUIElement,
                                file: StaticString = #filePath, line: UInt = #line) {
        guard let app else { XCTFail("The synthetic test app must be launched", file: file, line: line); return }
        var lastGeometry = "No usable target/window snapshots observed"
        let visible = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            let window = app.windows.firstMatch
            guard element.exists, window.exists else {
                lastGeometry = "Target or application window missing"
                return false
            }
            // Use the element's resolved geometry; an optional diagnostic
            // snapshot is not a readiness requirement for a real toolbar tap.
            let frame = element.frame, windowFrame = window.frame
            let intersection = frame.intersection(windowFrame)
            lastGeometry = "id=\(element.identifier);frame=\(frame);window=\(windowFrame);intersection=\(intersection)"
            guard self.usableFrame(frame), self.usableFrame(windowFrame), self.usableFrame(intersection) else {
                // Never ask XCTest to calculate an activation point for missing,
                // empty, nonfinite or entirely off-window geometry.
                return false
            }
            // Geometry is readiness only: the original real hittability result
            // remains required. No coordinate tap, navigation or input fallback.
            return element.isHittable
        }, object: nil)
        let result = XCTWaiter.wait(for: [visible], timeout: 5)
        if result != .completed {
            catalogReadinessDiagnostics(stage: "hittability wait failed", targetState: lastGeometry)
        }
        XCTAssertEqual(result, .completed, "The control must become hittable; \(lastGeometry)", file: file, line: line)
    }

    private func usableFrame(_ frame: CGRect) -> Bool {
        !frame.isNull && !frame.isEmpty &&
            [frame.minX, frame.minY, frame.maxX, frame.maxY].allSatisfy { $0.isFinite }
    }

    private func catalogReadinessDiagnostics(stage: String, targetState: String = "") {
        guard let app, app.launchArguments.contains("--uitesting"),
              app.launchArguments.contains("--test-store") else { return }
        // Emit the stage first in case a subsequent AX snapshot itself stalls.
        print("PUBLIC-CATALOG-READINESS-DIAGNOSTIC stage=\(stage); target=\(String(targetState.prefix(2_048)))")
        func state(_ name: String, _ element: XCUIElement) -> String {
            guard element.exists, let snapshot = try? element.snapshot() else {
                return "\(name): missing or snapshot unavailable"
            }
            return "\(name): id=\(snapshot.identifier);type=\(snapshot.elementType.rawValue);frame=\(snapshot.frame);value=\(String(describing: snapshot.value))"
        }
        let geometry = [
            state("window", app.windows.firstMatch),
            state("finder.page", app.scrollViews["finder.page"]),
            state("finder.unit", app.textFields["finder.unit"]),
            state("finder.address", app.textFields["finder.address"]),
            state("finder.editSearch", app.buttons["finder.editSearch"]),
            state("navigation", app.navigationBars.firstMatch),
            state("tabBar", app.tabBars.firstMatch),
            state("keyboard", app.keyboards.firstMatch)
        ].joined(separator: "\n")
        let diagnostics = String("stage=\(stage);target=\(targetState)\n\(geometry)\n\(app.debugDescription)".prefix(32_768))
        print("PUBLIC-CATALOG-READINESS-DIAGNOSTIC \(diagnostics)")
        let attachment = XCTAttachment(string: diagnostics)
        attachment.name = "Public catalog Finder readiness"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func reveal(_ element: XCUIElement) {
        let page = app.scrollViews["finder.page"]
        // Scroll the page gutter rather than delivering a pan to its embedded map.
        for _ in 0..<6 where !element.isHittable {
            page.coordinate(withNormalizedOffset: CGVector(dx: 0.02, dy: 0.85))
                .press(forDuration: 0.01, thenDragTo: page.coordinate(withNormalizedOffset: CGVector(dx: 0.02, dy: 0.2)))
        }
        expectHittable(element)
    }
}
