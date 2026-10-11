import Foundation

/// Hide immediately on an offscreen observation, but keep the processor alive
/// for a bounded recovery period. An epoch invalidates work crossing that gap.
public struct FrameInterpolationVisibilityGate: Sendable {
    public enum Decision: Equatable, Sendable { case visible, suspended, expired }
    private var hiddenSince: Double?
    public private(set) var epoch: UInt64 = 0
    public var canPresent: Bool { hiddenSince == nil }
    public init() {}

    public mutating func observe(isVisible: Bool, now: Double) -> Decision {
        guard now.isFinite else {
            if hiddenSince == nil { epoch &+= 1 }
            hiddenSince = -.infinity
            return .expired
        }
        if let hiddenSince, now < hiddenSince || now - hiddenSince >= 1 {
            return .expired
        }
        if isVisible {
            if hiddenSince != nil { epoch &+= 1 }
            hiddenSince = nil
            return .visible
        }
        if hiddenSince == nil { hiddenSince = now; epoch &+= 1 }
        return .suspended
    }

    public func accepts(epoch: UInt64) -> Bool { canPresent && epoch == self.epoch }
}
