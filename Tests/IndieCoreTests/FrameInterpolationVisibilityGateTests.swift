import XCTest
@testable import IndieCore

final class FrameInterpolationVisibilityGateTests: XCTestCase {
    func testShortOffscreenObservationHidesAndRecoversWithoutAcceptingOldWork() {
        var gate = FrameInterpolationVisibilityGate()
        let originalEpoch = gate.epoch
        XCTAssertEqual(gate.observe(isVisible: false, now: 10), .suspended)
        XCTAssertFalse(gate.canPresent)
        XCTAssertFalse(gate.accepts(epoch: originalEpoch))
        let suspendedEpoch = gate.epoch
        XCTAssertEqual(gate.observe(isVisible: false, now: 10.25), .suspended)
        XCTAssertEqual(gate.epoch, suspendedEpoch)
        XCTAssertEqual(gate.observe(isVisible: true, now: 10.5), .visible)
        XCTAssertTrue(gate.canPresent)
        XCTAssertFalse(gate.accepts(epoch: originalEpoch))
        XCTAssertFalse(gate.accepts(epoch: suspendedEpoch))
        XCTAssertTrue(gate.accepts(epoch: gate.epoch))
    }

    func testPersistentOffscreenStateExpiresWithoutExtendingDeadlineOnEachPoll() {
        var gate = FrameInterpolationVisibilityGate()
        XCTAssertEqual(gate.observe(isVisible: false, now: 20), .suspended)
        XCTAssertEqual(gate.observe(isVisible: false, now: 20.75), .suspended)
        XCTAssertEqual(gate.observe(isVisible: false, now: 21), .expired)
        XCTAssertFalse(gate.canPresent)
        XCTAssertEqual(gate.observe(isVisible: true, now: 21.25), .expired)
    }

    func testRepeatedShortGapsHaveIndependentDeadlinesAndEpochs() {
        var gate = FrameInterpolationVisibilityGate()
        for i in 0..<20 {
            let time = Double(i) * 2
            let old = gate.epoch
            XCTAssertEqual(gate.observe(isVisible: false, now: time), .suspended)
            XCTAssertEqual(gate.observe(isVisible: true, now: time + 0.25), .visible)
            XCTAssertFalse(gate.accepts(epoch: old))
        }
        XCTAssertEqual(gate.epoch, 40)
    }

    func testInvalidOrReversedClockCannotLeaveStaleOverlayVisible() {
        var gate = FrameInterpolationVisibilityGate()
        XCTAssertEqual(gate.observe(isVisible: false, now: 10), .suspended)
        XCTAssertEqual(gate.observe(isVisible: true, now: 9), .expired)
        XCTAssertFalse(gate.canPresent)
        var invalid = FrameInterpolationVisibilityGate()
        XCTAssertEqual(invalid.observe(isVisible: true, now: .nan), .expired)
        XCTAssertFalse(invalid.canPresent)
    }
}
