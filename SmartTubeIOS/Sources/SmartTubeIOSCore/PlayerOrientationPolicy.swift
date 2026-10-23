import Foundation

/// Pure orientation decision for the full-screen player: the video's aspect ratio
/// picks landscape or portrait, not the device sensor.
///
/// The first guess comes from `Video.isShort`. Once the player reports the decoded
/// size, `confirmAspect` replaces the guess — once per video, so later quality
/// switches cannot flip the orientation mid-playback. A manual toggle overrides
/// both for the current video only.
public struct PlayerOrientationPolicy: Equatable, Sendable {
    public private(set) var videoID: String?
    public private(set) var videoIsLandscape = true
    public private(set) var isAspectConfirmed = false
    /// Set by the manual orientation toggle; cleared when another video begins.
    public private(set) var manualLandscape: Bool?

    public init() {}

    public var wantsLandscape: Bool { manualLandscape ?? videoIsLandscape }

    /// Starts tracking `videoID`. Re-entering the same video (e.g. expanding the
    /// mini player) keeps the size already confirmed for it and the manual choice.
    public mutating func begin(videoID: String, isShort: Bool) {
        guard videoID != self.videoID else { return }
        self.videoID = videoID
        videoIsLandscape = !isShort
        isAspectConfirmed = false
        manualLandscape = nil
    }

    /// Flips the current orientation for this video.
    public mutating func toggleManually() {
        manualLandscape = !wantsLandscape
    }

    /// Applies the decoded size of `videoID`. Returns `true` when this changed
    /// `videoIsLandscape`. Sizes for another video, empty sizes and sizes after the
    /// first confirmed one are ignored.
    @discardableResult
    public mutating func confirmAspect(videoID: String, width: Double, height: Double) -> Bool {
        guard videoID == self.videoID, !isAspectConfirmed, width > 0, height > 0 else { return false }
        isAspectConfirmed = true
        let landscape = width >= height
        defer { videoIsLandscape = landscape }
        return landscape != videoIsLandscape
    }
}
