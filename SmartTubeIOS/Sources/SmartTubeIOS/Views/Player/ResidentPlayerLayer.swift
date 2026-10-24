#if os(iOS)
import SwiftUI
import AVFoundation
import UIKit
import SmartTubeIOSCore

private let residentLog = CrashlyticsLogger(category: "ResidentPlayer")

// MARK: - ResidentPlayerLayer

/// The AVPlayer player as one resident layer above MainTabView, from the moment a
/// video opens until the player is closed. A single `progress` (1 = full screen,
/// 0 = mini player) morphs the video between its full-screen frame and the
/// YouTube-style floating mini player. The video is the shared
/// PersistentPlayerHostView, hosted once here and never moved to another container.
///
/// Full screen: a black backdrop, the video, and PlayerView's controls on top.
///
/// Mini player: a rounded 16:9 window with the live video, a play/pause and a close
/// button. Everything around it stays interactive.
/// - Tap the video to expand back to full screen.
/// - Drag to move it; it follows the finger 1:1 (rubber-banded at the screen edges)
///   and on release flies to the corner its projected end point falls in.
/// - Pinch to resize, up to the full width or half the screen height.
///
/// Corner and size are persisted across launches.
///
/// Geometry lives in `MiniPlayerSnapping` and `ResidentPlayerGeometry`
/// (SmartTubeIOSCore).
struct ResidentPlayerLayer: View {
    @Environment(PlayerStateStore.self) private var playerState
    @Environment(SettingsStore.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let api: InnerTubeAPI
    /// Height covered at the bottom of the screen by the tab bar incl. home indicator.
    let tabBarBottomInset: CGFloat

    @AppStorage(Self.cornerDefaultsKey) private var storedCorner = MiniPlayerCorner.initial.rawValue
    /// User-chosen mini player size as a multiple of the default size; clamped when applied.
    @AppStorage(Self.scaleDefaultsKey) private var storedScale = 1.0

    /// 1 = full screen, 0 = mini player. Animated when the presentation changes.
    @State private var progress: CGFloat = 1
    /// Progress while the expanded player is dragged down; overrides `progress`.
    @State private var collapseDragProgress: CGFloat?
    /// Full screen size: the collapse drag's travel, and whether the window is portrait.
    @State private var screenSize: CGSize = .zero
    /// Minimized while the window was still landscape: the collapse waits until the
    /// window has rotated back to portrait.
    @State private var isWaitingForPortrait = false
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
    /// Last drag update; taps and button presses right after a drag belong to it.
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

    static let cornerDefaultsKey = "miniPlayer.corner"
    static let scaleDefaultsKey = "miniPlayer.scale"
    private static let dragMinimumDistance: CGFloat = 8
    /// How long after a drag a tap or button release still counts as part of it.
    private static let dragTapSuppression: TimeInterval = 0.35
    static let liftedScale: CGFloat = 1.03
    private static let snapSpring = Spring(response: 0.35, dampingRatio: 0.8)
    private static let presentationSpring = Spring(response: 0.4, dampingRatio: 0.9)
    private static let reducedMotionAnimation = Animation.easeOut(duration: 0.2)
    private static let relayoutAnimation = Animation.spring(response: 0.35, dampingFraction: 0.8)
    private static let gravityAnimation = Animation.easeInOut(duration: 0.25)
    private static let controlsFade = Animation.easeOut(duration: 0.15)
    /// Longest wait for the rotation back to portrait before collapsing anyway.
    private static let portraitWaitTimeout: Duration = .seconds(1.5)
    /// The window takes its portrait size when the rotation starts; the system's
    /// rotation animation runs about this long after that.
    private static let rotationAnimationDuration: Duration = .milliseconds(400)

    /// Accessibility identifiers; UITests (MiniPlayerUITests, PlayerAndMiniPlayerUITests) query these.
    private enum AXID {
        static let bar = "miniPlayer.bar"
        static let playPauseButton = "miniPlayer.playPauseButton"
        static let closeButton = "miniPlayer.closeButton"
    }

    private var corner: MiniPlayerCorner {
        MiniPlayerCorner(rawValue: storedCorner) ?? .initial
    }

    private var isMini: Bool { playerState.presentation == .miniPlayer }

    /// What the layer draws: the finger's progress while dragging, else `progress`.
    private var displayedProgress: CGFloat { collapseDragProgress ?? progress }

    /// Status bar and home indicator are hidden while the player is mostly expanded, so
    /// they switch midway through a drag instead of when it starts.
    private var hidesSystemOverlays: Bool {
        playerState.presentation != .hidden && displayedProgress > 0.5
    }

    /// PlayerView's controls fade out over the first 30 % of a collapse.
    private var controlsOpacity: Double {
        Double(ResidentPlayerGeometry.clamp((displayedProgress - 0.7) / 0.3))
    }

    /// Everything the mini player's anchors depend on except the corner. A change (tab
    /// bar height, keyboard, rotation) re-anchors the window in the same corner, animated.
    private struct Layout: Equatable {
        var screen: CGSize
        var obstructions: MiniPlayerInsets
        var scale: CGFloat
        var size: CGSize { MiniPlayerSnapping.size(screen: screen, obstructions: obstructions, scale: scale) }

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
            if playerState.presentation != .hidden, let video = playerState.currentVideo {
                Color.black
                    .opacity(Double(displayedProgress))
                    .ignoresSafeArea()
                    // Covers the tabs while expanded; the mini player leaves them usable.
                    .allowsHitTesting(!isMini)
                    .onGeometryChange(for: CGSize.self) { proxy in
                        let insets = proxy.safeAreaInsets
                        return CGSize(
                            width: proxy.size.width + insets.leading + insets.trailing,
                            height: proxy.size.height + insets.top + insets.bottom)
                    } action: {
                        screenSize = $0
                    }

                videoLayer

                if playerState.presentation == .fullScreen {
                    PlayerView(video: video, api: api)
                        .id(video.id)
                        .environment(
                            \.residentPlayer,
                            ResidentPlayerContext(
                                collapseDragChanged: { collapseDragChanged($0) },
                                collapseDragEnded: { collapseDragEnded($0, velocity: $1) }
                            )
                        )
                        .opacity(controlsOpacity)
                        .transition(.opacity.animation(Self.controlsFade))
                }
            }
        }
        .onChange(of: playerState.presentation) { _, presentation in
            presentationChanged(presentation)
        }
        .onChange(of: screenSize) { _, size in
            guard isWaitingForPortrait, size.height > size.width else { return }
            Task { @MainActor in
                try? await Task.sleep(for: Self.rotationAnimationDuration)
                finishLandscapeCollapse(reason: "portrait")
            }
        }
        .statusBarHidden(hidesSystemOverlays)
        .persistentSystemOverlays(hidesSystemOverlays ? .hidden : .automatic)
    }

    private func presentationChanged(_ presentation: PlayerStateStore.Presentation) {
        residentLog.notice("presentation=\(String(describing: presentation)) progress=\(progress)")
        switch presentation {
        case .fullScreen:
            isWaitingForPortrait = false
            withAnimation(transitionAnimation) { progress = 1 }
        case .miniPlayer:
            // A landscape player rotating back to portrait (XER-10) collapses only once
            // the window is portrait: shrinking first would land the mini player on a
            // landscape layout of the tabs that is about to change.
            if screenSize.width > screenSize.height, progress > 0,
                PlayerOrientationController.shared.dismissRotatesToPortrait
            {
                isWaitingForPortrait = true
                Task { @MainActor in
                    try? await Task.sleep(for: Self.portraitWaitTimeout)
                    finishLandscapeCollapse(reason: "timeout")
                }
            } else {
                withAnimation(transitionAnimation) { progress = 0 }
            }
        case .hidden:
            // Closed: the next video opens straight at full screen.
            progress = 1
            collapseDragProgress = nil
            isWaitingForPortrait = false
            dragStartCenter = nil
            offsetX = 0
            offsetY = 0
            isLifted = false
        }
    }

    private var transitionAnimation: Animation {
        reduceMotion ? Self.reducedMotionAnimation : .spring(Self.presentationSpring)
    }

    private func finishLandscapeCollapse(reason: String) {
        guard isWaitingForPortrait, playerState.presentation == .miniPlayer else { return }
        isWaitingForPortrait = false
        residentLog.notice("landscape collapse continues — \(reason) size=\(screenSize)")
        withAnimation(transitionAnimation) { progress = 0 }
    }

    // MARK: - Collapse drag

    private var collapseTravel: CGFloat { PlayerPanGesture.collapseTravel(screenHeight: screenSize.height) }

    /// The expanded player follows a downward drag (translation from touch-down).
    private func collapseDragChanged(_ translation: CGFloat) {
        guard playerState.presentation == .fullScreen else { return }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            collapseDragProgress = PlayerPanGesture.progress(translation: translation, travel: collapseTravel)
        }
    }

    /// Release (or cancel, with zero velocity): the projected end point decides between
    /// mini player and full screen, and a spring starting at the finger's velocity
    /// finishes the way there.
    private func collapseDragEnded(_ translation: CGFloat, velocity: CGFloat) {
        guard let current = collapseDragProgress else { return }
        let travel = collapseTravel
        let collapse = PlayerPanGesture.shouldCollapse(translation: translation, velocity: velocity, travel: travel)
        let target: CGFloat = collapse ? 0 : 1
        residentLog.notice(
            "collapse drag end dy=\(translation) vy=\(velocity) progress=\(current) collapse=\(collapse)")
        // Hand the finger's value over without moving, then animate from there.
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            progress = current
            collapseDragProgress = nil
        }
        let animation: Animation =
            reduceMotion
            ? Self.reducedMotionAnimation
            : .interpolatingSpring(
                Self.presentationSpring,
                initialVelocity: Double(
                    PlayerPanGesture.springVelocity(velocity: velocity, travel: travel, from: current, to: target))
            )
        withAnimation(animation) { progress = target }
        guard collapse else { return }
        // presentationChanged then finds progress already at 0 and leaves the spring alone.
        if store.settings.miniPlayerEnabled { playerState.minimize() } else { playerState.stop() }
    }

    // MARK: - Video layer

    private var videoLayer: some View {
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
                    scale: pinchScale ?? storedScale
                )
                let fill = store.settings.videoGravityMode == .fill

                ResidentVideoSurface(hostView: playerState.playerHostView)
                    .accessibilityHidden(true)
                    .modifier(
                        ResidentMorph(
                            progress: displayedProgress,
                            lift: isLifted ? 1 : 0,
                            fill: fill ? 1 : 0,
                            miniCenter: layout.anchor(corner),
                            videoFrame: ResidentPlayerGeometry.videoFrame(
                                aspectRatio: playerState.videoAspectRatio, screen: layout.screen),
                            miniSize: layout.size,
                            screen: layout.screen,
                            // geo's origin is the safe area's top-leading corner.
                            origin: CGPoint(x: insets.leading, y: insets.top),
                            chrome: miniChrome
                        )
                    )
                    .animation(Self.relayoutAnimation, value: layout)
                    .animation(Self.gravityAnimation, value: fill)
                    // PlayerView's previous / next slide moves the video too.
                    .offset(x: playerState.slideOffset)
                    .offset(x: offsetX)
                    .offset(y: offsetY)
                    .highPriorityGesture(
                        dragGesture(layout: layout).simultaneously(with: pinchGesture(layout: layout)),
                        including: isMini ? .all : .none
                    )
                    // Same level as the drag: a tap gesture inside the window would be
                    // blocked by the high-priority drag even when the drag never starts.
                    .simultaneousGesture(
                        SpatialTapGesture(coordinateSpace: .global)
                            .onEnded { handleTap(at: $0.location, layout: layout) },
                        including: isMini ? .all : .none
                    )
            }
            .ignoresSafeArea(.keyboard)
        }
    }

    // MARK: - Mini player chrome

    /// Play/pause and close over the mini player; fills the window. Carries the
    /// window's accessibility element. Only exists while minimized; expanded,
    /// PlayerView's controls take over.
    @ViewBuilder
    private var miniChrome: some View {
        if isMini {
            miniChromeContent
        }
    }

    private var miniChromeContent: some View {
        ZStack {
            controlButton(symbol: AppSymbol.xmark, size: 13, id: AXID.closeButton) {
                unlessDragging { playerState.stop() }
            }
            .accessibilityLabel("Close")
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)

            controlButton(
                symbol: playerState.vm.isPlaying ? "pause.fill" : "play.fill",
                size: 15,
                id: AXID.playPauseButton
            ) {
                unlessDragging { playerState.vm.togglePlayPause() }
            }
            .accessibilityLabel(playerState.vm.isPlaying ? "Pause" : "Play")
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        }
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
}

// MARK: - Mini player drag, pinch and snap

extension ResidentPlayerLayer {
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
                    start = MiniPlayerSnapping.scale(forWidth: layout.size.width, screenWidth: layout.screen.width)
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
                    forWidth: resized.size.width, screenWidth: resized.screen.width)
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
                residentLog.debug("pinch → scale=\(committed) width=\(finalLayout.size.width)")
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
        residentLog.debug("snap \(corner.rawValue) → \(target.rawValue) center=\(center) velocity=\(velocity)")

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

// MARK: - ResidentPlayerContext

/// What ResidentPlayerLayer hands to the PlayerView it hosts: the downward drag of the
/// expanded player, in points from touch-down (and the release velocity).
struct ResidentPlayerContext: Sendable {
    var collapseDragChanged: @MainActor @Sendable (CGFloat) -> Void
    var collapseDragEnded: @MainActor @Sendable (_ translation: CGFloat, _ velocity: CGFloat) -> Void
}

extension EnvironmentValues {
    /// Non-nil while PlayerView is hosted by ResidentPlayerLayer.
    @Entry var residentPlayer: ResidentPlayerContext?
}

// MARK: - ResidentMorph

/// Places the video surface for one frame of the morph. Everything that animates
/// (progress, lift, fit/fill, the mini player's anchor) is animatable data, so a
/// spring on any of them is evaluated through `ResidentPlayerGeometry` every frame
/// instead of SwiftUI interpolating the derived frames independently.
private struct ResidentMorph<Chrome: View>: ViewModifier, Animatable {
    var progress: CGFloat
    /// 0 resting, 1 picked up.
    var lift: CGFloat
    /// 0 fit, 1 fill.
    var fill: CGFloat
    var miniCenter: CGPoint
    let videoFrame: CGRect
    let miniSize: CGSize
    let screen: CGSize
    /// Screen coordinates of the parent's origin.
    let origin: CGPoint
    let chrome: Chrome

    nonisolated var animatableData:
        AnimatablePair<AnimatablePair<CGFloat, CGFloat>, AnimatablePair<CGFloat, AnimatablePair<CGFloat, CGFloat>>>
    {
        get {
            AnimatablePair(
                AnimatablePair(progress, lift),
                AnimatablePair(fill, AnimatablePair(miniCenter.x, miniCenter.y))
            )
        }
        set {
            progress = newValue.first.first
            lift = newValue.first.second
            fill = newValue.second.first
            miniCenter = CGPoint(x: newValue.second.second.first, y: newValue.second.second.second)
        }
    }

    func body(content: Content) -> some View {
        let mini = CGRect(
            x: miniCenter.x - miniSize.width / 2,
            y: miniCenter.y - miniSize.height / 2,
            width: miniSize.width,
            height: miniSize.height
        )
        let morph = ResidentPlayerGeometry.morph(
            progress: progress,
            videoFrame: videoFrame,
            fullScreenClip: ResidentPlayerGeometry.fullScreenClip(videoFrame: videoFrame, screen: screen, fill: fill),
            mini: mini
        )
        let shape = RoundedRectangle(cornerRadius: morph.cornerRadius, style: .continuous)
        let collapsed = Double(1 - min(1, max(0, progress)))
        content
            .frame(width: videoFrame.width, height: videoFrame.height)
            .scaleEffect(morph.scale)
            .frame(width: morph.clip.width, height: morph.clip.height)
            .overlay { chrome.opacity(collapsed) }
            .clipShape(shape)
            .contentShape(shape)
            .shadow(
                color: .black.opacity((0.3 + 0.15 * lift) * collapsed),
                radius: 10 + 8 * lift,
                y: 4 + 4 * lift
            )
            .scaleEffect(1 + (ResidentPlayerLayer.liftedScale - 1) * lift)
            .position(x: morph.clip.midX - origin.x, y: morph.clip.midY - origin.y)
    }
}

// MARK: - ResidentVideoSurface

/// Hosts PersistentPlayerHostView for the whole session. The surface always has the
/// video's own aspect ratio, so aspect-fill shows the whole video; the morph scales
/// and clips it.
private struct ResidentVideoSurface: UIViewRepresentable {
    let hostView: PersistentPlayerHostView

    func makeUIView(context: Context) -> UIView {
        let container = UIView()
        container.backgroundColor = .black
        container.isUserInteractionEnabled = false
        container.isAccessibilityElement = false
        container.accessibilityElementsHidden = true
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
