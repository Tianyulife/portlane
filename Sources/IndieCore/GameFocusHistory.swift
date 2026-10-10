import Foundation

/// Retain the most recently focused managed run, never an unrelated app or a reused PID.
public struct GameFocusHistory: Sendable {
    public struct Run: Hashable, Sendable {
        public let pid: Int32
        public let started: String
        public init(pid: Int32, started: String) { self.pid = pid; self.started = started }
    }
    public private(set) var target: Run?
    public init() {}
    public mutating func observe(runs: Set<Run>, foregroundPID: Int32?) {
        if let target, !runs.contains(target) { self.target = nil }
        let focused = runs.filter { $0.pid == foregroundPID }
        if focused.count == 1 { target = focused.first }
    }
}
