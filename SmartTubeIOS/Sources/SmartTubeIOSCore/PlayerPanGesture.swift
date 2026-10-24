import Foundation

/// The direction a pan on the full-screen player is locked to on its first movement.
public enum PlayerPanAxis: Equatable, Sendable {
    /// Previous / next video.
    case horizontal
    /// Collapse towards the mini player.
    case down
    /// Not used; the pan is ignored.
    case up
}

/// Pure decisions for the full-screen player's single pan gesture: which axis it
/// locks to, how far a downward drag has collapsed the player, and what a release
/// does. Translations and velocities are in points and points per second, positive
/// to the right and downwards.
public enum PlayerPanGesture {
    /// Finger travel for a full collapse, as a fraction of the screen height.
    public static let collapseTravelFraction: CGFloat = 0.4
    /// A release whose projected progress falls below this collapses the player.
    public static let collapseThreshold: CGFloat = 0.5
    /// Minimum horizontal travel for a swipe to previous / next video.
    public static let horizontalSwipeDistance: CGFloat = 40
    /// Minimum downward travel for the discrete (landscape) swipe down.
    public static let swipeDownDistance: CGFloat = 40

    /// Axis for the first movement; nil until the finger has moved.
    public static func axis(for translation: CGVector) -> PlayerPanAxis? {
        guard translation.dx != 0 || translation.dy != 0 else { return nil }
        if abs(translation.dx) > abs(translation.dy) { return .horizontal }
        return translation.dy > 0 ? .down : .up
    }

    /// Finger travel for progress to go from 1 (full screen) to 0 (mini player).
    public static func collapseTravel(screenHeight: CGFloat) -> CGFloat {
        max(1, screenHeight * collapseTravelFraction)
    }

    /// Progress while dragging down: 1 at rest, 0 after `travel`. Dragging above the
    /// starting point does not expand past full screen.
    public static func progress(translation: CGFloat, travel: CGFloat) -> CGFloat {
        ResidentPlayerGeometry.clamp(1 - max(0, translation) / max(1, travel))
    }

    /// Distance a release with `velocity` would coast, using UIScrollView's normal
    /// deceleration (the same projection as the mini player's snap).
    public static func projectedDistance(velocity: CGFloat) -> CGFloat {
        let rate = MiniPlayerSnapping.decelerationRate
        return velocity * rate / (1000 * (1 - rate))
    }

    /// Whether releasing a downward drag collapses the player: the projected end
    /// point's progress is below `collapseThreshold`.
    public static func shouldCollapse(translation: CGFloat, velocity: CGFloat, travel: CGFloat) -> Bool {
        let projected = 1 - (translation + projectedDistance(velocity: velocity)) / max(1, travel)
        return projected < collapseThreshold
    }

    /// Initial velocity for a spring that animates progress from `progress` to
    /// `target`, as SwiftUI expects it: fractions of the animated distance per second.
    /// A finger moving down (positive velocity) lowers progress.
    public static func springVelocity(
        velocity: CGFloat,
        travel: CGFloat,
        from progress: CGFloat,
        to target: CGFloat
    ) -> CGFloat {
        let distance = target - progress
        guard abs(distance) > 0.001, travel > 0 else { return 0 }
        return (-velocity / travel) / distance
    }

    /// Previous (+1) or next (-1) video for a horizontal release, 0 if too short.
    /// Swiping left (negative translation) goes to the next video.
    public static func horizontalSwipe(translation: CGFloat) -> CGFloat {
        guard abs(translation) > horizontalSwipeDistance else { return 0 }
        return translation < 0 ? -1 : 1
    }
}
