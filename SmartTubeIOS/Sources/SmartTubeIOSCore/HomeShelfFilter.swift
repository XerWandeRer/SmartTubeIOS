import Foundation

// MARK: - HomeShelfFilter
//
// The signed-in TVHTML5 home feed (FEwhat_to_watch) mixes the user's own shelves
// ("Recommended", "Recently uploaded") with shelves YouTube curates for everyone,
// e.g. "New music videos this week" or a promoted book-series round-up. The home
// parsers flatten every shelf into one list, so a curated shelf shows up as a run
// of unrelated videos in the middle of the personal feed.
//
// Curated shelves carry a "YouTube featured" badge in their header:
//
//   shelfRenderer.headerRenderer.shelfHeaderRenderer.avatarLockup
//     .avatarLockupRenderer.badges[].metadataBadgeRenderer.style
//       == "BADGE_STYLE_TYPE_YPC_TRANSPARENT"
//
// The style is a structural enum, so the rule works whatever the account's UI
// language is (the shelf title and badge label are localised). Personal shelves
// have no badge. Continuation pages (horizontalListContinuation) have no shelf
// headers and pass through unchanged.

public enum HomeShelfFilter {

    /// Header badge style YouTube uses on the shelves it curates for everyone.
    static let curatedBadgeStyle = "BADGE_STYLE_TYPE_YPC_TRANSPARENT"

    /// Returns `response` without the curated shelves, plus the titles of the
    /// shelves it removed (for logging).
    public static func removingCuratedShelves(
        from response: [String: Any]
    ) -> (response: [String: Any], removedTitles: [String]) {
        var removed: [String] = []
        let filtered = strip(response, removed: &removed, depth: 0)
        return ((filtered as? [String: Any]) ?? response, removed)
    }

    /// `true` when `shelf` (the value of a `shelfRenderer` key) is curated by YouTube.
    static func isCurated(_ shelf: [String: Any]) -> Bool {
        guard let badges = headerLockup(of: shelf)?["badges"] as? [[String: Any]] else { return false }
        return badges.contains {
            ($0["metadataBadgeRenderer"] as? [String: Any])?["style"] as? String == curatedBadgeStyle
        }
    }

    private static func headerLockup(of shelf: [String: Any]) -> [String: Any]? {
        let header =
            (shelf["headerRenderer"] as? [String: Any])?["shelfHeaderRenderer"] as? [String: Any]
        return (header?["avatarLockup"] as? [String: Any])?["avatarLockupRenderer"] as? [String: Any]
    }

    private static func title(of shelf: [String: Any]) -> String {
        guard let title = headerLockup(of: shelf)?["title"] as? [String: Any] else { return "?" }
        if let simple = title["simpleText"] as? String { return simple }
        let runs = (title["runs"] as? [[String: Any]]) ?? []
        return runs.compactMap { $0["text"] as? String }.joined()
    }

    /// Depth cap matching the deepest renderer walk in the parsers.
    private static let maxDepth = 50

    private static func strip(_ node: Any, removed: inout [String], depth: Int) -> Any {
        guard depth < maxDepth else { return node }
        if let dict = node as? [String: Any] {
            var copy = dict
            for (key, value) in dict where value is [String: Any] || value is [Any] {
                copy[key] = strip(value, removed: &removed, depth: depth + 1)
            }
            return copy
        }
        if let array = node as? [Any] {
            return array.compactMap { item -> Any? in
                if let shelf = (item as? [String: Any])?["shelfRenderer"] as? [String: Any], isCurated(shelf) {
                    removed.append(title(of: shelf))
                    return nil
                }
                return strip(item, removed: &removed, depth: depth + 1)
            }
        }
        return node
    }
}
