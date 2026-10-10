import Foundation

/// One attempt; subsequent attempts start a fresh timeline.
public struct GameLaunchReport: Sendable, Equatable {
    public struct Step: Sendable, Equatable {
        public let detail: String
        public let date: Date
    }
    public let appID: UInt64
    public let name: String
    public let startedAt: Date
    public private(set) var state: GameLaunchState = .preparing
    public private(set) var steps: [Step] = []
    public private(set) var error: String?
    public var logURL: URL?

    public init(appID: UInt64, name: String, date: Date = Date()) {
        self.appID = appID
        self.name = name
        self.startedAt = date
    }

    public mutating func update(_ state: GameLaunchState, detail: String, error: String? = nil, date: Date = Date()) {
        self.state = state
        self.error = error
        if steps.last?.detail != detail { steps.append(Step(detail: detail, date: date)) }
    }

    public var diagnosticText: String {
        (["\(name) · Steam AppID \(appID)", startedAt.ISO8601Format()] +
         steps.map { "[\(Int($0.date.timeIntervalSince(startedAt)))s] \($0.detail)" } +
         [error, logURL?.path].compactMap { $0 }).joined(separator: "\n")
    }
}
