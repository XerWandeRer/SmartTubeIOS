import Foundation
import os

// MARK: - ActiveChannel
//
// Process-wide selected Brand Account. Shared (not set per instance like setAuthToken)
// because many InnerTubeAPI instances exist and a missed one would silently hit the
// wrong channel. Read synchronously by InnerTubeAPI when building each request.

public final class ActiveChannel: Sendable {
    public static let shared = ActiveChannel()

    private let state = OSAllocatedUnfairLock<String?>(initialState: nil)

    public init() {}

    /// nil = primary account (no X-Goog-Pageid header).
    public var pageId: String? { state.withLock { $0 } }

    public func set(pageId: String?) {
        state.withLock { $0 = pageId }
    }

    /// Adds `X-Goog-Pageid` when a Brand Account is active. Call only on requests that carry
    /// the account's auth (Bearer or SAPISIDHASH) to www.youtube.com / youtubei.googleapis.com.
    public func apply(to request: inout URLRequest) {
        guard let pageId else { return }
        request.setValue(pageId, forHTTPHeaderField: "X-Goog-Pageid")
    }
}
