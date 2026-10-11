import XCTest
import IndieRuntime

final class SteamCloudLogTests: XCTestCase {
    private let zone = TimeZone(secondsFromGMT: 0)!
    private var baseline: Date { Date(timeIntervalSince1970: 1_791_244_800) } // 2026-10-06 00:00 UTC

    private func observation(_ messages: String, since: Date = .distantPast) -> SteamCloudLog.Observation {
        SteamCloudLog.parse(messages, since: since, timeZone: zone)
    }

    func testExitUploadRequiresMatchingAccountAndCurrentRun() {
        let log = """
        [2026-10-06 10:00:00] [AppID 42] AutoCloud checking local state for user 76561197960265851
        [2026-10-06 10:10:00] [AppID 42] Starting sync (up,AC Exit,)
        [2026-10-06 10:10:01] [AppID 42] Upload OK for file save.sav
        [2026-10-06 10:10:02] [AppID 42] Upload complete, result OK
        """
        let result = observation(log)
        XCTAssertEqual(result.states[42], .synced)
        XCTAssertTrue(result.confirms(.init(appID: 42, accountID: 123, beganAt: baseline)))
        XCTAssertFalse(result.confirms(.init(appID: 42, accountID: 456, beganAt: baseline)))
        XCTAssertFalse(result.confirms(.init(appID: 43, accountID: 123, beganAt: baseline)))
        XCTAssertFalse(result.confirms(.init(appID: 42, accountID: nil, beganAt: baseline)))
        XCTAssertFalse(result.confirms(.init(appID: 42, accountID: 123, beganAt: .distantFuture)))
    }

    func testDownloadAndEvaluationCannotAcknowledgeUpload() {
        let result = observation("""
        [2026-10-06 10:00:00] [AppID 42] Starting sync (down,)
        [2026-10-06 10:00:01] [AppID 42] Successfully synced to ChangeNumber 1
        [2026-10-06 10:00:02] [AppID 42] Starting sync (eval,)
        [2026-10-06 10:00:03] [AppID 42] File is in sync failed/conflict.sav
        [2026-10-06 10:00:04] [AppID 42] Eval complete
        """)
        XCTAssertEqual(result.states[42], .unknown)
        XCTAssertTrue(result.exitUploads.isEmpty)
    }

    func testPerFileSuccessAndInterruptedBatchRemainUploading() {
        let result = observation("""
        [2026-10-06 10:00:00] [AppID 42] Starting sync (up,AC Exit,)
        [2026-10-06 10:00:01] [AppID 42] Upload OK for file save.sav
        [2026-10-06 10:00:02] [AppID 7] Successfully synced to ChangeNumber 4
        """)
        XCTAssertEqual(result.states[42], .uploading)
        XCTAssertNil(result.exitUploads[42])
    }

    func testFailedBatchStaysFailedUntilRetryCompletes() {
        let failed = """
        [2026-10-06 10:00:00] [AppID 42] Starting sync (up,AC Exit,)
        [2026-10-06 10:00:01] [AppID 42] Upload complete, result Failure
        """
        XCTAssertEqual(observation(failed).states[42], .failed)
        let retried = observation(failed + "\n" + """
        [2026-10-06 10:01:00] [AppID 42] Starting sync (up,AC Exit,)
        [2026-10-06 10:01:01] [AppID 42] Upload complete, result OK
        """)
        XCTAssertEqual(retried.states[42], .synced)
        XCTAssertNotNil(retried.exitUploads[42])
    }

    func testNoChangedFilesIsValidExitUploadCompletion() {
        let result = observation("""
        [2026-10-06 10:00:00] [AppID 42] Starting sync (up,AC Exit,)
        [2026-10-06 10:00:01] [AppID 42] Upload complete in build list
        [2026-10-06 10:00:02] [AppID 42] Starting sync (eval,)
        [2026-10-06 10:00:03] [AppID 42] Eval complete
        """)
        XCTAssertEqual(result.states[42], .synced)
        XCTAssertNotNil(result.exitUploads[42])
    }

    func testOldLogsOrdinaryUploadsAndMissingStartCannotCompleteCurrentExit() {
        XCTAssertTrue(observation("[2026-09-06 10:00:00] [AppID 42] Upload complete, result OK", since: baseline).states.isEmpty)
        let result = observation("""
        [2026-10-06 10:00:00] [AppID 42] Starting sync (up,)
        [2026-10-06 10:00:01] [AppID 42] Upload complete, result OK
        [2026-10-06 10:00:02] [AppID 43] Upload complete, result OK
        """)
        XCTAssertTrue(result.exitUploads.isEmpty)
        XCTAssertNil(result.states[43])
    }

    func testAccountSwitchInvalidatesOldEvidence() {
        let result = observation("""
        [2026-10-06 10:00:00] [AppID 42] AutoCloud checking local state for user 76561197960265851
        [2026-10-06 10:00:01] [AppID 42] Starting sync (up,AC Exit,)
        [2026-10-06 10:00:02] [AppID 42] Upload complete, result OK
        [2026-10-06 10:00:03] [AppID 42] AutoCloud checking local state for user 76561197960266184
        """)
        XCTAssertNil(result.exitUploads[42])
        XCTAssertEqual(result.states[42], .unknown)
    }

    func testCacheAccountSwitchCannotReuseAnotherAccountsUpload() {
        let result = observation("""
        [2026-10-06 10:00:00] [AppID 42] AutoCloud checking local state for user 76561197960265851
        [2026-10-06 10:00:01] [AppID 42] Starting sync (up,AC Exit,)
        [2026-10-06 10:00:02] [AppID 42] Upload complete, result OK
        [2026-10-06 10:00:03] [AppID 42] Loaded cache file userdata/456/42/remotecache.vdf
        """)
        XCTAssertEqual(result.accounts[42], 456)
        XCTAssertFalse(result.confirms(.init(appID: 42, accountID: 456, beganAt: baseline)))
        XCTAssertNil(result.exitUploads[42])
    }

    func testReaderRejectsPartialAcknowledgementAndMissingLog() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cloud-log-test-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("logs"), withIntermediateDirectories: true)
        XCTAssertTrue(SteamCloudLog.read(steamDirectory: root, since: .distantPast).states.isEmpty)
        let log = "[2026-10-06 10:00:00] [AppID 42] Starting sync (up,AC Exit,)\n[2026-10-06 10:00:01] [AppID 42] Upload complete, result OK"
        try log.write(to: root.appendingPathComponent("logs/cloud_log.txt"), atomically: true, encoding: .utf8)
        XCTAssertEqual(SteamCloudLog.read(steamDirectory: root, since: .distantPast).states[42], .uploading)
    }

    func testWindowsLogReaderConfirmsCompleteExitUploadButRejectsPartialAcknowledgement() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("windows-cloud-log-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("logs"), withIntermediateDirectories: true)
        let file = root.appendingPathComponent("logs/cloud_log.txt")
        let lines = [
            "[2026-10-06 10:00:00] [AppID 42] AutoCloud checking local state for user 76561197960265851",
            "[2026-10-06 10:00:01] [AppID 42] Starting sync (up,AC Exit,)",
            "[2026-10-06 10:00:02] [AppID 42] Upload complete, result OK",
        ]
        let requirement = SteamCloudUploadRequirement(appID: 42, accountID: 123, beganAt: baseline)
        let complete = "\r\n" + lines.joined(separator: "\r\n") + "\r\n"
        try complete.write(to: file, atomically: true, encoding: .utf8)
        XCTAssertTrue(observation(complete).confirms(requirement))
        XCTAssertTrue(SteamCloudLog.read(steamDirectory: root, since: baseline).confirms(requirement))

        try lines.joined(separator: "\r\n").write(to: file, atomically: true, encoding: .utf8)
        let partial = SteamCloudLog.read(steamDirectory: root, since: baseline)
        XCTAssertEqual(partial.states[42], .uploading)
        XCTAssertFalse(partial.confirms(requirement))

        try "[2026-10-06 10:00:00] Connection established for [U:1:123]\r\n".write(
            to: root.appendingPathComponent("logs/connection_log.txt"), atomically: true, encoding: .utf8
        )
        XCTAssertEqual(SteamCloudLog.accountID(steamDirectory: root), 123)
    }
}
