import Foundation
import SmartTubeIOSCore

extension AuthService {

    // MARK: - Channels (Brand Accounts)

    public var activeChannel: YouTubeChannel? {
        channels.first { $0.pageId == activePageId }
    }

    /// Switches every InnerTube request to `channel`. The OAuth token stays the primary
    /// account's; only `X-Goog-Pageid` changes, so no new sign-in is needed.
    public func selectChannel(_ channel: YouTubeChannel) {
        guard channel.pageId != activePageId else { return }
        authLog.notice("selectChannel() — \(channel.isPrimary ? "primary" : "brand account")")
        setActivePageId(channel.pageId)
        accountName = channel.name
        accountAvatarURL = channel.avatarURL
        saveToKeychain()
    }

    /// accounts_list is only fetched at sign-in, so the list is empty after a relaunch.
    public func loadChannelsIfNeeded() async {
        guard isSignedIn, channels.isEmpty else { return }
        do { try await fetchUserInfo() } catch {
            authLog.error("loadChannelsIfNeeded() failed: \(String(describing: error))")
        }
    }

    /// Applies the accounts_list result; drops a stored pageId the account no longer has.
    func applyChannels(_ list: [YouTubeChannel]) {
        guard !list.isEmpty else { return }
        channels = list
        if let pageId = activePageId, !list.contains(where: { $0.pageId == pageId }) {
            authLog.notice("applyChannels() — stored Brand Account not found, back to primary")
            setActivePageId(nil)
        }
    }

    func setActivePageId(_ pageId: String?) {
        activePageId = pageId
        ActiveChannel.shared.set(pageId: pageId)
        Task { await tokenManager.setPageId(pageId) }
        NotificationCenter.default.post(name: .activeChannelDidChange, object: nil)
    }

    func resetChannels() {
        channels = []
        activePageId = nil
        ActiveChannel.shared.set(pageId: nil)
    }
}
