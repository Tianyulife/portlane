import Foundation

public enum DLLLoadOrder: String, Codable, CaseIterable, Sendable {
    case builtin = "b"
    case nativeFirst = "n,b"
    case builtinFirst = "b,n"
    case disabled = ""
}

public enum GameCompatibilityEnvironment {
    public static func validate(_ configuration: GameConfiguration) throws {
        let variables = configuration.environmentVariables ?? [:]
        let overrides = configuration.dllOverrides ?? [:]
        guard variables.count <= 64, overrides.count <= 64 else {
            throw IndieError.invalidArgument(L("兼容设置最多允许 64 项"))
        }
        let reserved: Set<String> = ["WINEPREFIX", "WINEDLLOVERRIDES", "STEAMAPPID", "STEAMGAMEID",
            "PATH", "HOME", "DYLD_LIBRARY_PATH", "WINEDLLPATH_PREPEND", "DYLD_INSERT_LIBRARIES"]
        for (name, value) in variables {
            guard name.range(of: #"^[A-Za-z_][A-Za-z0-9_]{0,127}$"#, options: .regularExpression) != nil,
                  !reserved.contains(name.uppercased()), !name.uppercased().hasPrefix("MGU_"),
                  value.utf8.count <= 4096, !value.contains("\0"), !value.contains("\n"), !value.contains("\r") else {
                throw IndieError.invalidArgument(L("环境变量无效或由运行管理器保留：\(name)"))
            }
        }
        for name in overrides.keys {
            guard name.range(of: #"^[A-Za-z0-9_.-]{1,128}$"#, options: .regularExpression) != nil else {
                throw IndieError.invalidArgument(L("DLL 名称无效：\(name)"))
            }
        }
    }

    /// Apply user choices after built-in renderer and game compatibility rules.
    /// DLL entries are appended so unrelated renderer overrides are preserved.
    public static func applying(_ configuration: GameConfiguration, to base: [String: String]) throws -> [String: String] {
        try validate(configuration)
        var result = base
        result.merge(configuration.environmentVariables ?? [:]) { _, user in user }
        let entries = (configuration.dllOverrides ?? [:]).sorted { $0.key < $1.key }
            .map { "\($0.key.lowercased())=\($0.value.rawValue)" }.joined(separator: ";")
        if !entries.isEmpty {
            result["WINEDLLOVERRIDES"] = [result["WINEDLLOVERRIDES"], entries]
                .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ";")
        }
        return result
    }
}
