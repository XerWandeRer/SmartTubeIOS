#if os(iOS)
import SwiftUI
import AVFoundation
import UIKit
import SmartTubeIOSCore

private let miniPlayerLog = CrashlyticsLogger(category: "MiniPlayer")

// MARK: - MiniPlayerView

/// Compact bar overlaid at the bottom of MainTabView when the player is minimized.
/// Modelled on YouTube's mini player: a thin read-only progress line on top, the live
/// video (the shared PersistentPlayerHostView) flush against the leading edge, title
/// and channel, then play/pause, next and close buttons.
///
/// Gestures: tap or swipe up expands back to full-screen; swipe left/right or down
/// dismisses (stops playback). While dragging, the bar follows the finger and fades;
/// below the distance/velocity thresholds it springs back.
struct MiniPlayerView: View {
    @Environment(PlayerStateStore.self) private var playerState

    /// Total bar height including the progress line. RootView reserves the same
    /// amount of bottom safe-area inset so tab content is not hidden underneath.
    static let height: CGFloat = 62
    private static let progressHeight: CGFloat = 2
    private static let rowHeight: CGFloat = height - progressHeight
    private static let thumbnailWidth: CGFloat = (rowHeight * 16 / 9).rounded()

    /// Axis locked on the first drag update so a diagonal swipe cannot switch
    /// between "dismiss sideways" and "expand/dismiss vertically" mid-gesture.
    private enum DragAxis { case horizontal, vertical }

    /// Accessibility identifiers; UITests (PlayerAndMiniPlayerUITests) query these.
    fileprivate enum AXID {
        static let bar = "miniPlayer.bar"
        static let progressBar = "miniPlayer.progressBar"
        static let titleLabel = "miniPlayer.titleLabel"
        static let channelLabel = "miniPlayer.channelLabel"
        static let playPauseButton = "miniPlayer.playPauseButton"
        static let nextButton = "miniPlayer.nextButton"
        static let closeButton = "miniPlayer.closeButton"
    }

    @State private var dragAxis: DragAxis?
    @State private var dragOffset: CGSize = .zero
    @State private var isDismissing = false

    var body: some View {
        VStack(spacing: 0) {
            MiniPlayerProgressBar(vm: playerState.vm)
                .frame(height: Self.progressHeight)

            HStack(spacing: 0) {
                // Live video thumbnail (same AVPlayerLayer, transplanted here)
                MiniPlayerLayerView(hostView: playerState.playerHostView)
                    .frame(width: Self.thumbnailWidth, height: Self.rowHeight)
                    .clipped()
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 2) {
                    Text(playerState.playingVideo?.title ?? "")
                        .font(.subheadline)
                        .lineLimit(1)
                        .foregroundStyle(.primary)
                        .accessibilityIdentifier(AXID.titleLabel)
                    Text(playerState.playingVideo?.channelTitle ?? "")
                        .font(.caption)
                        .lineLimit(1)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier(AXID.channelLabel)
                }
                .padding(.leading, 10)

                Spacer(minLength: 4)

                controlButton(
                    symbol: playerState.vm.isPlaying ? "pause.fill" : "play.fill",
                    size: 20,
                    id: AXID.playPauseButton
                ) {
                    playerState.vm.togglePlayPause()
                }

                controlButton(symbol: AppSymbol.nextTrack, size: 18, id: AXID.nextButton) {
                    playerState.vm.playNext()
                }
                .disabled(!playerState.vm.hasNext)
                // .plain buttons with an explicit foregroundStyle don't dim when disabled.
                .opacity(playerState.vm.hasNext ? 1 : 0.35)

                controlButton(symbol: AppSymbol.xmark, size: 18, id: AXID.closeButton) {
                    playerState.stop()
                }
                .padding(.trailing, 4)
            }
            .frame(height: Self.rowHeight)
        }
        .frame(height: Self.height)
        // White in light mode, elevated dark grey in dark mode — matches YouTube's
        // solid mini-player surface better than a translucent material.
        .background(Color(uiColor: .tertiarySystemBackground))
        .contentShape(Rectangle())
        // One gesture, drag first: a tap only fires once the drag has failed (finger lifted
        // before moving 12 pt). With a separate onTapGesture, SwiftUI gives the tap
        // precedence and a slow short drag ends up expanding the player.
        .gesture(
            dragGesture.exclusively(
                before: TapGesture().onEnded { playerState.expand() }
            )
        )
        .offset(dragOffset)
        .opacity(dragOpacity)
        // Ensure child buttons remain individually discoverable by XCTest even though
        // the enclosing stack carries its own tap gesture (which can cause SwiftUI
        // to group all children into a single accessibility element).
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AXID.bar)
    }

    private func controlButton(
        symbol: String,
        size: CGFloat,
        id: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size))
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
        .accessibilityIdentifier(id)
    }

    // MARK: - Drag to expand / dismiss

    /// Distance past which a release commits the gesture.
    private static let horizontalDismissDistance: CGFloat = 100
    private static let downDismissDistance: CGFloat = 40
    private static let upExpandDistance: CGFloat = 30
    /// Predicted end translation (≈ fling velocity) past which a release commits
    /// even when the finger itself travelled less than the distance above.
    private static let horizontalFlingDistance: CGFloat = 220
    private static let verticalFlingDistance: CGFloat = 120

    private var dragGesture: some Gesture {
        // Global space: the bar itself moves with dragOffset, so local translations would
        // feed back into themselves and jitter.
        DragGesture(minimumDistance: 12, coordinateSpace: .global)
            .onChanged { value in
                guard !isDismissing else { return }
                let translation = value.translation
                if dragAxis == nil {
                    dragAxis = abs(translation.width) > abs(translation.height) ? .horizontal : .vertical
                }
                switch dragAxis {
                case .horizontal:
                    dragOffset = CGSize(width: translation.width, height: 0)
                case .vertical:
                    // Downward follows the finger; upward is damped so the bar only
                    // hints at the expand rather than sliding over the content.
                    dragOffset = CGSize(
                        width: 0, height: translation.height > 0 ? translation.height : translation.height * 0.4)
                case nil:
                    break
                }
            }
            .onEnded { value in
                guard !isDismissing else { return }
                let translation = value.translation
                let predicted = value.predictedEndTranslation
                let axis = dragAxis
                dragAxis = nil
                miniPlayerLog.debug(
                    "drag end axis=\(String(describing: axis)) t=\(translation) predicted=\(predicted)")

                switch axis {
                case .horizontal:
                    if abs(translation.width) > Self.horizontalDismissDistance
                        || abs(predicted.width) > Self.horizontalFlingDistance
                    {
                        let direction: CGFloat =
                            (predicted.width != 0 ? predicted.width : translation.width) < 0 ? -1 : 1
                        dismiss(to: CGSize(width: direction * Self.horizontalDismissDistance * 4, height: 0))
                        return
                    }
                case .vertical:
                    if translation.height > Self.downDismissDistance || predicted.height > Self.verticalFlingDistance {
                        dismiss(to: CGSize(width: 0, height: Self.height * 2))
                        return
                    }
                    if translation.height < -Self.upExpandDistance || predicted.height < -Self.verticalFlingDistance {
                        dragOffset = .zero
                        playerState.expand()
                        return
                    }
                case nil:
                    break
                }
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                    dragOffset = .zero
                }
            }
    }

    /// Fades out as the bar moves away: fully transparent at the horizontal
    /// dismiss distance × 1.5, or after a short downward pull.
    private var dragOpacity: Double {
        if dragOffset.width != 0 {
            return max(0, 1 - Double(abs(dragOffset.width) / (Self.horizontalDismissDistance * 1.5)))
        }
        if dragOffset.height > 0 {
            return max(0, 1 - Double(dragOffset.height / (Self.height * 1.5)))
        }
        return 1
    }

    private func dismiss(to offset: CGSize) {
        isDismissing = true
        withAnimation(.easeOut(duration: 0.18)) {
            dragOffset = offset
        } completion: {
            playerState.stop()
        }
    }
}

// MARK: - MiniPlayerProgressBar

/// Read-only playback progress line along the top edge of the mini player.
/// Kept as its own view so the 0.5 s `currentTime` ticks only invalidate this
/// line, not the whole bar.
private struct MiniPlayerProgressBar: View {
    let vm: PlaybackViewModel

    private var fraction: Double {
        guard vm.duration > 0, vm.currentTime.isFinite else { return 0 }
        return min(max(vm.currentTime / vm.duration, 0), 1)
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Rectangle().fill(Color.secondary.opacity(0.25))
                Rectangle()
                    .fill(Color.red)
                    .frame(width: geo.size.width * fraction)
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Playback progress")
        .accessibilityValue("\(Int((fraction * 100).rounded())) percent")
        .accessibilityIdentifier(MiniPlayerView.AXID.progressBar)
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
