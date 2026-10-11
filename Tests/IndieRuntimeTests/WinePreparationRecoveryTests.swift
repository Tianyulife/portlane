import XCTest
import IndieCore
@testable import IndieRuntime

final class WinePreparationRecoveryTests: XCTestCase {
    private func fixture(script: String) throws -> (URL, BottleRecord, WineRuntimeProvider) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("wine recovery 中文-\(UUID())")
        let runtime = root.appendingPathComponent("runtime")
        let bottle = BottleRecord(name: "Test", root: root.appendingPathComponent("bottle"), runtimeID: "test")
        try FileManager.default.createDirectory(at: runtime.appendingPathComponent("bin"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: bottle.root, withIntermediateDirectories: true)
        for (name, contents) in [("wine", script), ("wineserver", "#!/bin/sh\nexit 0\n")] {
            let file = runtime.appendingPathComponent("bin/\(name)")
            try contents.write(to: file, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
        }
        return (root, bottle, WineRuntimeProvider(manifest: CommunityIndieWineBootstrapper.manifest, root: runtime))
    }

    func testTimedOutHelperRetriesOnceAndSucceeds() async throws {
        let (root, bottle, provider) = try fixture(script: """
        #!/bin/sh
        if [ ! -f "$WINEPREFIX/attempt" ]; then
          : > "$WINEPREFIX/attempt"
          exec /bin/sleep 3
        fi
        exit 0
        """)
        defer { try? FileManager.default.removeItem(at: root) }
        try await provider.runPreparation(in: bottle, arguments: ["reg"], operation: "Display", timeout: .seconds(1))
        let log = try String(contentsOf: bottle.root.appendingPathComponent(".indie-diagnostics/wine-preparation.log"), encoding: .utf8)
        XCTAssertTrue(log.contains("attempt 2 succeeded"))
    }

    func testSecondTimeoutHasSpecificOperationAndDiagnosticLocation() async throws {
        let (root, bottle, provider) = try fixture(script: "#!/bin/sh\nexec /bin/sleep 3\n")
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            try await provider.runPreparation(in: bottle, arguments: ["reg"], operation: "CJK registration", timeout: .seconds(1))
            XCTFail("Expected timeout")
        } catch let IndieError.timedOut(operation) {
            XCTAssertTrue(operation.contains("CJK registration"))
            XCTAssertTrue(operation.contains("wine-preparation.log"))
        }
    }

    func testNonTimeoutFailureIsNotRetriedOrHidden() async throws {
        let (root, bottle, provider) = try fixture(script: "#!/bin/sh\necho failed\nexit 7\n")
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            try await provider.runPreparation(in: bottle, arguments: ["reg"], operation: "Display", timeout: .seconds(1))
            XCTFail("Expected process failure")
        } catch let IndieError.processFailed(_, status, _) {
            XCTAssertEqual(status, 7)
        }
    }
}
