import Foundation
import Testing

@testable import SmartTubeIOSCore

// MARK: - HomeInterleaveTests
//
// XER-17: the merged Home feed slots one subscription video after every 4
// recommendations. Subscriptions never trail the feed on their own; leftover
// ones wait for the next page of recommendations.

@Suite("Home feed interleave")
@MainActor
struct HomeInterleaveTests {

    private static let homeId = BrowseSection.SectionType.home.rawValue
    private static let subsId = BrowseSection.SectionType.subscriptions.rawValue

    private func recs(_ range: Range<Int>) -> [Video] { range.map { makeVideo(String(format: "rec%03d_AAAA", $0)) } }
    private func subs(_ range: Range<Int>) -> [Video] { range.map { makeVideo(String(format: "sub%03d_BBBB", $0)) } }

    private func loadedHomeVM(recs: [Video], recsToken: String? = nil, subs: [Video]) async -> HomeViewModel {
        let mock = MockInnerTubeAPI()
        mock.homeRowsResult = [VideoGroup(title: "Rec", videos: recs, nextPageToken: recsToken)]
        mock.subscriptionsResult = VideoGroup(title: "Subs", videos: subs, nextPageToken: "subs_tok")
        let vm = HomeViewModel(api: mock)
        vm.load()
        await waitUntil { vm.loadedAt != nil }
        return vm
    }

    @Test("rebuild places one subscription after every 4 recommendations and no trailing subscriptions")
    func interleaveHasNoSubscriptionTail() async {
        let vm = await loadedHomeVM(recs: recs(0..<8), subs: subs(0..<10))
        defer { vm.cancel() }

        let recIds = recs(0..<8).map(\.id)
        let subIds = subs(0..<10).map(\.id)
        #expect(vm.mergedVideos.map(\.id) == Array(recIds[0..<4]) + [subIds[0]] + Array(recIds[4..<8]) + [subIds[1]])
        // The other 8 subscriptions wait for more recommendations instead of trailing the feed.
        #expect(vm.sections.first { $0.id == Self.subsId }?.videos.count == 10)
    }

    @Test("subscriptions make up 1 in 5 of the merged feed")
    func interleaveRatioIsOneInFive() async {
        // 20 = the first page cap (InnerTubeClients.maxVideoResults) on both sections.
        let vm = await loadedHomeVM(recs: recs(0..<20), subs: subs(0..<20))
        defer { vm.cancel() }

        let ids = vm.mergedVideos.map(\.id)
        #expect(ids.count == 25)
        #expect(ids.filter { $0.hasPrefix("sub") }.count == 5)
        for (index, id) in ids.enumerated() {
            #expect(id.hasPrefix("sub") == ((index + 1) % 5 == 0), "position \(index): \(id)")
        }
    }

    @Test("Shorts from subscriptions never take an interleave slot")
    func interleaveSkipsSubscriptionShorts() async {
        let short = Video(id: "subshort_CCC", title: "S", channelTitle: "C", isShort: true)
        let vm = await loadedHomeVM(recs: recs(0..<4), subs: [short] + subs(0..<2))
        defer { vm.cancel() }

        #expect(vm.mergedVideos.map(\.id) == recs(0..<4).map(\.id) + [subs(0..<1)[0].id])
        #expect(vm.homeShortsVideos.map(\.id).contains("subshort_CCC"))
    }

    @Test("loadMore of recommendations keeps the slot cadence and the existing prefix")
    func loadMoreRecommendationsContinuesInterleave() async {
        let mock = MockInnerTubeAPI()
        mock.homeRowsResult = [VideoGroup(title: "Rec", videos: recs(0..<6), nextPageToken: "rec_tok")]
        mock.subscriptionsResult = VideoGroup(title: "Subs", videos: subs(0..<10), nextPageToken: nil)
        let vm = HomeViewModel(api: mock)
        defer { vm.cancel() }
        vm.load()
        await waitUntil { vm.loadedAt != nil }
        let before = vm.mergedVideos.map(\.id)
        let recIds = recs(0..<12).map(\.id)
        let subIds = subs(0..<10).map(\.id)
        #expect(before == Array(recIds[0..<4]) + [subIds[0]] + Array(recIds[4..<6]))

        mock.homeRowsResult = [VideoGroup(title: "Rec", videos: recs(6..<12), nextPageToken: nil)]
        vm.loadMore(sectionId: Self.homeId)
        await waitUntil { vm.mergedVideos.count > before.count }

        // Slot count runs across pages: recs 7–8 complete the second group of 4.
        let appended = Array(recIds[6..<8]) + [subIds[1]] + Array(recIds[8..<12]) + [subIds[2]]
        #expect(vm.mergedVideos.map(\.id) == before + appended)
    }

    @Test("loadMore of subscriptions refills the pool without appending to the feed")
    func loadMoreSubscriptionsOnlyRefillsPool() async {
        let mock = MockInnerTubeAPI()
        mock.homeRowsResult = [VideoGroup(title: "Rec", videos: recs(0..<4), nextPageToken: nil)]
        mock.subscriptionsResult = VideoGroup(title: "Subs", videos: subs(0..<2), nextPageToken: "subs_tok")
        let vm = HomeViewModel(api: mock)
        defer { vm.cancel() }
        vm.load()
        await waitUntil { vm.loadedAt != nil }
        let before = vm.mergedVideos.map(\.id)

        mock.subscriptionsResult = VideoGroup(title: "Subs", videos: subs(2..<12), nextPageToken: nil)
        vm.loadMore(sectionId: Self.subsId)
        await waitUntil { vm.sections.first { $0.id == Self.subsId }?.videos.count == 12 }

        #expect(vm.mergedVideos.map(\.id) == before)
    }

    @Test("with no recommendations the feed falls back to subscriptions alone")
    func subscriptionsOnlyFallback() async {
        let vm = await loadedHomeVM(recs: [], subs: subs(0..<5))
        defer { vm.cancel() }

        #expect(vm.mergedVideos.map(\.id) == subs(0..<5).map(\.id))
    }

    /// Yields until `condition` holds or `timeout` passes. Mock fetches complete
    /// within a few hops of the main actor, so no wall-clock sleep is needed.
    private func waitUntil(timeout: TimeInterval = 2, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline { await Task.yield() }
    }

    private func makeVideo(_ id: String) -> Video {
        Video(id: id, title: "Video \(id)", channelTitle: "Channel")
    }
}
