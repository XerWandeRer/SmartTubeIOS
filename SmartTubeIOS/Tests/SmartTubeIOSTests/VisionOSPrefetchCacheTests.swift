import Foundation
import Testing

@testable import SmartTubeIOSCore

@Suite("VisionOS prefetch cache")
struct VisionOSPrefetchCacheTests {

    private func makeInfo(_ videoId: String) -> PlayerInfo {
        PlayerInfo(
            video: Video(id: videoId, title: "T", channelTitle: "C", thumbnailURL: nil),
            formats: [],
            hlsURL: URL(string: "https://manifest.googlevideo.com/api/manifest/hls_variant/id/\(videoId)"),
            dashURL: nil, captionTracks: [], trackingURLs: nil, endCards: []
        )
    }

    @Test("a prefetched VisionOS response is returned apart from iOS player info")
    func storesInItsOwnSlot() async {
        let videoId = "visionos-slot-\(Int.random(in: 0..<Int.max))"
        await VideoPreloadCache.shared.store(visionOSPlayerInfo: makeInfo(videoId), for: videoId)
        let cached = await VideoPreloadCache.shared.consume(videoId: videoId)
        #expect(cached.visionOSPlayerInfo?.video.id == videoId)
        #expect(cached.playerInfo == nil)
    }

    @Test("invalidating player info also drops the VisionOS response")
    func invalidationDropsVisionOS() async {
        let videoId = "visionos-evict-\(Int.random(in: 0..<Int.max))"
        await VideoPreloadCache.shared.store(visionOSPlayerInfo: makeInfo(videoId), for: videoId)
        await VideoPreloadCache.shared.invalidatePlayerInfo(for: videoId)
        let cached = await VideoPreloadCache.shared.consume(videoId: videoId)
        #expect(cached.visionOSPlayerInfo == nil)
    }

    @Test("a VisionOS response counts towards a complete cache entry")
    func visionOSCompletesEntry() async {
        let videoId = "visionos-complete-\(Int.random(in: 0..<Int.max))"
        await VideoPreloadCache.shared.store(visionOSPlayerInfo: makeInfo(videoId), for: videoId)
        await VideoPreloadCache.shared.store(
            nextInfo: NextInfo(relatedVideos: [], likeStatus: .none, chapters: []), for: videoId)
        await VideoPreloadCache.shared.store(sponsorSegments: [], for: videoId)
        let cached = await VideoPreloadCache.shared.consume(videoId: videoId)
        #expect(cached.isComplete)
    }

    @Test("no in-flight VisionOS fetch is reported for an unknown video")
    func noInFlightByDefault() async {
        let videoId = "visionos-none-\(Int.random(in: 0..<Int.max))"
        let task = await VideoPreloadCache.shared.inFlightVisionOSFetch(videoId: videoId)
        #expect(task == nil)
    }
}
