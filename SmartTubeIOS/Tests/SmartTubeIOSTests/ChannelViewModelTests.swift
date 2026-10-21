import Foundation
import Testing

@testable import SmartTubeIOSCore

// MARK: - ChannelViewModelTests
//
// Regression tests for GitHub issue #138: a channel's video list stopped after the first page
// (about 50 items). The Home tab's continuation tokens are per shelf and return no videos, so
// the list must page the Videos tab instead. Shorts are not in the Videos tab; they come from
// the Home shelf.

@Suite("ChannelViewModel pagination")
@MainActor
struct ChannelViewModelTests {

    private struct FetchFailure: Error {}

    private func video(_ id: String, isShort: Bool = false) -> Video {
        Video(id: id, title: "Video \(id)", channelTitle: "Channel", isShort: isShort)
    }

    private func loadedVM(
        home: [Video], homeToken: String? = "home_shelf_token", videosTab: VideoGroup,
        videosTabError: Error? = nil
    ) async -> (ChannelViewModel, MockInnerTubeAPI) {
        let mock = MockInnerTubeAPI()
        mock.channelResult = (
            Channel(id: "UCchannel", title: "Channel"),
            VideoGroup(title: "Home", videos: home, nextPageToken: homeToken)
        )
        mock.channelVideosResult = videosTab
        mock.channelVideosError = videosTabError
        let vm = ChannelViewModel(api: mock)
        await vm.loadAsync(channelId: "UCchannel")
        return (vm, mock)
    }

    @Test("load() takes the first page from the Videos tab, not the Home shelves")
    func firstPageComesFromVideosTab() async {
        let (vm, mock) = await loadedVM(
            home: [video("homeOnly1")],
            videosTab: VideoGroup(title: "V", videos: [video("grid1"), video("grid2")], nextPageToken: "grid_p2"))

        #expect(vm.videos.map(\.id) == ["grid1", "grid2"])
        #expect(
            mock.calls.map(\.method) == ["fetchChannel", "fetchChannelVideos"],
            "Home supplies the header, the Videos tab supplies the list")
        #expect(mock.calls.last?.args == ["UCchannel", "nil"])
    }

    @Test("loadMore() continues with the Videos tab token, never the Home token")
    func loadMoreUsesVideosTabToken() async {
        let (vm, mock) = await loadedVM(
            home: [video("homeOnly1")],
            videosTab: VideoGroup(title: "V", videos: [video("grid1")], nextPageToken: "grid_p2"))

        mock.channelVideosResult = VideoGroup(title: "V", videos: [video("grid2")], nextPageToken: "grid_p3")
        await vm.loadMoreAsync()

        #expect(vm.videos.map(\.id) == ["grid1", "grid2"])
        #expect(mock.calls.last?.args == ["UCchannel", "grid_p2"])

        mock.channelVideosResult = VideoGroup(title: "V", videos: [video("grid3")])
        await vm.loadMoreAsync()

        #expect(vm.videos.map(\.id) == ["grid1", "grid2", "grid3"])
        #expect(mock.calls.last?.args == ["UCchannel", "grid_p3"])
        #expect(
            !mock.calls.contains { $0.args.contains("home_shelf_token") },
            "The per-shelf Home token returns no videos and must not be sent")
    }

    @Test("Shorts from the Home shelf land in shorts, not in the paged video list")
    func shortsComeFromHome() async {
        let (vm, _) = await loadedVM(
            home: [video("homeShort1", isShort: true), video("homeVideo1")],
            videosTab: VideoGroup(title: "V", videos: [video("grid1")], nextPageToken: "grid_p2"))

        #expect(vm.shorts.map(\.id) == ["homeShort1"])
        #expect(vm.videos.map(\.id) == ["grid1"])
    }

    @Test("An empty Videos tab falls back to the Home videos")
    func emptyVideosTabFallsBackToHome() async {
        let (vm, _) = await loadedVM(
            home: [video("homeVideo1")], videosTab: VideoGroup(title: "V", videos: []))

        #expect(vm.videos.map(\.id) == ["homeVideo1"])
    }

    @Test("A failing Videos tab still shows the Home page and does not raise an error")
    func failingVideosTabFallsBackToHome() async {
        let (vm, _) = await loadedVM(
            home: [video("homeVideo1"), video("homeShort1", isShort: true)],
            videosTab: VideoGroup(title: "V", videos: []), videosTabError: FetchFailure())

        #expect(vm.videos.map(\.id) == ["homeVideo1", "homeShort1"])
        #expect(vm.shorts.map(\.id) == ["homeShort1"])
        #expect(vm.error == nil)
    }
}
