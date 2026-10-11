import XCTest
import IndieCore
@testable import IndieRuntime

final class SteamClientHandoffTests: XCTestCase {
    func testWukongUsesDefaultDLLLoadingAndInvalidatesDisabledSession() throws {
        let environment = ["WINEDLLOVERRIDES": "d3d11,dxgi=n,b", "WINEMSYNC": "1"]
        let regular = SteamCompatibilityManager.relayEnvironment(for: environment, appID: 2001120)
        let sharedWukong = SteamCompatibilityManager.relayEnvironment(for: environment, appID: 2358720)
        XCTAssertEqual(regular["WINEDLLOVERRIDES"], "d3d11,dxgi=n,b;winedbg.exe=d")
        XCTAssertEqual(sharedWukong, regular)
        var configuration = GameConfiguration.steam(appID: 2358720)
        XCTAssertNil(configuration.dllOverrides)
        let wukong = try GameCompatibilityEnvironment.applying(configuration, to: sharedWukong)
        XCTAssertEqual(wukong, regular)
        // Explicit user choices still apply; they are not an automatic game preset.
        configuration.dllOverrides = ["mscoree": .builtin]
        let customized = try GameCompatibilityEnvironment.applying(configuration, to: sharedWukong)
        XCTAssertEqual(customized["WINEDLLOVERRIDES"], "d3d11,dxgi=n,b;winedbg.exe=d;mscoree=b")
        XCTAssertEqual(wukong["WINEMSYNC"], "1")
        let bottleID = UUID()
        var disabled = regular
        disabled["WINEDLLOVERRIDES"] = "d3d11,dxgi=n,b;mscoree,mshtml=;winedbg.exe=d"
        let oldSession = SteamSessionDescriptor(bottleID: bottleID, runtimeID: "wine", environment: disabled, virtualDesktop: nil)
        let newSession = SteamSessionDescriptor(bottleID: bottleID, runtimeID: "wine", environment: wukong, virtualDesktop: nil)
        var tracker = SteamSessionTracker()
        tracker.didLaunch(oldSession, reused: false)
        XCTAssertFalse(tracker.canReuse(newSession))
        tracker.didLaunch(newSession, reused: false)
        XCTAssertTrue(tracker.canReuse(newSession))
        XCTAssertFalse(tracker.canReuse(oldSession))
    }

    func testMappedFileAliasResolvesToSameInstallation() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("steam-client-alias-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("steam.exe")
        try Data().write(to: file)
        let alias = root.appendingPathComponent("alias.exe")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: file)
        let result = SteamClientProcessSnapshot.parse("p321\nn\(alias.path)\n",
            mainPath: file.resolvingSymlinksInPath().path, helperPaths: [])
        XCTAssertEqual(result.steamPIDs, [321])
    }

    func testColdClientRepairUsesActualInstallationDirectory() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("steam-client-location-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let bottle = BottleRecord(name: "Test", root: root, runtimeID: "wine")
        let steam = root.appendingPathComponent("drive_c/Program Files/Steam")
        let cef = steam.appendingPathComponent("bin/cef/cef.win64")
        try FileManager.default.createDirectory(at: cef, withIntermediateDirectories: true)
        try Data("original".utf8).write(to: cef.appendingPathComponent("steamwebhelper.exe"))
        let wrapper = root.appendingPathComponent("wrapper.exe")
        try Data("INDIE_STEAM_WEBHELPER_WRAPPER_V1-test".utf8).write(to: wrapper)
        let result = try SteamCompatibilityManager.prepare(bottle: bottle, wrapper: wrapper, steamDirectory: steam)
        XCTAssertTrue(result.wrapperInstalled)
        XCTAssertEqual(try Data(contentsOf: result.upstreamWebHelper), Data("original".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: SteamCompatibilityManager.steamRoot(in: bottle).path))
    }

    func testExplicitFallbackNavigatesWithoutStartingAnotherDownload() {
        XCTAssertEqual(SteamClientDestination.installDestination(appID: 2495980, owned: true).uri,
                       "steam://nav/games/details/2495980")
        XCTAssertEqual(SteamClientDestination.installDestination(appID: 2495980, owned: false).uri,
                       "steam://store/2495980")
        XCTAssertEqual(SteamClientDestination.downloads.uri, "steam://nav/downloads")
        XCTAssertEqual(SteamClientDestination.library.uri, "steam://open/main")
        XCTAssertFalse(SteamCompatibilityManager.launchArguments(silent: false).contains("-silent"))
    }

    func testReuseRequiresLiveProcessAndMatchingBottleRuntime() {
        let id = UUID()
        let descriptor = SteamSessionDescriptor(bottleID: id, runtimeID: "wine",
            environment: ["WINEMSYNC":"1"], virtualDesktop: .init(width:1920,height:1080))
        XCTAssertEqual(SteamClientDestination.reusableDescriptor(descriptor, bottleID: id, runtimeID: "wine", processExists: true), descriptor)
        XCTAssertNil(SteamClientDestination.reusableDescriptor(descriptor, bottleID: id, runtimeID: "wine", processExists: false))
        XCTAssertNil(SteamClientDestination.reusableDescriptor(descriptor, bottleID: UUID(), runtimeID: "wine", processExists: true))
        XCTAssertNil(SteamClientDestination.reusableDescriptor(descriptor, bottleID: id, runtimeID: "other", processExists: true))
    }

    func testMappedPathsCannotMatchAnotherBottleOrGame() {
        let main = "/private/tmp/bottle/drive_c/Steam/steam.exe"
        let helper = "/private/tmp/bottle/drive_c/Steam/bin/steamwebhelper_real.exe"
        let output = "p100\nn\(main)\np101\nn\(helper)\np102\nn/other/bottle/drive_c/Steam/steam.exe\np103\nn\(main).old\np104\nn/private/tmp/bottle/drive_c/Game/game.exe\npinvalid\nn\(main)\n"
        let snapshot = SteamClientProcessSnapshot.parse(output, mainPath: main, helperPaths: [helper])
        XCTAssertEqual(snapshot.steamPIDs, [100])
        XCTAssertEqual(snapshot.helperPIDs, [101])
        XCTAssertTrue(snapshot.hasClients)
        XCTAssertFalse(SteamClientProcessSnapshot.parse("", mainPath: main, helperPaths: []).hasClients)
    }
}
