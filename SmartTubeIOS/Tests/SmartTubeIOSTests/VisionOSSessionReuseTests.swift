import Foundation
import Testing

@testable import SmartTubeIOSCore

// MARK: - URLProtocol serving a watch page and scripted VisionOS /player replies

private final class VisionOSSessionURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var watchPageRequests = 0
    nonisolated(unsafe) static var homePageRequests = 0
    nonisolated(unsafe) static var playerRequests = 0
    /// Player replies in order; the last one repeats.
    nonisolated(unsafe) static var playerReplies: [[String: Any]] = []
    nonisolated(unsafe) static var sentVisitorIds: [String] = []

    override static func canInit(with request: URLRequest) -> Bool { true }
    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url,
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)
        else { return }
        let body: Data
        if url.path == "/watch" || url.path == "/" || url.path.isEmpty {
            if url.path == "/watch" { Self.watchPageRequests += 1 } else { Self.homePageRequests += 1 }
            let pages = Self.watchPageRequests + Self.homePageRequests
            let html = #"<script>ytcfg.set({"VISITOR_DATA":"visitor-\#(pages)"});</script>"#
            body = Data(html.utf8)
        } else {
            let reply = Self.playerReplies[min(Self.playerRequests, Self.playerReplies.count - 1)]
            Self.playerRequests += 1
            Self.sentVisitorIds.append(request.value(forHTTPHeaderField: "X-Goog-Visitor-Id") ?? "")
            body = (try? JSONSerialization.data(withJSONObject: reply)) ?? Data()
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    static func reset(replies: [[String: Any]]) {
        watchPageRequests = 0
        homePageRequests = 0
        playerRequests = 0
        playerReplies = replies
        sentVisitorIds = []
    }
}

private func playableReply() -> [String: Any] {
    [
        "playabilityStatus": ["status": "OK"],
        "streamingData": ["hlsManifestUrl": "https://manifest.googlevideo.com/api/manifest/hls_variant/id/x"],
        "videoDetails": ["videoId": "abcdefghijk", "title": "t"],
    ]
}

private func loginRequiredReply() -> [String: Any] {
    ["playabilityStatus": ["status": "LOGIN_REQUIRED", "reason": "Sign in to confirm you're not a bot"]]
}

private func makeAPI() -> InnerTubeAPI {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [VisionOSSessionURLProtocol.self]
    return InnerTubeAPI(authToken: nil, session: URLSession(configuration: config))
}

@Suite("VisionOS session reuse", .serialized)
struct VisionOSSessionReuseTests {

    @Test("the watch page is fetched once and its visitorData reused")
    func reusesSeededSession() async throws {
        VisionOSSessionURLProtocol.reset(replies: [playableReply()])
        let api = makeAPI()
        _ = try await api.fetchPlayerInfoVisionOS(videoId: "abcdefghijk")
        _ = try await api.fetchPlayerInfoVisionOS(videoId: "bcdefghijkl")
        #expect(VisionOSSessionURLProtocol.watchPageRequests == 1)
        #expect(VisionOSSessionURLProtocol.playerRequests == 2)
        #expect(VisionOSSessionURLProtocol.sentVisitorIds == ["visitor-1", "visitor-1"])
    }

    @Test("LOGIN_REQUIRED on a reused session reseeds and retries once")
    func reseedsStaleSession() async throws {
        VisionOSSessionURLProtocol.reset(replies: [playableReply(), loginRequiredReply(), playableReply()])
        let api = makeAPI()
        _ = try await api.fetchPlayerInfoVisionOS(videoId: "abcdefghijk")
        _ = try await api.fetchPlayerInfoVisionOS(videoId: "bcdefghijkl")
        #expect(VisionOSSessionURLProtocol.watchPageRequests == 2)
        #expect(VisionOSSessionURLProtocol.sentVisitorIds == ["visitor-1", "visitor-1", "visitor-2"])
    }

    @Test("LOGIN_REQUIRED on a fresh session is not retried")
    func freshSessionFailsOnce() async {
        VisionOSSessionURLProtocol.reset(replies: [loginRequiredReply()])
        let api = makeAPI()
        await #expect(throws: APIError.self) {
            _ = try await api.fetchPlayerInfoVisionOS(videoId: "abcdefghijk")
        }
        #expect(VisionOSSessionURLProtocol.watchPageRequests == 1)
        #expect(VisionOSSessionURLProtocol.playerRequests == 1)
    }

    @Test("clearing visitorData drops the cached VisionOS session")
    func resetDropsSession() async throws {
        VisionOSSessionURLProtocol.reset(replies: [playableReply()])
        let api = makeAPI()
        _ = try await api.fetchPlayerInfoVisionOS(videoId: "abcdefghijk")
        await api.resetVisitorData()
        _ = try await api.fetchPlayerInfoVisionOS(videoId: "bcdefghijkl")
        #expect(VisionOSSessionURLProtocol.watchPageRequests == 2)
    }

    @Test("a load after the launch prewarm reuses its session")
    func prewarmSeedsSession() async throws {
        VisionOSSessionURLProtocol.reset(replies: [playableReply()])
        let api = makeAPI()
        await api.prewarmVisionOSSession()
        await api.prewarmVisionOSSession()
        _ = try await api.fetchPlayerInfoVisionOS(videoId: "abcdefghijk")
        #expect(VisionOSSessionURLProtocol.homePageRequests == 1)
        #expect(VisionOSSessionURLProtocol.watchPageRequests == 0)
        #expect(VisionOSSessionURLProtocol.sentVisitorIds == ["visitor-1"])
    }

    @Test("a load during the prewarm joins it instead of fetching a second page")
    func loadJoinsInFlightPrewarm() async throws {
        VisionOSSessionURLProtocol.reset(replies: [playableReply()])
        let api = makeAPI()
        async let prewarm: Void = api.prewarmVisionOSSession()
        async let info = api.fetchPlayerInfoVisionOS(videoId: "abcdefghijk")
        _ = try await (prewarm, info)
        #expect(VisionOSSessionURLProtocol.homePageRequests + VisionOSSessionURLProtocol.watchPageRequests == 1)
    }
}
