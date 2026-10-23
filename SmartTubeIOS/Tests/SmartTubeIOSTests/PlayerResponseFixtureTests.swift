import Foundation
import Testing

@testable import SmartTubeIOSCore

// MARK: - PlayerResponseFixtureTests
//
// Offline tests for `parsePlayerInfo` against real `/player` responses recorded per client
// with `--uitesting-record-player-responses` (see PlayerResponseRecorder). Fixtures live in
// Fixtures/PlayerResponses as `<case>-<probe method>.json`, scrubbed of the client IP.
// Re-record them when YouTube changes a client's response shape; the expectations below
// describe what each client returned on 2026-10-23 (unauthenticated unless the name says
// signed-in).

@Suite("Player response fixtures")
struct PlayerResponseFixtureTests {

    private func makeAPI() -> InnerTubeAPI {
        InnerTubeAPI(authToken: nil, session: URLSession(configuration: .ephemeral))
    }

    private func fixture(_ name: String) throws -> [String: Any] {
        let url = try #require(
            Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures/PlayerResponses"))
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
        return try #require(object as? [String: Any])
    }

    private func parse(_ name: String, videoId: String) async throws -> PlayerInfo {
        try await makeAPI().parsePlayerInfo(from: try fixture(name), videoId: videoId)
    }

    // MARK: - Playable responses

    @Test("VisionOS VOD: token-free HLS plus direct adaptive URLs")
    func visionOSVod() async throws {
        let info = try await parse("vod-visionos", videoId: "dQw4w9WgXcQ")
        #expect(info.hlsURL != nil)
        #expect(!info.formats.isEmpty)
        #expect(info.formats.allSatisfy { $0.url != nil })
        #expect(info.formats.compactMap(\.url).allSatisfy { $0.absoluteString.contains("c=VISIONOS") })
        #expect(info.video.isLive == false)
        #expect(info.video.duration == 213)
    }

    @Test("VisionOS live: HLS manifest is the playable source")
    func visionOSLive() async throws {
        let info = try await parse("live-visionos", videoId: "0sfDth4lMLc")
        #expect(info.hlsURL != nil)
        #expect(info.video.isLive)
    }

    @Test("iOS VOD: HLS present, adaptive formats are cipher-only")
    func iOSVod() async throws {
        let info = try await parse("vod-ios", videoId: "dQw4w9WgXcQ")
        #expect(info.hlsURL != nil)
        #expect(info.formats.allSatisfy { $0.url == nil })
    }

    @Test("AndroidVR VOD: direct adaptive URLs, no HLS")
    func androidVRVod() async throws {
        let info = try await parse("vod-android-vr", videoId: "dQw4w9WgXcQ")
        #expect(info.hlsURL == nil)
        #expect(info.bestAdaptiveVideoURL != nil)
        #expect(info.bestAdaptiveAudioURL != nil)
    }

    // MARK: - Unplayable responses

    @Test("MWEB VOD: cipher-only formats without HLS are reported as needing decryption")
    func mwebCipherOnly() async throws {
        await expectUnavailable("vod-mweb", videoId: "dQw4w9WgXcQ", containing: "decryption")
    }

    @Test("iOS live: no HLS and cipher-only formats")
    func iOSLiveCipherOnly() async throws {
        await expectUnavailable("live-ios", videoId: "0sfDth4lMLc", containing: "decryption")
    }

    @Test("Embedded player: embedder identity denied surfaces the server reason")
    func embeddedDenied() async throws {
        await expectUnavailable("vod-tvembedded", videoId: "dQw4w9WgXcQ", containing: "unavailable")
    }

    @Test("Signed-in TVHTML5: 'page needs to be reloaded' surfaces as unavailable")
    func tvAuthReload() async throws {
        await expectUnavailable("vod-tvauth-signed-in", videoId: "dQw4w9WgXcQ", containing: "reloaded")
    }

    @Test("Age-restricted video without sign-in maps to signInRequired")
    func ageRestricted() async throws {
        do {
            _ = try await parse("age-restricted-visionos", videoId: "HtVdAasjOgU")
            Issue.record("expected signInRequired")
        } catch APIError.signInRequired {
        } catch {
            Issue.record("expected signInRequired, got \(error)")
        }
    }

    @Test("Upcoming live event surfaces the scheduled-start reason")
    func upcomingLive() async throws {
        await expectUnavailable("upcoming-visionos", videoId: "hv867HnY4j4", containing: "will begin")
    }

    // MARK: - Recorder

    @Test("Recorder scrubs the client IP from plain, percent-encoded and path forms")
    func recorderScrubsIP() {
        let plain = PlayerResponseRecorder.scrubIP(in: "https://r.googlevideo.com/videoplayback?a=1&ip=2605%3A52c0&id=x")
        #expect(plain == "https://r.googlevideo.com/videoplayback?a=1&ip=0.0.0.0&id=x")
        let cipher = PlayerResponseRecorder.scrubIP(in: "s=a&url=https%3A%2F%2Fr.googlevideo.com%3Fa%3D1%26ip%3D1.2.3.4%26id%3Dx")
        #expect(cipher == "s=a&url=https%3A%2F%2Fr.googlevideo.com%3Fa%3D1%26ip%3D0.0.0.0%26id%3Dx")
        let path = PlayerResponseRecorder.scrubIP(in: "https://manifest.googlevideo.com/api/manifest/hls_variant/ip/1.2.3.4/id/x")
        #expect(path == "https://manifest.googlevideo.com/api/manifest/hls_variant/ip/0.0.0.0/id/x")
    }

    @Test("Recorder keeps only parser keys and the client marker")
    func recorderReducesKeys() {
        let raw: [String: Any] = [
            "playabilityStatus": ["status": "OK"],
            "playbackTracking": ["videostatsPlaybackUrl": ["baseUrl": "https://s.youtube.com/x"]],
            "responseContext": [
                "visitorData": "secret",
                "serviceTrackingParams": [["service": "CSI", "params": [["key": "c", "value": "IOS"]]]],
            ],
        ]
        let scrubbed = PlayerResponseRecorder.scrubbed(raw)
        #expect(Set(scrubbed.keys) == ["playabilityStatus", "responseContext"])
        #expect(PlayerResponseRecorder.clientName(of: scrubbed) == "IOS")
        #expect((scrubbed["responseContext"] as? [String: Any])?["visitorData"] == nil)
    }

    // MARK: - Helpers

    private func expectUnavailable(_ name: String, videoId: String, containing text: String) async {
        do {
            _ = try await parse(name, videoId: videoId)
            Issue.record("\(name): expected APIError.unavailable")
        } catch APIError.unavailable(let reason) {
            #expect(reason.localizedCaseInsensitiveContains(text), "\(name): reason was \(reason)")
        } catch {
            Issue.record("\(name): expected APIError.unavailable, got \(error)")
        }
    }
}
