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
        // Select the identical fixture through Finder's existing exact-address
        // path before checking refresh, selection preservation and pin editing.
        let editSearch = app.buttons["finder.editSearch"]
        expectHittable(editSearch)
        editSearch.tap()
        replace(app.textFields["finder.address"], with: "7255 W Sunset Rd")
        replace(app.textFields["finder.unit"], with: "2066")
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

    private func expectHittable(_ element: XCUIElement) {
        let visible = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hittable == true"), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [visible], timeout: 5), .completed)
    }

    private func replace(_ field: XCUIElement, with value: String) {
        guard field.value as? String != value else { return }
        expectHittable(field)
        field.tap()
        let current = field.value as? String ?? ""
        if !current.isEmpty && current != field.placeholderValue {
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
