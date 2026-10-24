import Foundation

/// What the resident player shows at one point of the collapse/expand morph.
///
/// The video surface has the video's own aspect ratio (`videoFrame`'s size) and is
/// never resized during the morph; it is scaled by `scale` about the centre of
/// `clip` and clipped to `clip` with `cornerRadius`.
public struct ResidentPlayerMorph: Equatable, Sendable {
    /// Visible rect, in full-screen coordinates.
    public var clip: CGRect
    /// Scale of the video surface.
    public var scale: CGFloat
    public var cornerRadius: CGFloat
}

/// Pure geometry for the resident player: where the video sits at full screen and
/// how it morphs into the floating mini player. All rects are in full-screen
/// coordinates (origin at the screen's top-leading corner).
public enum ResidentPlayerGeometry {
    /// Aspect ratio used until the decoded size is known.
    public static let defaultAspectRatio: CGFloat = 16 / 9
    public static let defaultShortAspectRatio: CGFloat = 9 / 16

    /// The video's own frame on the full screen: `aspectRatio` (width / height)
    /// fitted into the screen and centred.
    public static func videoFrame(aspectRatio: CGFloat, screen: CGSize) -> CGRect {
        guard aspectRatio > 0, screen.width > 0, screen.height > 0 else {
            return CGRect(origin: .zero, size: screen)
        }
        let size =
            screen.width / screen.height > aspectRatio
            ? CGSize(width: screen.height * aspectRatio, height: screen.height)
            : CGSize(width: screen.width, height: screen.width / aspectRatio)
        return CGRect(
            x: (screen.width - size.width) / 2,
            y: (screen.height - size.height) / 2,
            width: size.width,
            height: size.height
        )
    }

    /// The visible rect at full screen: the video's frame when it is fitted, the whole
    /// screen when it fills. `fill` may be fractional while the mode change animates.
    public static func fullScreenClip(videoFrame: CGRect, screen: CGSize, fill: CGFloat) -> CGRect {
        lerp(videoFrame, CGRect(origin: .zero, size: screen), clamp(fill))
    }

    /// The morph at `progress` (1 = full screen, 0 = mini player). The clip moves
    /// linearly from `fullScreenClip` to `mini`, and the scale from the one that covers
    /// the full-screen clip to the one that fits the video into the mini player (never
    /// crop it there). While the mini player has the video's shape no frame shows bars;
    /// a video outside the mini player's aspect range ends letterboxed in it.
    public static func morph(
        progress: CGFloat,
        videoFrame: CGRect,
        fullScreenClip: CGRect,
        mini: CGRect
    ) -> ResidentPlayerMorph {
        let collapsed = 1 - clamp(progress)
        let fullScale = coverScale(of: videoFrame.size, over: fullScreenClip.size)
        let miniScale = fitScale(of: videoFrame.size, into: mini.size)
        return ResidentPlayerMorph(
            clip: lerp(fullScreenClip, mini, collapsed),
            scale: fullScale + (miniScale - fullScale) * collapsed,
            cornerRadius: MiniPlayerSnapping.cornerRadius * collapsed
        )
    }

    /// Smallest scale at which `size` covers `target`.
    static func coverScale(of size: CGSize, over target: CGSize) -> CGFloat {
        guard size.width > 0, size.height > 0 else { return 1 }
        return max(target.width / size.width, target.height / size.height)
    }

    /// Largest scale at which `size` fits inside `target`.
    static func fitScale(of size: CGSize, into target: CGSize) -> CGFloat {
        guard size.width > 0, size.height > 0 else { return 1 }
        return min(target.width / size.width, target.height / size.height)
    }

    /// `value` limited to 0...1.
    public static func clamp(_ value: CGFloat) -> CGFloat { min(1, max(0, value)) }

    static func lerp(_ from: CGRect, _ to: CGRect, _ fraction: CGFloat) -> CGRect {
        CGRect(
            x: from.minX + (to.minX - from.minX) * fraction,
            y: from.minY + (to.minY - from.minY) * fraction,
            width: from.width + (to.width - from.width) * fraction,
            height: from.height + (to.height - from.height) * fraction
        )
    }
}
