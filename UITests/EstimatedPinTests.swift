import XCTest

final class EstimatedPinTests: XCTestCase {
    func testDurangoEstimateWarningCorrectionAndRelaunch() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting", "--test-store", UUID().uuidString,
                               "--reset-test-inbox", "--coverage-level25-durango"]
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.buttons["test.mixed"].waitForExistence(timeout: 20))
        app.buttons["test.mixed"].tap()
        XCTAssertTrue(app.buttons["manifest.import"].waitForExistence(timeout: 10))
        app.buttons["manifest.import"].tap()
        XCTAssertTrue(app.buttons["apartment.level25-durango"].waitForExistence(timeout: 10))
        app.buttons["apartment.level25-durango"].tap()
        app.buttons["mini.start"].tap()
        XCTAssertTrue(app.maps.firstMatch.waitForExistence(timeout: 8))
        XCTAssertEqual(app.staticTexts["mini.evidenceStatus"].label, "Estimated")
        let pin = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "mini.pin.1.")).firstMatch
        XCTAssertTrue(pin.waitForExistence(timeout: 5))
        XCTAssertTrue(pin.label.contains("1002"))
        XCTAssertTrue(pin.label.contains("building 1"))
        XCTAssertTrue(pin.label.contains("Estimated"))
        XCTAssertFalse(app.buttons["mini.navigate"].exists)
        capture(app, "Durango estimates with per-unit warning")
        app.buttons["mini.prepare"].tap()
        XCTAssertTrue(app.navigationBars["Check Door Pin"].waitForExistence(timeout: 5))
        let editorForm = app.collectionViews.firstMatch
        XCTAssertTrue(editorForm.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["door.estimateWarning"].waitForExistence(timeout: 5))
        let chooseAnother = app.buttons["Choose another pin"]
        reveal(chooseAnother, in: editorForm, towardBottom: true, app: app)
        chooseAnother.tap()
        let placeNew = app.buttons["Place a new door pin"]
        reveal(placeNew, in: editorForm, towardBottom: false, app: app)
        placeNew.tap()
        let warning = app.staticTexts["door.estimateWarning"]
        reveal(warning, in: editorForm, towardBottom: false, app: app)
        XCTAssertTrue(warning.exists)
        let building = app.textFields["Building (optional)"]
        reveal(building, in: editorForm, towardBottom: true, app: app)
        XCTAssertEqual(building.value as? String, "1")
        let editorMap = editorForm.descendants(matching: .any).matching(identifier: "door.map").firstMatch
        reveal(editorMap, in: editorForm, towardBottom: false, app: app)
        XCTAssertFalse(app.buttons["door.confirm"].isEnabled)
        editorMap.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.55)).tap()
        app.buttons["door.confirm"].tap()
        XCTAssertTrue(app.buttons["mini.navigate"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["mini.evidenceStatus"].label, "Checked door")
        XCTAssertTrue(pin.label.contains("Checked door"))
        app.terminate()
        app.launchArguments.removeAll { $0 == "--reset-test-inbox" }
        app.launch()
        XCTAssertTrue(app.buttons["apartment.level25-durango"].waitForExistence(timeout: 15))
        app.buttons["apartment.level25-durango"].tap()
        app.buttons["mini.start"].tap()
        XCTAssertTrue(app.buttons["mini.navigate"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["mini.evidenceStatus"].label, "Checked door")
        app.buttons["mini.delivered"].tap()
        XCTAssertEqual(app.staticTexts["mini.next"].label, "Next · Stop 2")
        XCTAssertEqual(app.staticTexts["mini.evidenceStatus"].label, "Estimated")
        capture(app, "Corrected door persists and next estimate remains marked")
    }

    private func capture(_ app: XCUIApplication, _ name: String) {
        let image = XCTAttachment(screenshot: app.screenshot())
        image.name = name; image.lifetime = .keepAlways; add(image)
    }

    private func reveal(_ element: XCUIElement, in form: XCUIElement, towardBottom: Bool, app: XCUIApplication) {
        for _ in 0..<4 {
            if element.isHittable { return }
            // The form margin is outside its embedded map, so the gesture scrolls the form.
            let start = form.coordinate(withNormalizedOffset: CGVector(dx: 0.03, dy: towardBottom ? 0.82 : 0.24))
            let end = form.coordinate(withNormalizedOffset: CGVector(dx: 0.03, dy: towardBottom ? 0.24 : 0.82))
            start.press(forDuration: 0.05, thenDragTo: end)
        }
        XCTAssertTrue(element.isHittable, "Form control remained offscreen: \(element.identifier)\n\(app.debugDescription)")
    }
}
