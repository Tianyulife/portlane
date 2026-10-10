import Foundation

public enum AppBrand {
    public static let name = "Portlane"
    /// Older installed runtime manifests retain their original metadata.
    public static func runtimeDisplayName(_ value: String) -> String {
        value.replacingOccurrences(of: "Mac Gaming Uncle", with: name)
    }
}
