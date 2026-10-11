import XCTest
@testable import IndieCore

final class FrameInterpolationWindowLayerTests: XCTestCase {
    func testWineBorderlessRenderWindowIsEligibleAlongsideNormalWindows() {
        XCTAssertTrue(FrameInterpolationWindowLayer.isEligible(0))
        XCTAssertTrue(FrameInterpolationWindowLayer.isEligible(26))
        for layer in [-1, 3, 24, 25, 27, 101, 1000] {
            XCTAssertFalse(FrameInterpolationWindowLayer.isEligible(layer))
        }
    }
}
