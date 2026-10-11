import XCTest
@testable import IndieCore

final class FrameInterpolationPredictionTests: XCTestCase {
    func testPredictionHorizonDoesNotConsumeBothImagesOnTheFirstRefresh() {
        var clock = FrameInterpolationPacer()
        let completed = 10.0, lead = 0.025, refresh = 1/120.0
        let pair = clock.schedule(previous: completed-1/30.0, current: completed,
                                  completedAt: completed, processingSeconds: 0.012,
                                  refreshInterval: refresh, presentationLead: lead)!
        XCTAssertGreaterThan(pair.generated, completed+lead+refresh)
        XCTAssertGreaterThan(pair.original, pair.generated)
        XCTAssertLessThanOrEqual(pair.original-completed, 0.1)
        XCTAssertNil(clock.schedule(previous: 10, current: 10.033,
                                    completedAt: 10.05, processingSeconds: 0.012,
                                    refreshInterval: refresh, presentationLead: .infinity))
    }
}
