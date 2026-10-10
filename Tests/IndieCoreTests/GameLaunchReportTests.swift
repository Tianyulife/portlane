import XCTest
@testable import IndieCore

final class GameLaunchReportTests: XCTestCase {
    func testFailureKeepsTimelineAndLogAfterOtherOperations() {
        let start = Date(timeIntervalSince1970: 100)
        var report = GameLaunchReport(appID: 2358720, name: "Wukong", date: start)
        report.update(.preparing, detail: "Apply settings", date: start)
        report.logURL = URL(fileURLWithPath: "/tmp/game.log")
        report.update(.failed, detail: "Steam launch failed", error: "Missing runtime", date: start.addingTimeInterval(5))
        XCTAssertEqual(report.state, .failed)
        XCTAssertEqual(report.steps.count, 2)
        XCTAssertTrue(report.diagnosticText.contains("[5s] Steam launch failed"))
        XCTAssertTrue(report.diagnosticText.contains("Missing runtime"))
        XCTAssertTrue(report.diagnosticText.contains("/tmp/game.log"))
    }
    func testRepeatedProcessPollsDoNotGrowTimeline() {
        var report = GameLaunchReport(appID: 1, name: "Game")
        report.update(.waiting, detail: "Waiting")
        for _ in 0..<100 { report.update(.running, detail: "Process detected") }
        XCTAssertEqual(report.steps.count, 2)
        XCTAssertEqual(report.state, .running)
    }
    func testRetryDoesNotInheritPreviousFailure() {
        var report = GameLaunchReport(appID: 1, name: "Game")
        report.update(.failed, detail: "Failed", error: "Error")
        report = GameLaunchReport(appID: 1, name: "Game")
        XCTAssertNil(report.error)
        XCTAssertTrue(report.steps.isEmpty)
        XCTAssertEqual(report.state, .preparing)
    }
}
