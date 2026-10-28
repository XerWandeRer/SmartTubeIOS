import Foundation
import SmartTubeIOSCore
import os

// MARK: - PlaybackProbeLog

/// Debug-only, machine-readable playback outcome records for scripted regression runs.
///
/// Each record is one `os.Logger` line in category `PlaybackProbe`, formatted as
/// `PROBE event=<start|ready|error> video=<id> key=value …` with public privacy so
/// `log stream --predicate 'category == "PlaybackProbe"'` on a Simulator (or
/// `idevicesyslog` on a device) can assert pass/fail without parsing free-form logs.
///
/// Fields:
/// - `forced`: value of `--uitesting-force-stream-method`, or `none`.
/// - `ms`: elapsed time since `load()`.
/// - `client` / `itag` / `kind`: read from the stream URL handed to AVPlayer
///   (`c=` / `itag=` query items or `/key/value` path pairs); for HLS manifests the
///   client comes from the response's format URLs and `itag` is `abr`.
/// - `type`: `lastSuccessfulStreamType` of the winning load path.
/// - `stage` records (`event=stage`) time the steps between `start` and `ready`.
///
/// Release builds compile every call to a no-op.
enum PlaybackProbeLog {
    #if DEBUG
    private static let logger = Logger(subsystem: appSubsystem, category: "PlaybackProbe")
    #endif

    static func start(videoId: String) {
        #if DEBUG
        let forced = StreamMethodProbeSupport.forcedStreamMethod ?? "none"
        logger.notice("PROBE event=start video=\(videoId, privacy: .public) forced=\(forced, privacy: .public)")
        #endif
    }

    /// `infoURL`: any format URL of the `PlayerInfo` that was played. HLS manifest URLs
    /// carry no `c=` parameter, so the client is read from the response's format URLs.
    static func ready(videoId: String, elapsedMs: Int, streamURL: URL?, infoURL: URL?, streamType: String) {
        #if DEBUG
        var fields = streamFields(streamURL)
        if fields.client == "unknown" { fields.client = streamFields(infoURL).client }
        logger.notice(
            "PROBE event=ready video=\(videoId, privacy: .public) ms=\(elapsedMs, privacy: .public) client=\(fields.client, privacy: .public) itag=\(fields.itag, privacy: .public) kind=\(fields.kind, privacy: .public) type=\(streamType, privacy: .public)"
        )
        #endif
    }

    /// One step of the startup path, e.g. `stage=player`. `ms` is the time since `load()`
    /// when the step finished; `dur` (when known) is the step's own duration. `detail` is
    /// appended verbatim and must already be space-separated `key=value` pairs.
    static func stage(_ name: String, videoId: String, elapsedMs: Int, durationMs: Int? = nil, detail: String = "") {
        #if DEBUG
        let dur = durationMs.map { " dur=\($0)" } ?? ""
        let extra = detail.isEmpty ? "" : " \(detail)"
        logger.notice(
            "PROBE event=stage video=\(videoId, privacy: .public) stage=\(name, privacy: .public) ms=\(elapsedMs, privacy: .public)\(dur, privacy: .public)\(extra, privacy: .public)"
        )
        #endif
    }

    static func error(videoId: String, elapsedMs: Int, streamURL: URL?, error: Error) {
        #if DEBUG
        let fields = streamFields(streamURL)
        let nsError = error as NSError
        // Single-line value: the record is parsed as space-separated key=value pairs.
        let message = String(describing: error)
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\"", with: "'")
        logger.error(
            "PROBE event=error video=\(videoId, privacy: .public) ms=\(elapsedMs, privacy: .public) client=\(fields.client, privacy: .public) domain=\(nsError.domain, privacy: .public) code=\(nsError.code, privacy: .public) message=\"\(message, privacy: .public)\""
        )
        #endif
    }

    struct StreamFields: Equatable {
        var client: String
        var itag: String
        var kind: String
    }

    /// Extracts the signing client, itag and stream kind from a googlevideo URL.
    static func streamFields(_ url: URL?) -> StreamFields {
        guard let url else { return StreamFields(client: "none", itag: "none", kind: "none") }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let segments = url.pathComponents
        func value(_ key: String) -> String? {
            if let query = items.first(where: { $0.name == key })?.value, !query.isEmpty { return query }
            // HLS manifest URLs carry parameters as /key/value path pairs.
            if let index = segments.firstIndex(of: key), index + 1 < segments.count { return segments[index + 1] }
            return nil
        }
        let kind: String
        if url.isFileURL {
            kind = "local"
        } else if url.path.contains("/manifest/hls") || url.pathExtension == "m3u8" {
            kind = "hls"
        } else if url.path.contains("/manifest/dash") {
            kind = "dash"
        } else if url.host?.hasSuffix("googlevideo.com") == true {
            kind = "direct"
        } else {
            kind = url.scheme ?? "unknown"
        }
        // HLS manifests always carry itag/0; the variant is chosen later by AVPlayer.
        let itag = kind == "hls" ? "abr" : (value("itag") ?? "none")
        return StreamFields(client: value("c") ?? "unknown", itag: itag, kind: kind)
    }
}

extension PlaybackViewModel {
    /// Logs a startup stage of `videoId`; `stepStart` is when the step began.
    func probeStage(_ name: String, videoId: String, since stepStart: Date? = nil, detail: String = "") {
        #if DEBUG
        let now = Date()
        PlaybackProbeLog.stage(
            name, videoId: videoId,
            elapsedMs: Int(now.timeIntervalSince(videoLoadStartedAt) * 1000),
            durationMs: stepStart.map { Int(now.timeIntervalSince($0) * 1000) },
            detail: detail)
        #endif
    }
}
