import XCTest

final class PublicCatalogUpdatesUITests: XCTestCase {
    private var app: XCUIApplication!
    private var readinessDiagnosticEmitted = false
    private var cachedReadinessTarget = "No readiness geometry captured"

    override func setUp() {
        super.setUp()
        readinessDiagnosticEmitted = false
        cachedReadinessTarget = "No readiness geometry captured"
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
            // Failure evidence is cached; another AX request can delay teardown.
            catalogReadinessDiagnostics(stage: "tearDown after failure")
        } else {
            let screenshot = XCTAttachment(screenshot: app.screenshot())
            screenshot.name = "Public pin data offline refresh final screen"
            screenshot.lifetime = .keepAlways
            add(screenshot)
        }
        app.terminate()
        super.tearDown()
    }

    func testOfflineRefreshKeepsCatalogSelectionAndPinEditingAvailable() {
        XCTAssertTrue(app.tabBars.buttons["Apartments"].isSelected)
        app.tabBars.buttons["Finder"].tap()
        XCTAssertTrue(app.buttons["finder.community"].waitForExistence(timeout: 5))
        // Use the production picker search instead of walking the full catalog.
        // Keep the identical Tuscano fixture and one final community-row tap.
        app.buttons["finder.community"].tap()
        XCTAssertTrue(app.navigationBars["Communities"].waitForExistence(timeout: 5))
        let communitySearch = app.searchFields.firstMatch
        XCTAssertTrue(communitySearch.waitForExistence(timeout: 5))
        XCTAssertEqual(app.searchFields.count, 1, "The presented picker must expose one unambiguous production search field")
        expectHittable(communitySearch)
        communitySearch.tap()
        communitySearch.typeText("Tuscano")
        let queryEntered = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "Tuscano"), object: communitySearch)
        XCTAssertEqual(XCTWaiter.wait(for: [queryEntered], timeout: 5), .completed)
        let tuscano = app.buttons["finder.community.tuscano"]
        XCTAssertTrue(tuscano.waitForExistence(timeout: 5))
        let filteredCommunityRows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "finder.community."))
        XCTAssertEqual(filteredCommunityRows.count, 1, "The entered query must filter the presented list to one community")
        XCTAssertEqual(filteredCommunityRows.firstMatch.identifier, "finder.community.tuscano")
        XCTAssertTrue(tuscano.isHittable)
        XCTAssertTrue(pickerRowFullyVisible(tuscano), "The entire community row must be inside the app window before its single tap")
        observePickerSnapshotBeforeTap()
        tuscano.tap()
        // The Finder button also exists behind this sheet; its existence is not
        // a dismissal signal. Wait for the actual presentation boundary.
        let picker = app.navigationBars["Communities"]
        let pickerClosed = picker.waitForNonExistence(timeout: 5)
        if pickerClosed {
            observePickerTraceAfterWait()
        } else {
            print("PublicCatalogPickerFailure pickerClosed=false;lateAXReadsSkipped=true")
            catalogReadinessDiagnostics(stage: "community picker dismissal wait failed")
        }
        XCTAssertTrue(pickerClosed, "Selecting the community must dismiss its picker before entering a unit")
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5),
                      "Dismissing the community picker must end its search editing before Finder input")
        XCTAssertTrue(app.buttons["finder.community"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.navigationBars["Communities"].exists)
        XCTAssertTrue(app.buttons["finder.community"].label.contains("Tuscano"))
        XCTAssertEqual(app.textFields["finder.address"].value as? String, "7255 W Sunset Rd")
        // Reveal the search card through its production toolbar control. The
        // community button can be visible while the fields above it are not.
        let editSearch = app.buttons.matching(NSPredicate(format: "identifier == %@", "finder.editSearch")).firstMatch
        expectHittable(editSearch, requestedIdentifier: "finder.editSearch")
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
            // The original result is final. Failure diagnostics must not issue
            // new value/placeholder/keyboard/hierarchy AX reads after its deadline.
            print("PublicCatalogInputFailure wait=\(entryWaitResult.rawValue);lateAXReadsSkipped=true")
            catalogReadinessDiagnostics(stage: "typed unit value wait failed")
        }
        XCTAssertEqual(entryWaitResult, .completed)
        XCTAssertEqual(unit.value as? String, "2066")
        // Use the production control to end editing and reveal the search card
        // before requiring a hit point for its Search button.
        expectHittable(editSearch, requestedIdentifier: "finder.editSearch")
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
                                requestedIdentifier: String? = nil,
                                file: StaticString = #filePath, line: UInt = #line) {
        guard let app else { XCTFail("The synthetic test app must be launched", file: file, line: line); return }
        let startedAt = ProcessInfo.processInfo.systemUptime
        let deadline = startedAt + 5
        var timingEvents = 0
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
        // Readiness is a real on-time XCTest hit point, followed by the test's
        // actual interactions and assertions. Do not add frame/snapshot AX reads
        // here: their independent latency can outlast an already returned hit.
        // The separate full selected-row geometry assertion remains in the test.
        timing("hitWait", "begin")
        let hitBudget = deadline - ProcessInfo.processInfo.systemUptime
        let hittable = hitBudget > 0 && element.wait(for: \.isHittable, toEqual: true, timeout: hitBudget)
        timing("hitWait", hittable ? "returnedTrue" : "returnedFalse")
        let result: XCTWaiter.Result =
            hittable && ProcessInfo.processInfo.systemUptime <= deadline ? .completed : .timedOut
        timing("result", result == .completed ? "completed" : "failed")
        let readinessState = "requestedID=\(requestedIdentifier ?? "unspecified");realHit=\(hittable);result=\(result.rawValue);geometryNotRead;actualInteractionAssertionsStillRequired"
        cachedReadinessTarget = String(readinessState.prefix(2_048))
        if result != .completed {
            catalogReadinessDiagnostics(stage: "hittability wait failed", targetState: readinessState)
        }
        XCTAssertEqual(result, .completed, "The control must become hittable within five seconds; \(readinessState)", file: file, line: line)
    }

    private func usableFrame(_ frame: CGRect) -> Bool {
        !frame.isNull && !frame.isEmpty &&
            [frame.minX, frame.minY, frame.maxX, frame.maxY].allSatisfy { $0.isFinite }
    }

    private func catalogReadinessDiagnostics(stage: String, targetState: String = "") {
        #if DEBUG && targetEnvironment(simulator)
        guard let app, !readinessDiagnosticEmitted else { return }
        let arguments = app.launchArguments
        guard arguments.contains("--uitesting"),
              let storeFlag = arguments.firstIndex(of: "--test-store"),
              storeFlag + 1 < arguments.count, UUID(uuidString: arguments[storeFlag + 1]) != nil,
              arguments.contains("--catalog-refresh-offline"),
              arguments.contains("--synthetic-community-picker-trace") else { return }
        readinessDiagnosticEmitted = true
        // This failure-only record uses already captured strings and scalars.
        // Do not request snapshots, hierarchy dumps, values or screenshots here.
        let cached = targetState.isEmpty ? cachedReadinessTarget : targetState
        let diagnostics = "stage=\(String(stage.prefix(96)));target=\(String(cached.prefix(2_048)));lateAXReadsSkipped=true"
        print("PUBLIC-CATALOG-READINESS-DIAGNOSTIC \(diagnostics)")
        let attachment = XCTAttachment(string: diagnostics)
        attachment.name = "Public catalog Finder readiness"
        attachment.lifetime = .keepAlways
        add(attachment)
        #endif
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
