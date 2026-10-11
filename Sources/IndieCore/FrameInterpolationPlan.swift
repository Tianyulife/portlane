import Foundation

/// Processing dimensions are separate from the game's display dimensions.
/// The 720p budget is a measured backend limit, not an advertised VT capability.
public struct FrameInterpolationResolution: Equatable, Sendable {
    public let width: Int
    public let height: Int
    public static let maximumPixels = 1280 * 720

    public static func fitted(width: Int, height: Int) -> Self? {
        guard width >= 16, height >= 16 else { return nil }
        let scale = min(1, min(1280.0 / Double(width), 720.0 / Double(height)))
        // VT counts padded dimensions. Keep both dimensions aligned, including
        // decorated windows and Retina resolutions with unusual aspect ratios.
        let w = max(16, Int(Double(width) * scale) / 16 * 16)
        let h = max(16, Int(Double(height) * scale) / 16 * 16)
        guard w * h <= maximumPixels else { return nil }
        return Self(width: w, height: h)
    }
}

/// A bounded-latency clock for pairs, independent of inference completion rate.
/// Timestamps use the host clock. The display link picks frames at refresh time.
public struct FrameInterpolationPacer: Sendable {
    public struct Pair: Equatable, Sendable {
        public let generated: Double
        public let original: Double
    }
    private var interval: Double?
    private var lastOriginal: Double?
    public init() {}
    public mutating func reset() { interval = nil; lastOriginal = nil }

    public mutating func schedule(previous: Double, current: Double,
                                  completedAt: Double, processingSeconds: Double,
                                  refreshInterval: Double, presentationLead: Double = 0) -> Pair? {
        guard FrameInterpolationTiming.midpoint(previous: previous, current: current) != nil,
              completedAt.isFinite, processingSeconds.isFinite, processingSeconds >= 0,
              refreshInterval.isFinite, refreshInterval > 0,
              presentationLead.isFinite, presentationLead >= 0 else { reset(); return nil }
        let gap = current - previous
        // Never build latency by interpolating pairs that cannot keep up.
        guard processingSeconds <= min(0.05, gap * 1.5) else { reset(); return nil }
        if let old = interval, gap > old * 2.5 || gap < old * 0.4 { reset() }
        let smooth = interval.map { $0 * 0.9 + gap * 0.1 } ?? gap
        interval = smooth
        let generated: Double
        if let lastOriginal {
            generated = lastOriginal + smooth / 2
        } else {
            // Reserve one output slot plus jitter headroom on initial warmup.
            generated = completedAt + presentationLead + max(smooth / 2, refreshInterval) + min(processingSeconds, smooth / 2)
        }
        let original = generated + smooth / 2
        guard generated > completedAt + presentationLead + refreshInterval * 0.25,
              original - completedAt <= 0.1 else { reset(); return nil }
        lastOriginal = original
        return Pair(generated: generated, original: original)
    }
}
