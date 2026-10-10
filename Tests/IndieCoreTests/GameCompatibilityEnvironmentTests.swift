import XCTest
@testable import IndieCore

final class GameCompatibilityEnvironmentTests: XCTestCase {
    func testOldConfigurationDecodesWithoutNewFields() throws {
        let original = GameConfiguration.steam(appID: 2358720)
        var json = try JSONSerialization.jsonObject(with: IndieJSON.encoder().encode(original)) as! [String: Any]
        json.removeValue(forKey: "dllOverrides")
        json.removeValue(forKey: "environmentVariables")
        let decoded = try IndieJSON.decoder().decode(GameConfiguration.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(decoded.dllOverrides)
        XCTAssertNil(decoded.environmentVariables)
        XCTAssertEqual(decoded.id, original.id)
    }

    func testPerGameOverridesPreserveRendererAndOtherGameDefaults() throws {
        let base = ["WINEDLLOVERRIDES": "dxgi,d3d11,d3d12=n,b;mscoree=b", "D3DM_MTL4": "1"]
        var wukong = GameConfiguration.steam(appID: 2358720)
        wukong.updatedAt = Date(timeIntervalSince1970: 1_700_000_000)
        wukong.dllOverrides = ["mscoree": .builtin, "example": .disabled]
        wukong.environmentVariables = ["MY_GAME_FLAG": "a=b"]
        let applied = try GameCompatibilityEnvironment.applying(wukong, to: base)
        XCTAssertEqual(applied["WINEDLLOVERRIDES"], "dxgi,d3d11,d3d12=n,b;mscoree=b;example=;mscoree=b")
        XCTAssertEqual(applied["D3DM_MTL4"], "1")
        XCTAssertEqual(applied["MY_GAME_FLAG"], "a=b")
        XCTAssertEqual(try GameCompatibilityEnvironment.applying(.steam(appID: 2001120), to: base), base)
        XCTAssertTrue(wukong.isCustomized)
        let roundTrip = try IndieJSON.decoder().decode(GameConfiguration.self, from: IndieJSON.encoder().encode(wukong))
        XCTAssertEqual(roundTrip, wukong)
    }

    func testInvalidOverridesCannotChangeBottleOrSteamIdentity() {
        for name in ["WINEPREFIX", "SteamAppId", "STEAMGAMEID", "WINEDLLOVERRIDES", "DYLD_INSERT_LIBRARIES", "BAD=NAME"] {
            var configuration = GameConfiguration.steam(appID: 2358720)
            configuration.environmentVariables = [name: "value"]
            XCTAssertThrowsError(try GameCompatibilityEnvironment.validate(configuration), name)
        }
        var configuration = GameConfiguration.steam(appID: 2358720)
        configuration.dllOverrides = ["dxgi;mscoree": .builtin]
        XCTAssertThrowsError(try GameCompatibilityEnvironment.validate(configuration))
    }
}
