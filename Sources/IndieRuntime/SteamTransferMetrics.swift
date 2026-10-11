import Foundation

public enum SteamTransferMetrics {
    public static func progress(live: Double?, fallback: Double?) -> Double? {
        for value in [live,fallback].compactMap({ $0 }) where value.isFinite && value >= 0 && value <= 1 { return value }
        return nil
    }
    public static func bytes(downloaded: Double?, total: Double?) -> (downloaded:Double,total:Double)? {
        guard let downloaded, let total, downloaded.isFinite, total.isFinite,
              downloaded >= 0, total > 0, downloaded <= total else { return nil }
        return (downloaded,total)
    }
}
