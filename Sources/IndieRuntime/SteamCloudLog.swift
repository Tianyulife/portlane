import Foundation

public enum SteamCloudState: String, Codable, Sendable {
    case unknown, checking, downloading, uploading, synced, failed
    public var blocksRestart: Bool { self == .checking || self == .downloading || self == .uploading || self == .failed }
}

public struct SteamCloudUploadRequirement: Codable, Sendable, Equatable {
    public let appID: UInt64
    public let accountID: UInt64?
    public let beganAt: Date

    public init(appID: UInt64, accountID: UInt64?, beganAt: Date) {
        self.appID = appID
        self.accountID = accountID
        self.beganAt = beganAt
    }
}

/// Observations of Steam's own log, never writes to remotecache.vdf or save files.
/// Unknown formats and missing/rotated logs cannot acknowledge an upload.
public enum SteamCloudLog {
    public struct Observation: Sendable, Equatable {
        public var states: [UInt64: SteamCloudState] = [:]
        public var exitUploads: [UInt64: Date] = [:]
        public var accounts: [UInt64: UInt64] = [:]

        public func confirms(_ requirement: SteamCloudUploadRequirement) -> Bool {
            guard let account = requirement.accountID, accounts[requirement.appID] == account,
                  let completed = exitUploads[requirement.appID] else { return false }
            return completed >= requirement.beganAt && states[requirement.appID] == .synced
        }
    }

    public static func accountID(steamDirectory: URL) -> UInt64? {
        let text = tail(steamDirectory.appendingPathComponent("logs/connection_log.txt"))
        guard let range = text.range(of: "[U:1:", options: .backwards) else { return nil }
        guard let account = UInt64(text[range.upperBound...].prefix(while: { $0.isNumber })), account > 0 else { return nil }
        return account
    }

    public static func read(steamDirectory: URL, since: Date) -> Observation {
        parse(tail(steamDirectory.appendingPathComponent("logs/cloud_log.txt")), since: since)
    }

    public static func parse(_ text: String, since: Date, timeZone: TimeZone = .current) -> Observation {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        var result = Observation()
        var exitUpload = Set<UInt64>()
        var upload = Set<UInt64>()
        // Swift treats CRLF as one Character; splitting on LF misses Steam's
        // Windows logs. Accept each newline Character, including CRLF.
        for line in text.split(whereSeparator: \.isNewline) {
            guard line.first == "[", line.count > 21,
                  let date = formatter.date(from: String(line.dropFirst().prefix(19))),
                  date >= since,
                  let marker = line.range(of: "[AppID "),
                  let appID = UInt64(line[marker.upperBound...].prefix(while: { $0.isNumber })), appID != 7 else { continue }
            let message = String(line[marker.upperBound...].drop(while: { $0 != "]" }).dropFirst()).trimmingCharacters(in: .whitespaces)
            let lower = message.lowercased()
            if let user = lower.range(of: "autocloud checking local state for user "),
               let steamID = UInt64(lower[user.upperBound...].prefix(while: { $0.isNumber })),
               steamID >= 76561197960265728 {
                let account = steamID - 76561197960265728
                if let previous = result.accounts[appID], previous != account {
                    result.exitUploads[appID] = nil
                    result.states[appID] = .unknown
                    upload.remove(appID)
                    exitUpload.remove(appID)
                }
                result.accounts[appID] = account
            }
            if let userdata = lower.range(of: "userdata/"),
               let account = UInt64(lower[userdata.upperBound...].prefix(while: { $0.isNumber })) {
                if let previous = result.accounts[appID], previous != account {
                    result.exitUploads[appID] = nil
                    result.states[appID] = .unknown
                    upload.remove(appID)
                    exitUpload.remove(appID)
                }
                result.accounts[appID] = account
            }
            if lower.hasPrefix("starting sync (") {
                exitUpload.remove(appID)
                upload.remove(appID)
                if lower.hasPrefix("starting sync (up,") {
                    result.exitUploads[appID] = nil
                    upload.insert(appID)
                    if lower.contains("exit,") { exitUpload.insert(appID) }
                    result.states[appID] = .uploading
                } else if lower.hasPrefix("starting sync (down,") {
                    result.states[appID] = .downloading
                } else if lower.hasPrefix("starting sync (eval,") {
                    result.states[appID] = .checking
                }
            } else if lower.contains(" - failed") || lower.contains("failed for '") || lower.contains("result failure") ||
                        lower.hasPrefix("sync failed") || lower.hasPrefix("conflict") || lower.contains("cloud conflict") ||
                        (lower.hasPrefix("upload complete, result ") && lower != "upload complete, result ok") {
                result.states[appID] = .failed
                result.exitUploads[appID] = nil
            } else if upload.contains(appID) && (lower == "upload complete, result ok" || lower == "upload complete in build list") {
                result.states[appID] = .synced
                if exitUpload.contains(appID) { result.exitUploads[appID] = date }
                upload.remove(appID)
            } else if lower.hasPrefix("successfully synced to changenumber "), !upload.contains(appID) {
                result.states[appID] = .synced
            } else if lower == "eval complete", result.states[appID] == .checking {
                // Evaluation against a local cache is not an upload acknowledgement.
                result.states[appID] = result.exitUploads[appID] == nil ? .unknown : .synced
            }
        }
        return result
    }

    private static func tail(_ file: URL) -> String {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return "" }
        defer { try? handle.close() }
        do {
            let end = try handle.seekToEnd()
            let offset = end > 2_000_000 ? end - 2_000_000 : 0
            try handle.seek(toOffset: offset)
            var text = String(decoding: try handle.readToEnd() ?? Data(), as: UTF8.self)
            // Normalize before boundary checks so complete CRLF lines are
            // retained and a partially written final acknowledgement is dropped.
            text = text.replacingOccurrences(of: "\r\n", with: "\n")
            if offset > 0 { text = text.firstIndex(of: "\n").map { String(text[text.index(after: $0)...]) } ?? "" }
            // A partial final line cannot be a terminal acknowledgement.
            if !text.hasSuffix("\n") { text = text.lastIndex(of: "\n").map { String(text[...$0]) } ?? "" }
            return text
        } catch { return "" }
    }
}
