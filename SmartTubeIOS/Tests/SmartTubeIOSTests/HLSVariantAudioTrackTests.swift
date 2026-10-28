import Foundation
import Testing

@testable import SmartTubeIOSCore

// MARK: - HLSVariantAudioTrackTests

/// Initial audio track for YouTube's YT-EXT-AUDIO-CONTENT-ID manifests (WebView HLS path).
@Suite("HLS Variant Audio Track")
struct HLSVariantAudioTrackTests {
    /// When the original carries its own CONTENT-ID (`acont=original` in YT-EXT-XTAGS,
    /// seen on 3UiW-Yn_ERE), the initial proxy filter must be that ID, not nil: nil keeps
    /// only variants without a CONTENT-ID, matches none, and the proxy then serves every
    /// language — AVPlayer starts on the English AI dub listed first (XER-18).
    @Test func initialHLSVariantAudioTrack_originalWithContentID_filtersOnIt() {
        let manifest = """
            #EXTM3U
            #EXT-X-STREAM-INF:BANDWIDTH=2800000,RESOLUTION=1280x720,YT-EXT-XTAGS="ChQKBWFjb250EgtkdWJiZWQtYXV0bwoNCgRsYW5nEgVlbi1VUw",YT-EXT-AUDIO-CONTENT-ID="en-US.10"
            https://example.com/720p_en.m3u8
            #EXT-X-STREAM-INF:BANDWIDTH=2800000,RESOLUTION=1280x720,YT-EXT-XTAGS="ChEKBWFjb250EghvcmlnaW5hbAoPCgRsYW5nEgd6aC1IYW50",YT-EXT-AUDIO-CONTENT-ID="zh-Hant.4"
            https://example.com/720p_zh.m3u8
            """
        let tracks = parseHLSAudioLanguages(from: manifest)
        #expect(tracks.count == 2, "No synthetic Original when a real one is tagged")
        for preferred in [nil, "original", "ja"] {
            let initial = initialHLSVariantAudioTrack(in: tracks, preferred: preferred)
            #expect(initial?.contentID == "zh-Hant.4", "preferred=\(preferred ?? "nil")")
        }
        #expect(initialHLSVariantAudioTrack(in: tracks, preferred: "en-US")?.contentID == "en-US.10")
    }

    /// With an untagged original, the synthetic "Original" entry keeps the nil filter.
    @Test func initialHLSVariantAudioTrack_untaggedOriginal_keepsNilFilter() {
        let manifest = """
            #EXTM3U
            #EXT-X-STREAM-INF:BANDWIDTH=3000000,RESOLUTION=1280x720
            https://example.com/original.m3u8
            #EXT-X-STREAM-INF:BANDWIDTH=2800000,RESOLUTION=1280x720,YT-EXT-AUDIO-CONTENT-ID="ja-JP.1"
            https://example.com/ja.m3u8
            """
        let initial = initialHLSVariantAudioTrack(in: parseHLSAudioLanguages(from: manifest), preferred: "original")
        #expect(initial?.id == "yt-original-audio")
        #expect(initial?.contentID == nil)
    }
}
