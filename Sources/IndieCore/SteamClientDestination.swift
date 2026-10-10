import Foundation

/// Navigation only. Steam owns installation, license prompts and download scheduling.
public enum SteamClientDestination: Equatable, Sendable {
    case library
    case downloads
    case storeFront
    case game(UInt64)
    case store(UInt64)

    public var uri: String {
        switch self {
        case .library: "steam://open/main"
        case .downloads: "steam://nav/downloads"
        case .storeFront: "steam://store"
        case .game(let id): "steam://nav/games/details/\(id)"
        case .store(let id): "steam://store/\(id)"
        }
    }

    public static func installDestination(appID: UInt64, owned: Bool) -> Self {
        owned ? .game(appID) : .store(appID)
    }

    public static func reusableDescriptor(_ descriptor: SteamSessionDescriptor?, bottleID: UUID,
                                          runtimeID: String, processExists: Bool) -> SteamSessionDescriptor? {
        guard processExists, let descriptor, descriptor.bottleID == bottleID,
              descriptor.runtimeID == runtimeID else { return nil }
        return descriptor
    }
}
