import Foundation
import CoreVideo
import IndieCore

/// CPU buffer locking and duplicate checks never run on the UI/display-link thread.
public final class InterpolationFrameAnalyzer: @unchecked Sendable {
    public struct Result: Sendable {
        public let duplicate: Bool
        public let sceneCut: Bool
    }
    private let queue = DispatchQueue(label: "indie.interpolation.analysis", qos: .userInitiated)
    public init() {}
    public func analyze(previous: InterpolationImage, current: InterpolationImage) async -> Result {
        await withCheckedContinuation { reply in
            queue.async {
                let duplicate = Self.identical(previous.buffer, current.buffer)
                let cut: Bool
                if !duplicate, let a = Self.signature(previous.buffer), let b = Self.signature(current.buffer) {
                    cut = b.isSceneCut(from: a)
                } else { cut = false }
                reply.resume(returning: Result(duplicate: duplicate, sceneCut: cut))
            }
        }
    }
    private static func signature(_ pixel: CVPixelBuffer) -> FrameContentSignature? {
        guard CVPixelBufferGetPixelFormatType(pixel) == kCVPixelFormatType_32BGRA else { return nil }
        guard CVPixelBufferLockBaseAddress(pixel, .readOnly) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(pixel, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pixel)?.assumingMemoryBound(to: UInt8.self) else { return nil }
        let width = CVPixelBufferGetWidth(pixel), height = CVPixelBufferGetHeight(pixel)
        let stride = CVPixelBufferGetBytesPerRow(pixel)
        guard width > 0, height > 0 else { return nil }
        var samples: [UInt8] = []
        samples.reserveCapacity(32 * 18)
        for row in 0..<18 { for column in 0..<32 {
            let p = min(height-1, row*height/18)*stride + min(width-1, column*width/32)*4
            samples.append(UInt8((Int(base[p]) + 2*Int(base[p+1]) + Int(base[p+2]))/4))
        } }
        return FrameContentSignature(luma: samples)
    }
    private static func identical(_ first: CVPixelBuffer, _ second: CVPixelBuffer) -> Bool {
        let width = CVPixelBufferGetWidth(first), height = CVPixelBufferGetHeight(first)
        guard width == CVPixelBufferGetWidth(second), height == CVPixelBufferGetHeight(second),
              CVPixelBufferGetPixelFormatType(first) == kCVPixelFormatType_32BGRA,
              CVPixelBufferGetPixelFormatType(second) == kCVPixelFormatType_32BGRA else { return false }
        guard CVPixelBufferLockBaseAddress(first, .readOnly) == kCVReturnSuccess else { return false }
        defer { CVPixelBufferUnlockBaseAddress(first, .readOnly) }
        guard CVPixelBufferLockBaseAddress(second, .readOnly) == kCVReturnSuccess else { return false }
        defer { CVPixelBufferUnlockBaseAddress(second, .readOnly) }
        guard let a = CVPixelBufferGetBaseAddress(first), let b = CVPixelBufferGetBaseAddress(second) else { return false }
        for row in 0..<height {
            if memcmp(a.advanced(by: row*CVPixelBufferGetBytesPerRow(first)),
                      b.advanced(by: row*CVPixelBufferGetBytesPerRow(second)), width*4) != 0 { return false }
        }
        return true
    }
}
