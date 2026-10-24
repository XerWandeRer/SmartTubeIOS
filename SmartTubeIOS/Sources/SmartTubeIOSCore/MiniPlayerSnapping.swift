import Foundation

/// Corner the floating mini player rests in.
public enum MiniPlayerCorner: String, CaseIterable, Sendable {
    case topLeading, topTrailing, bottomLeading, bottomTrailing

    /// Where the mini player first appears, before the user has moved it.
    public static let initial: MiniPlayerCorner = .bottomTrailing

    public var isTop: Bool { self == .topLeading || self == .topTrailing }
    public var isLeading: Bool { self == .topLeading || self == .bottomLeading }
}

/// Distance from each screen edge to the area the mini player may rest in.
/// Every value is measured from the matching edge of the full screen.
public struct MiniPlayerInsets: Equatable, Sendable {
    public var top: CGFloat
    public var leading: CGFloat
    public var bottom: CGFloat
    public var trailing: CGFloat

    public init(top: CGFloat, leading: CGFloat, bottom: CGFloat, trailing: CGFloat) {
        self.top = top
        self.leading = leading
        self.bottom = bottom
        self.trailing = trailing
    }
}

/// Pure geometry for the floating mini player: size, corner anchors, release
/// projection, target-corner choice and edge rubber-banding. All points are in
/// full-screen coordinates (origin at the screen's top-leading corner) and refer to
/// the mini player's centre.
public enum MiniPlayerSnapping {
    /// Mini player width as a fraction of the screen width.
    public static let widthFraction: CGFloat = 0.45
    public static let minimumWidth: CGFloat = 160
    public static let aspectRatio: CGFloat = 16 / 9
    public static let cornerRadius: CGFloat = 10
    /// Gap between the mini player and the safe area / tab bar / keyboard.
    public static let margin: CGFloat = 12
    /// Initial slope of the rubber band once the mini player crosses a screen edge.
    public static let rubberBandCoefficient: CGFloat = 0.3
    /// `UIScrollView.DecelerationRate.normal`.
    public static let decelerationRate: CGFloat = 0.998

    /// 16:9 size: `widthFraction` of the screen width, at least `minimumWidth`.
    public static func size(screenWidth: CGFloat) -> CGSize {
        let width = max(minimumWidth, (screenWidth * widthFraction).rounded())
        return CGSize(width: width, height: (width / aspectRatio).rounded())
    }

    /// Largest width the user can pinch the mini player to: the full width between
    /// the side margins, or the width whose 16:9 height is half the screen height,
    /// whichever is smaller (never below `minimumWidth`).
    public static func maximumWidth(screen: CGSize, obstructions: MiniPlayerInsets) -> CGFloat {
        let fullWidth = screen.width - obstructions.leading - obstructions.trailing - 2 * margin
        let halfHeightWidth = (screen.height / 2 * aspectRatio).rounded(.down)
        return max(minimumWidth, min(fullWidth, halfHeightWidth).rounded(.down))
    }

    /// Size for a user-chosen `scale` of the default size (1 = `size(screenWidth:)`),
    /// clamped between `minimumWidth` and `maximumWidth`. The default itself is clamped
    /// too, so in landscape it never exceeds half the screen height.
    public static func size(screen: CGSize, obstructions: MiniPlayerInsets, scale: CGFloat) -> CGSize {
        let base = size(screenWidth: screen.width).width
        let maximum = maximumWidth(screen: screen, obstructions: obstructions)
        let width = min(max((base * scale).rounded(), minimumWidth), maximum)
        return CGSize(width: width, height: (width / aspectRatio).rounded())
    }

    /// The scale that reproduces `width` on a screen of `screenWidth`.
    public static func scale(forWidth width: CGFloat, screenWidth: CGFloat) -> CGFloat {
        width / size(screenWidth: screenWidth).width
    }

    /// Centre of the mini player when it rests in `corner`.
    ///
    /// - Parameters:
    ///   - screen: full screen size.
    ///   - obstructions: safe area at the top and sides; at the bottom, whatever covers
    ///     the screen there (tab bar incl. home indicator, or the keyboard if taller).
    public static func anchor(
        for corner: MiniPlayerCorner,
        size: CGSize,
        screen: CGSize,
        obstructions: MiniPlayerInsets
    ) -> CGPoint {
        let minX = obstructions.leading + margin + size.width / 2
        let maxX = screen.width - obstructions.trailing - margin - size.width / 2
        let minY = obstructions.top + margin + size.height / 2
        let maxY = screen.height - obstructions.bottom - margin - size.height / 2
        return CGPoint(
            x: corner.isLeading ? minX : max(minX, maxX),
            y: corner.isTop ? minY : max(minY, maxY)
        )
    }

    /// Where a release at `position` with `velocity` (points per second) would coast
    /// to, using UIScrollView's deceleration projection.
    public static func project(
        _ position: CGPoint,
        velocity: CGVector,
        decelerationRate: CGFloat = decelerationRate
    ) -> CGPoint {
        let factor = decelerationRate / (1000 * (1 - decelerationRate))
        return CGPoint(x: position.x + velocity.dx * factor, y: position.y + velocity.dy * factor)
    }

    /// Corner for a projected centre: the screen quadrant it falls in, split at the
    /// screen's midX / midY.
    public static func corner(for projectedCenter: CGPoint, screen: CGSize) -> MiniPlayerCorner {
        let top = projectedCenter.y < screen.height / 2
        let leading = projectedCenter.x < screen.width / 2
        switch (top, leading) {
        case (true, true): return .topLeading
        case (true, false): return .topTrailing
        case (false, true): return .bottomLeading
        case (false, false): return .bottomTrailing
        }
    }

    /// Target corner for a release at `position` with `velocity`.
    public static func targetCorner(
        releasedAt position: CGPoint,
        velocity: CGVector,
        screen: CGSize
    ) -> MiniPlayerCorner {
        corner(for: project(position, velocity: velocity), screen: screen)
    }

    /// Applies edge resistance to a dragged centre. Inside the screen the centre is
    /// returned unchanged; past an edge the overshoot is damped so that at most half
    /// the mini player can leave the screen and its body always stays on it.
    public static func rubberBanded(_ center: CGPoint, size: CGSize, screen: CGSize) -> CGPoint {
        CGPoint(
            x: rubberBand(center.x, lower: size.width / 2, upper: screen.width - size.width / 2, limit: size.width / 2),
            y: rubberBand(
                center.y, lower: size.height / 2, upper: screen.height - size.height / 2, limit: size.height / 2)
        )
    }

    /// UIScrollView-style rubber band: `(1 - 1 / (x * c / d + 1)) * d`, where `x` is the
    /// overshoot, `c` the coefficient and `d` the asymptotic maximum overshoot.
    static func rubberBand(_ value: CGFloat, lower: CGFloat, upper: CGFloat, limit: CGFloat) -> CGFloat {
        guard limit > 0, upper >= lower else { return value }
        func damp(_ overshoot: CGFloat) -> CGFloat {
            (1 - 1 / (overshoot * rubberBandCoefficient / limit + 1)) * limit
        }
        if value < lower { return lower - damp(lower - value) }
        if value > upper { return upper + damp(value - upper) }
        return value
    }
}
