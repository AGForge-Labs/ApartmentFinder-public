import XCTest

final class PublicCatalogUpdatesUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["--uitesting", "--test-store", UUID().uuidString,
                               "--reset-test-inbox", "--catalog-refresh-offline",
                               "--synthetic-map-location", "--synthetic-community-picker-trace"]
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
            if pickerRowFullyVisible(tuscano) { break }
            app.swipeUp()
        }
        XCTAssertTrue(tuscano.waitForExistence(timeout: 5))
        XCTAssertTrue(tuscano.isHittable)
        XCTAssertTrue(pickerRowFullyVisible(tuscano), "The entire community row must be inside the app window before its single tap")
        observePickerSnapshotBeforeTap()
        tuscano.tap()
        // The Finder button also exists behind this sheet; its existence is not
        // a dismissal signal. Wait for the actual presentation boundary.
        let picker = app.navigationBars["Communities"]
        let pickerClosed = picker.waitForNonExistence(timeout: 5)
        observePickerTraceAfterWait()
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
        let editSearch = app.navigationBars["ApartmentFinder"].buttons["finder.editSearch"]
        expectHittable(editSearch)
        editSearch.tap()
        let unit = app.scrollViews["finder.page"].textFields["finder.unit"]
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

    private func observePickerSnapshotBeforeTap() {
        print("PICKER-BOUNDARY-OBSERVATION schema=1;phase=beforeSingleTap;status=readStarted")
        do {
            let snapshot = try app.snapshot()
            var visited = 0, truncated = false
            var targets: [(CGRect, CGRect?, CGRect?)] = []
            var traceValues: [String] = []
            func visit(_ node: XCUIElementSnapshot, window: CGRect?, list: CGRect?) {
                guard visited < 4096 else { truncated = true; return }
                visited += 1
                let currentWindow = node.elementType == .window ? node.frame : window
                let isList = node.elementType == .collectionView || node.elementType == .table || node.elementType == .scrollView
                let currentList = isList ? node.frame : list
                if node.identifier == "finder.community.tuscano" {
                    targets.append((node.frame, currentWindow, currentList))
                }
                if node.identifier == "finder.community" { traceValues.append(safePickerTrace(node.value)) }
                for child in node.children {
                    if truncated { break }
                    visit(child, window: currentWindow, list: currentList)
                }
            }
            visit(snapshot, window: nil, list: nil)
            guard !truncated, targets.count == 1, let target = targets.first,
                  let window = target.1, let list = target.2 else {
                print("PICKER-BOUNDARY-OBSERVATION schema=1;phase=beforeSingleTap;status=ambiguousOrTruncated;targetCount=\(min(2, targets.count))")
                return
            }
            let trace = traceValues.count == 1 ? traceValues[0] : "unavailable"
            print("PICKER-BOUNDARY-OBSERVATION schema=1;phase=beforeSingleTap;status=observed;target=\(target.0);window=\(window);list=\(list);trace=\(trace)")
        } catch {
            print("PICKER-BOUNDARY-OBSERVATION schema=1;phase=beforeSingleTap;status=unavailable")
        }
    }

    private func observePickerTraceAfterWait() {
        // Read after the original result is fixed; this never changes that result.
        print("PICKER-BOUNDARY-OBSERVATION schema=1;phase=afterOriginalDismissalWait;status=readStarted")
        let snapshot = try? app.buttons["finder.community"].snapshot()
        let trace = safePickerTrace(snapshot?.value)
        print("PICKER-BOUNDARY-OBSERVATION schema=1;phase=afterOriginalDismissalWait;trace=\(trace)")
    }

    private func safePickerTrace(_ value: Any?) -> String {
        guard let raw = value as? String, raw.count <= 200, raw.hasPrefix("PickerTraceV1:") else { return "unavailable" }
        let stages = raw.dropFirst("PickerTraceV1:".count).split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        if stages == ["mirrorUnavailable"] { return "mirrorUnavailable" }
        let allowed: Set<String> = ["armed", "chooseEntered", "finderTargetAssigned", "finderAssignmentMismatch",
                                    "clearPreviewEntered", "clearPreviewReturned", "chooseReturned", "dismissRequested", "sheetDisappeared"]
        guard stages.first == "armed", stages.count <= 8, Set(stages).count == stages.count,
              stages.allSatisfy({ allowed.contains($0) }) else { return "unavailable" }
        return stages.joined(separator: ",")
    }

    private func pickerRowFullyVisible(_ row: XCUIElement) -> Bool {
        guard let app else { return false }
        let window = app.windows.firstMatch
        guard row.exists, window.exists else { return false }
        let frame = row.frame, windowFrame = window.frame
        // A partly clipped List row can be hittable while its default tap
        // center lies outside the window. Keep scrolling the real picker until
        // the complete finite row is visible; do not retry the selection tap.
        guard usableFrame(frame), usableFrame(windowFrame), windowFrame.contains(frame) else { return false }
        return row.isHittable
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
        let startedAt = ProcessInfo.processInfo.systemUptime
        let deadline = startedAt + 5
        var timingEvents = 0
        var snapshotErrorEvents = 0
        func timing(_ stage: String, _ status: String) {
            #if DEBUG && targetEnvironment(simulator)
            let arguments = app.launchArguments
            guard arguments.contains("--uitesting"),
                  let storeFlag = arguments.firstIndex(of: "--test-store"),
                  storeFlag + 1 < arguments.count, UUID(uuidString: arguments[storeFlag + 1]) != nil,
                  arguments.contains("--catalog-refresh-offline"),
                  arguments.contains("--synthetic-community-picker-trace"), timingEvents < 32 else { return }
            timingEvents += 1
            let elapsed = ProcessInfo.processInfo.systemUptime - startedAt
            let milliseconds = Int(min(600_000, max(0, elapsed * 1_000)))
            print("FINDER-HIT-TIMING schema=1;line=\(line);event=\(timingEvents);stage=\(stage);status=\(status);elapsedMs=\(milliseconds);deadlineMs=5000")
            #endif
        }
        func snapshotFailure(_ error: Error) {
            #if DEBUG && targetEnvironment(simulator)
            let arguments = app.launchArguments
            guard arguments.contains("--uitesting"),
                  let storeFlag = arguments.firstIndex(of: "--test-store"),
                  storeFlag + 1 < arguments.count, UUID(uuidString: arguments[storeFlag + 1]) != nil,
                  arguments.contains("--catalog-refresh-offline"),
                  arguments.contains("--synthetic-community-picker-trace"), snapshotErrorEvents < 4 else { return }
            snapshotErrorEvents += 1
            let ns = error as NSError
            let sampledDomain = String(ns.domain.prefix(97))
            let domainPrefix = String(sampledDomain.prefix(96))
            let domainIsIdentifier = !domainPrefix.isEmpty && domainPrefix.utf8.allSatisfy {
                (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || [45, 46, 95].contains($0)
            }
            let domain = domainIsIdentifier ? domainPrefix : "nonIdentifierDomain"
            // Inspect a bounded message only in memory; never log it or userInfo.
            // The fixed category is a keyword hint, not an official error-code diagnosis.
            let text = String(ns.localizedDescription.prefix(512)).lowercased()
            let reason: String
            if text.contains("multiple matching") || text.contains("ambiguous") { reason = "ambiguous" }
            else if text.contains("no matches") || text.contains("no matching") { reason = "noMatches" }
            else if text.contains("timed out") || text.contains("timeout") { reason = "timeout" }
            else { reason = "other" }
            print("FINDER-SNAPSHOT-ERROR schema=1;line=\(line);stage=targetSnapshot;domain=\(domain);domainTruncated=\(sampledDomain.count > 96);code=\(ns.code);reason=\(reason)")
            #endif
        }
        timing("geometryWait", "begin")
        var lastGeometry = "No usable target/window snapshots observed"
        let geometry = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            let window = app.windows.firstMatch
            let targetSnapshot: XCUIElementSnapshot
            timing("targetSnapshot", "begin")
            do {
                targetSnapshot = try element.snapshot()
                timing("targetSnapshot", "returned")
            } catch {
                lastGeometry = "Target snapshot unavailable"
                timing("targetSnapshot", "unavailable")
                snapshotFailure(error)
                return false
            }
            let windowSnapshot: XCUIElementSnapshot
            timing("windowSnapshot", "begin")
            do {
                windowSnapshot = try window.snapshot()
                timing("windowSnapshot", "returned")
            } catch {
                lastGeometry = "Application window snapshot unavailable"
                timing("windowSnapshot", "unavailable")
                return false
            }
            // Read the captured attributes locally before asking XCTest for a
            // real hit point; missing or unusable geometry never qualifies.
            let frame = targetSnapshot.frame, windowFrame = windowSnapshot.frame
            let intersection = frame.intersection(windowFrame)
            lastGeometry = "id=\(targetSnapshot.identifier);frame=\(frame);window=\(windowFrame);intersection=\(intersection)"
            guard self.usableFrame(frame), self.usableFrame(windowFrame), self.usableFrame(intersection) else {
                timing("geometry", "unusable")
                return false
            }
            timing("geometry", "usable")
            return true
        }, object: nil)
        let geometryResult = XCTWaiter.wait(for: [geometry], timeout: 5)
        timing("geometryWait", geometryResult == .completed ? "completed" : "failed")
        let remaining = deadline - ProcessInfo.processInfo.systemUptime
        var hittable = false
        if geometryResult == .completed, remaining > 0 {
            // Geometry and the framework-owned hit wait share one deadline.
            // A late true result cannot turn an expired wait into success.
            timing("hitWait", "begin")
            hittable = element.wait(for: \.isHittable, toEqual: true, timeout: remaining)
            timing("hitWait", hittable ? "returnedTrue" : "returnedFalse")
        } else {
            timing("hitWait", geometryResult == .completed ? "deadlineExpired" : "geometryUnavailable")
        }
        let result: XCTWaiter.Result =
            hittable && ProcessInfo.processInfo.systemUptime <= deadline ? .completed : .timedOut
        timing("result", result == .completed ? "completed" : "failed")
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
