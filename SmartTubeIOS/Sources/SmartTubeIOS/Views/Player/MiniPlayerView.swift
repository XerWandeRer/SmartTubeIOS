#if os(iOS)
import SwiftUI
import AVFoundation
import UIKit
import SmartTubeIOSCore

private let miniPlayerLog = CrashlyticsLogger(category: "MiniPlayer")

// MARK: - MiniPlayerView

/// YouTube-style floating mini player shown over MainTabView when the player is
/// minimized: a rounded window shaped like the video (16:9 for landscape videos,
/// upright 9:16 for portrait ones) with the live video (the shared
/// PersistentPlayerHostView), a play/pause and a close button.
///
/// - Tap the video to expand back to the full-screen player.
/// - Drag to move it; it follows the finger 1:1 (rubber-banded at the screen edges)
///   and on release flies to the corner its projected end point falls in.
/// - Pinch to resize, up to the full width or half the screen height.
///
/// Corner and size are persisted across launches.
///
/// The view fills the overlay it is placed in, but only the window itself takes
/// touches; everything around it stays interactive. Geometry lives in
/// `MiniPlayerSnapping` (SmartTubeIOSCore).
struct MiniPlayerView: View {
    @Environment(PlayerStateStore.self) private var playerState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Height covered at the bottom of the screen by the tab bar incl. home indicator.
    let tabBarBottomInset: CGFloat

    @AppStorage(Self.cornerDefaultsKey) private var storedCorner = MiniPlayerCorner.initial.rawValue
    /// User-chosen size as a multiple of the default size; clamped when applied.
    @AppStorage(Self.scaleDefaultsKey) private var storedScale = 1.0

    /// Centre (screen coordinates) when the current drag began; nil when not dragging.
    @State private var dragStartCenter: CGPoint?
    /// Displacement from the current corner's anchor. Separate axes so the snap can
    /// give each its own spring with its own initial velocity.
    @State private var offsetX: CGFloat = 0
    @State private var offsetY: CGFloat = 0
    /// Picked up: slightly larger with a deeper shadow, from drag start until the snap ends.
    @State private var isLifted = false
    /// Bottom safe-area inset including the keyboard: the keyboard's height while it is
    /// shown, otherwise the home-indicator inset.
    @State private var keyboardAwareBottomInset: CGFloat = 0
    /// Last drag or pinch update; taps and button presses right after one belong to it.
    @State private var lastDragActivity: Date?
    /// Latest drag translation, kept while a pinch overrides the drag.
    @State private var lastDragTranslation: CGSize = .zero
    /// A drag gesture is tracking a finger (even while a pinch overrides it).
    @State private var isDragTouchActive = false
    /// Scale when the current pinch began; nil when not pinching.
    @State private var pinchStartScale: CGFloat?
    /// Live scale during a pinch.
    @State private var pinchScale: CGFloat?
    /// Centre (screen coordinates) kept fixed while pinching.
    @State private var pinchCenter: CGPoint?
    /// Aspect ratio (width / height) of the decoded video, once the player reports it.
    @State private var decodedAspect: DecodedAspect?

    private struct DecodedAspect: Equatable {
        var videoID: String
        var aspect: CGFloat
    }

    static let cornerDefaultsKey = "miniPlayer.corner"
    static let scaleDefaultsKey = "miniPlayer.scale"
    private static let dragMinimumDistance: CGFloat = 8
    /// How long after a drag a tap or button release still counts as part of it.
    private static let dragTapSuppression: TimeInterval = 0.35
    private static let liftedScale: CGFloat = 1.03
    private static let snapSpring = Spring(response: 0.35, dampingRatio: 0.8)
    private static let reducedMotionAnimation = Animation.easeOut(duration: 0.2)
    private static let relayoutAnimation = Animation.spring(response: 0.35, dampingFraction: 0.8)
    private static let aspectPollAttempts = 120
    private static let aspectPollInterval = Duration.milliseconds(250)

    /// Accessibility identifiers; UITests (PlayerAndMiniPlayerUITests) query these.
    private enum AXID {
        static let bar = "miniPlayer.bar"
        static let playPauseButton = "miniPlayer.playPauseButton"
        static let closeButton = "miniPlayer.closeButton"
    }

    /// Shape of the window: the decoded video's aspect ratio, else the full player's
    /// orientation decision for this video, else the Shorts flag.
    private var videoAspect: CGFloat {
        let video = playerState.vm.currentVideo
        if let decodedAspect, decodedAspect.videoID == video?.id { return decodedAspect.aspect }
        let policy = PlayerOrientationController.shared.policy
        if let video, policy.videoID == video.id {
            return policy.videoIsLandscape ? MiniPlayerSnapping.aspectRatio : 1 / MiniPlayerSnapping.aspectRatio
        }
        return video?.isShort == true ? 1 / MiniPlayerSnapping.aspectRatio : MiniPlayerSnapping.aspectRatio
    }

    private var corner: MiniPlayerCorner {
        MiniPlayerCorner(rawValue: storedCorner) ?? .initial
    }

    /// Everything the anchors depend on except the corner. A change (tab bar height,
    /// keyboard, rotation) re-anchors the window in the same corner, animated.
    private struct Layout: Equatable {
        var screen: CGSize
        var obstructions: MiniPlayerInsets
        var scale: CGFloat
        /// Video width / height; the window takes the same shape.
        var aspect: CGFloat
        var size: CGSize {
            MiniPlayerSnapping.size(screen: screen, obstructions: obstructions, scale: scale, aspect: aspect)
        }
        var longSide: CGFloat { max(size.width, size.height) }

        func with(scale: CGFloat) -> Layout {
            var copy = self
            copy.scale = scale
            return copy
        }

        func anchor(_ corner: MiniPlayerCorner) -> CGPoint {
            MiniPlayerSnapping.anchor(for: corner, size: size, screen: screen, obstructions: obstructions)
        }
    }

    var body: some View {
        ZStack {
            // Keyboard probe: unlike the layout reader below, this one respects the
            // keyboard safe area.
            GeometryReader { probe in
                Color.clear
                    .onChange(of: probe.safeAreaInsets.bottom, initial: true) { _, inset in
                        keyboardAwareBottomInset = inset
                    }
            }
            .allowsHitTesting(false)

            GeometryReader { geo in
                // Insets reach the screen edges (keyboard ignored here, see probe).
                let insets = geo.safeAreaInsets
                let keyboardShown = keyboardAwareBottomInset > insets.bottom + 1
                let layout = Layout(
                    screen: CGSize(
                        width: geo.size.width + insets.leading + insets.trailing,
                        height: geo.size.height + insets.top + insets.bottom
                    ),
                    obstructions: MiniPlayerInsets(
                        top: insets.top,
                        leading: insets.leading,
                        // The keyboard covers the tab bar; while it is up the tab content
                        // reports a keyboard-based inset too, so use the keyboard alone.
                        bottom: keyboardShown ? keyboardAwareBottomInset : max(tabBarBottomInset, insets.bottom),
                        trailing: insets.trailing
                    ),
                    scale: pinchScale ?? storedScale,
                    aspect: videoAspect
                )
                let anchor = layout.anchor(corner)

                window(size: layout.size)
                    .scaleEffect(isLifted ? Self.liftedScale : 1)
                    // geo's origin is the safe area's top-leading corner.
                    .position(x: anchor.x - insets.leading, y: anchor.y - insets.top)
                    .animation(Self.relayoutAnimation, value: layout)
                    .offset(x: offsetX)
                    .offset(y: offsetY)
                    .highPriorityGesture(dragGesture(layout: layout).simultaneously(with: pinchGesture(layout: layout)))
                    // Same level as the drag: a tap gesture inside the window would be
                    // blocked by the high-priority drag even when the drag never starts.
                    .simultaneousGesture(
                        SpatialTapGesture(coordinateSpace: .global)
                            .onEnded { handleTap(at: $0.location, layout: layout) }
                    )
            }
            .ignoresSafeArea(.keyboard)
        }
        // The player item's size is not observable; poll until it is known, as the
        // full-screen player does for its orientation (PlayerView+Lifecycle).
        .task(id: playerState.vm.currentVideoId) {
            guard let videoID = playerState.vm.currentVideoId, decodedAspect?.videoID != videoID else { return }
            for _ in 0..<Self.aspectPollAttempts {
                if Task.isCancelled { return }
                if !playerState.vm.isLoading, playerState.vm.currentVideoId == videoID,
                    let size = playerState.vm.player.currentItem?.presentationSize, size.width > 0, size.height > 0
                {
                    withAnimation(Self.relayoutAnimation) {
                        decodedAspect = DecodedAspect(videoID: videoID, aspect: size.width / size.height)
                    }
                    miniPlayerLog.debug("video aspect \(Int(size.width))x\(Int(size.height)) id=\(videoID)")
                    return
                }
                try? await Task.sleep(for: Self.aspectPollInterval)
            }
        }
        .onChange(of: keyboardAwareBottomInset) { _, inset in
            miniPlayerLog.debug("keyboard-aware bottom inset=\(inset) tabBar=\(tabBarBottomInset)")
        }
    }

    // MARK: - Window

    private func window(size: CGSize) -> some View {
        let shape = RoundedRectangle(cornerRadius: MiniPlayerSnapping.cornerRadius, style: .continuous)
        return MiniPlayerLayerView(hostView: playerState.playerHostView)
            // Touches belong to the SwiftUI window, not the UIKit player view.
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .overlay(alignment: .topTrailing) {
                controlButton(symbol: AppSymbol.xmark, size: 13, id: AXID.closeButton) {
                    unlessDragging { playerState.stop() }
                }
                .accessibilityLabel("Close")
            }
            .overlay(alignment: .bottomLeading) {
                controlButton(
                    symbol: playerState.vm.isPlaying ? "pause.fill" : "play.fill",
                    size: 15,
                    id: AXID.playPauseButton
                ) {
                    unlessDragging { playerState.vm.togglePlayPause() }
                }
                .accessibilityLabel(playerState.vm.isPlaying ? "Pause" : "Play")
            }
            .frame(width: size.width, height: size.height)
            .clipShape(shape)
            .contentShape(shape)
            .shadow(
                color: .black.opacity(isLifted ? 0.45 : 0.3),
                radius: isLifted ? 18 : 10,
                y: isLifted ? 8 : 4
            )
            .accessibilityElement(children: .contain)
            .accessibilityLabel(playerState.playingVideo?.title.trimmingCharacters(in: .whitespaces) ?? "")
            .accessibilityAction(named: "Expand") { playerState.expand() }
            .accessibilityIdentifier(AXID.bar)
    }

    /// Side of each control button's square hit area.
    private static let buttonHitSize: CGFloat = 44

    /// Tap anywhere on the video expands; taps on the buttons are left to them.
    private func handleTap(at location: CGPoint, layout: Layout) {
        let anchor = layout.anchor(corner)
        let size = layout.size
        let frame = CGRect(
            x: anchor.x + offsetX - size.width / 2,
            y: anchor.y + offsetY - size.height / 2,
            width: size.width,
            height: size.height
        )
        let hit = Self.buttonHitSize
        let closeButton = CGRect(x: frame.maxX - hit, y: frame.minY, width: hit, height: hit)
        let playPauseButton = CGRect(x: frame.minX, y: frame.maxY - hit, width: hit, height: hit)
        guard frame.contains(location), !closeButton.contains(location), !playPauseButton.contains(location)
        else { return }
        unlessDragging { playerState.expand() }
    }

    /// Small circular button over the video with a 44 pt hit area.
    private func controlButton(
        symbol: String,
        size: CGFloat,
        id: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(Circle().fill(.black.opacity(0.5)))
                .frame(width: Self.buttonHitSize, height: Self.buttonHitSize)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(id)
    }

    // MARK: - Drag and snap

    /// High priority over the tap and the buttons: once the finger has moved
    /// `dragMinimumDistance`, the drag owns the touch. Shorter touches fail the drag
    /// and reach the tap / buttons; `unlessDragging` additionally drops a tap or button
    /// release that still arrives for a touch the drag has taken.
    private func dragGesture(layout: Layout) -> some Gesture {
        // Global space: the window itself moves with the drag, so local translations
        // would feed back into themselves.
        DragGesture(minimumDistance: Self.dragMinimumDistance, coordinateSpace: .global)
            .onChanged { value in
                lastDragActivity = .now
                isDragTouchActive = true
                lastDragTranslation = value.translation
                // A pinch owns the window while it lasts.
                guard pinchStartScale == nil else { return }
                let anchor = layout.anchor(corner)
                let start: CGPoint
                if let dragStartCenter {
                    start = dragStartCenter
                } else {
                    // Picking the window up mid-snap continues from where it is now.
                    start = CGPoint(x: anchor.x + offsetX, y: anchor.y + offsetY)
                    dragStartCenter = start
                    withAnimation(liftAnimation) { isLifted = true }
                }
                // Translation counts from touch-down, so the grabbed point stays
                // under the finger without a jump once the drag is recognized.
                let center = MiniPlayerSnapping.rubberBanded(
                    CGPoint(x: start.x + value.translation.width, y: start.y + value.translation.height),
                    size: layout.size,
                    screen: layout.screen
                )
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    offsetX = center.x - anchor.x
                    offsetY = center.y - anchor.y
                }
            }
            .onEnded { value in
                lastDragActivity = .now
                isDragTouchActive = false
                dragStartCenter = nil
                // The pinch settles the window when it ends.
                guard pinchStartScale == nil else { return }
                settle(layout: layout, velocity: CGVector(dx: value.velocity.width, dy: value.velocity.height))
            }
    }

    /// Pinch to resize between `MiniPlayerSnapping.minimumWidth` and
    /// `maximumWidth` (full width or half the screen height). The centre stays put
    /// while pinching; on release the window snaps to the nearest corner at its new size.
    private func pinchGesture(layout: Layout) -> some Gesture {
        MagnifyGesture()
            .onChanged { value in
                lastDragActivity = .now
                let start: CGFloat
                let center: CGPoint
                if let pinchStartScale, let pinchCenter {
                    start = pinchStartScale
                    center = pinchCenter
                } else {
                    // Start from the size on screen (the stored scale may be clamped).
                    start = MiniPlayerSnapping.scale(forLongSide: layout.longSide, screenWidth: layout.screen.width)
                    let anchor = layout.anchor(corner)
                    center = CGPoint(x: anchor.x + offsetX, y: anchor.y + offsetY)
                    pinchStartScale = start
                    pinchCenter = center
                    withAnimation(liftAnimation) { isLifted = true }
                }
                let resized = layout.with(scale: start * value.magnification)
                let anchor = resized.anchor(corner)
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    pinchScale = resized.scale
                    offsetX = center.x - anchor.x
                    offsetY = center.y - anchor.y
                }
            }
            .onEnded { _ in
                lastDragActivity = .now
                let resized = layout.with(scale: pinchScale ?? storedScale)
                let committed = MiniPlayerSnapping.scale(
                    forLongSide: resized.longSide, screenWidth: resized.screen.width)
                let finalLayout = layout.with(scale: committed)
                let center = CGPoint(x: resized.anchor(corner).x + offsetX, y: resized.anchor(corner).y + offsetY)
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    storedScale = Double(committed)
                    pinchScale = nil
                    pinchStartScale = nil
                    pinchCenter = nil
                    let anchor = finalLayout.anchor(corner)
                    offsetX = center.x - anchor.x
                    offsetY = center.y - anchor.y
                }
                miniPlayerLog.debug("pinch → scale=\(committed) width=\(finalLayout.size.width)")
                if isDragTouchActive {
                    // A finger is still down: let the drag carry on from here.
                    dragStartCenter = CGPoint(
                        x: center.x - lastDragTranslation.width, y: center.y - lastDragTranslation.height)
                } else {
                    settle(layout: finalLayout, velocity: .zero)
                }
            }
    }

    /// Flies to the corner the release projects into, springing from `velocity`.
    private func settle(layout: Layout, velocity: CGVector) {
        let oldAnchor = layout.anchor(corner)
        let center = CGPoint(x: oldAnchor.x + offsetX, y: oldAnchor.y + offsetY)
        let target = MiniPlayerSnapping.targetCorner(releasedAt: center, velocity: velocity, screen: layout.screen)
        let newAnchor = layout.anchor(target)
        miniPlayerLog.debug("snap \(corner.rawValue) → \(target.rawValue) center=\(center) velocity=\(velocity)")

        // Re-base the offset on the target corner without moving the window,
        // then let each axis spring back to zero.
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            storedCorner = target.rawValue
            offsetX = center.x - newAnchor.x
            offsetY = center.y - newAnchor.y
        }
        withAnimation(snapAnimation(velocity: velocity.dx, distance: -offsetX)) {
            offsetX = 0
        }
        withAnimation(snapAnimation(velocity: velocity.dy, distance: -offsetY)) {
            offsetY = 0
        } completion: {
            // A new drag or pinch may have begun before this snap settled.
            guard dragStartCenter == nil, pinchStartScale == nil else { return }
            withAnimation(liftAnimation) { isLifted = false }
        }
    }

    /// Runs `action` only if the current touch is a tap, not the end of a drag. The
    /// tap/button and the drag can end in either order, hence both checks.
    private func unlessDragging(_ action: () -> Void) {
        if dragStartCenter != nil || pinchStartScale != nil { return }
        if let lastDragActivity, Date.now.timeIntervalSince(lastDragActivity) < Self.dragTapSuppression { return }
        action()
    }

    private var liftAnimation: Animation {
        reduceMotion ? Self.reducedMotionAnimation : .easeOut(duration: 0.15)
    }

    /// Spring that starts at the finger's release velocity, so there is no hitch
    /// between letting go and the snap. SwiftUI expects that velocity relative to the
    /// animated distance (fractions of the distance per second).
    private func snapAnimation(velocity: CGFloat, distance: CGFloat) -> Animation {
        if reduceMotion { return Self.reducedMotionAnimation }
        let relativeVelocity = abs(distance) > 1 ? Double(velocity / distance) : 0
        return .interpolatingSpring(Self.snapSpring, initialVelocity: relativeVelocity)
    }
}

// MARK: - MiniPlayerLayerView

/// UIViewRepresentable that embeds PersistentPlayerHostView as a subview.
/// UIView.addSubview transplants the hostView from the full-screen context
/// automatically — no explicit removeFromSuperview needed.
private struct MiniPlayerLayerView: UIViewRepresentable {
    let hostView: PersistentPlayerHostView

    func makeUIView(context: Context) -> UIView {
        let container = UIView()
        container.backgroundColor = .black
        hostView.videoGravity = .resizeAspectFill
        hostView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(hostView)
        NSLayoutConstraint.activate([
            hostView.topAnchor.constraint(equalTo: container.topAnchor),
            hostView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            hostView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            hostView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ])
        return container
    }

    func updateUIView(_ uiView: UIView, context: Context) {}
}
#endif
