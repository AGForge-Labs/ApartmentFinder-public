import XCTest

/// Public community references and invented deliveries. No owner store or actual route is loaded.
final class CommunityMapControlsTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        app = XCUIApplication()
    }

    override func tearDown() {
        capture("Community map controls final screen")
        app.terminate()
        super.tearDown()
    }

    private func openRoute(_ id: String, fixture: String) {
        app.launchArguments = ["--uitesting", "--test-store", UUID().uuidString,
            "--reset-test-inbox", fixture, "--synthetic-map-location", "--synthetic-map-direction"]
        app.launch()
        XCTAssertTrue(app.buttons["test.mixed"].waitForExistence(timeout: 25))
        app.buttons["test.mixed"].tap()
        XCTAssertTrue(app.buttons["manifest.import"].waitForExistence(timeout: 10))
        app.buttons["manifest.import"].tap()
        XCTAssertTrue(app.buttons["apartment.\(id)"].waitForExistence(timeout: 10))
        app.buttons["apartment.\(id)"].tap()
        app.buttons["mini.start"].tap()
        XCTAssertTrue(app.maps.firstMatch.waitForExistence(timeout: 8))
        XCTAssertTrue(app.buttons["mini.recenter"].waitForExistence(timeout: 5))
    }

    func testPausedControlsStayCompactAndKeepTheirActions() {
        openRoute("tuscano", fixture: "--tuscano-manifest")
        assertCompactControls()
        app.buttons["Show all stops"].tap()
        XCTAssertEqual(app.buttons["mini.recenter"].label, "Resume following")
        assertCompactControls()
        capture("Paused controls leave the map clear")
        app.buttons["mini.mapStyle"].tap()
        XCTAssertTrue(app.buttons["Map"].waitForExistence(timeout: 5))
        app.buttons["Map"].tap()
        let selectedMap = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "Map"),
                                                     object: app.buttons["mini.mapStyle"])
        XCTAssertEqual(XCTWaiter.wait(for: [selectedMap], timeout: 5), .completed,
                       "The visible map type must update to Map after its action")
        XCTAssertEqual(app.buttons["mini.mapStyle"].value as? String, "Map")
        assertCompactControls()
        app.buttons["mini.focus.3"].tap()
        XCTAssertTrue(app.staticTexts["Unit 2137"].exists)
        app.buttons["mini.recenter"].tap()
        XCTAssertTrue(app.staticTexts["Unit 2137"].exists)
        XCTAssertNotEqual(app.buttons["mini.recenter"].label, "Resume following")
        assertCompactControls()
        capture("Following controls remain compact after map-style and stop changes")
    }

    func testLyricAndTrendShowTheirCommunityAreasWithoutInventingDoors() {
        for (id, latitude, longitude) in [
            ("lyric", 36.01408, -115.159018),
            ("trend", 36.01422151644452, -115.16156023077903)
        ] {
            openRoute(id, fixture: "--community-area-manifest")
            assertCenter(latitude: latitude, longitude: longitude)
            XCTAssertFalse(app.staticTexts["Community location not mapped"].exists)
            XCTAssertTrue(app.staticTexts["mini.communityLocation"].label.contains("Community area"))
            XCTAssertTrue(app.staticTexts["mini.coverage"].label.contains("2 doors not mapped"))
            XCTAssertEqual(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "mini.pin.")).count, 0)
            XCTAssertEqual(app.buttons["mini.prepare"].label, "Add door pin on map")
            if id == "lyric" {
                XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Operator map building 15")).firstMatch.exists)
                app.buttons["mini.focus.2"].tap()
                XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Operator map building 13")).firstMatch.exists)
                XCTAssertTrue(app.staticTexts["mini.associationWithoutPoint"].label.contains("Building and door locations"))
            }
            capture("\(id) official community center, no invented door pins")
            app.buttons["Show all stops"].tap()
            assertCenter(latitude: latitude, longitude: longitude)
            assertCompactControls()
            app.terminate()
        }
    }

    private func assertCompactControls(file: StaticString = #filePath, line: UInt = #line) {
        let controls = [app.buttons["mini.mapStyle"], app.buttons["Show all stops"], app.buttons["mini.recenter"]]
        var union = CGRect.null
        for control in controls {
            XCTAssertTrue(control.exists && control.isHittable, file: file, line: line)
            let frame = control.frame
            XCTAssertTrue([frame.minX, frame.minY, frame.width, frame.height].allSatisfy(\.isFinite), file: file, line: line)
            XCTAssertGreaterThanOrEqual(frame.width, 44, file: file, line: line)
            XCTAssertGreaterThanOrEqual(frame.height, 44, file: file, line: line)
            XCTAssertLessThanOrEqual(frame.width, 48, "Visible map controls must not expand with the paused label: \(frame)", file: file, line: line)
            XCTAssertLessThanOrEqual(frame.height, 48, file: file, line: line)
            union = union.union(frame)
        }
        XCTAssertLessThanOrEqual(union.width, 56, "The floating controls must remain a narrow column", file: file, line: line)
        XCTAssertLessThanOrEqual(union.height, 172, file: file, line: line)
        print("COMMUNITY-MAP-CONTROLS bounds=\(union), buttonFrames=\(controls.map(\.frame))")
    }

    private func assertCenter(latitude: Double, longitude: Double, file: StaticString = #filePath, line: UInt = #line) {
        let control = app.buttons["mini.recenter"]
        let centered = NSPredicate { _, _ in
            guard let value = control.value as? String,
                  let area = value.components(separatedBy: ", map center ").dropFirst().first else { return false }
            let fields = area.components(separatedBy: ", camera revision ")[0].split(separator: ",")
            guard fields.count == 2, let lat = Double(fields[0]), let lon = Double(fields[1]) else { return false }
            return abs(lat - latitude) < 0.0003 && abs(lon - longitude) < 0.0003
        }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: centered, object: nil)], timeout: 10), .completed,
            "The map must frame the official community area instead of a distant synthetic driver: \(String(describing: control.value))", file: file, line: line)
        print("COMMUNITY-MAP-CENTER expected=\(latitude),\(longitude), camera=\(String(describing: control.value))")
    }

    private func capture(_ name: String) {
        guard app != nil, app.state == .runningForeground else { return }
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
}
