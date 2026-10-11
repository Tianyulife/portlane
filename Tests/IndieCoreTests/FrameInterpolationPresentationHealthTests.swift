import XCTest
@testable import IndieCore

final class FrameInterpolationPresentationHealthTests: XCTestCase {
    func testGeneratedAndSubmittedWorkCannotKeepAnUnpresentedDisplayAlive() {
        var health = FrameInterpolationPresentationHealth()
        XCTAssertFalse(health.isStalled(presented: 0, expectingOutput: true, now: 10))
        XCTAssertFalse(health.isStalled(presented: 0, expectingOutput: true, now: 11.75))
        XCTAssertTrue(health.isStalled(presented: 0, expectingOutput: true, now: 12))
    }

    func testProgressResetsRunningDeadlineButRepeatedImagesDoNot() {
        var health = FrameInterpolationPresentationHealth()
        XCTAssertFalse(health.isStalled(presented: 5, expectingOutput: true, now: 0))
        XCTAssertFalse(health.isStalled(presented: 10, expectingOutput: true, now: 0.75))
        XCTAssertFalse(health.isStalled(presented: 10, expectingOutput: true, now: 1.5))
        XCTAssertTrue(health.isStalled(presented: 10, expectingOutput: true, now: 1.75))
    }

    func testStaticSceneOrHiddenOverlayDoesNotCauseFalseFailure() {
        var health = FrameInterpolationPresentationHealth()
        XCTAssertFalse(health.isStalled(presented: 10, expectingOutput: true, now: 0))
        XCTAssertFalse(health.isStalled(presented: 10, expectingOutput: false, now: 0.5))
        XCTAssertFalse(health.isStalled(presented: 10, expectingOutput: false, now: 100))
        XCTAssertFalse(health.isStalled(presented: 10, expectingOutput: true, now: 101))
        XCTAssertFalse(health.isStalled(presented: 11, expectingOutput: true, now: 101.75))
    }

    func testInvalidOrReversedClockFailsClosed() {
        var health = FrameInterpolationPresentationHealth()
        XCTAssertTrue(health.isStalled(presented: 0, expectingOutput: true, now: .nan))
        XCTAssertFalse(health.isStalled(presented: 0, expectingOutput: true, now: 10))
        XCTAssertTrue(health.isStalled(presented: 0, expectingOutput: true, now: 9))
    }
}
