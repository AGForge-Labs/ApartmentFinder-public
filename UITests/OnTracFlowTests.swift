import XCTest

final class OnTracFlowTests: XCTestCase {
    private var app: XCUIApplication!
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["--uitesting", "--test-store", UUID().uuidString, "--reset-test-inbox"]
        if name.contains("testShuffledOnTracNumbersRemainOrderedAndVisibleAfterRelaunch") {
            app.launchArguments.append("--numbered-ontrac-manifest")
        } else if name.contains("testNewManifestReplacesPreviousApartmentsAndPutsTuscanoStopOneFirst") {
            app.launchArguments.append("--replacement-manifest")
        }
        app.launch()
        XCTAssertTrue(app.buttons["apartments.import"].waitForExistence(timeout: 20))
        app.launchArguments.removeAll { $0 == "--reset-test-inbox" }
    }
    override func tearDown() {
        if let app {
            capture("Final screen")
            if (testRun?.totalFailureCount ?? 0) > 0 {
                let hierarchy = XCTAttachment(string: app.debugDescription)
                hierarchy.name = "Accessibility"; hierarchy.lifetime = .keepAlways; add(hierarchy)
            }
            app.terminate()
        }
        super.tearDown()
    }
    private func capture(_ name: String) {
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
        control.tap()
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
        tapTestImport()
        chooseDay()
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
    private func chooseDay() {
        let day = app.buttons["manifest.file.manifest_2026-01-02.csv"]
        XCTAssertTrue(day.waitForExistence(timeout: 10), chooserDiagnostics()); day.tap()
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
