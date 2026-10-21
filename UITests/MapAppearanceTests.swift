import XCTest

final class MapAppearanceTests: XCTestCase {
    private struct PanFailureWitness {
        let map: CGRect
        let visibleMap: CGRect
        let start: CGPoint
        let end: CGPoint
        let pinFrames: [CGRect]
        let obstacleFrames: [CGRect]
        let camera: [Double]
    }
    private var panFailureWitness: PanFailureWitness?

    func testMapTypePersistsAcrossDoorReviewDeliveryAdvanceAndRelaunch() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting", "--test-store", UUID().uuidString,
                               "--reset-test-inbox", "--tuscano-manifest"]
        app.launch()
        XCTAssertTrue(app.buttons["test.mixed"].waitForExistence(timeout: 20))
        app.buttons["test.mixed"].tap()
        XCTAssertTrue(app.buttons["manifest.import"].waitForExistence(timeout: 10))
        app.buttons["manifest.import"].tap()
        app.buttons["apartment.tuscano"].tap()
        app.buttons["mini.start"].tap()

        let style = app.buttons["mini.mapStyle"]
        XCTAssertTrue(style.waitForExistence(timeout: 5), "The delivery map needs a map-type control")
        expectStyle("Satellite", on: style)
        let firstPin = app.buttons["mini.pin.2.tuscano-unit-county-2187653-2066"]
        let secondPin = app.buttons["mini.pin.3.tuscano-unit-county-2187691-2137"]
        XCTAssertTrue(firstPin.waitForExistence(timeout: 5))
        XCTAssertTrue(secondPin.exists)
        capture(app, "Compact pointed pins on the satellite map")

        waitForSettledPins([firstPin, secondPin])
        let initialFrame = firstPin.frame
        let initialSecondFrame = secondPin.frame
        let initialX = initialFrame.midX
        let map = app.maps.firstMatch
        let mapFrame = map.frame
        XCTAssertFalse(mapFrame.isEmpty, "The map must have usable bounds")
        let coverage = app.staticTexts["mini.coverage"]
        let locationStatus = app.staticTexts["mini.locationStatus"]
        let blocked = [firstPin, secondPin, style, app.buttons["Show all stops"],
                       app.buttons["mini.recenter"], coverage, locationStatus]
        let next = app.staticTexts["mini.next"]
        let navigation = app.navigationBars.firstMatch
        XCTAssertTrue(next.exists)
        XCTAssertTrue(navigation.exists)
        let nextFrame = next.frame, navigationFrame = navigation.frame
        guard [mapFrame, initialFrame, nextFrame, navigationFrame].allSatisfy({ frame in
            !frame.isEmpty && [frame.minX, frame.minY, frame.maxX, frame.maxY].allSatisfy { $0.isFinite }
        }) else { XCTFail("Map, pin, navigation and stop-card frames must be finite and nonempty"); return }
        let top = max(mapFrame.minY, navigationFrame.maxY)
        let bottom = min(mapFrame.maxY, nextFrame.minY - 24)
        let visibleMap = CGRect(x: mapFrame.minX, y: top, width: mapFrame.width, height: bottom - top)
        guard visibleMap.height > 0 else { XCTFail("No visible map above the stop card"); return }
        let clearance = (app.buttons.allElementsBoundByIndex + [coverage, locationStatus])
            .filter { $0.exists && $0.isHittable }.map { $0.frame.insetBy(dx: -24, dy: -24) }
        let startX = mapFrame.minX + mapFrame.width * 0.60
        let endX = mapFrame.minX + mapFrame.width * 0.70
        let candidateY = [0.5, 0.35, 0.65].map { visibleMap.minY + visibleMap.height * $0 }
        guard let y = candidateY.first(where: { y in
            let path = CGRect(x: startX, y: y - 1, width: endX - startX, height: 2)
            return visibleMap.contains(path) && !clearance.contains { $0.intersects(path) } &&
                y > coverage.frame.maxY + 24 && y < locationStatus.frame.minY - 24
        }) else { XCTFail("No unobstructed style-test pan inside visible map \(visibleMap)"); return }
        let startOffset = CGVector(dx: 0.60, dy: (y - mapFrame.minY) / mapFrame.height)
        let endOffset = CGVector(dx: 0.70, dy: startOffset.dy)
        let start = CGPoint(x: startX, y: y), end = CGPoint(x: endX, y: y)
        let segment = CGRect(x: start.x, y: start.y - 1, width: end.x - start.x, height: 2)
        XCTAssertTrue(visibleMap.contains(segment), "The entire drag must stay above the stop card")
        XCTAssertTrue(mapFrame.contains(segment), "The entire drag must stay inside the map bounds")
        XCTAssertGreaterThan(start.x, mapFrame.minX + 44, "Avoid the navigation back-swipe edge")
        for element in blocked {
            XCTAssertTrue(element.exists, "A map annotation or overlay needed for clearance is missing")
            let frame = element.frame
            XCTAssertFalse(frame.isEmpty, "A map annotation or overlay has no usable bounds")
            XCTAssertFalse(segment.intersects(frame.insetBy(dx: -24, dy: -24)),
                           "The entire drag must stay on clear map background: \(frame)")
        }
        XCTAssertGreaterThan(start.y, coverage.frame.maxY + 24, "Stay below the map's top overlay")
        XCTAssertLessThan(start.y, locationStatus.frame.minY - 24, "Stay above the map's bottom overlay")
        let initialCameraValue = String(describing: app.buttons["mini.recenter"].value)
        let originalObstacleFrames = blocked.map { $0.frame } + [nextFrame, navigationFrame]
        print("MAP-APPEARANCE background drag map=\(mapFrame) visible=\(visibleMap) start=\(start) end=\(end), camera=\(initialCameraValue)")
        map.coordinate(withNormalizedOffset: startOffset)
            .press(forDuration: 0.2, thenDragTo: map.coordinate(withNormalizedOffset: endOffset),
                   withVelocity: .slow, thenHoldForDuration: 0.5)
        // MapKit can keep moving after XCTest reports the drag complete. Measure
        // the settled pan, not a transient frame before the style menu opens.
        waitForSettledPins([firstPin, secondPin])
        let originalTip = CGPoint(x: firstPin.frame.midX, y: firstPin.frame.maxY)
        let secondTip = CGPoint(x: secondPin.frame.midX, y: secondPin.frame.maxY)
        let originalAfterFrame = firstPin.frame
        let originalAfterCamera = String(describing: app.buttons["mini.recenter"].value)
        if abs(originalTip.x - initialX) <= 5, let camera = cameraSignature(initialCameraValue) {
            panFailureWitness = PanFailureWitness(map: mapFrame, visibleMap: visibleMap, start: start, end: end,
                pinFrames: [initialFrame, initialSecondFrame], obstacleFrames: originalObstacleFrames, camera: camera)
        }
        XCTAssertGreaterThan(abs(originalTip.x - initialX), 5,
                             "Exercise a panned map before changing styles; before=\(initialFrame), after=\(originalAfterFrame), initial camera=\(initialCameraValue), camera=\(originalAfterCamera)")
        capture(app, "Settled panned map before changing style")
        XCTAssertTrue(style.isHittable)
        style.tap()
        capture(app, "Map and Satellite choices from the layers button")
        app.buttons["Map"].tap()
        expectStyle("Map", on: style)
        XCTAssertEqual(app.staticTexts["mini.next"].label, "Next · Stop 2")
        XCTAssertEqual(firstPin.frame.midX, originalTip.x, accuracy: 3)
        XCTAssertEqual(firstPin.frame.maxY, originalTip.y, accuracy: 3,
                       "Changing map type must keep the pin on the same map position")
        XCTAssertEqual(secondPin.frame.midX, secondTip.x, accuracy: 3)
        XCTAssertEqual(secondPin.frame.maxY, secondTip.y, accuracy: 3)
        capture(app, "Compact pointed pins on the standard map")

        app.buttons["mini.prepare"].tap()
        XCTAssertTrue(app.buttons["door.confirm"].waitForExistence(timeout: 5))
        let doorStyle = app.buttons["door.mapStyle"]
        expectStyle("Map", on: doorStyle)
        XCTAssertTrue(doorStyle.isHittable)
        doorStyle.tap()
        app.buttons["Satellite"].tap()
        expectStyle("Satellite", on: doorStyle)
        app.buttons["Cancel"].tap()
        expectStyle("Satellite", on: style)
        style.tap()
        app.buttons["Map"].tap()

        firstPin.tap()
        XCTAssertTrue(app.staticTexts["Unit 2066"].exists)
        app.buttons["mini.delivered"].tap()
        XCTAssertEqual(app.staticTexts["mini.next"].label, "Next · Stop 3")
        expectStyle("Map", on: style)
        capture(app, "Standard map retains progress and the completed pin")
        app.terminate()
        app.launchArguments.removeAll { $0 == "--reset-test-inbox" }
        app.launch()
        app.buttons["apartment.tuscano"].tap()
        app.buttons["mini.start"].tap()
        XCTAssertTrue(style.waitForExistence(timeout: 5))
        expectStyle("Map", on: style)
        XCTAssertEqual(app.staticTexts["mini.next"].label, "Next · Stop 3")
        XCTAssertTrue(firstPin.exists)
        XCTAssertTrue(secondPin.exists)
        capture(app, "Standard map preference and delivery progress survive relaunch")
    }

    override func tearDown() {
        let app = XCUIApplication()
        capture(app, "Map appearance final screen")
        if (testRun?.totalFailureCount ?? 0) > 0 {
            let hierarchy = XCTAttachment(string: app.debugDescription)
            hierarchy.name = "Map appearance accessibility"
            hierarchy.lifetime = .keepAlways
            add(hierarchy)
        }
        if let witness = panFailureWitness { diagnosePanFailure(app, witness: witness) }
        app.terminate()
        super.tearDown()
    }

    private func cameraSignature(_ value: String) -> [Double]? {
        let patterns = [#"map center (-?[0-9.]+),(-?[0-9.]+)"#, #"map distance ([0-9]+) meters"#, #"map heading ([0-9]+) degrees"#]
        var values: [Double] = []
        for pattern in patterns {
            guard let expression = try? NSRegularExpression(pattern: pattern),
                  let match = expression.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) else { return nil }
            for index in 1..<match.numberOfRanges {
                guard let range = Range(match.range(at: index), in: value), let number = Double(value[range]), number.isFinite else { return nil }
                values.append(number)
            }
        }
        return values.count == 4 ? values : nil
    }

    /// Runs only after the original assertion has failed and its screen is captured.
    /// These launches never replace its cached result or execute another gesture path.
    private func diagnosePanFailure(_ app: XCUIApplication, witness: PanFailureWitness) {
        let environment = ProcessInfo.processInfo.environment
        guard let nonce = environment["APARTMENTFINDER_MAP_PAN_RUN_NONCE"] ?? environment["TEST_RUNNER_APARTMENTFINDER_MAP_PAN_RUN_NONCE"],
              UUID(uuidString: nonce) != nil,
              let path = try? JSONEncoder().encode([[Double(witness.start.x), Double(witness.start.y)],
                                                    [Double(witness.end.x), Double(witness.end.y)]]),
              let pathValue = String(data: path, encoding: .utf8) else { return }
        for mode in ["interactive", "disabled"] {
            app.terminate()
            app.launchArguments = ["--uitesting", "--test-store", UUID().uuidString,
                "--reset-test-inbox", "--tuscano-manifest", "--synthetic-map-pan-diagnostics"]
            if mode == "disabled" { app.launchArguments.append("--synthetic-map-pan-disable-pin-hits") }
            app.launchEnvironment["APARTMENTFINDER_MAP_PAN_RUN_NONCE"] = nonce
            app.launchEnvironment["APARTMENTFINDER_MAP_PAN_PATH"] = pathValue
            app.launch()
            guard app.buttons["test.mixed"].waitForExistence(timeout: 20) else { print("MAP-PAN phase=\(mode), incomplete=mixed"); continue }
            app.buttons["test.mixed"].tap()
            guard app.buttons["manifest.import"].waitForExistence(timeout: 10) else { print("MAP-PAN phase=\(mode), incomplete=import"); continue }
            app.buttons["manifest.import"].tap()
            guard app.buttons["apartment.tuscano"].waitForExistence(timeout: 10) else { print("MAP-PAN phase=\(mode), incomplete=apartment"); continue }
            app.buttons["apartment.tuscano"].tap()
            guard app.buttons["mini.start"].waitForExistence(timeout: 5) else { print("MAP-PAN phase=\(mode), incomplete=start"); continue }
            app.buttons["mini.start"].tap()
            let map = app.maps.firstMatch, style = app.buttons["mini.mapStyle"]
            let first = app.buttons["mini.pin.2.tuscano-unit-county-2187653-2066"]
            let second = app.buttons["mini.pin.3.tuscano-unit-county-2187691-2137"]
            guard style.waitForExistence(timeout: 5), first.waitForExistence(timeout: 5), second.exists,
                  diagnosticSettle([first, second]) else { print("MAP-PAN phase=\(mode), incomplete=pins"); continue }
            let frame = map.frame, before = first.frame
            let obstacles = [first, second, style, app.buttons["Show all stops"], app.buttons["mini.recenter"],
                app.staticTexts["mini.coverage"], app.staticTexts["mini.locationStatus"],
                app.staticTexts["mini.next"], app.navigationBars.firstMatch].map { $0.frame }
            let pinFrames = [before, second.frame]
            let camera = cameraSignature(String(describing: app.buttons["mini.recenter"].value))
            func same(_ a: CGRect, _ b: CGRect) -> Bool {
                !a.isEmpty && !b.isEmpty && zip([a.minX, a.minY, a.width, a.height], [b.minX, b.minY, b.width, b.height])
                    .allSatisfy { $0.isFinite && $1.isFinite && abs($0 - $1) <= 1 }
            }
            let matched = same(frame, witness.map) && obstacles.count == witness.obstacleFrames.count &&
                zip(obstacles, witness.obstacleFrames).allSatisfy { same($0, $1) } &&
                zip(pinFrames, witness.pinFrames).allSatisfy { same($0, $1) } && style.value as? String == "Satellite" &&
                camera.map { values in zip(zip(values, witness.camera), [0.00001, 0.00001, 5, 1]).allSatisfy { abs($0.0 - $0.1) <= $1 } } == true
            print("MAP-PAN phase=\(mode), matchedOriginalSetup=\(matched), map=\(frame), pinBefore=\(before), camera=\(camera ?? [])")
            guard matched else { print("MAP-PAN phase=\(mode), incomplete=setupMismatch"); continue }
            let start = CGVector(dx: (witness.start.x - frame.minX) / frame.width, dy: (witness.start.y - frame.minY) / frame.height)
            let end = CGVector(dx: (witness.end.x - frame.minX) / frame.width, dy: (witness.end.y - frame.minY) / frame.height)
            map.coordinate(withNormalizedOffset: start)
                .press(forDuration: 0.2, thenDragTo: map.coordinate(withNormalizedOffset: end),
                       withVelocity: .slow, thenHoldForDuration: 0.5)
            let settled = diagnosticSettle([first, second])
            let after = first.frame
            print("MAP-PAN phase=\(mode), settled=\(settled), pinAfter=\(after), deltaX=\(abs(after.midX - before.midX)), camera=\(cameraSignature(String(describing: app.buttons["mini.recenter"].value)) ?? [])")
            capture(app, "Failure-only pan comparison \(mode)")
        }
    }

    private func diagnosticSettle(_ pins: [XCUIElement]) -> Bool {
        var previous: [CGRect] = [], stableSince: Date?
        let predicate = NSPredicate { _, _ in
            let frames = pins.map { $0.frame }
            if frames.count == previous.count && zip(frames, previous).allSatisfy({ a, b in
                !a.isEmpty && abs(a.midX - b.midX) < 1 && abs(a.maxY - b.maxY) < 1
            }) { stableSince = stableSince ?? Date() } else { stableSince = nil }
            previous = frames
            return stableSince.map { Date().timeIntervalSince($0) >= 0.75 } ?? false
        }
        return XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: nil)], timeout: 8) == .completed
    }

    private func expectStyle(_ name: String, on control: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", name), object: control)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 5), .completed,
                       "The visible map type must update to \(name)", file: file, line: line)
    }

    private func waitForSettledPins(_ pins: [XCUIElement], file: StaticString = #filePath, line: UInt = #line) {
        var previous: [CGRect] = []
        var stableSince: Date?
        let settled = NSPredicate { _, _ in
            let frames = pins.map { $0.frame }
            let unchanged = frames.count == previous.count && zip(frames, previous).allSatisfy { current, prior in
                !current.isEmpty && abs(current.midX - prior.midX) < 1 && abs(current.maxY - prior.maxY) < 1
            }
            if unchanged {
                stableSince = stableSince ?? Date()
            } else {
                stableSince = nil
            }
            previous = frames
            return stableSince.map { Date().timeIntervalSince($0) >= 0.75 } ?? false
        }
        let expectation = XCTNSPredicateExpectation(predicate: settled, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 8), .completed,
                       "Both map pins must stop moving before measuring style preservation", file: file, line: line)
    }

    private func capture(_ app: XCUIApplication, _ name: String) {
        guard app.state == .runningForeground else { return }
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
