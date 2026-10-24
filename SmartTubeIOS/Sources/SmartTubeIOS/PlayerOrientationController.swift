#if os(iOS)
import Foundation
import UIKit
import OSLog
import SmartTubeIOSCore

private let orientationLog = Logger(subsystem: appSubsystem, category: "Orientation")

/// File-scope handler passed to `UIWindowScene.requestGeometryUpdate(_:errorHandler:)`.
/// Must live outside any `@MainActor` class so it does NOT inherit actor isolation.
/// On iOS 26+ UIKit calls this handler on a background GCD queue via `_BSActionResponder`;
/// a `@MainActor`-isolated closure would crash with `EXC_BREAKPOINT` in
/// `_swift_task_checkIsolatedSwift` / `_dispatch_assert_queue_fail`.
@Sendable
private func geometryUpdateErrorHandler(_ error: Error) {
    orientationLog.error("[PlayerOrientation] requestGeometryUpdate error: \(error.localizedDescription)")
}

/// Single source of truth for the full-screen player's interface orientation.
///
/// The video decides: landscape videos get `.landscape` (the sensor only picks
/// left or right), portrait videos and Shorts get `.portrait`. Device rotation
/// never switches between the two. The app delegate returns `appMask`, which is the
/// player's `mask` while a full-screen player is shown. The player stores report
/// their full-screen video through `fullScreenVideoChanged(_:)`, so neither the
/// presenting view controller nor the player view's appear/disappear timing matters.
@MainActor
@Observable
public final class PlayerOrientationController {
    public static let shared = PlayerOrientationController()

    private init() {
        // Unlocking or returning from the home screen: UIKit may have rotated the
        // window meanwhile (the lock screen is portrait-only). The player lives in a
        // UIKit-presented hosting controller, where SwiftUI's scenePhase never changes,
        // so listen to UIKit directly.
        didBecomeActiveObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated { PlayerOrientationController.shared.appDidBecomeActive() }
        }
    }

    @ObservationIgnored private var didBecomeActiveObserver: Any?

    private(set) var policy = PlayerOrientationPolicy()
    /// True while a full-screen player is presented.
    private(set) var isPresented = false
    /// The interface was portrait when the player opened.
    @ObservationIgnored private var openedInPortrait = false
    /// Landscape was requested while `openedInPortrait` — closing rotates back.
    @ObservationIgnored private var forcedLandscape = false
    /// A rotate-back is queued. A player presented before it runs (dismiss and
    /// re-present for another video) cancels it and inherits the portrait origin.
    @ObservationIgnored private var rotateBackPending = false

    /// The last dismissal rotates the window back to portrait (the player forced
    /// landscape). ResidentPlayerLayer waits for that rotation before collapsing.
    private(set) var dismissRotatesToPortrait = false

    /// The orientations the player supports right now.
    var mask: UIInterfaceOrientationMask { policy.wantsLandscape ? .landscape : .portrait }

    /// True while the Shorts player is on screen. It is a SwiftUI full-screen cover
    /// whose hosting controller cannot be subclassed, so the lock lives in `appMask`.
    private(set) var isShortsPlayerOnScreen = false

    /// The app-wide mask returned by the app delegate: portrait while Shorts play
    /// (they are vertical and fill the screen), the player's mask while a full-screen
    /// player is shown, otherwise everything but upside down.
    public var appMask: UIInterfaceOrientationMask {
        if isShortsPlayerOnScreen { return .portrait }
        if isPresented { return mask }
        return .allButUpsideDown
    }

    // MARK: - Inputs

    /// A player store's full-screen video changed: non-nil while its player is full
    /// screen, nil once it is minimized or stopped.
    func fullScreenVideoChanged(_ video: Video?) {
        if let video {
            playerPresented(video: video)
        } else {
            playerDismissed()
        }
    }

    private func playerPresented(video: Video) {
        if !isPresented {
            isPresented = true
            if rotateBackPending {
                rotateBackPending = false
                openedInPortrait = true
            } else {
                openedInPortrait = Self.windowScene()?.interfaceOrientation.isPortrait ?? true
            }
            forcedLandscape = false
        }
        policy.begin(videoID: video.id, isShort: video.isShort)
        apply(reason: "presented id=\(video.id) isShort=\(video.isShort)")
    }

    /// Another video started inside the open player (autoplay, next, related).
    func videoChanged(to video: Video) {
        guard isPresented, video.id != policy.videoID else { return }
        policy.begin(videoID: video.id, isShort: video.isShort)
        apply(reason: "video changed id=\(video.id) isShort=\(video.isShort)")
    }

    /// The player reported the decoded size of `videoID`.
    func videoSizeKnown(videoID: String, size: CGSize) {
        let changed = policy.confirmAspect(
            videoID: videoID, width: Double(size.width), height: Double(size.height))
        orientationLog.notice(
            "[PlayerOrientation] size \(Int(size.width))x\(Int(size.height)) id=\(videoID, privacy: .public) changed=\(changed)"
        )
        guard changed, isPresented else { return }
        apply(reason: "decoded size")
    }

    /// The player's orientation button: flips portrait/landscape for the current video.
    func toggleOrientation() {
        guard isPresented else { return }
        policy.toggleManually()
        apply(reason: "manual toggle")
    }

    private func appDidBecomeActive() {
        if isShortsPlayerOnScreen {
            invalidateOrientationCache()
            requestGeometryUpdate(.portrait)
        }
        reassert(reason: "app active")
    }

    /// Requests the current mask again, changed or not. Used when the app becomes
    /// active (unlock, home screen, returning from PiP): UIKit may have rotated the
    /// window meanwhile (e.g. the lock screen is portrait-only).
    func reassert(reason: String) {
        guard isPresented else { return }
        apply(reason: reason)
    }

    func shortsPlayerAppeared() {
        isShortsPlayerOnScreen = true
        orientationLog.notice("[PlayerOrientation] Shorts player on screen — portrait only")
        invalidateOrientationCache()
        requestGeometryUpdate(.portrait)
    }

    func shortsPlayerDisappeared() {
        guard isShortsPlayerOnScreen else { return }
        isShortsPlayerOnScreen = false
        orientationLog.notice("[PlayerOrientation] Shorts player closed")
        invalidateOrientationCache()
    }

    private func playerDismissed() {
        guard isPresented else { return }
        isPresented = false
        let rotateBack = forcedLandscape
        forcedLandscape = false
        dismissRotatesToPortrait = rotateBack
        orientationLog.notice("[PlayerOrientation] dismissed — rotateBackToPortrait=\(rotateBack)")
        guard rotateBack else { return }
        rotateBackPending = true
        invalidateOrientationCache()
        requestGeometryUpdate(.portrait, rotatingBack: true)
    }

    // MARK: - Applying

    private func apply(reason: String) {
        let mask = mask
        if mask == .landscape, openedInPortrait { forcedLandscape = true }
        orientationLog.notice(
            "[PlayerOrientation] apply mask=\(mask == .landscape ? "landscape" : "portrait", privacy: .public) — \(reason, privacy: .public)"
        )
        invalidateOrientationCache()
        requestGeometryUpdate(mask)
    }

    private static func windowScene() -> UIWindowScene? {
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
    }

    private func invalidateOrientationCache() {
        guard let scene = Self.windowScene() else {
            orientationLog.error("[PlayerOrientation] invalidateOrientationCache — no UIWindowScene found")
            return
        }
        let window =
            scene.windows.first(where: { $0.rootViewController != nil })
            ?? scene.windows.first
        let rootVC = window?.rootViewController
        rootVC?.setNeedsUpdateOfSupportedInterfaceOrientations()
        var topVC = rootVC
        while let presented = topVC?.presentedViewController { topVC = presented }
        if topVC !== rootVC {
            topVC?.setNeedsUpdateOfSupportedInterfaceOrientations()
        }
    }

    private func requestGeometryUpdate(_ mask: UIInterfaceOrientationMask, rotatingBack: Bool = false) {
        Task { @MainActor in
            guard let scene = Self.windowScene() else {
                orientationLog.error("[PlayerOrientation] requestGeometryUpdate — no UIWindowScene found")
                return
            }
            // Brief yield so UIKit processes setNeedsUpdateOfSupportedInterfaceOrientations
            // before requestGeometryUpdate consults the updated mask.
            try? await Task.sleep(for: .milliseconds(50))
            if rotatingBack {
                guard rotateBackPending else { return }
                rotateBackPending = false
            }
            let pref = UIWindowScene.GeometryPreferences.iOS(interfaceOrientations: mask)
            scene.requestGeometryUpdate(pref, errorHandler: geometryUpdateErrorHandler)
        }
    }
}
#endif
