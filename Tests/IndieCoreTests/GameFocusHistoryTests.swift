import XCTest
@testable import IndieCore

final class GameFocusHistoryTests: XCTestCase {
    func testSystemInterfacePreservesLastFocusedGame() {
        var history = GameFocusHistory()
        let first = GameFocusHistory.Run(pid: 10, started: "first")
        let second = GameFocusHistory.Run(pid: 20, started: "second")
        history.observe(runs: [first, second], foregroundPID: 10)
        history.observe(runs: [first, second], foregroundPID: 999)
        XCTAssertEqual(history.target, first)
        history.observe(runs: [first, second], foregroundPID: 20)
        XCTAssertEqual(history.target, second)
    }
    func testExitedRunAndReusedPIDAreNotRestored() {
        var history = GameFocusHistory()
        let run = GameFocusHistory.Run(pid: 10, started: "old")
        history.observe(runs: [run], foregroundPID: 10)
        history.observe(runs: [.init(pid: 10, started: "new")], foregroundPID: 999)
        XCTAssertNil(history.target)
    }
    func testNoGameIsGuessedWhenOnlySystemWasFocused() {
        var history = GameFocusHistory()
        history.observe(runs: [.init(pid: 10, started: "run")], foregroundPID: 999)
        XCTAssertNil(history.target)
    }
}
