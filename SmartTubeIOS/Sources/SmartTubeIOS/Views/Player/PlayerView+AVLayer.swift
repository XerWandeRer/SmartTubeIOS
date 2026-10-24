import AVFoundation
import AVKit
import SmartTubeIOSCore
import SwiftUI

#if canImport(UIKit)
import UIKit
#endif
#if canImport(AppKit)
import AppKit
#endif

// MARK: - Platform-specific AVKit / UIKit views
//
// Extracted from PlayerView.swift to keep that file under 1 000 lines.

// MARK: - AVPlayerLayerView

#if os(iOS) || os(tvOS)
/// Lightweight UIViewRepresentable wrapping an `AVPlayerLayer` directly.
/// Unlike `VideoPlayer` / `AVPlayerViewController`, it does not interfere
/// with the UIKit accessibility tree so SwiftUI overlays remain reachable.
/// On tvOS, `AVPlayerViewController` would provide system transport controls
/// but `AVPlayerLayer` is used here for layout consistency with iOS.
/// Named `PlayerAVLayerView` to avoid a module-level name clash with
/// `ShortsPlayerView`, which uses this type via `videoGravity: .resizeAspectFill`.
struct PlayerAVLayerView: UIViewRepresentable {
    let player: AVPlayer?
    var videoGravity: AVLayerVideoGravity = .resizeAspect
    var onLayerReady: ((AVPlayerLayer) -> Void)? = nil

    func makeUIView(context: Context) -> _PlayerUIView {
        let view = _PlayerUIView()
        view.backgroundColor = .black
        view.isAccessibilityElement = false
        view.accessibilityElementsHidden = true
        view.playerLayer.player = player
        view.playerLayer.videoGravity = videoGravity
        view.onLayerReady = onLayerReady
        return view
    }

    func updateUIView(_ uiView: _PlayerUIView, context: Context) {
        uiView.playerLayer.player = player
        uiView.playerLayer.videoGravity = videoGravity
    }

    final class _PlayerUIView: UIView {
        override static var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
        var onLayerReady: ((AVPlayerLayer) -> Void)?
        private var didFireCallback = false

        override func willMove(toWindow newWindow: UIWindow?) {
            super.willMove(toWindow: newWindow)
            guard newWindow != nil, !didFireCallback else { return }
            didFireCallback = true
            // Defer to next run-loop tick so the layer has a non-zero frame.
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.onLayerReady?(self.playerLayer)
            }
        }
    }
}

// MARK: - PiPDelegate

/// AVPictureInPictureControllerDelegate that notifies a SwiftUI closure when
/// PiP starts or stops, and implements the restore callback required for a
/// smooth transition back to full-screen without rebuffering.
final class PiPDelegate: NSObject, AVPictureInPictureControllerDelegate {
    private let onActiveChange: (Bool) -> Void
    private let onDidStart: (() -> Void)?
    private let onRestore: (() -> Void)?

    init(
        onActiveChange: @escaping (Bool) -> Void,
        onDidStart: (() -> Void)? = nil,
        onRestore: (() -> Void)? = nil
    ) {
        self.onActiveChange = onActiveChange
        self.onDidStart = onDidStart
        self.onRestore = onRestore
    }

    func pictureInPictureControllerDidStartPictureInPicture(_ controller: AVPictureInPictureController) {
        onDidStart?()
        onActiveChange(true)
    }

    func pictureInPictureControllerDidStopPictureInPicture(_ controller: AVPictureInPictureController) {
        onActiveChange(false)
    }

    /// Called when the user taps the PiP window to return to the app.
    /// Must call completionHandler(true) once the UI is ready to show the video
    /// again — without this iOS cannot complete the restore animation and the
    /// player rebuffers/stutters.
    func pictureInPictureController(
        _ controller: AVPictureInPictureController,
        restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void
    ) {
        // The AVPlayerLayer never leaves the window (ResidentPlayerLayer), so the
        // UI is immediately ready. Calling completionHandler(true) right away
        // lets AVKit animate the video seamlessly back into the layer.
        onRestore?()
        completionHandler(true)
    }
}

// MARK: - HoldSpeedBadge

struct HoldSpeedBadge: View {
    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: "forward.fill")
                .font(.system(size: 20, weight: .semibold))
            Text("2×")
                .font(.system(size: 14, weight: .bold, design: .rounded))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .allowsHitTesting(false)
    }
}

// MARK: - PlayerSwipeGestureOverlay (taps)

#if os(iOS)
/// Tap → `onTap`, double tap, two-finger tap and long press over the video. Pans
/// belong to `PlayerPanGestureInstaller`. Set `isEnabled = false` (e.g. while the
/// progress slider is being scrubbed) to suppress the taps and the long press.
/// Named `PlayerSwipeGestureOverlay` to avoid a module-level clash with the
/// identically-structured private copy in `ShortsPlayerView.swift`.
struct PlayerSwipeGestureOverlay: UIViewRepresentable {
    var onTap: () -> Void
    var onDoubleTap: (CGFloat) -> Void = { _ in }
    var onTwoFingerTap: () -> Void = {}
    var onLongPressStart: (() -> Void)?
    var onLongPressEnd: (() -> Void)?
    var isEnabled: Bool = true

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear

        let doubleTap = UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        doubleTap.cancelsTouchesInView = false
        view.addGestureRecognizer(doubleTap)
        context.coordinator.doubleTap = doubleTap

        let tap = UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleTap))
        tap.cancelsTouchesInView = false
        tap.require(toFail: doubleTap)
        view.addGestureRecognizer(tap)
        context.coordinator.tap = tap

        let twoFingerTap = UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleTwoFingerTap))
        twoFingerTap.numberOfTouchesRequired = 2
        twoFingerTap.cancelsTouchesInView = false
        view.addGestureRecognizer(twoFingerTap)

        let longPress = UILongPressGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleLongPress(_:)))
        longPress.minimumPressDuration = 0.4
        longPress.cancelsTouchesInView = false
        view.addGestureRecognizer(longPress)
        context.coordinator.longPress = longPress

        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.tap?.isEnabled = isEnabled
        context.coordinator.doubleTap?.isEnabled = isEnabled
        context.coordinator.longPress?.isEnabled = isEnabled
    }

    final class Coordinator: NSObject {
        var parent: PlayerSwipeGestureOverlay
        weak var tap: UITapGestureRecognizer?
        weak var doubleTap: UITapGestureRecognizer?
        weak var longPress: UILongPressGestureRecognizer?
        init(_ parent: PlayerSwipeGestureOverlay) { self.parent = parent }

        @MainActor @objc func handleTap() { parent.onTap() }
        @MainActor @objc func handleDoubleTap(_ gr: UITapGestureRecognizer) {
            let width = gr.view?.bounds.width ?? 1
            let normalizedX = width > 0 ? gr.location(in: gr.view).x / width : 0.5
            parent.onDoubleTap(normalizedX)
        }
        @MainActor @objc func handleTwoFingerTap() { parent.onTwoFingerTap() }

        @MainActor @objc func handleLongPress(_ gr: UILongPressGestureRecognizer) {
            switch gr.state {
            case .began:
                parent.onLongPressStart?()
            case .ended, .cancelled, .failed:
                parent.onLongPressEnd?()
            default:
                break
            }
        }
    }
}

// MARK: - PlayerPanGestureInstaller

/// The full-screen player's single pan: horizontal for the previous / next video,
/// downward to collapse into the mini player. It is installed on the root view, so it
/// also sees touches that land on the controls, and replaces both the pan that lived
/// in PlayerSwipeGestureOverlay and the controls' SwiftUI drag.
///
/// The axis is locked on the first movement (`PlayerPanGesture.axis`). Touches on a
/// UIControl never start it, and it does not begin while `isEnabled` is false
/// (scrubbing, menus). A cancelled or failed pan still ends, so a drag always settles.
struct PlayerPanGestureInstaller: UIViewRepresentable {
    var isEnabled: Bool
    /// Axis and translation from touch-down.
    var onChanged: (PlayerPanAxis, CGPoint) -> Void
    /// Axis, translation and velocity (points per second). `cancelled` is true when the
    /// system cancelled the pan or it failed; the velocity is zero then.
    var onEnded: (_ axis: PlayerPanAxis, _ translation: CGPoint, _ velocity: CGPoint, _ cancelled: Bool) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> InstallerView {
        let view = InstallerView()
        view.isUserInteractionEnabled = false
        view.coordinator = context.coordinator
        return view
    }

    func updateUIView(_ uiView: InstallerView, context: Context) {
        context.coordinator.parent = self
    }

    static func dismantleUIView(_ uiView: InstallerView, coordinator: Coordinator) {
        coordinator.uninstall()
    }

    /// Zero-size marker view: once in a window it installs the pan on the root view.
    final class InstallerView: UIView {
        weak var coordinator: Coordinator?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if let window {
                coordinator?.install(on: window.rootViewController?.view ?? window)
            } else {
                coordinator?.uninstall()
            }
        }
    }

    @MainActor
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var parent: PlayerPanGestureInstaller
        private var pan: UIPanGestureRecognizer?
        private var axis: PlayerPanAxis?

        init(_ parent: PlayerPanGestureInstaller) { self.parent = parent }

        func install(on view: UIView) {
            guard pan?.view !== view else { return }
            uninstall()
            let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
            pan.maximumNumberOfTouches = 1
            pan.cancelsTouchesInView = true
            pan.delegate = self
            view.addGestureRecognizer(pan)
            self.pan = pan
        }

        func uninstall() {
            if let pan { pan.view?.removeGestureRecognizer(pan) }
            pan = nil
            axis = nil
        }

        @objc func handlePan(_ gr: UIPanGestureRecognizer) {
            let translation = gr.translation(in: gr.view)
            switch gr.state {
            case .began, .changed:
                if axis == nil {
                    axis = PlayerPanGesture.axis(for: CGVector(dx: translation.x, dy: translation.y))
                }
                if let axis { parent.onChanged(axis, translation) }
            case .ended:
                if let axis { parent.onEnded(axis, translation, gr.velocity(in: gr.view), false) }
                axis = nil
            case .cancelled, .failed:
                if let axis { parent.onEnded(axis, translation, .zero, true) }
                axis = nil
            default:
                break
            }
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            parent.isEnabled
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            var view = touch.view
            while let current = view {
                if current is UIControl { return false }
                view = current.superview
            }
            return true
        }
    }
}
#endif  // os(iOS)
#endif  // os(iOS) || os(tvOS)

// MARK: - PlayerNSLayerView (macOS)

#if os(macOS)
/// NSViewRepresentable wrapping an AVPlayerLayer directly — the AppKit
/// equivalent of PlayerAVLayerView on iOS/tvOS.
struct PlayerNSLayerView: NSViewRepresentable {
    let player: AVPlayer?
    var videoGravity: AVLayerVideoGravity = .resizeAspect

    func makeNSView(context: Context) -> _PlayerNSView {
        let view = _PlayerNSView()
        view.playerLayer.player = player
        view.playerLayer.videoGravity = videoGravity
        return view
    }

    func updateNSView(_ nsView: _PlayerNSView, context: Context) {
        nsView.playerLayer.player = player
        nsView.playerLayer.videoGravity = videoGravity
    }

    final class _PlayerNSView: NSView {
        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            layer = AVPlayerLayer()
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }

        override func layout() {
            super.layout()
            playerLayer.frame = bounds
        }
    }
}
#endif
