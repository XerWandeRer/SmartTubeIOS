import Foundation
import Testing

@testable import SmartTubeIOSCore

// MARK: - HomeShelfFilterTests
//
// XER-17: the signed-in TV home feed (FEwhat_to_watch) carries shelves YouTube
// curates for everyone ("YouTube featured"), which the home parsers flattened into
// the personal feed. Fixtures in Fixtures/HomeResponses are real TVHTML5 responses
// recorded on 2026-10-28, rebuilt to the fields the parsers read; tiles in the
// account's own shelves carry placeholder IDs ("personalNNN") and titles.
//
//  - tv-home-new-music-shelf: Recommended, "本週新上架的音樂影片" (featured), Shorts
//  - tv-home-featured-books-shelf: Recommended, an ACOTAR round-up (featured), Recently uploaded
//  - tv-home-continuation: a horizontalListContinuation page (no shelf headers)

@Suite("Home curated-shelf filter")
struct HomeShelfFilterTests {

    private static let newMusicIds = ["-5ZXrO_lYSA", "tAg4Fa1JtPo", "qAAifLfNnKQ", "37kT408ETtg", "_PWSiM3uUZA"]
    private static let booksIds = ["raiUOXyzV2k", "BozFv-6eN3k", "aYhz3aq1eIQ", "tQoS8F251Uc", "0zCsj1WRIjo"]

    private func fixture(_ name: String) throws -> [String: Any] {
        let url = try #require(
            Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures/HomeResponses"))
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
        return try #require(object as? [String: Any])
    }

    /// Parses fixture `name` the way `fetchHome` (Recommended tab, `flat`) or
    /// `fetchHomeRows` (Home tab) does, optionally through the curated-shelf filter.
    /// Each call loads its own copy: `[String: Any]` is not Sendable, so the JSON
    /// handed to the parser actor must not be used afterwards.
    private struct Parsed {
        var ids: [String]
        var token: String?
        var removed: [String]
    }

    private func parse(_ name: String, flat: Bool, filtered: Bool) async throws -> Parsed {
        var json = try fixture(name)
        var removed: [String] = []
        if filtered { (json, removed) = HomeShelfFilter.removingCuratedShelves(from: json) }
        let api = InnerTubeAPI()
        if flat {
            let group = try await api.parseVideoGroupForTesting(json, title: "Home")
            return Parsed(ids: group.videos.map(\.id), token: group.nextPageToken, removed: removed)
        }
        let rows = await api.parseVideoGroupRowsForTesting(json)
        return Parsed(ids: rows.flatMap(\.videos).map(\.id), token: rows.last?.nextPageToken, removed: removed)
    }

    @Test("drops the localised new-music shelf and keeps the personal shelves", arguments: [true, false])
    func dropsNewMusicShelf(flat: Bool) async throws {
        let before = try await parse("tv-home-new-music-shelf", flat: flat, filtered: false)
        #expect(Set(Self.newMusicIds).isSubset(of: before.ids), "fixture must reproduce the bug")

        let after = try await parse("tv-home-new-music-shelf", flat: flat, filtered: true)

        #expect(after.removed == ["本週新上架的音樂影片"])
        #expect(Set(after.ids).isDisjoint(with: Self.newMusicIds))
        #expect(Set(after.ids) == Set(before.ids).subtracting(Self.newMusicIds))
        #expect(after.ids.contains("personal002"))
    }

    @Test("drops a promoted round-up shelf and keeps Recently uploaded", arguments: [true, false])
    func dropsFeaturedBooksShelf(flat: Bool) async throws {
        let after = try await parse("tv-home-featured-books-shelf", flat: flat, filtered: true)

        #expect(after.removed.count == 1)
        #expect(Set(after.ids).isDisjoint(with: Self.booksIds))
        #expect(after.ids.contains("personal009"), "Recently uploaded shelf must survive")
        #expect(after.ids.allSatisfy { $0.hasPrefix("personal") })
    }

    @Test("the home feed keeps a continuation token after filtering", arguments: [true, false])
    func keepsContinuationToken(flat: Bool) async throws {
        let after = try await parse("tv-home-new-music-shelf", flat: flat, filtered: true)
        #expect(after.token?.hasPrefix("CONTINUATION_TOKEN") == true)
    }

    @Test("continuation pages pass through unchanged")
    func continuationPageUnchanged() async throws {
        let before = try await parse("tv-home-continuation", flat: true, filtered: false)
        let after = try await parse("tv-home-continuation", flat: true, filtered: true)

        #expect(after.removed.isEmpty)
        #expect(!before.ids.isEmpty)
        #expect(after.ids == before.ids)
    }

    // MARK: - Rule

    private func shelf(title: String, badge: [String: Any]?) -> [String: Any] {
        var lockup: [String: Any] = ["title": ["simpleText": title]]
        if let badge { lockup["badges"] = [["metadataBadgeRenderer": badge]] }
        return ["headerRenderer": ["shelfHeaderRenderer": ["avatarLockup": ["avatarLockupRenderer": lockup]]]]
    }

    @Test("the rule reads the badge style, not the localised title or label")
    func ruleIsStructural() {
        let style = HomeShelfFilter.curatedBadgeStyle
        #expect(HomeShelfFilter.isCurated(shelf(title: "本週熱門", badge: ["label": "YouTube 精選", "style": style])))
        #expect(!HomeShelfFilter.isCurated(shelf(title: "New music videos this week", badge: nil)))
        #expect(!HomeShelfFilter.isCurated(shelf(title: "Recommended", badge: nil)))
        #expect(
            !HomeShelfFilter.isCurated(
                shelf(title: "Live", badge: ["label": "LIVE", "style": "BADGE_STYLE_TYPE_LIVE_NOW"]))
        )
    }
}
