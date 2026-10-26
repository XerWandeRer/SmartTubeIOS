import Foundation
import Observation

// MARK: - SearchViewModel
//
// Mirrors the Android `SearchPresenter`.

@MainActor
@Observable
public final class SearchViewModel {

    public var query: String = ""
    public var filter: SearchFilter = .default
    public private(set) var results: [Video] = []
    public private(set) var suggestions: [String] = []
    public private(set) var history: [SearchHistoryEntry] = []
    public private(set) var isLoading: Bool = false
    public var error: Error?

    private let api: any InnerTubeAPIProtocol
    private let historyStore: SearchHistoryStore
    private var nextPageToken: String?
    private var searchTask: Task<Void, Never>?
    private var suggestTask: Task<Void, Never>?
    private var hideObserverTasks: [Task<Void, Never>] = []

    private static let recommendedTerms: [String] = [
        "trending videos", "music 2025", "cooking recipes", "travel vlog",
        "programming tutorial", "workout", "movie trailer", "lofi hip hop",
        "documentary", "gaming highlights",
    ]

    /// History entries that match the current query (case-insensitive). Returns
    /// the full history when the query is empty.
    public var filteredHistory: [SearchHistoryEntry] {
        guard !query.isEmpty else { return history }
        return history.filter { $0.query.localizedCaseInsensitiveContains(query) }
    }

    public init(api: any InnerTubeAPIProtocol = InnerTubeAPI(), historyStore: SearchHistoryStore = .shared) {
        self.api = api
        self.historyStore = historyStore
        suggestions = Self.recommendedTerms
        Task { await loadHistory() }
        observeFeedHideNotifications()
    }

    /// Call from `.task(id: query)` in the view to debounce live suggestions.
    /// When `q` is empty, restores the recommended terms immediately.
    public func updateSuggestions(for q: String) async {
        print("[Suggestions] updateSuggestions called, q='\(q)'")
        if q.isEmpty {
            print("[Suggestions] Empty query — restoring recommendedTerms")
            suggestions = Self.recommendedTerms
            return
        }
        try? await Task.sleep(for: .milliseconds(300))
        guard !Task.isCancelled else {
            print("[Suggestions] Task cancelled before fetch")
            return
        }
        fetchSuggestions(for: q)
    }

    public func search() {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        results = []
        nextPageToken = nil
        searchTask?.cancel()
        searchTask = Task { await performSearch(query: trimmed, filter: filter) }
        Task { await recordSearch(trimmed) }
    }

    // MARK: - History management

    /// Loads history from the store into the published `history` property.
    public func loadHistory() async {
        history = await historyStore.all
    }

    /// Saves `query` to history and refreshes the in-memory list.
    private func recordSearch(_ query: String) async {
        await historyStore.add(query)
        history = await historyStore.all
    }

    /// Removes a single entry from history.
    public func removeHistoryEntry(_ query: String) {
        Task {
            await historyStore.remove(query)
            history = await historyStore.all
        }
    }

    /// Clears all history entries.
    public func clearHistory() {
        Task {
            await historyStore.clear()
            history = await historyStore.all
        }
    }

    /// Apply a new filter and re-run the current search immediately.
    public func applyFilter(_ newFilter: SearchFilter) {
        filter = newFilter
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        results = []
        nextPageToken = nil
        searchTask?.cancel()
        searchTask = Task { await performSearch(query: query, filter: filter) }
    }

    public func loadMore() {
        guard let token = nextPageToken, !isLoading else { return }
        searchTask = Task { await performSearch(query: query, continuationToken: token, filter: filter) }
    }

    private func performSearch(query: String, continuationToken: String? = nil, filter: SearchFilter = .default) async {
        isLoading = true
        defer { isLoading = false }
        do {
            let group = try await retryWithBackoff(label: "SearchVM") {
                try await api.search(query: query, continuationToken: continuationToken, filter: filter)
            }
            if continuationToken == nil {
                results = group.videos
            } else {
                results.append(contentsOf: group.videos)
            }
            nextPageToken = group.nextPageToken
        } catch {
            if !Task.isCancelled { self.error = error }
        }
    }

    private func fetchSuggestions(for query: String) {
        print("[Suggestions] fetchSuggestions spawning task for q='\(query)'")
        suggestTask?.cancel()
        suggestTask = Task {
            do {
                let s = try await api.fetchSearchSuggestions(query: query)
                guard !Task.isCancelled else {
                    print("[Suggestions] Task cancelled after fetch")
                    return
                }
                let result = s.isEmpty ? Self.recommendedTerms : s
                print("[Suggestions] Setting \(result.count) suggestions")
                suggestions = result
            } catch {
                print("[Suggestions] fetchSearchSuggestions threw: \(error)")
                if !Task.isCancelled { suggestions = Self.recommendedTerms }
            }
        }
    }

    // MARK: - Feed hide handling

    private func observeFeedHideNotifications() {
        hideObserverTasks.append(
            Task { [weak self] in
                for await note in NotificationCenter.default.notifications(named: .hideVideoFromFeed) {
                    guard let self, let videoId = note.userInfo?["videoId"] as? String else { continue }
                    self.results.removeAll { $0.id == videoId }
                }
            })
        hideObserverTasks.append(
            Task { [weak self] in
                for await note in NotificationCenter.default.notifications(named: .hideChannelFromFeed) {
                    guard let self, let channelId = note.userInfo?["channelId"] as? String else { continue }
                    self.results.removeAll { $0.channelId == channelId }
                }
            })
    }
}

// MARK: - ChannelViewModel

@MainActor
@Observable
public final class ChannelViewModel {

    public private(set) var channel: Channel?
    /// The channel's Videos tab, newest first. This is the only list that pages.
    public private(set) var videos: [Video] = []
    /// Shorts from the channel's Home tab. The Videos tab does not list Shorts, so they come
    /// from the Home shelf and are not paged.
    public private(set) var shorts: [Video] = []
    public private(set) var isLoading: Bool = false
    public var error: Error?

    private let api: any InnerTubeAPIProtocol
    private var nextPageToken: String?
    private var hideObserverTasks: [Task<Void, Never>] = []

    public init(api: any InnerTubeAPIProtocol = InnerTubeAPI()) {
        self.api = api
        observeFeedHideNotifications()
    }

    public func load(channelId: String) {
        Task { await loadAsync(channelId: channelId) }
    }

    func loadAsync(channelId: String) async {
        isLoading = true
        defer { isLoading = false }
        do {
            let (ch, home) = try await api.fetchChannel(channelId: channelId)
            channel = ch
            // The Home tab's continuation tokens are per shelf and return no videos, so paging
            // them stopped the list after the first page (#138). Page the Videos tab instead,
            // and keep Home for the header and the Shorts shelf.
            let grid = try? await retryWithBackoff(label: "ChannelVM") {
                try await api.fetchChannelVideos(channelId: ch.id, continuationToken: nil)
            }
            if let grid, !grid.videos.isEmpty {
                videos = grid.videos
                nextPageToken = grid.nextPageToken
            } else {
                // No Videos tab (or the request failed): show what Home has, as before.
                videos = home.videos
                nextPageToken = home.nextPageToken
            }
            var seen = Set<String>()
            shorts = (home.videos + videos).filter { $0.isShort && seen.insert($0.id).inserted }
        } catch {
            self.error = error
        }
    }

    public func loadMore() {
        Task { await loadMoreAsync() }
    }

    func loadMoreAsync() async {
        guard let id = channel?.id, let token = nextPageToken, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let group = try await retryWithBackoff(label: "ChannelVM") {
                try await api.fetchChannelVideos(channelId: id, continuationToken: token)
            }
            videos.append(contentsOf: group.videos)
            nextPageToken = group.nextPageToken
        } catch {
            self.error = error
        }
    }

    // MARK: - Feed hide handling

    private func observeFeedHideNotifications() {
        hideObserverTasks.append(
            Task { [weak self] in
                for await note in NotificationCenter.default.notifications(named: .hideVideoFromFeed) {
                    guard let self, let videoId = note.userInfo?["videoId"] as? String else { continue }
                    self.videos.removeAll { $0.id == videoId }
                    self.shorts.removeAll { $0.id == videoId }
                }
            })
        hideObserverTasks.append(
            Task { [weak self] in
                for await note in NotificationCenter.default.notifications(named: .hideChannelFromFeed) {
                    guard let self, let channelId = note.userInfo?["channelId"] as? String else { continue }
                    self.videos.removeAll { $0.channelId == channelId }
                    self.shorts.removeAll { $0.channelId == channelId }
                }
            })
    }
}
