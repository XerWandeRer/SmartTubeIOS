import Foundation
import os

// MARK: - PlayerResponseRecorder

/// Debug-only capture of raw `/player` responses as offline test fixtures.
///
/// Enabled by the `--uitesting-record-player-responses` launch argument. Every response
/// that reaches `parsePlayerInfo` is written to
/// `Documents/PlayerResponses/<videoId>-<method>-<CLIENT>.json` in the app container, where
/// `<method>` is the `--uitesting-force-stream-method` value (`auto` without it) and
/// `<CLIENT>` is the `c` value YouTube echoes in `responseContext.serviceTrackingParams`.
///
/// Responses are reduced to the keys the parser reads and scrubbed before writing:
/// the client IP in stream URLs becomes `0.0.0.0`, and account-bound `playbackTracking`
/// and `visitorData` are dropped. Release builds never record.
enum PlayerResponseRecorder {
    static let launchArgument = "--uitesting-record-player-responses"
    static let directoryName = "PlayerResponses"
    static let forcedMethodPrefix = "--uitesting-force-stream-method="
    /// Top-level keys kept in a fixture; everything else is dropped to keep fixtures small.
    static let keptKeys: Set<String> = [
        "playabilityStatus", "streamingData", "videoDetails", "captions", "endscreen",
    ]

    private static let log = Logger(subsystem: appSubsystem, category: "PlayerResponseRecorder")

    static func record(_ json: [String: Any], videoId: String) {
        #if DEBUG
        guard ProcessInfo.processInfo.arguments.contains(launchArgument),
            let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        else { return }
        let directory = documents.appendingPathComponent(directoryName, isDirectory: true)
        // Not every client echoes `c`, so the forced probe method names the file too.
        let method =
            ProcessInfo.processInfo.arguments
            .first { $0.hasPrefix(forcedMethodPrefix) }
            .map { String($0.dropFirst(forcedMethodPrefix.count)) } ?? "auto"
        let client = clientName(of: json) ?? "UNKNOWN"
        let file = directory.appendingPathComponent("\(videoId)-\(method)-\(client).json")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try JSONSerialization.data(
                withJSONObject: scrubbed(json), options: [.prettyPrinted, .sortedKeys])
            try data.write(to: file, options: .atomic)
            log.notice("recorded \(file.lastPathComponent, privacy: .public)")
        } catch {
            log.error("record failed for \(videoId, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
        #endif
    }

    /// The InnerTube client name YouTube echoes back, e.g. `IOS`, `VISIONOS`, `TVHTML5`.
    static func clientName(of json: [String: Any]) -> String? {
        let context = json["responseContext"] as? [String: Any]
        let services = context?["serviceTrackingParams"] as? [[String: Any]] ?? []
        for service in services {
            for param in service["params"] as? [[String: Any]] ?? [] where param["key"] as? String == "c" {
                return param["value"] as? String
            }
        }
        return nil
    }

    static func scrubbed(_ json: [String: Any]) -> [String: Any] {
        var kept = json.filter { keptKeys.contains($0.key) }
        if let client = clientName(of: json) {
            // Keep only the client marker so fixtures still identify their source.
            kept["responseContext"] = [
                "serviceTrackingParams": [["service": "CSI", "params": [["key": "c", "value": client]]]]
            ]
        }
        return scrubValue(kept) as? [String: Any] ?? [:]
    }

    private static func scrubValue(_ value: Any) -> Any {
        switch value {
        case let dict as [String: Any]:
            return dict.mapValues(scrubValue)
        case let array as [Any]:
            return array.map(scrubValue)
        case let string as String where string.contains("googlevideo.com"):
            return scrubIP(in: string)
        default:
            return value
        }
    }

    /// Replaces the client IP in `ip=<v>` query items (plain or percent-encoded inside
    /// `signatureCipher`) and `/ip/<v>/` path pairs.
    static func scrubIP(in url: String) -> String {
        url.replacingOccurrences(of: #"(?<=[?&]ip=)[^&]+"#, with: "0.0.0.0", options: .regularExpression)
            .replacingOccurrences(of: #"(?<=ip%3D)(?:(?!%26)[^&])+"#, with: "0.0.0.0", options: .regularExpression)
            .replacingOccurrences(of: #"(?<=/ip/)[^/]+"#, with: "0.0.0.0", options: .regularExpression)
    }
}
