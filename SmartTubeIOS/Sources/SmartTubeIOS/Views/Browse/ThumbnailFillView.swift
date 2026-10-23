import SwiftUI

// MARK: - ThumbnailFillView
//
// Loads a thumbnail URL and fills its frame with the image, cropped to fit
// (scaledToFill + clipped). Falls back through `fallbackURLs` on load error
// (including HTTP 404, see ThumbnailImage).
//
// Uses GeometryReader to give the image explicit pixel dimensions so that
// scaledToFill is always constrained to exactly the offered frame — the only
// reliable way to prevent SwiftUI layout bleed with fill-mode images.

struct ThumbnailFillView: View {
    /// Primary URL to try first.
    let primaryURL: URL?
    /// Ordered fallbacks tried after `primaryURL` fails.
    var fallbackURLs: [URL] = []

    var body: some View {
        GeometryReader { geo in
            ThumbnailImage(urls: [primaryURL].compactMap { $0 } + fallbackURLs) { img in
                img.resizable()
                    .scaledToFill()
                    .frame(width: geo.size.width, height: geo.size.height)
                    .clipped()
            } placeholder: { isLoading in
                if isLoading {
                    Color.secondary.opacity(0.15)
                        .overlay { ProgressView().tint(.white) }
                } else {
                    Color.secondary.opacity(0.15)
                }
            }
        }
    }
}
