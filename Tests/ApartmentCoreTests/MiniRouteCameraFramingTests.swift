import XCTest
@testable import ApartmentCore

final class MiniRouteCameraFramingTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000)
    private let user = Coordinate(latitude: 36.07,longitude: -115.28)
    private var pins: [Coordinate] { [Coordinate(latitude:36.071,longitude:-115.281),Coordinate(latitude:36.069,longitude:-115.279)] }
    private func fix(_ point: Coordinate, accuracy: Double = 5, age: Double = 0) -> LocationFix {
        LocationFix(coordinate:point,accuracy:accuracy,timestamp:now.addingTimeInterval(-age))
    }
    func testNearbyInitialFrameIncludesUserAndPinsBeyondOld350MeterZoomWithControlPadding() throws {
        let frame=try XCTUnwrap(MiniRouteCameraFraming.frame(pins:pins,fix:fix(user),at:now,width:390,height:500))
        XCTAssertTrue(frame.includesUser);XCTAssertEqual(frame.center,user)
        XCTAssertGreaterThan(frame.distance,650)
        let radius=try XCTUnwrap(pins.map { Geometry.distance(frame.center,$0) }.max())
        // A 30-degree vertical FOV and measured usable map fraction must contain the
        // farthest pin even when heading rotates it onto the narrow padded axis.
        let availableFraction=min((195.0-76)/250,(250.0-96)/250)
        XCTAssertGreaterThanOrEqual(frame.distance*tan(.pi/12)*availableFraction,radius)
    }
    func testFarUserKeepsPropertyUsefulInsteadOfFittingAcrossTheCity() throws {
        let far=Coordinate(latitude:36.2,longitude:-115.1)
        let frame=try XCTUnwrap(MiniRouteCameraFraming.frame(pins:pins,fix:fix(far),at:now,width:390,height:500))
        XCTAssertFalse(frame.includesUser)
        XCTAssertLessThan(Geometry.distance(frame.center,user),20)
        XCTAssertLessThan(frame.distance,4000)
    }
    func testBadStaleOrMissingGPSFramesPropertyWithoutFollowingAnInvalidFix() throws {
        for value in [nil,fix(user,accuracy:100),fix(user,age:16)] {
            let frame=try XCTUnwrap(MiniRouteCameraFraming.frame(pins:pins,fix:value,at:now,width:390,height:500))
            XCTAssertFalse(frame.includesUser);XCTAssertTrue(frame.center.isValid)
        }
        XCTAssertNil(MiniRouteCameraFraming.frame(pins:[],fix:nil,at:now,width:390,height:500))
    }
    func testSmallViewportGetsMorePaddingWithoutInvalidOrTinyCamera() throws {
        let large=try XCTUnwrap(MiniRouteCameraFraming.frame(pins:pins,fix:fix(user),at:now,width:500,height:650))
        let small=try XCTUnwrap(MiniRouteCameraFraming.frame(pins:pins,fix:fix(user),at:now,width:320,height:300))
        XCTAssertGreaterThan(small.distance,large.distance)
        let fallback=try XCTUnwrap(MiniRouteCameraFraming.frame(pins:[user],fix:fix(user),at:now,width:0,height:.nan))
        XCTAssertTrue(fallback.distance.isFinite);XCTAssertGreaterThanOrEqual(fallback.distance,650)
    }
    func testRepeatedGPSAndHeadingFramesDoNotKeepOverwritingInitialZoom() {
        var state=MiniRouteMapFollowingState()
        state.adoptInitialFrame(distance:1600,includesUser:true)
        XCTAssertEqual(state.distance,1600)
        state.adoptInitialFrame(distance:2200,includesUser:true)
        XCTAssertEqual(state.distance,1600)
    }
    func testManualPinchAndResumeKeepChosenZoomAcrossLocationContextChanges() {
        var state=MiniRouteMapFollowingState()
        state.adoptInitialFrame(distance:1600,includesUser:true)
        state.userMoved(distance:900);state.resume()
        state.adoptInitialFrame(distance:2400,includesUser:false)
        XCTAssertTrue(state.isFollowing);XCTAssertEqual(state.distance,900)
    }
    func testApproachingFromFarAwayMayFitOnceBeforeAnyManualCameraGesture() {
        var state=MiniRouteMapFollowingState()
        state.adoptInitialFrame(distance:800,includesUser:false)
        state.adoptInitialFrame(distance:1800,includesUser:true)
        XCTAssertEqual(state.distance,1800)
        state.adoptInitialFrame(distance:2100,includesUser:true)
        XCTAssertEqual(state.distance,1800)
    }
    func testGPSJitterAtFarThresholdDoesNotRepeatedlyChangeAutomaticZoom() {
        var state=MiniRouteMapFollowingState()
        state.adoptInitialFrame(distance:1600,includesUser:true)
        state.adoptInitialFrame(distance:800,includesUser:false)
        state.adoptInitialFrame(distance:1800,includesUser:true)
        XCTAssertEqual(state.distance,1600)
    }
}
