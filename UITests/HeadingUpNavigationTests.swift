import XCTest

/// Synthetic course checks prove camera/marker wiring, not physical iPhone compass accuracy.
final class HeadingUpNavigationTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["--uitesting", "--test-store", UUID().uuidString,
            "--reset-test-inbox", "--tuscano-manifest", "--synthetic-map-location", "--synthetic-map-direction"]
    }

    override func tearDown() {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Heading-up mini-route final screen"
        attachment.lifetime = .keepAlways; add(attachment)
        app.terminate()
        super.tearDown()
    }

    private func openRoute() {
        app.launch()
        XCTAssertTrue(app.buttons["test.mixed"].waitForExistence(timeout: 20))
        app.buttons["test.mixed"].tap()
        XCTAssertTrue(app.buttons["manifest.import"].waitForExistence(timeout: 10))
        app.buttons["manifest.import"].tap()
        XCTAssertTrue(app.buttons["apartment.tuscano"].waitForExistence(timeout: 10))
        app.buttons["apartment.tuscano"].tap()
        app.buttons["mini.start"].tap()
        XCTAssertTrue(app.maps.firstMatch.waitForExistence(timeout: 8))
    }

    private func expectFollowing() {
        let control = app.buttons["mini.recenter"]
        let predicate = NSPredicate(format: "value BEGINSWITH %@", "Following, map heading 270 degrees")
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: control)], timeout: 8), .completed)
        let arrow = app.descendants(matching: .any).matching(identifier: "mini.userLocation").firstMatch
        XCTAssertTrue(arrow.waitForExistence(timeout: 5))
        XCTAssertEqual(arrow.value as? String, "Direction 270 degrees")
    }

    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways; add(attachment)
    }

    func testStartsHeadingUpAndResumePreservesChosenStop() {
        openRoute()
        expectFollowing()
        let map=app.maps.firstMatch
        let pinQuery=app.buttons.matching(NSPredicate(format:"identifier BEGINSWITH %@","mini.pin."))
        XCTAssertGreaterThanOrEqual(pinQuery.count,2)
        for pin in pinQuery.allElementsBoundByIndex {
            XCTAssertTrue(pin.isHittable,"Initial framing must reveal every relevant apartment pin")
            XCTAssertTrue(map.frame.insetBy(dx:12,dy:12).contains(CGPoint(x:pin.frame.midX,y:pin.frame.midY)))
        }
        capture("Initial heading-up frame includes user and apartment pins above the stop card")
        capture("Mini-route starts facing synthetic west with blue direction arrow")
        app.buttons["Show all stops"].tap()
        let control = app.buttons["mini.recenter"]
        XCTAssertEqual(control.label, "Resume following")
        let northUp = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value CONTAINS %@", "map heading 0 degrees"), object: control)
        XCTAssertEqual(XCTWaiter.wait(for: [northUp], timeout: 5), .completed)
        XCTAssertTrue((control.value as? String ?? "").hasPrefix("Paused"))
        capture("Show-all north-up map keeps the west-pointing blue arrow")
        app.buttons["mini.focus.3"].tap()
        XCTAssertTrue(app.staticTexts["Unit 2137"].exists)
        control.tap()
        expectFollowing()
        XCTAssertTrue(app.staticTexts["Unit 2137"].exists)
        app.buttons["mini.delivered"].tap()
        XCTAssertTrue(app.staticTexts["Unit 2066"].waitForExistence(timeout: 5))
        expectFollowing()
        capture("Heading-up delivery advances selected unit and retains following")
    }

    func testPanPausesAcrossGPSUpdatesAndOneTapCompletionUndoStillWork() {
        openRoute()
        expectFollowing()
        let map = app.maps.firstMatch
        let start = map.coordinate(withNormalizedOffset: CGVector(dx: 0.65, dy: 0.30))
        let end = map.coordinate(withNormalizedOffset: CGVector(dx: 0.82, dy: 0.30))
        start.press(forDuration: 0.2, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.5)
        let control = app.buttons["mini.recenter"]
        let paused = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value BEGINSWITH %@", "Paused"), object: control)
        XCTAssertEqual(XCTWaiter.wait(for: [paused], timeout: 5), .completed)
        // Inverted expectation observes two new synthetic GPS callbacks without a sleep.
        let resumed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value BEGINSWITH %@", "Following"), object: control)
        resumed.isInverted = true
        XCTAssertEqual(XCTWaiter.wait(for: [resumed], timeout: 4.5), .completed)
        capture("Panned mini-route remains paused across GPS updates")
        app.buttons["mini.completeRoute"].tap()
        XCTAssertTrue(app.buttons["mini.undoRoute"].waitForExistence(timeout: 5))
        XCTAssertTrue((control.value as? String ?? "").hasPrefix("Paused"))
        app.buttons["mini.undoRoute"].tap()
        XCTAssertTrue(app.buttons["mini.completeRoute"].waitForExistence(timeout: 5))
        XCTAssertTrue((control.value as? String ?? "").hasPrefix("Paused"))
        capture("Mini-route Undo restores stops while following stays paused")
        control.tap()
        expectFollowing()
        capture("Resume following restores west-up camera after manual pan")
    }

    func testResumePreservesActualPinchZoomAndSelectedStop() throws {
        openRoute()
        expectFollowing()
        let control = app.buttons["mini.recenter"]
        let initialDistance = try settledMapDistance(control)
        let initialCameraValue = String(describing: control.value)
        app.maps.firstMatch.pinch(withScale: 1.6, velocity: 0.7)
        print("MAP-PINCH before=\(initialCameraValue), after=\(String(describing: control.value))")
        let paused = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value BEGINSWITH %@", "Paused"), object: control)
        XCTAssertEqual(XCTWaiter.wait(for: [paused], timeout: 5), .completed,
                       "Pinch must pause following; initial distance=\(initialDistance), initial camera=\(initialCameraValue), camera value=\(String(describing: control.value)), map=\(app.maps.firstMatch.frame)")
        let zoomDistance = try settledMapDistance(control)
        XCTAssertGreaterThan(abs(initialDistance - zoomDistance), 20, "The gesture must actually change MapKit zoom")
        app.buttons["mini.focus.3"].tap()
        XCTAssertTrue(app.staticTexts["Unit 2137"].exists)
        XCTAssertEqual(try mapDistance(control), zoomDistance, accuracy: max(3, zoomDistance * 0.02))
        control.tap()
        expectFollowing()
        XCTAssertEqual(try settledMapDistance(control), zoomDistance, accuracy: max(3, zoomDistance * 0.02),
                       "Resume must use the actual gesture zoom, not reset a default distance")
        XCTAssertTrue(app.staticTexts["Unit 2137"].exists)
        capture("Heading-up Resume preserves the user's zoom")
        capture("Padded mini-route controls retain chosen zoom after Resume")
    }

    private func mapDistance(_ control: XCUIElement) throws -> Double {
        let value = try XCTUnwrap(control.value as? String)
        let expression = try NSRegularExpression(pattern: #"map distance ([0-9]+) meters"#)
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        let match = try XCTUnwrap(expression.firstMatch(in: value, range: range),
                                 "Unexpected camera accessibility value: \(value.debugDescription)")
        let numberRange = try XCTUnwrap(Range(match.range(at: 1), in: value))
        return try XCTUnwrap(Double(value[numberRange]))
    }

    private func settledMapDistance(_ control: XCUIElement) throws -> Double {
        var previous: Double?
        var stableSince: Date?
        let settled = NSPredicate { _, _ in
            guard let value = try? self.mapDistance(control) else { return false }
            if let prior = previous, abs(value - prior) <= 2 { stableSince = stableSince ?? Date() }
            else { stableSince = nil }
            previous = value
            return stableSince.map { Date().timeIntervalSince($0) >= 0.75 } ?? false
        }
        let expectation = XCTNSPredicateExpectation(predicate: settled, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 8), .completed,
                       "Wait for the actual MapKit zoom to settle before comparing it")
        return try mapDistance(control)
    }
}
