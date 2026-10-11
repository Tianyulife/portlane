import XCTest
import CoreVideo
import CoreMedia
@testable import IndieRuntime

final class InterpolationFrameAnalyzerTests: XCTestCase {
    private func image(_ value: UInt8) throws -> InterpolationImage {
        var buffer: CVPixelBuffer?
        let result = CVPixelBufferCreate(nil, 64, 64, kCVPixelFormatType_32BGRA, nil, &buffer)
        XCTAssertEqual(result, kCVReturnSuccess)
        let pixel = try XCTUnwrap(buffer)
        CVPixelBufferLockBaseAddress(pixel, [])
        memset(CVPixelBufferGetBaseAddress(pixel), Int32(value), CVPixelBufferGetBytesPerRow(pixel) * 64)
        CVPixelBufferUnlockBaseAddress(pixel, [])
        return InterpolationImage(buffer: pixel, timestamp: CMTime(value: 1, timescale: 30))
    }
    func testDuplicateRequiresEveryPixelEvenWhenSampleGridDoesNotChange() async throws {
        let a = try image(30), b = try image(30)
        let analyzer = InterpolationFrameAnalyzer()
        let duplicate = await analyzer.analyze(previous: a, current: b)
        XCTAssertTrue(duplicate.duplicate); XCTAssertFalse(duplicate.sceneCut)
        CVPixelBufferLockBaseAddress(b.buffer, [])
        let pointer = CVPixelBufferGetBaseAddress(b.buffer)!.assumingMemoryBound(to: UInt8.self)
        pointer[7 * CVPixelBufferGetBytesPerRow(b.buffer) + 7 * 4] = 31
        CVPixelBufferUnlockBaseAddress(b.buffer, [])
        let changed = await analyzer.analyze(previous: a, current: b)
        XCTAssertFalse(changed.duplicate); XCTAssertFalse(changed.sceneCut)
    }
    func testAbruptSceneChangeIsRejectedWhileOrdinaryMotionIsAdmitted() async throws {
        let analyzer = InterpolationFrameAnalyzer()
        let a = try image(30), modestChange = try image(35), cut = try image(240)
        let motion = await analyzer.analyze(previous: a, current: modestChange)
        XCTAssertFalse(motion.duplicate); XCTAssertFalse(motion.sceneCut)
        let sceneCut = await analyzer.analyze(previous: a, current: cut)
        XCTAssertFalse(sceneCut.duplicate); XCTAssertTrue(sceneCut.sceneCut)
    }
}
