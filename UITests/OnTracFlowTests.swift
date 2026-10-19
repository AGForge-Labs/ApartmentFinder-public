import XCTest

final class OnTracFlowTests: XCTestCase {
    private var app: XCUIApplication!
    private var syntheticDiagnosticsEnabled: Bool {
        ProcessInfo.processInfo.environment["APARTMENTFINDER_SYNTHETIC_DIAGNOSTICS"] == "1" &&
            name.contains("testSourceUnitPinAppearsOnMapAfterOnTracImport")
    }
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["--uitesting", "--test-store", UUID().uuidString, "--reset-test-inbox"]
        if syntheticDiagnosticsEnabled {
            app.launchArguments += ["--synthetic-ui-diagnostics", "--synthetic-diagnostic-probe", "toolbar"]
            print("syntheticHarness=toolbar;event=beforeLaunch")
        }
        if name.contains("testShuffledOnTracNumbersRemainOrderedAndVisibleAfterRelaunch") {
            app.launchArguments.append("--numbered-ontrac-manifest")
        } else if name.contains("testNewManifestReplacesPreviousApartmentsAndPutsTuscanoStopOneFirst") {
            app.launchArguments.append("--replacement-manifest")
        }
        app.launch()
        if syntheticDiagnosticsEnabled { print("syntheticHarness=toolbar;event=launchReturned") }
        XCTAssertTrue(app.buttons["apartments.import"].waitForExistence(timeout: 20))
        app.launchArguments.removeAll { $0 == "--reset-test-inbox" }
    }
    override func tearDown() {
        if let app {
            capture("Final screen")
            if !syntheticDiagnosticsEnabled && (testRun?.totalFailureCount ?? 0) > 0 {
                let hierarchy = XCTAttachment(string: app.debugDescription)
                hierarchy.name = "Accessibility"; hierarchy.lifetime = .keepAlways; add(hierarchy)
            }
            app.terminate()
        }
        super.tearDown()
    }
    private func capture(_ name: String) {
        if syntheticDiagnosticsEnabled { return }
        let image = XCTAttachment(screenshot: app.screenshot())
        image.name = name; image.lifetime = .keepAlways; add(image)
    }
    private func reach(_ element: XCUIElement) {
        XCTAssertTrue(element.waitForExistence(timeout: 10))
        for _ in 0..<5 where !element.isHittable { app.swipeUp() }
        XCTAssertTrue(element.isHittable)
    }
    private func tapTestImport() {
        let controls = app.buttons.matching(identifier: "test.import")
        XCTAssertEqual(controls.count, 1, chooserDiagnostics())
        let control = controls.firstMatch
        XCTAssertTrue(control.isEnabled, chooserDiagnostics())
        XCTAssertTrue(control.isHittable, chooserDiagnostics())
        if syntheticDiagnosticsEnabled { print("syntheticHarness=toolbar;event=beforeTap") }
        control.tap()
        if syntheticDiagnosticsEnabled { print("syntheticHarness=toolbar;event=tapReturned") }
    }
    private func controlDiagnostics(_ id: String, token: String) -> String {
        let controls = app.buttons.matching(identifier: id)
        guard controls.count == 1 else { return "\(token)Count=\(controls.count)" }
        let control = controls.firstMatch, frame = control.frame
        let valid = !frame.isEmpty && [frame.minX, frame.minY, frame.width, frame.height].allSatisfy { $0.isFinite }
        let inside = valid && app.frame.contains(CGPoint(x: frame.midX, y: frame.midY))
        return "\(token)Count=1;\(token)Enabled=\(control.isEnabled);\(token)Hittable=\(control.isHittable);\(token)FrameValid=\(valid);\(token)CenterInside=\(inside)"
    }
    // Fixed-key state only: never print alert text, labels, paths or a hierarchy.
    private func chooserDiagnostics() -> String {
        if syntheticDiagnosticsEnabled { return activationDiagnostics() }
        let fullID = "manifest.file.manifest_2026-01-02.csv"
        let emptyID = "manifest.file.manifest_2026-01-01.csv"
        let anyFull = app.descendants(matching: .any).matching(identifier: fullID)
        let type = anyFull.firstMatch.exists ? String(anyFull.firstMatch.elementType.rawValue) : "none"
        let controls = app.buttons.matching(identifier: "test.import")
        let status = controls.count == 1 ? (controls.firstMatch.value as? String ?? "no-status") : "importControlCount=\(controls.count)"
        let submit = app.buttons["manifest.import"]
        let geometry = [("test.mixed", "mixed"), ("test.import", "import"), ("test.share", "share")]
            .map { controlDiagnostics($0.0, token: $0.1) }.joined(separator: ";")
        let frames = ["test.mixed", "test.import", "test.share"].compactMap { id -> CGRect? in
            let items = app.buttons.matching(identifier: id)
            return items.count == 1 ? items.firstMatch.frame : nil
        }
        var overlap = false, equalFrames = false
        for i in frames.indices { for j in frames.indices where j > i {
            overlap = overlap || frames[i].intersects(frames[j])
            equalFrames = equalFrames || frames[i] == frames[j]
        } }
        return "state=\(app.state.rawValue);appAlert=\(app.alerts["ApartmentFinder"].exists);importAlert=\(app.alerts["Could not import"].exists);settings=\(app.navigationBars["Settings"].exists);preview=\(app.navigationBars["Preview manifest"].exists);fullButtons=\(app.buttons.matching(identifier: fullID).count);emptyButtons=\(app.buttons.matching(identifier: emptyID).count);fullAny=\(anyFull.count);fullType=\(type);submit=\(submit.exists);submitEnabled=\(submit.exists && submit.isEnabled);overlap=\(overlap);equalFrames=\(equalFrames);\(geometry);\(status)"
    }
    func testSourceUnitPinAppearsOnMapAfterOnTracImport() {
        let packImport = app.buttons["Import private map pack"]
        XCTAssertTrue(packImport.waitForExistence(timeout: 5))
        XCTAssertTrue(packImport.isEnabled)
        XCTAssertTrue(packImport.isHittable)
        XCTAssertFalse(packImport.frame.intersects(app.navigationBars["Apartments"].frame))
        tapTestImport()
        guard chooseDay() else { return }
        let submit = app.buttons["manifest.import"]; reach(submit); submit.tap()
        XCTAssertTrue(app.buttons["apartment.fictional-courtyard"].waitForExistence(timeout: 10))
        app.buttons["apartment.fictional-courtyard"].tap()
        app.buttons["mini.start"].tap()
        XCTAssertTrue(app.maps.firstMatch.waitForExistence(timeout: 8))
        XCTAssertFalse(app.navigationBars["Check Door Pin"].exists)
        let pin = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "mini.pin.1.")).firstMatch
        XCTAssertTrue(pin.waitForExistence(timeout: 5))
        XCTAssertTrue(pin.label.contains("4102"))
        XCTAssertFalse(app.buttons["mini.navigate"].exists)
        capture("OnTrac unit 4102 shown on mini-route map")
        app.buttons["mini.prepare"].tap()
        XCTAssertTrue(app.buttons["door.confirm"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.textFields["door.unit"].value as? String, "4102")
        app.buttons["Cancel"].tap()
        XCTAssertTrue(app.maps.firstMatch.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["mini.navigate"].exists)
        capture("Cancelling pin review preserves the active map")
    }
    func testZIPPreviewCancellationEmptyDayAndApartmentNavigation() {
        tapTestImport()
        XCTAssertTrue(app.buttons["manifest.file.manifest_2026-01-02.csv"].waitForExistence(timeout: 10), chooserDiagnostics())
        XCTAssertFalse(app.buttons["manifest.import"].exists)
        chooseDay()
        let submit = app.buttons["manifest.import"]; reach(submit)
        XCTAssertTrue(submit.isEnabled)
        capture("OnTrac manifest preview")
        app.buttons["Cancel"].tap()
        XCTAssertFalse(app.buttons["apartment.fictional-courtyard"].exists)
        tapTestImport()
        let empty = app.buttons["manifest.file.manifest_2026-01-01.csv"]
        XCTAssertTrue(empty.waitForExistence(timeout: 10)); empty.tap()
        XCTAssertFalse(app.buttons["manifest.import"].isEnabled)
        XCTAssertTrue(app.staticTexts["manifest.empty"].exists)
        app.buttons["manifest.file.manifest_2026-01-02.csv"].tap()
        reach(submit); submit.tap()
        let stop = app.buttons["apartment.fictional-courtyard"]; XCTAssertTrue(stop.waitForExistence(timeout: 5)); stop.tap()
        XCTAssertTrue(app.buttons["mini.stop.1"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["mini.stop.1"].label.contains("4102"))
        capture("Imported apartment mini-route")
        app.terminate(); app.launch()
        XCTAssertTrue(app.buttons["apartment.fictional-courtyard"].waitForExistence(timeout: 5))
    }
    func testSystemShareSheetAcceptsZIPAndHandsOffToPersistentStops() {
        app.buttons["test.share"].tap()
        let target = app.cells["ApartmentFinder"].firstMatch
        if !target.waitForExistence(timeout: 5) {
            let more = app.cells["More"].firstMatch
            if more.exists { more.tap() }
        }
        XCTAssertTrue(target.waitForExistence(timeout: 10))
        reach(target); capture("ApartmentFinder in iOS share sheet"); target.tap()
        chooseDay()
        let submit = app.buttons["manifest.import"]; reach(submit)
        submit.tap()
        XCTAssertTrue(app.otherElements["manifest.saved"].waitForExistence(timeout: 10) ||
                      app.staticTexts["Saved to ApartmentFinder"].waitForExistence(timeout: 5))
        capture("Share extension saved manifest")
        app.buttons["Done"].firstMatch.tap()
        app.terminate(); app.launch()
        let importButton = app.buttons["manifest.import"]; reach(importButton); importButton.tap()
        XCTAssertTrue(app.buttons["apartment.fictional-courtyard"].waitForExistence(timeout: 5))
        app.buttons["apartment.fictional-courtyard"].tap()
        XCTAssertTrue(app.buttons["mini.stop.1"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["mini.stop.1"].label.contains("4102"))
        capture("Shared OnTrac apartment mini-route")
    }
    // Screen points only, never GPS. A control center is not evidence of the injected tap point.
    private func frameDiagnostics(_ frame: CGRect, token: String) -> String {
        let values = [frame.minX, frame.minY, frame.width, frame.height]
        guard !frame.isEmpty, values.allSatisfy({ $0.isFinite && abs($0) < 10000 }) else {
            return "\(token)Frame=invalid"
        }
        return "\(token)X=\(Int(frame.minX.rounded()));\(token)Y=\(Int(frame.minY.rounded()));\(token)W=\(Int(frame.width.rounded()));\(token)H=\(Int(frame.height.rounded()))"
    }
    private func activationDiagnostics() -> String {
        let toolbar = app.buttons.matching(identifier: "test.import")
        let rawStatus = toolbar.count == 1 ? (toolbar.firstMatch.value as? String ?? "") : ""
        let pattern = "^mixedAttempts=[0-9]{1,3};importAttempts=[0-9]{1,3};shareAttempts=[0-9]{1,3};lastAction=(none|mixed|manifestImport|share|productionImport);fixtureReady=(true|false);loading=(true|false);documents=[0-9]{1,3};errorPresent=(true|false)$"
        let status = rawStatus.range(of: pattern, options: .regularExpression) != nil ? rawStatus : "toolbarAX=unavailable"
        let production = app.buttons.matching(identifier: "apartments.import")
        let rawProduction = production.count == 1 ? (production.firstMatch.value as? String ?? "") : ""
        let productionPattern = "^mixedAttempts=[0-9]{1,3};importAttempts=[0-9]{1,3};shareAttempts=[0-9]{1,3};productionAttempts=[0-9]{1,3};lastAction=(none|mixed|manifestImport|share|productionImport)$"
        let productionAX = rawProduction.range(of: productionPattern, options: .regularExpression) != nil
            ? "productionAX." + rawProduction.replacingOccurrences(of: ";", with: ";productionAX.") : "productionAX=unavailable"
        var frames = [frameDiagnostics(app.frame, token: "window")]
        for (query, token) in [(toolbar, "toolbar"),
                               (production, "production"),
                               (app.navigationBars.matching(identifier: "Apartments"), "navigation"),
                               (app.buttons.matching(identifier: "Import private map pack"), "noPackControl")] {
            if query.count == 1 { frames.append(frameDiagnostics(query.firstMatch.frame, token: token)) }
            else { frames.append("\(token)Frame=unavailable") }
        }
        return "state=\(app.state.rawValue);\(status);\(productionAX);\(frames.joined(separator: ";"))"
    }
    private func probeProductionImport() {
        guard syntheticDiagnosticsEnabled,
              let storeIndex = app.launchArguments.firstIndex(of: "--test-store"),
              storeIndex + 1 < app.launchArguments.count,
              let probeIndex = app.launchArguments.firstIndex(of: "--synthetic-diagnostic-probe"),
              probeIndex + 1 < app.launchArguments.count else {
            print("syntheticHarness=production;event=invalidArguments"); return
        }
        let deadline = Date().addingTimeInterval(60)
        func remaining() -> TimeInterval { min(6, max(0, deadline.timeIntervalSinceNow)) }
        app.terminate()
        app.launchArguments[storeIndex + 1] = UUID().uuidString
        app.launchArguments[probeIndex + 1] = "production"
        guard remaining() > 0 else { print("syntheticHarness=production;event=probeDeadline"); return }
        print("syntheticHarness=production;event=beforeLaunch")
        app.launch()
        print("syntheticHarness=production;event=launchReturned")
        let importButton = app.buttons["apartments.import"]
        guard remaining() > 0, importButton.waitForExistence(timeout: remaining()),
              importButton.isEnabled, importButton.isHittable else {
            print("syntheticHarness=production;event=controlUnavailable"); return
        }
        print("syntheticHarness=production;event=beforeTap")
        importButton.tap()
        print("syntheticHarness=production;event=tapReturned")
        let cancel = app.buttons.matching(identifier: "Cancel").firstMatch
        let cancelObserved = remaining() > 0 && cancel.waitForExistence(timeout: remaining())
        print("syntheticHarness=production;event=waitEnded;pickerCancelObserved=\(cancelObserved)")
        guard cancelObserved, remaining() > 0, cancel.isHittable else { return }
        cancel.tap()
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: cancel)
        let dismissed = remaining() > 0 && XCTWaiter.wait(for: [gone], timeout: remaining()) == .completed
        let returned = dismissed && importButton.exists && importButton.isHittable
        print("syntheticHarness=production;event=dismissed;pickerGone=\(dismissed);listReturned=\(returned)")
    }
    // Comparison observations never replace the original acceptance assertion.
    // Fresh A/B/A stores keep persistent data and launch-order warmup separate.
    private func probeToolbarHitRegion(_ probe: String) {
        guard syntheticDiagnosticsEnabled, ["bannerPassThrough", "toolbarRecheck"].contains(probe),
              let storeIndex = app.launchArguments.firstIndex(of: "--test-store"),
              storeIndex + 1 < app.launchArguments.count,
              let probeIndex = app.launchArguments.firstIndex(of: "--synthetic-diagnostic-probe"),
              probeIndex + 1 < app.launchArguments.count else {
            print("syntheticHarness=toolbarComparison;event=invalidArguments"); return
        }
        let deadline = Date().addingTimeInterval(60)
        func remaining() -> TimeInterval { min(10, max(0, deadline.timeIntervalSinceNow)) }
        app.terminate()
        app.launchArguments[storeIndex + 1] = UUID().uuidString
        app.launchArguments[probeIndex + 1] = probe
        guard remaining() > 0 else { print("syntheticHarness=\(probe);event=probeDeadline"); return }
        print("syntheticHarness=\(probe);event=beforeLaunch")
        app.launch()
        print("syntheticHarness=\(probe);event=launchReturned")
        let controls = app.buttons.matching(identifier: "test.import"), control = controls.firstMatch
        guard remaining() > 0, control.waitForExistence(timeout: remaining()),
              controls.count == 1, control.isEnabled, control.isHittable else {
            print("syntheticHarness=\(probe);event=controlUnavailable"); return
        }
        print("syntheticHarness=\(probe);event=beforeTap;\(controlDiagnostics("test.import", token: "import"));\(activationDiagnostics())")
        control.tap()
        print("syntheticHarness=\(probe);event=tapReturned")
        let chooser = app.buttons["manifest.file.manifest_2026-01-02.csv"]
        let chooserObserved = remaining() > 0 && chooser.waitForExistence(timeout: remaining())
        print("syntheticHarness=\(probe);event=waitEnded;chooserObserved=\(chooserObserved);\(activationDiagnostics())")
    }
    @discardableResult
    private func chooseDay() -> Bool {
        let day = app.buttons["manifest.file.manifest_2026-01-02.csv"]
        let originalChooserFound = day.waitForExistence(timeout: 10)
        if originalChooserFound { day.tap(); return true }
        let originalDiagnostics = chooserDiagnostics()
        if !originalChooserFound && syntheticDiagnosticsEnabled {
            print("syntheticHarness=toolbar;event=chooserMissing;\(originalDiagnostics)")
            probeProductionImport()
            probeToolbarHitRegion("bannerPassThrough")
            probeToolbarHitRegion("toolbarRecheck")
        }
        XCTAssertTrue(originalChooserFound, originalDiagnostics)
        return false
    }
    func testShuffledOnTracNumbersRemainOrderedAndVisibleAfterRelaunch() {
        let mixed = app.buttons["test.mixed"]
        XCTAssertTrue(mixed.waitForExistence(timeout: 10)); mixed.tap()
        let first = app.staticTexts["manifest.first-apartment"]
        XCTAssertTrue(first.waitForExistence(timeout: 10))
        XCTAssertTrue(first.label.contains("Stop 1"))
        XCTAssertTrue(first.label.contains("Tuscano"))
        let submit = app.buttons["manifest.import"]; reach(submit); submit.tap()
        let tuscano = app.buttons["apartment.tuscano"]
        let envision = app.buttons["apartment.envision-at-sunset"]
        XCTAssertTrue(tuscano.waitForExistence(timeout: 10))
        XCTAssertTrue(envision.waitForExistence(timeout: 10))
        XCTAssertTrue(tuscano.label.contains("First stop 1"))
        XCTAssertTrue(tuscano.label.contains("3 of 3 deliveries left"))
        XCTAssertTrue(envision.label.contains("First stop 20"))
        XCTAssertLessThan(tuscano.frame.minY, envision.frame.minY)
        capture("Shuffled OnTrac export preserves source stop numbers")
        app.terminate(); app.launch()
        XCTAssertTrue(tuscano.waitForExistence(timeout: 10))
        XCTAssertLessThan(tuscano.frame.minY, envision.frame.minY)
        tuscano.tap()
        let secondPackage = app.buttons["mini.stop.2"]
        XCTAssertTrue(secondPackage.waitForExistence(timeout: 10))
        XCTAssertTrue(secondPackage.label.contains("Stop 1 Â· Unit 2137"))
        XCTAssertTrue(app.buttons["mini.stop.3"].label.contains("Stop 1.2 Â· Unit 2149"))
    }
    func testNewManifestReplacesPreviousApartmentsAndPutsTuscanoStopOneFirst() {
        let mixed = app.buttons["test.mixed"]
        XCTAssertTrue(mixed.waitForExistence(timeout: 10)); mixed.tap()
        let submit = app.buttons["manifest.import"]; reach(submit); submit.tap()
        let tango = app.buttons["apartment.tango-bay"]
        let tuscano = app.buttons["apartment.tuscano"]
        XCTAssertTrue(tango.waitForExistence(timeout: 10))
        XCTAssertTrue(tuscano.waitForExistence(timeout: 10))
        XCTAssertLessThan(tango.frame.minY, tuscano.frame.minY)
        XCTAssertTrue(app.tabBars.buttons["Apartments"].isSelected)
        XCTAssertTrue(app.tabBars.buttons["Finder"].exists)
        tuscano.tap()
        XCTAssertTrue(app.buttons["mini.stop.27"].waitForExistence(timeout: 10))
        app.buttons["mini.start"].tap()
        XCTAssertTrue(app.maps.firstMatch.waitForExistence(timeout: 8))
        XCTAssertTrue(mixed.waitForExistence(timeout: 5))
        XCTAssertTrue(mixed.isHittable)
        XCTAssertEqual(app.buttons.matching(identifier: "test.mixed").count, 1)
        mixed.tap()
        XCTAssertTrue(app.staticTexts["manifest.first-apartment"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["manifest.first-apartment"].label.contains("Stop 1"))
        reach(submit); submit.tap()
        XCTAssertTrue(tuscano.waitForExistence(timeout: 10))
        XCTAssertEqual(app.state, .runningForeground)
        XCTAssertTrue(app.navigationBars["Apartments"].exists,
                      "Replacing a manifest from an active route must return to the Apartments list")
        XCTAssertTrue(app.buttons["apartments.import"].isHittable)
        XCTAssertFalse(app.maps.firstMatch.exists)
        XCTAssertFalse(app.buttons["mini.start"].exists)
        XCTAssertTrue(tuscano.isHittable)
        XCTAssertTrue(tuscano.label.contains("First stop 1"))
        XCTAssertTrue(tuscano.label.contains("2 of 2 deliveries left"))
        XCTAssertLessThan(tuscano.frame.minY, tango.frame.minY)
        XCTAssertFalse(app.buttons["apartment.solana-post"].exists)
        XCTAssertEqual(app.staticTexts["apartments.manifest-name"].label, "New-day.csv")
        capture("Replacement manifest starts with Tuscano stop 1")
        app.buttons["apartments.review"].tap()
        XCTAssertTrue(app.navigationBars["Review addresses"].waitForExistence(timeout: 5))
        app.navigationBars.buttons["Apartments"].tap()
        XCTAssertTrue(tuscano.waitForExistence(timeout: 5))
        app.buttons["apartments.review"].tap()
        XCTAssertTrue(app.navigationBars["Review addresses"].waitForExistence(timeout: 5))
        XCTAssertTrue(mixed.waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons.matching(identifier: "test.mixed").count, 1)
        mixed.tap()
        reach(submit); submit.tap()
        XCTAssertTrue(tuscano.waitForExistence(timeout: 10))
        XCTAssertTrue(app.navigationBars["Apartments"].exists,
                      "A new manifest must reset a pushed review even when its stop IDs are unchanged")
        XCTAssertTrue(app.buttons["apartments.import"].isHittable)
        XCTAssertFalse(app.navigationBars["Review addresses"].exists)
        XCTAssertEqual(app.staticTexts["apartments.manifest-name"].label, "New-day.csv")
        capture("Replacement from address review returns to the Apartments list")
        app.terminate(); app.launch()
        XCTAssertTrue(tuscano.waitForExistence(timeout: 10))
        XCTAssertLessThan(tuscano.frame.minY, tango.frame.minY)
        XCTAssertFalse(app.buttons["apartment.solana-post"].exists)
        tuscano.tap()
        XCTAssertTrue(app.buttons["mini.stop.1"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["mini.stop.3"].exists)
        XCTAssertFalse(app.buttons["mini.stop.27"].exists)
    }
}
