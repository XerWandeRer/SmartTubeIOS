#if os(iOS)
import AVFoundation
import OSLog
import SmartTubeIOSCore
import SwiftUI
import UIKit

private let residentLog = Logger(subsystem: appSubsystem, category: "ResidentPlayer")

// MARK: - ResidentPlayerContext
//
// PROTOTYPE (XER-13): the full-screen player and the mini player are one resident
// layer above MainTabView instead of a UIKit modal. A single `progress` (0 = mini,
// 1 = full screen) drives the video frame, corner radius, backdrop and controls.

/// Handed to PlayerView through the environment while it lives in the resident layer.
struct ResidentPlayerContext: Sendable {
    /// The layer is fully expanded; the player owns the status bar and hit testing.
    var isExpanded: Bool
    /// Vertical pan from the player: translation, velocity, ended.
    var onCollapseDrag: @MainActor @Sendable (CGFloat, CGFloat, Bool) -> Void
}

private struct ResidentPlayerContextKey: EnvironmentKey {
    static let defaultValue: ResidentPlayerContext? = nil
}

extension EnvironmentValues {
    /// Non-nil when PlayerView is hosted by `ResidentPlayerLayer`.
    var residentPlayer: ResidentPlayerContext? {
        get { self[ResidentPlayerContextKey.self] }
        set { self[ResidentPlayerContextKey.self] = newValue }
    }
}

// MARK: - Geometry

/// Pure geometry for the collapse/expand morph. Kept free of SwiftUI state so the
/// real implementation can move it to SmartTubeIOSCore with unit tests.
struct ResidentPlayerGeometry {
    static let miniWidthFraction: CGFloat = 0.45
    static let miniMinWidth: CGFloat = 160
    static let miniMargin: CGFloat = 12
    static let miniCornerRadius: CGFloat = 10

    let screen: CGSize
    let safeArea: EdgeInsets
    let tabBarBottomInset: CGFloat
    /// Width / height of the video, 16:9 until the player knows better.
    let videoAspect: CGFloat

    var fullRect: CGRect { CGRect(origin: .zero, size: screen) }

    /// Bottom-trailing corner above the tab bar (XER-12 owns the other corners).
    var miniRect: CGRect {
        let width = max(Self.miniMinWidth, screen.width * Self.miniWidthFraction)
        let height = width * 9 / 16
        return CGRect(
            x: screen.width - safeArea.trailing - Self.miniMargin - width,
            y: screen.height - tabBarBottomInset - Self.miniMargin - height,
            width: width, height: height)
    }

    /// Where an aspect-fit video sits inside the full-screen player.
    var videoBand: CGRect { AVMakeRect(aspectRatio: CGSize(width: videoAspect, height: 1), insideRect: fullRect) }

    /// Distance the finger travels for progress to go from 1 to 0.
    var travel: CGFloat { max(1, miniRect.midY - videoBand.midY) }

    /// The visible (clipped) rect at `progress`.
    func clipRect(_ p: CGFloat) -> CGRect { lerp(miniRect, fullRect, p) }

    /// Scale of the full-size video surface at `progress`: aspect-fill of the video
    /// band into the mini rect at 0, identity at 1.
    func scale(_ p: CGFloat) -> CGFloat {
        let band = videoBand
        let s0 = max(miniRect.width / band.width, miniRect.height / band.height)
        return s0 + (1 - s0) * p
    }

    /// Offset of the surface's centre so the video band's centre lands on the
    /// mini rect's centre at 0.
    func offset(_ p: CGFloat) -> CGSize {
        let from = CGPoint(x: miniRect.midX - fullRect.midX, y: miniRect.midY - fullRect.midY)
        // The band is centred in the full rect, so scaling about the centre keeps it there.
        return CGSize(width: from.x * (1 - p), height: from.y * (1 - p))
    }

    func cornerRadius(_ p: CGFloat) -> CGFloat { Self.miniCornerRadius * (1 - p) }

    /// UIScrollView.DecelerationRate.normal projection (WWDC18 "Designing Fluid Interfaces").
    static func project(velocity: CGFloat, decelerationRate: CGFloat = 0.998) -> CGFloat {
        (velocity / 1000) * decelerationRate / (1 - decelerationRate)
    }

    private func lerp(_ a: CGRect, _ b: CGRect, _ t: CGFloat) -> CGRect {
        CGRect(
            x: a.minX + (b.minX - a.minX) * t,
            y: a.minY + (b.minY - a.minY) * t,
            width: a.width + (b.width - a.width) * t,
            height: a.height + (b.height - a.height) * t)
    }
}

// MARK: - ResidentPlayerLayer

struct ResidentPlayerLayer: View {
    let tabBarBottomInset: CGFloat

    @Environment(PlayerStateStore.self) private var playerState
    @Environment(SettingsStore.self) private var store
    @Environment(\.innerTubeAPI) private var api

    /// Settled progress: 1 full screen, 0 mini. Animated on commit.
    @State private var progress: CGFloat = 1
    /// Live pan translation while the user drags the expanded player down.
    @State private var dragY: CGFloat?

    var body: some View {
        if let video = playerState.currentVideo, playerState.presentation != .hidden {
            GeometryReader { geo in
                let g = ResidentPlayerGeometry(
                    screen: CGSize(
                        width: geo.size.width + geo.safeAreaInsets.leading + geo.safeAreaInsets.trailing,
                        height: geo.size.height + geo.safeAreaInsets.top + geo.safeAreaInsets.bottom),
                    safeArea: geo.safeAreaInsets,
                    tabBarBottomInset: tabBarBottomInset,
                    videoAspect: videoAspect)
                let p = effectiveProgress(g)
                content(video: video, g: g, p: p)
                    .frame(width: g.screen.width, height: g.screen.height)
                    .ignoresSafeArea()
            }
            .onChange(of: playerState.presentation, initial: true) { _, presentation in
                presentationChanged(presentation, video: video)
            }
        }
    }

    private var videoAspect: CGFloat {
        guard let size = playerState.vm.player.currentItem?.presentationSize, size.width > 0, size.height > 0
        else { return 16 / 9 }
        return size.width / size.height
    }

    private func effectiveProgress(_ g: ResidentPlayerGeometry) -> CGFloat {
        guard let dragY else { return progress }
        return min(1, max(0, 1 - max(0, dragY) / g.travel))
    }

    @ViewBuilder
    private func content(video: Video, g: ResidentPlayerGeometry, p: CGFloat) -> some View {
        let clip = g.clipRect(p)
        let expanded = playerState.presentation == .fullScreen && dragY == nil && p == 1
        ZStack(alignment: .topLeading) {
            // Backdrop: dims the tab UI while the player is (mostly) expanded.
            Color.black
                .opacity(Double(p))
                .allowsHitTesting(false)

            // One video surface for both states — the AVPlayerLayer never leaves the
            // window, so PiP stays bound and nothing is transplanted.
            ResidentVideoSurface(
                hostView: playerState.playerHostView,
                videoGravity: store.settings.videoGravityMode.avGravity
            )
            .frame(width: g.screen.width, height: g.screen.height)
            .scaleEffect(g.scale(p))
            .offset(g.offset(p))
            .frame(width: g.screen.width, height: g.screen.height)
            .mask(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: g.cornerRadius(p), style: .continuous)
                    .frame(width: clip.width, height: clip.height)
                    .offset(x: clip.minX, y: clip.minY)
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)

            // Full player controls fade out over the first 30 % of the collapse.
            PlayerView(video: video, api: api)
                .id(video.id)
                .environment(
                    \.residentPlayer,
                    ResidentPlayerContext(
                        isExpanded: expanded,
                        onCollapseDrag: { dy, vy, ended in collapseDrag(dy: dy, vy: vy, ended: ended, g: g) }))
                .frame(width: g.screen.width, height: g.screen.height)
                .opacity(Double(max(0, (p - 0.7) / 0.3)))
                .allowsHitTesting(p > 0.99)
                .accessibilityHidden(p < 1)

            // Mini controls.
            miniControls
                .frame(width: clip.width, height: clip.height)
                .offset(x: clip.minX, y: clip.minY)
                .opacity(Double(max(0, 1 - p * 3)))
                .allowsHitTesting(p < 0.01)
        }
    }

    private var miniControls: some View {
        ZStack(alignment: .topTrailing) {
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { playerState.expand() }
                .accessibilityIdentifier("miniPlayer.bar")
            HStack(spacing: 0) {
                Button {
                    playerState.vm.togglePlayPause()
                } label: {
                    Image(systemName: playerState.vm.isPlaying ? "pause.fill" : "play.fill")
                        .frame(width: 40, height: 40)
                }
                .accessibilityIdentifier("miniPlayer.playPauseButton")
                Button {
                    playerState.stop()
                } label: {
                    Image(systemName: AppSymbol.xmark).frame(width: 40, height: 40)
                }
                .accessibilityIdentifier("miniPlayer.closeButton")
            }
            .foregroundStyle(.white)
            .shadow(radius: 2)
        }
        .accessibilityElement(children: .contain)
    }

    // MARK: Drag

    private func collapseDrag(dy: CGFloat, vy: CGFloat, ended: Bool, g: ResidentPlayerGeometry) {
        guard playerState.presentation == .fullScreen else { return }
        guard ended else {
            residentLog.debug("[ResidentPlayer] drag dy=\(Int(dy)) progress=\(effectiveProgress(g))")
            dragY = dy
            return
        }
        let current = effectiveProgress(g)
        let projected = 1 - (max(0, dy) + ResidentPlayerGeometry.project(velocity: vy)) / g.travel
        // Hand the live value over before animating so the spring starts where the finger left off.
        progress = current
        dragY = nil
        let collapse = projected < 0.5
        residentLog.notice(
            "[ResidentPlayer] release dy=\(Int(dy)) vy=\(Int(vy)) projected=\(projected) collapse=\(collapse)")
        let initialVelocity = g.travel > 0 ? -vy / g.travel : 0
        withAnimation(.interpolatingSpring(duration: 0.35, bounce: 0, initialVelocity: initialVelocity)) {
            progress = collapse ? 0 : 1
        }
        if collapse {
            if store.settings.miniPlayerEnabled { playerState.minimize() } else { playerState.stop() }
        }
    }

    private func presentationChanged(_ presentation: PlayerStateStore.Presentation, video: Video) {
        residentLog.notice("[ResidentPlayer] presentation=\(String(describing: presentation))")
        switch presentation {
        case .fullScreen:
            PlayerOrientationController.shared.playerPresented(video: playerState.vm.currentVideo ?? video)
            if progress != 1 {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.9)) { progress = 1 }
            }
        case .miniPlayer:
            PlayerOrientationController.shared.playerDismissed()
            if progress != 0 {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.9)) { progress = 0 }
            }
        case .hidden:
            PlayerOrientationController.shared.playerDismissed()
            progress = 1
        }
    }
}

// MARK: - ResidentVideoSurface

/// Hosts the persistent player view once; the layer keeps it for the whole session.
private struct ResidentVideoSurface: UIViewRepresentable {
    let hostView: PersistentPlayerHostView
    var videoGravity: AVLayerVideoGravity

    func makeUIView(context: Context) -> UIView {
        let container = UIView()
        container.backgroundColor = .clear
        container.isUserInteractionEnabled = false
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

    func updateUIView(_ uiView: UIView, context: Context) {
        hostView.videoGravity = videoGravity
        if hostView.superview !== uiView { uiView.addSubview(hostView) }
    }
}
#endif
