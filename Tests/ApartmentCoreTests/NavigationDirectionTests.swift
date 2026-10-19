import XCTest
@testable import ApartmentCore

final class NavigationDirectionTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 10_000)

    func testReliableWalkingCourseWinsOverPhoneCompass() {
        var state = NavigationDirectionState()
        state.receiveCompass(degrees: 90, accuracy: 5, timestamp: now, at: now)
        state.receiveCourse(degrees: 270, accuracy: 8, speed: 1.2, speedAccuracy: 0.1, positionAccuracy: 5,
                            timestamp: now.addingTimeInterval(2), at: now.addingTimeInterval(2))
        XCTAssertEqual(state.direction?.source, .course)
        XCTAssertEqual(state.direction?.degrees ?? -1, 270, accuracy: 0.01)
    }

    func testSlowWalkingUsesReliableCompassInsteadOfGPSCourseNoise() {
        var state = NavigationDirectionState()
        state.receiveCompass(degrees: 120, accuracy: 6, timestamp: now, at: now)
        state.receiveCourse(degrees: 300, accuracy: 8, speed: 0.2, speedAccuracy: 0.1, positionAccuracy: 5,
                            timestamp: now, at: now)
        XCTAssertEqual(state.direction?.source, .compass)
        XCTAssertEqual(state.direction?.degrees, 120)
    }

    func testUnreliableOrUnknownCourseCannotProduceAnArrow() {
        for sample in [(Double.nan, 5.0, 1.0, 5.0), (-1, 5, 1, 5),
                       (90, -1, 1, 5), (90, 70, 1, 5), (90, 5, -1, 5),
                       (90, 5, 0.1, 5), (90, 5, 1, 100), (90, 5, 1, -1)] {
            var state = NavigationDirectionState()
            state.receiveCourse(degrees: sample.0, accuracy: sample.1, speed: sample.2, speedAccuracy: 0.1,
                                positionAccuracy: sample.3, timestamp: now, at: now)
            XCTAssertNil(state.direction)
        }
    }

    func testPoorCompassReadingDoesNotRotateTheMap() {
        var state = NavigationDirectionState()
        state.receiveCompass(degrees: 45, accuracy: 5, timestamp: now, at: now)
        for accuracy in [-1.0, 90.0, .nan] {
            state.receiveCompass(degrees: 225, accuracy: accuracy,
                                 timestamp: now.addingTimeInterval(1), at: now.addingTimeInterval(1))
            XCTAssertEqual(state.direction?.degrees, 45)
        }
    }

    func testCompassJitterWhileStoppedKeepsTheSameDirection() {
        var state = NavigationDirectionState()
        state.receiveCompass(degrees: 90, accuracy: 5, timestamp: now, at: now)
        for (index, heading) in [91.0, 89, 92, 88, 91].enumerated() {
            let time = now.addingTimeInterval(Double(index + 1) / 5)
            state.receiveCompass(degrees: heading, accuracy: 5, timestamp: time, at: time)
            XCTAssertEqual(state.direction?.degrees, 90)
        }
    }

    func testNorthCrossingTakesTheShortTurn() {
        var state = NavigationDirectionState()
        state.receiveCompass(degrees: 358, accuracy: 5, timestamp: now, at: now)
        state.receiveCompass(degrees: 8, accuracy: 5,
                             timestamp: now.addingTimeInterval(0.5), at: now.addingTimeInterval(0.5))
        let angle = state.direction?.degrees ?? 180
        XCTAssertTrue(angle > 358 || angle < 8, "Turn across north, not halfway around the map")
    }

    func testOneCompassReversalIsRejectedButConfirmedTurnCanAdvance() {
        var state = NavigationDirectionState()
        state.receiveCompass(degrees: 0, accuracy: 5, timestamp: now, at: now)
        state.receiveCompass(degrees: 170, accuracy: 5,
                             timestamp: now.addingTimeInterval(0.2), at: now.addingTimeInterval(0.2))
        XCTAssertEqual(state.direction?.degrees, 0)
        state.receiveCompass(degrees: 168, accuracy: 5,
                             timestamp: now.addingTimeInterval(0.4), at: now.addingTimeInterval(0.4))
        XCTAssertGreaterThan(state.direction?.degrees ?? 0, 0)
        XCTAssertLessThanOrEqual(state.direction?.degrees ?? 180, 36)
    }

    func testStaleAndFutureSamplesAreRejectedAndDirectionExpires() {
        var state = NavigationDirectionState()
        state.receiveCompass(degrees: 90, accuracy: 5, timestamp: now.addingTimeInterval(-60), at: now)
        state.receiveCompass(degrees: 90, accuracy: 5, timestamp: now.addingTimeInterval(30), at: now)
        XCTAssertNil(state.direction)
        state.receiveCompass(degrees: 90, accuracy: 5, timestamp: now, at: now)
        state.tick(at: now.addingTimeInterval(6))
        XCTAssertNil(state.direction, "An old bearing must not look like a current direction")
    }

    func testOutOfOrderSamplesCannotReplaceNewerDirection() {
        var state = NavigationDirectionState()
        state.receiveCompass(degrees: 90, accuracy: 5, timestamp: now, at: now)
        state.receiveCompass(degrees: 270, accuracy: 5, timestamp: now.addingTimeInterval(-1), at: now)
        XCTAssertEqual(state.direction?.degrees, 90)
    }

    func testStoppingFallsBackToCompassWithoutResurrectingOldCourse() {
        var state = NavigationDirectionState()
        state.receiveCourse(degrees: 270, accuracy: 5, speed: 1.2, speedAccuracy: 0.1, positionAccuracy: 5, timestamp: now, at: now)
        state.receiveCompass(degrees: 280, accuracy: 5,
                             timestamp: now.addingTimeInterval(0.5), at: now.addingTimeInterval(0.5))
        state.receiveCourse(degrees: 90, accuracy: 5, speed: 0, speedAccuracy: 0.1,
                            positionAccuracy: 5, timestamp: now.addingTimeInterval(1), at: now.addingTimeInterval(1))
        XCTAssertEqual(state.direction?.source, .compass)
        XCTAssertGreaterThan(state.direction?.degrees ?? 0, 270)
    }

    func testResetRemovesAllPriorDirectionAfterLocationStops() {
        var state = NavigationDirectionState()
        state.receiveCompass(degrees: 90, accuracy: 5, timestamp: now, at: now)
        state.reset()
        state.tick(at: now.addingTimeInterval(1))
        XCTAssertNil(state.direction)
    }

    func testUncertainSpeedCannotReplaceReliableCompass() {
        for uncertainty in [-1.0, 1.5, .nan] {
            var state = NavigationDirectionState()
            state.receiveCompass(degrees: 90, accuracy: 5, timestamp: now, at: now)
            state.receiveCourse(degrees: 270, accuracy: 5, speed: 0.8, speedAccuracy: uncertainty,
                                positionAccuracy: 5, timestamp: now.addingTimeInterval(1), at: now.addingTimeInterval(1))
            XCTAssertEqual(state.direction?.source, .compass)
            XCTAssertEqual(state.direction?.degrees, 90)
        }
    }

    func testMovingToStoppedWithoutCompassRemovesCurrentCourseArrow() {
        var state = NavigationDirectionState()
        state.receiveCourse(degrees: 270, accuracy: 5, speed: 1.2, speedAccuracy: 0.1,
                            positionAccuracy: 5, timestamp: now, at: now)
        XCTAssertNotNil(state.direction)
        state.receiveCourse(degrees: 270, accuracy: 5, speed: 0, speedAccuracy: 0.1,
                            positionAccuracy: 5, timestamp: now.addingTimeInterval(1), at: now.addingTimeInterval(1))
        XCTAssertNil(state.direction)
    }

    func testCourseArrowExpiresAtItsOwnFreshnessDeadline() {
        var state = NavigationDirectionState()
        state.receiveCourse(degrees: 270, accuracy: 5, speed: 1.2, speedAccuracy: 0.1,
                            positionAccuracy: 5, timestamp: now, at: now)
        state.tick(at: now.addingTimeInterval(3.1))
        XCTAssertNil(state.direction)
    }

    func testArrowIsRelativeToActualMapRotation() {
        XCTAssertEqual(NavigationDirection.relativeAngle(heading: 270, mapHeading: 270), 0)
        XCTAssertEqual(NavigationDirection.relativeAngle(heading: 270, mapHeading: 0), -90)
        XCTAssertEqual(NavigationDirection.relativeAngle(heading: 2, mapHeading: 358), 4)
    }
}

final class MiniRouteMapFollowingTests: XCTestCase {
    func testMiniRouteStartsFollowingAndUserPanPausesUntilExplicitResume() {
        var state = MiniRouteMapFollowingState()
        XCTAssertTrue(state.isFollowing)
        state.userMoved(distance: 640)
        XCTAssertFalse(state.isFollowing)
        XCTAssertEqual(state.mode, .manual)
        XCTAssertEqual(state.distance, 640)
        state.resume()
        XCTAssertTrue(state.isFollowing)
        XCTAssertEqual(state.distance, 640, "Recenter must preserve the user's chosen zoom")
    }

    func testShowAllStopsPausesFollowingWithoutAutomaticResume() {
        var state = MiniRouteMapFollowingState()
        state.showOverview()
        XCTAssertFalse(state.isFollowing)
        XCTAssertEqual(state.mode, .overview)
        state.resume()
        XCTAssertTrue(state.isFollowing)
    }

    func testInvalidCameraDistanceCannotSpoilResumeZoom() {
        var state = MiniRouteMapFollowingState()
        state.userMoved(distance: .nan)
        XCTAssertTrue(state.distance.isFinite)
        XCTAssertGreaterThan(state.distance, 0)
        state.resume()
        XCTAssertTrue(state.isFollowing)
    }
}
