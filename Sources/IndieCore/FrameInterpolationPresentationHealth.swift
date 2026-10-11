import Foundation

/// Capture/inference progress is not evidence that a drawable reached the
/// compositor. Check actual distinct presentations only while new output is due.
public struct FrameInterpolationPresentationHealth: Sendable {
    private var count = 0
    private var waitingSince: Double?
    private var hasPresented = false
    public init() {}

    public mutating func isStalled(presented: Int, expectingOutput: Bool, now: Double) -> Bool {
        guard now.isFinite, presented >= 0 else { return true }
        if !expectingOutput {
            count = presented; waitingSince = nil; hasPresented = presented > 0
            return false
        }
        if presented > count {
            count = presented; waitingSince = now; hasPresented = true
            return false
        }
        if waitingSince == nil { waitingSince = now }
        guard let waitingSince else { return false }
        // Allow initial drawable acquisition more time than a running display.
        return now < waitingSince || now - waitingSince >= (hasPresented ? 1 : 2)
    }
}
