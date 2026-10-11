import XCTest
@testable import IndieCore

final class FrameInterpolationPlanTests: XCTestCase {
    func testRetinaDecoratedPortraitAndUltrawideFitThePaddedBudget() {
        for (width, height) in [(3024,1964), (1920,1080), (1280,752), (3440,1440), (1080,1920), (640,480)] {
            let fit = FrameInterpolationResolution.fitted(width: width, height: height)!
            XCTAssertLessThanOrEqual(fit.width, width)
            XCTAssertLessThanOrEqual(fit.height, height)
            XCTAssertLessThanOrEqual(fit.width * fit.height, 1280 * 720)
            XCTAssertEqual(fit.width % 16, 0); XCTAssertEqual(fit.height % 16, 0)
            XCTAssertLessThan(abs(Double(fit.width)/Double(fit.height) - Double(width)/Double(height)), 0.04)
        }
        XCTAssertEqual(FrameInterpolationResolution.fitted(width: 1920, height: 1080),
                       FrameInterpolationResolution.fitted(width: 1280, height: 720))
        XCTAssertNil(FrameInterpolationResolution.fitted(width: 0, height: 720))
    }
    func testJitterDoesNotReanchorEveryCompletionAndPairsRemainOrdered() {
        var clock = FrameInterpolationPacer()
        var prior: FrameInterpolationPacer.Pair?
        for i in 1...120 {
            let current = Double(i) / 30
            let cost = i % 2 == 0 ? 0.010 : 0.015
            let pair = clock.schedule(previous: current - 1/30.0, current: current,
                                      completedAt: current + cost, processingSeconds: cost, refreshInterval: 1/120.0)!
            XCTAssertEqual(pair.original - pair.generated, 1/60.0, accuracy: 0.000001)
            if let prior { XCTAssertEqual(pair.generated - prior.original, 1/60.0, accuracy: 0.000001) }
            prior = pair
        }
    }
    func testOverrunDiscontinuityAndInvalidClockResetWithoutBuildingLatency() {
        var clock = FrameInterpolationPacer()
        XCTAssertNotNil(clock.schedule(previous: 0, current: 1/30.0, completedAt: 0.05,
                                       processingSeconds: 0.01, refreshInterval: 1/120.0))
        XCTAssertNil(clock.schedule(previous: 1/30.0, current: 2/30.0, completedAt: 0.2,
                                   processingSeconds: 0.01, refreshInterval: 1/120.0))
        let recovered = clock.schedule(previous: 0.2, current: 0.2 + 1/30.0, completedAt: 0.25,
                                       processingSeconds: 0.01, refreshInterval: 1/120.0)
        XCTAssertNotNil(recovered)
        XCTAssertLessThan(recovered!.original - 0.25, 0.1)
        XCTAssertNil(clock.schedule(previous: 1, current: 1.02, completedAt: 1.08,
                                   processingSeconds: 0.06, refreshInterval: 1/120.0))
        XCTAssertNil(clock.schedule(previous: 1, current: 1.02, completedAt: .nan,
                                   processingSeconds: 0.01, refreshInterval: 1/120.0))
    }
}
