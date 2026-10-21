import XCTest

final class MapAppearanceTests: XCTestCase {
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
        print("MAP-APPEARANCE background drag map=\(mapFrame) visible=\(visibleMap) start=\(start) end=\(end), camera=\(initialCameraValue)")
        map.coordinate(withNormalizedOffset: startOffset)
            .press(forDuration: 0.2, thenDragTo: map.coordinate(withNormalizedOffset: endOffset),
                   withVelocity: .slow, thenHoldForDuration: 0.5)
        // MapKit can keep moving after XCTest reports the drag complete. Measure
        // the settled pan, not a transient frame before the style menu opens.
        waitForSettledPins([firstPin, secondPin])
        let originalTip = CGPoint(x: firstPin.frame.midX, y: firstPin.frame.maxY)
        let secondTip = CGPoint(x: secondPin.frame.midX, y: secondPin.frame.maxY)
        let originalMovement = abs(originalTip.x - initialX)
        var failedOriginalWitness = ""
        if originalMovement <= 5 {
            // Save the original result and witness before any diagnostic input.
            failedOriginalWitness = "Exercise a panned map before changing styles; before=\(initialFrame), after=\(firstPin.frame), initial camera=\(initialCameraValue), camera=\(String(describing: app.buttons["mini.recenter"].value))"
            if ProcessInfo.processInfo.environment["APARTMENTFINDER_PAN_INPUT_DIAGNOSTICS"] == "1" {
                print("MAP-PAN-INPUT originalMovement=\(originalMovement);\(failedOriginalWitness)")
                observeFailedPanInput(app: app, map: map, pins: [firstPin, secondPin],
                    mapFrame: mapFrame, visibleMap: visibleMap, start: startOffset, end: endOffset,
                    coverage: coverage, locationStatus: locationStatus)
            }
        }
        XCTAssertGreaterThan(originalMovement, 5, failedOriginalWitness)
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
        app.terminate()
        super.tearDown()
    }

    private func expectStyle(_ name: String, on control: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", name), object: control)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 5), .completed,
                       "The visible map type must update to \(name)", file: file, line: line)
    }

    /// Additional real input is diagnostic only: the saved original guard still fails.
    private func observeFailedPanInput(app: XCUIApplication, map: XCUIElement, pins: [XCUIElement],
                                      mapFrame: CGRect, visibleMap: CGRect, start: CGVector, end: CGVector,
                                      coverage: XCUIElement, locationStatus: XCUIElement) {
        func finite(_ frame: CGRect) -> Bool {
            !frame.isEmpty && [frame.minX, frame.minY, frame.maxX, frame.maxY].allSatisfy { $0.isFinite }
        }
        func cameraValue() -> String? {
            guard let raw = app.buttons["mini.recenter"].value as? String, raw.count <= 400 else { return nil }
            let number = #"-?[0-9]+(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?"#
            let pattern = #"\A(?:Showing apartment pins|Paused|Following), map heading -?[0-9]+ degrees, map distance [0-9]+ meters(?:, direction unavailable)?, map center "# + number + "," + number + #", camera revision [0-9]+\z"#
            return raw.range(of: pattern, options: .regularExpression) == nil ? nil : raw
        }
        func clearPath(to end: CGVector) -> Bool {
            let currentMap = map.frame, next = app.staticTexts["mini.next"], navigation = app.navigationBars.firstMatch
            guard next.exists, navigation.exists else { return false }
            let nextFrame = next.frame, navigationFrame = navigation.frame
            guard [currentMap, nextFrame, navigationFrame].allSatisfy(finite), currentMap == mapFrame else { return false }
            let top = max(currentMap.minY, navigationFrame.maxY)
            let bottom = min(currentMap.maxY, nextFrame.minY - 24)
            let currentVisible = CGRect(x: currentMap.minX, y: top, width: currentMap.width, height: bottom - top)
            guard currentVisible == visibleMap else { return false }
            let origin = CGPoint(x: mapFrame.minX + mapFrame.width * start.dx, y: mapFrame.minY + mapFrame.height * start.dy)
            let segment = CGRect(x: origin.x, y: origin.y - 1, width: mapFrame.width * (end.dx - start.dx), height: 2)
            let required = [app.buttons["mini.mapStyle"], app.buttons["Show all stops"], app.buttons["mini.recenter"], coverage, locationStatus]
            guard required.allSatisfy({ $0.exists }) else { return false }
            let requiredFrames = required.map { $0.frame }
            let buttonFrames = app.buttons.allElementsBoundByIndex.filter { $0.exists && $0.isHittable }.map { $0.frame }
            guard (requiredFrames + buttonFrames).allSatisfy(finite) else { return false }
            let clearance = (requiredFrames + buttonFrames).map { $0.insetBy(dx: -24, dy: -24) }
            return visibleMap.contains(segment) && mapFrame.contains(segment) && origin.x > mapFrame.minX + 44 &&
                !clearance.contains { $0.intersects(segment) } &&
                origin.y > coverage.frame.maxY + 24 && origin.y < locationStatus.frame.minY - 24
        }
        func perform(_ end: CGVector, phase: String) -> Double? {
            guard clearPath(to: end), pins[0].exists else {
                print("MAP-PAN-INPUT phase=\(phase);clearPath=false"); return nil
            }
            let before = pins[0].frame
            guard finite(before) else { print("MAP-PAN-INPUT phase=\(phase);firstPinFrame=false"); return nil }
            guard let cameraBefore = cameraValue() else { print("MAP-PAN-INPUT phase=\(phase);cameraBefore=false"); return nil }
            map.coordinate(withNormalizedOffset: start)
                .press(forDuration: 0.2, thenDragTo: map.coordinate(withNormalizedOffset: end),
                       withVelocity: .slow, thenHoldForDuration: 0.5)
            var previous: [CGRect] = [], previousPresence: [Bool] = [], stableSince: Date?
            let settled = NSPredicate { _, _ in
                let presence = pins.map { $0.exists }
                let frames = zip(pins, presence).compactMap { $0.1 ? $0.0.frame : nil }
                let unchanged = presence == previousPresence && frames.count == previous.count && zip(frames, previous).allSatisfy {
                    finite($0.0) && abs($0.0.midX - $0.1.midX) < 1 && abs($0.0.maxY - $0.1.maxY) < 1
                }
                stableSince = unchanged ? stableSince ?? Date() : nil
                previous = frames; previousPresence = presence
                return stableSince.map { Date().timeIntervalSince($0) >= 0.75 } ?? false
            }
            let result = XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: settled, object: nil)], timeout: 8)
            let presence = pins.map { $0.exists }
            let after = presence[0] ? pins[0].frame : CGRect.null
            let cameraAfter = cameraValue()
            let delta: Double? = finite(after) ? Double(max(abs(after.midX - before.midX), abs(after.maxY - before.maxY))) : nil
            let afterText = finite(after) ? String(describing: after) : "unavailable"
            print("MAP-PAN-INPUT phase=\(phase);start=\(start);end=\(end);settled=\(result.rawValue);pinPresence=\(presence);movement=\(String(describing: delta));before=\(before);after=\(afterText);cameraBefore=\(cameraBefore);cameraAfter=\(cameraAfter ?? "unavailable");paused=\(cameraAfter?.hasPrefix("Paused") == true)")
            // Do not issue more input with stale geometry after any observed change.
            return result == .completed && cameraAfter != nil && cameraBefore == cameraAfter ? delta : nil
        }
        // One unchanged replay tests repeatability before changing input length.
        guard let replayMovement = perform(end, phase: "sameInputReplay"), replayMovement <= 5 else { return }
        let longerEnd = [CGFloat(0.85), 0.80, 0.78, 0.75].first { x in
            (x - start.dx) >= 0.15 && clearPath(to: CGVector(dx: x, dy: start.dy))
        }
        guard let longerEnd else { print("MAP-PAN-INPUT phase=longerSameStart;clearPath=false"); return }
        _ = perform(CGVector(dx: longerEnd, dy: start.dy), phase: "longerSameStart")
    }

    private func waitForSettledPins(_ pins: [XCUIElement], file: StaticString = #filePath, line: UInt = #line) {
        var previous: [CGRect] = []
        var stableSince: Date?
        let diagnostic = ProcessInfo.processInfo.environment["APARTMENTFINDER_STYLE_DIAGNOSTICS"] == "1"
        let origin = ProcessInfo.processInfo.systemUptime
        var samples = 0
        let settled = NSPredicate { _, _ in
            let started = ProcessInfo.processInfo.systemUptime
            if diagnostic && samples < 16 { print("MAP-STYLE-QUERY begin=\(started - origin);sample=\(samples)") }
            let frames = pins.map { $0.frame }
            if diagnostic && samples < 16 {
                let ended = ProcessInfo.processInfo.systemUptime
                // The two existing frame reads only; no additional AX query.
                let values = frames.map { frame in
                    [frame.minX, frame.minY, frame.width, frame.height].map {
                        $0.isFinite && abs($0) < 10000 ? String(format: "%.3f", Double($0)) : "invalid"
                    }.joined(separator: ",")
                }.joined(separator: "|")
                print("MAP-STYLE-QUERY end=\(ended - origin);duration=\(ended - started);sample=\(samples);frames=\(values)")
                samples += 1
            }
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
        let originalResult = XCTWaiter.wait(for: [expectation], timeout: 8)
        if diagnostic { print("MAP-STYLE-SETTLE result=\(originalResult.rawValue);samples=\(samples)") }
        XCTAssertEqual(originalResult, .completed,
                       "Both map pins must stop moving before measuring style preservation", file: file, line: line)
    }

    private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
