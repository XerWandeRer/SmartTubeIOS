#if os(iOS)
import SmartTubeIOSCore
import SwiftUI

private let panLog = CrashlyticsLogger(category: "Player")

/// Window frame of the progress bar while the controls show it; nil otherwise.
struct PlayerScrubberFrameKey: PreferenceKey {
    static let defaultValue: CGRect? = nil

    static func reduce(value: inout CGRect?, nextValue: () -> CGRect?) {
        value = nextValue() ?? value
    }
}

extension View {
    /// Reports this view's window frame as the progress bar, so the player's pan leaves
    /// touches there to the scrub drag.
    func reportsScrubberFrame() -> some View {
        background {
            GeometryReader { geo in
                Color.clear.preference(key: PlayerScrubberFrameKey.self, value: geo.frame(in: .global))
            }
        }
    }
}

// MARK: - PlayerView pan
//
// The single pan from PlayerPanGestureInstaller, after its axis is locked:
// - horizontal: the content follows the finger; a release past 40 pt slides to the
//   next (left) or previous (right) video.
// - down, portrait: the resident player collapses under the finger
//   (ResidentPlayerLayer); the release decides between mini player and full screen.
// - down, landscape: no tracking; a release past 40 pt minimizes (rotating back to
//   portrait first is step 4 of XER-14).
extension PlayerView {
    /// Not while scrubbing, during a slide, or while a menu or picker is open (their
    /// own scroll views and drags take the touches).
    var isPanEnabled: Bool {
        !vm.isScrubbing && !isTransitioning
            && !(showMoreMenu || showQualityPicker || showSpeedPicker || showSleepTimerPicker || showCaptionPicker
                || showAudioTrackPicker || showDescriptionSheet || showCommentsSheet)
    }

    /// Collapse follows the finger only in portrait with the resident layer present.
    private var tracksCollapse: Bool { !vm.isLandscape && residentPlayer != nil }

    func panChanged(_ axis: PlayerPanAxis, translation: CGPoint) {
        switch axis {
        case .horizontal:
            guard !isTransitioning else { return }
            let dx = translation.x
            // Rubber-band when there is nothing to slide to.
            slideOffset = (dx < 0 && vm.hasNext) || (dx > 0 && vm.hasPrevious) ? dx : dx * 0.15
        case .down:
            guard tracksCollapse else { return }
            residentPlayer?.collapseDragChanged(translation.y)
        case .up:
            break
        }
    }

    func panEnded(
        _ axis: PlayerPanAxis,
        translation: CGPoint,
        velocity: CGPoint,
        cancelled: Bool,
        screenWidth: CGFloat
    ) {
        switch axis {
        case .horizontal:
            let direction = cancelled ? 0 : PlayerPanGesture.horizontalSwipe(translation: translation.x)
            panLog.debug(
                "[pan] horizontal end dx=\(translation.x) direction=\(direction) hasNext=\(vm.hasNext) hasPrevious=\(vm.hasPrevious)"
            )
            if direction < 0, vm.hasNext, !isTransitioning {
                performHorizontalTransition(direction: -1, screenWidth: screenWidth) { vm.playNext() }
            } else if direction > 0, vm.hasPrevious, !isTransitioning {
                performHorizontalTransition(direction: 1, screenWidth: screenWidth) { vm.playPrevious() }
            } else {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { slideOffset = 0 }
            }
        case .down:
            if tracksCollapse, let residentPlayer {
                residentPlayer.collapseDragEnded(translation.y, velocity.y)
            } else if !cancelled, translation.y > PlayerPanGesture.swipeDownDistance {
                if store.settings.miniPlayerEnabled { playerState.minimize() } else { playerState.stop() }
            }
        case .up:
            break
        }
    }
}
#endif
