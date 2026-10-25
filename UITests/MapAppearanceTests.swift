import XCTest

final class MapAppearanceTests: XCTestCase {
    private var syntheticApp: XCUIApplication?

    func testMapTypePersistsAcrossDoorReviewDeliveryAdvanceAndRelaunch() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting", "--test-store", UUID().uuidString,
                               "--reset-test-inbox", "--tuscano-manifest"]
        syntheticApp = app
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

        let initialPinFrames = waitForSettledPins([firstPin, secondPin], in: app)
        guard initialPinFrames.count == 2 else { return }
        let initialFrame = initialPinFrames[0]
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
        guard ([mapFrame, nextFrame, navigationFrame] + initialPinFrames).allSatisfy({ frame in
            !frame.isEmpty && [frame.minX, frame.minY, frame.maxX, frame.maxY].allSatisfy { $0.isFinite }
        }) else { XCTFail("Map, pin, navigation and stop-card frames must be finite and nonempty"); return }
        let top = max(mapFrame.minY, navigationFrame.maxY)
        let bottom = min(mapFrame.maxY, nextFrame.minY - 24)
        let visibleMap = CGRect(x: mapFrame.minX, y: top, width: mapFrame.width, height: bottom - top)
        guard visibleMap.height > 0 else { XCTFail("No visible map above the stop card"); return }
        let clearance = (app.buttons.allElementsBoundByIndex + [coverage, locationStatus])
            .filter { $0.exists && $0.isHittable }.map { $0.frame.insetBy(dx: -24, dy: -24) }
        let startX = mapFrame.minX + mapFrame.width * 0.50
        let pinEnvelope = initialPinFrames.reduce(CGRect.null) { $0.union($1) }
        let rightRoom = visibleMap.maxX - pinEnvelope.maxX - 24
        let leftRoom = pinEnvelope.minX - visibleMap.minX - 24
        let directions = [(direction: CGFloat(1), room: rightRoom),
                          (direction: CGFloat(-1), room: leftRoom)].sorted { $0.room > $1.room }
        let candidateY = [0.5, 0.35, 0.65].map { visibleMap.minY + visibleMap.height * $0 }
        var chosenPan: (y: CGFloat, dx: CGFloat)?
        for option in directions {
            // Reserve half the available pin room for MapKit's post-drag motion.
            let distance = min(mapFrame.width * 0.20, option.room * 0.5)
            guard distance > 5 else { continue }
            let dx = option.direction * distance
            let endX = startX + dx
            guard endX > mapFrame.minX + 44,
                  initialPinFrames.allSatisfy({
                      $0.minX + dx >= visibleMap.minX && $0.maxX + dx <= visibleMap.maxX
                  }) else { continue }
            if let y = candidateY.first(where: { y in
                let path = CGRect(x: min(startX, endX), y: y - 1, width: abs(dx), height: 2)
                return visibleMap.contains(path) && !clearance.contains { $0.intersects(path) } &&
                    y > coverage.frame.maxY + 24 && y < locationStatus.frame.minY - 24
            }) {
                chosenPan = (y, dx)
                break
            }
        }
        guard let pan = chosenPan else {
            mapAppearanceDiagnostics(app, stage: "no safe adaptive pan", pins: [firstPin, secondPin],
                context: "visible=\(visibleMap);initialPins=\(initialPinFrames);rightRoom=\(rightRoom);leftRoom=\(leftRoom)")
            XCTFail("No unobstructed style-test pan retaining both pin bounds inside visible map \(visibleMap)")
            return
        }
        let y = pan.y, endX = startX + pan.dx
        let startOffset = CGVector(dx: 0.50, dy: (y - mapFrame.minY) / mapFrame.height)
        let endOffset = CGVector(dx: (endX - mapFrame.minX) / mapFrame.width, dy: startOffset.dy)
        let start = CGPoint(x: startX, y: y), end = CGPoint(x: endX, y: y)
        let segment = CGRect(x: min(start.x, end.x), y: start.y - 1, width: abs(end.x - start.x), height: 2)
        XCTAssertGreaterThan(abs(end.x - start.x), 5, "The adaptive background drag must exercise a real pan")
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
        print("MAP-APPEARANCE background drag map=\(mapFrame) visible=\(visibleMap) start=\(start) end=\(end), initialPins=\(initialPinFrames), rightRoom=\(rightRoom), leftRoom=\(leftRoom), camera=\(initialCameraValue)")
        map.coordinate(withNormalizedOffset: startOffset)
            .press(forDuration: 0.2, thenDragTo: map.coordinate(withNormalizedOffset: endOffset),
                   withVelocity: .slow, thenHoldForDuration: 0.5)
        // MapKit can keep moving after XCTest reports the drag complete. Measure
        // the settled pan, not a transient frame before the style menu opens.
        let pannedPinFrames = waitForSettledPins([firstPin, secondPin], in: app, movingFrom: initialPinFrames)
        guard pannedPinFrames.count == 2 else { return }
        let originalTip = CGPoint(x: pannedPinFrames[0].midX, y: pannedPinFrames[0].maxY)
        let secondTip = CGPoint(x: pannedPinFrames[1].midX, y: pannedPinFrames[1].maxY)
        print("MAP-APPEARANCE settled pan before=\(initialPinFrames) after=\(pannedPinFrames), camera=\(String(describing: app.buttons["mini.recenter"].value))")
        XCTAssertGreaterThan(abs(originalTip.x - initialX), 5,
                             "Exercise a panned map before changing styles; before=\(initialFrame), after=\(firstPin.frame), initial camera=\(initialCameraValue), camera=\(String(describing: app.buttons["mini.recenter"].value))")
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
        guard let app = syntheticApp else { super.tearDown(); return }
        capture(app, "Map appearance final screen")
        if (testRun?.totalFailureCount ?? 0) > 0 {
            mapAppearanceDiagnostics(app, stage: "tearDown", pins: [
                app.buttons["mini.pin.2.tuscano-unit-county-2187653-2066"],
                app.buttons["mini.pin.3.tuscano-unit-county-2187691-2137"]
            ])
        }
        app.terminate()
        syntheticApp = nil
        super.tearDown()
    }

    private func expectStyle(_ name: String, on control: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", name), object: control)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 5), .completed,
                       "The visible map type must update to \(name)", file: file, line: line)
    }

    private func waitForSettledPins(_ pins: [XCUIElement], in app: XCUIApplication,
                                    movingFrom baseline: [CGRect]? = nil,
                                    file: StaticString = #filePath, line: UInt = #line) -> [CGRect] {
        var previous: [CGRect] = []
        var settledFrames: [CGRect] = []
        var stableSince: Date?
        let settled = NSPredicate { _, _ in
            var frames: [CGRect] = []
            for pin in pins {
                // A temporarily culled annotation is not a settled frame. Read
                // one guarded snapshot instead of querying frame on a missing pin.
                guard pin.exists, let snapshot = try? pin.snapshot() else {
                    previous = []; settledFrames = []; stableSince = nil
                    return false
                }
                let frame = snapshot.frame
                guard !frame.isEmpty,
                      [frame.minX, frame.minY, frame.maxX, frame.maxY].allSatisfy(\.isFinite) else {
                    previous = []; settledFrames = []; stableSince = nil
                    return false
                }
                frames.append(frame)
            }
            // Unchanged pre-gesture snapshots are not evidence of a settled pan.
            // Keep the existing movement threshold and the same total wait budget.
            if let baseline {
                guard frames.count == baseline.count, let first = frames.first,
                      let original = baseline.first, abs(first.midX - original.midX) > 5 else {
                    previous = []; settledFrames = frames; stableSince = nil
                    return false
                }
            }
            let unchanged = frames.count == previous.count && zip(frames, previous).allSatisfy { current, prior in
                abs(current.midX - prior.midX) < 1 && abs(current.maxY - prior.maxY) < 1
            }
            if unchanged {
                stableSince = stableSince ?? Date()
            } else {
                stableSince = nil
            }
            previous = frames
            settledFrames = frames
            return stableSince.map { Date().timeIntervalSince($0) >= 0.75 } ?? false
        }
        let expectation = XCTNSPredicateExpectation(predicate: settled, object: nil)
        let result = XCTWaiter.wait(for: [expectation], timeout: 8)
        if result != .completed {
            mapAppearanceDiagnostics(app, stage: "pins did not settle", pins: pins,
                                     context: "lastFiniteFrames=\(settledFrames)")
        }
        XCTAssertEqual(result, .completed,
                       "Both map pins must stop moving before measuring style preservation", file: file, line: line)
        return result == .completed ? settledFrames : []
    }

    private func mapAppearanceDiagnostics(_ app: XCUIApplication, stage: String, pins: [XCUIElement],
                                         context: String = "") {
        guard app.launchArguments.contains("--uitesting"),
              app.launchArguments.contains("--test-store") else { return }
        let pinState = pins.map { pin -> String in
            guard pin.exists, let snapshot = try? pin.snapshot() else { return "pin missing or unavailable snapshot" }
            return "id=\(snapshot.identifier);frame=\(snapshot.frame);hittable=\(pin.exists && pin.isHittable)"
        }.joined(separator: "\n")
        let camera = app.buttons["mini.recenter"]
        let cameraValue = camera.exists ? String(describing: camera.value) : "control missing"
        let diagnostics = String("""
        stage=\(stage);\(context)
        camera=\(cameraValue)
        pins:
        \(pinState)
        \(app.debugDescription)
        """.prefix(32_768))
        print("MAP-APPEARANCE-DIAGNOSTIC \(diagnostics)")
        let attachment = XCTAttachment(string: diagnostics)
        attachment.name = "Map appearance accessibility"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
