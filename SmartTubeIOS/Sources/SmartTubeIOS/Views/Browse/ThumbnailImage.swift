import SmartTubeIOSCore
import SwiftUI
import os

#if canImport(UIKit)
import UIKit
private typealias PlatformImage = UIImage
#else
import AppKit
private typealias PlatformImage = NSImage
#endif

private let thumbnailLog = Logger(subsystem: appSubsystem, category: "Thumbnail")

// MARK: - ThumbnailImage
//
// AsyncImage replacement for YouTube thumbnails that walks an ordered URL chain.
//
// AsyncImage only reports `.failure` when the body can't be decoded. i.ytimg.com
// answers a missing size (maxresdefault/hq720/sddefault on low-res uploads) with
// HTTP 404 *and* a valid 120×90 grey "no thumbnail" JPEG, so AsyncImage shows that
// grey image as a success and never reaches the next fallback. This view treats
// any non-2xx status as a miss, remembers misses for the session so later cards
// skip straight to the size that exists, and does not advance the chain when the
// load is merely cancelled (cell scrolled away).

struct ThumbnailImage<Content: View, Placeholder: View>: View {
    /// Ordered candidates (duplicates dropped); the first one that loads wins.
    let urls: [URL]
    let content: (Image) -> Content
    /// `true` while still loading, `false` once every candidate failed.
    let placeholder: (_ isLoading: Bool) -> Placeholder

    init(
        urls: [URL],
        @ViewBuilder content: @escaping (Image) -> Content,
        @ViewBuilder placeholder: @escaping (_ isLoading: Bool) -> Placeholder
    ) {
        var seen = Set<URL>()
        self.urls = urls.filter { seen.insert($0).inserted }
        self.content = content
        self.placeholder = placeholder
    }

    @State private var loaded: Loaded?
    @State private var exhausted = false

    private struct Loaded {
        let urls: [URL]
        let image: Image
    }

    var body: some View {
        // Ignore a result that belongs to a previous URL chain (reused cell slot).
        let current = loaded.flatMap { $0.urls == urls ? $0.image : nil }
        Group {
            if let current {
                content(current)
            } else {
                placeholder(!exhausted)
            }
        }
        .task(id: urls) { await load() }
    }

    private func load() async {
        if loaded?.urls != urls {
            loaded = nil
            exhausted = false
        }
        guard loaded == nil else { return }
        for url in urls {
            switch await ThumbnailCache.shared.image(for: url) {
            case .loaded(let image):
                loaded = Loaded(urls: urls, image: image)
                return
            case .missing:
                continue
            case .cancelled:
                return
            }
        }
        exhausted = true
    }
}

// MARK: - ThumbnailCache

@MainActor
final class ThumbnailCache {
    static let shared = ThumbnailCache()

    enum Outcome {
        case loaded(Image)
        case missing
        case cancelled
    }

    private let images = NSCache<NSURL, PlatformImage>()
    /// URLs that answered non-2xx or undecodable data. Session-scoped: a missing
    /// maxresdefault doesn't appear later for an existing upload.
    private var missing: Set<URL> = []

    private init() {
        images.countLimit = 300
    }

    func image(for url: URL) async -> Outcome {
        if let cached = images.object(forKey: url as NSURL) { return .loaded(Image(platformImage: cached)) }
        if missing.contains(url) { return .missing }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(from: url)
        } catch {
            if Task.isCancelled || (error as? URLError)?.code == .cancelled { return .cancelled }
            // Transient network error: try the next candidate, but don't blacklist this URL.
            thumbnailLog.debug(
                "load failed \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
            return .missing
        }
        guard Self.isUsable(response), let image = PlatformImage(data: data) else {
            missing.insert(url)
            return .missing
        }
        images.setObject(image, forKey: url as NSURL)
        return .loaded(Image(platformImage: image))
    }

    /// Only 2xx counts: i.ytimg.com's 404 carries a decodable grey placeholder JPEG.
    nonisolated static func isUsable(_ response: URLResponse) -> Bool {
        guard let http = response as? HTTPURLResponse else { return true }
        return (200..<300).contains(http.statusCode)
    }
}

extension Image {
    fileprivate init(platformImage: PlatformImage) {
        #if canImport(UIKit)
        self.init(uiImage: platformImage)
        #else
        self.init(nsImage: platformImage)
        #endif
    }
}
