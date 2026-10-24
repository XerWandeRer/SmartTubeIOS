#if os(iOS)
import AVFoundation
import AVKit
import UIKit
import Observation
import SmartTubeIOSCore
import OSLog

private let storeLog = Logger(subsystem: "com.void.smarttube.app", category: "PlayerStateStore")

// MARK: - PersistentPlayerHostView

/// A UIView that owns an AVPlayerLayer for the lifetime of the app.
/// Its reference lives in PlayerStateStore, so the layer — and the AVPlayer
/// connection — survive PlayerView appearing and disappearing.
///
/// ResidentPlayerLayer hosts it once, for both the full-screen and the mini player.
final class PersistentPlayerHostView: UIView {

    let playerLayer = AVPlayerLayer()

    var videoGravity: AVLayerVideoGravity {
        get { playerLayer.videoGravity }
        set { playerLayer.videoGravity = newValue }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        playerLayer.backgroundColor = UIColor.black.cgColor
        layer.addSublayer(playerLayer)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    override func layoutSubviews() {
        super.layoutSubviews()
        playerLayer.frame = bounds
    }
}

// MARK: - PlayerStateStore

/// Centralised iOS playback state for the in-app mini-player.
///
/// Owns the single `PlaybackViewModel` and `PersistentPlayerHostView` so they
/// survive PlayerView presentation/dismiss cycles. Injected as an environment
/// object at the `AppEntry` level; accessed via `@Environment(PlayerStateStore.self)`.
@MainActor
@Observable
public final class PlayerStateStore {

    // MARK: - Presentation state

    public enum Presentation: Equatable {
        case hidden
        case miniPlayer
        case fullScreen
    }

    public private(set) var presentation: Presentation = .hidden

    /// The video that is currently loaded or playing. Non-nil when presentation != .hidden.
    private(set) var currentVideo: Video? = nil

    /// The video whose frames the AVPlayer is actually rendering.
    ///
    /// During a load (`vm.isLoading == true`), `currentVideo` has already been updated to
    /// the newly selected video but `AVPlayerItem` may not be ready yet — the player layer
    /// is still showing the previous video's frames. `playingVideo` resolves this by
    /// returning the last-confirmed playing video while the new one is loading, so the
    /// MiniPlayer label stays in sync with the visual content.
    ///
    /// - When idle (`isLoading == false`): equals `currentVideo`.
    /// - When loading (`isLoading == true`) and there is a previous video: equals that
    ///   video (last entry in `vm.history` — pushed onto the stack just before the new
    ///   video starts loading).
    /// - When loading the very first video ever (history is empty): returns `nil` (the
    ///   MiniPlayer is hidden during a first-play full-screen open, so this is harmless).
    var playingVideo: Video? {
        vm.isLoading ? vm.history.last : currentVideo
    }

    /// Horizontal offset of PlayerView's previous / next slide; ResidentPlayerLayer
    /// moves the video by the same amount.
    var slideOffset: CGFloat = 0

    // MARK: - Video size

    /// Decoded size of a video, reported once AVPlayer knows it.
    struct VideoSize: Equatable {
        let videoID: String
        let size: CGSize
    }

    /// The last decoded size PlayerView reported.
    private(set) var videoSize: VideoSize?

    func videoSizeKnown(videoID: String, size: CGSize) {
        videoSize = VideoSize(videoID: videoID, size: size)
    }

    /// Width / height of the video on screen. Until its decoded size is known, a guess
    /// from the Short flag.
    var videoAspectRatio: CGFloat {
        if let videoSize, videoSize.videoID == vm.currentVideoId, videoSize.size.height > 0 {
            return videoSize.size.width / videoSize.size.height
        }
        return (vm.currentVideo ?? currentVideo)?.isShort == true
            ? ResidentPlayerGeometry.defaultShortAspectRatio : ResidentPlayerGeometry.defaultAspectRatio
    }

    // MARK: - Imperative dismiss hook

    /// Set by LandscapePresenter's coordinator when a full-screen player is presented.
    /// Fired imperatively by minimize() / stop() to bypass the SwiftUI update-propagation
    /// pause that occurs when the presenting VC's view is removed from the window by
    /// UIKit's .fullScreen presentation style (so updateUIViewController never fires).
    var dismissPlayerAction: (() -> Void)?

    // MARK: - Owned objects

    /// The single PlaybackViewModel for the app. Lives for the app's lifetime.
    public let vm: PlaybackViewModel

    /// The UIView that owns the AVPlayerLayer. Never deallocated; hosted by
    /// ResidentPlayerLayer in both the full-screen and the mini player.
    let playerHostView: PersistentPlayerHostView

    // MARK: - Init

    public init(api: InnerTubeAPI) {
        let vm = PlaybackViewModel(api: api)
        self.vm = vm
        let hostView = PersistentPlayerHostView()
        hostView.playerLayer.player = vm.player
        self.playerHostView = hostView
        vm.onSystemBackgroundPause = { [weak self] in self?.detachVideoLayerForBackground() }
        // UI tests start the mini player from its defaults (corner and size are persisted).
        if ProcessInfo.processInfo.arguments.contains("--uitesting-reset-mini-player") {
            UserDefaults.standard.removeObject(forKey: ResidentPlayerLayer.cornerDefaultsKey)
            UserDefaults.standard.removeObject(forKey: ResidentPlayerLayer.scaleDefaultsKey)
        }
        didBecomeActiveObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleAppDidBecomeActive() }
        }
    }

    @ObservationIgnored nonisolated(unsafe) private var didBecomeActiveObserver: Any?

    deinit {
        if let obs = didBecomeActiveObserver { NotificationCenter.default.removeObserver(obs) }
    }

    // MARK: - Picture in Picture

    /// One controller for the app's lifetime, bound to the persistent layer, so
    /// automatic PiP works from both the full-screen and the mini player.
    private(set) var pipController: AVPictureInPictureController?
    private var pipDelegate: PiPDelegate?
    /// The app is closing PiP itself because it became active (app icon, app switcher,
    /// unlock); the player then stays as it was before PiP.
    @ObservationIgnored private var isStoppingPictureInPictureForActivation = false

    /// Creates the PiP controller once the player has an item. Creating it before
    /// any item is loaded leaves isPictureInPicturePossible stuck at false.
    func preparePictureInPicture(enabled: Bool) {
        guard enabled else {
            pipController = nil
            pipDelegate = nil
            return
        }
        let uiTestingOverride = ProcessInfo.processInfo.arguments.contains("--uitesting-enable-pip")
        guard pipController == nil, vm.player.currentItem != nil,
            uiTestingOverride || AVPictureInPictureController.isPictureInPictureSupported()
        else { return }
        reattachVideoLayer()
        let pip = AVPictureInPictureController(playerLayer: playerHostView.playerLayer)
        pip?.canStartPictureInPictureAutomaticallyFromInline = true
        let delegate = PiPDelegate(
            onActiveChange: { [weak self] active in
                self?.vm.isPictureInPictureActive = active
                if !active { self?.isStoppingPictureInPictureForActivation = false }
                storeLog.notice("[PiP] active=\(active)")
            },
            onDidStart: { [weak self] in self?.vm.updateNowPlayingInfo() },
            onRestore: { [weak self] in self?.restoreFromPictureInPicture() }
        )
        pip?.delegate = delegate
        pipDelegate = delegate
        pipController = pip
        storeLog.notice("[PiP] controller created — possible=\(pip?.isPictureInPicturePossible ?? false)")
    }

    /// AVKit hands the video back from PiP. The PiP window's restore button opens the
    /// full-screen player (like YouTube); a stop the app asked for on activation keeps
    /// the full-screen or mini player that was showing before PiP.
    private func restoreFromPictureInPicture() {
        let byActivation = isStoppingPictureInPictureForActivation
        storeLog.notice(
            "[PiP] restore — byActivation=\(byActivation) presentation=\(String(describing: self.presentation))")
        guard !byActivation, presentation == .miniPlayer else { return }
        expand()
    }

    // MARK: - Background playback

    /// Detaches the player from the video layer so iOS keeps playing audio in the
    /// background. Skipped while PiP is showing the layer.
    private func detachVideoLayerForBackground() {
        guard !vm.isPictureInPictureActive, playerHostView.playerLayer.player != nil else { return }
        playerHostView.playerLayer.player = nil
        storeLog.notice("[background] video layer detached")
    }

    private func reattachVideoLayer() {
        guard playerHostView.playerLayer.player == nil else { return }
        playerHostView.playerLayer.player = vm.player
        storeLog.notice("[background] video layer reattached")
    }

    /// Returning to the app (unlock, app icon, app switcher) brings the video back
    /// into the player: reattach the layer and close PiP.
    private func handleAppDidBecomeActive() {
        reattachVideoLayer()
        if let pip = pipController, pip.isPictureInPictureActive {
            isStoppingPictureInPictureForActivation = true
            pip.stopPictureInPicture()
            storeLog.notice("[PiP] app became active — stopping PiP")
        }
    }

    // MARK: - Orientation

    /// The full-screen video last reported to `PlayerOrientationController`.
    @ObservationIgnored private var reportedFullScreenVideo: Video?

    /// Reports the full-screen video to `PlayerOrientationController` when it changes,
    /// so the orientation follows this store's state, not the presenting view controller.
    private func syncOrientation() {
        let video = presentation == .fullScreen ? currentVideo : nil
        guard video?.id != reportedFullScreenVideo?.id else { return }
        reportedFullScreenVideo = video
        PlayerOrientationController.shared.fullScreenVideoChanged(video)
    }

    // MARK: - Actions

    /// Load `video` (if not already loaded) and present the full-screen player.
    public func play(video: Video) {
        storeLog.notice(
            "[PlayerStateStore] play — id=\(video.id) currentPresentation=\(String(describing: self.presentation))")
        // Stamp intended_video_id immediately — before load() runs and before the
        // breadcrumb buffer can fill. Comparing with active_video_id in a report
        // reveals prefetch-race / wrong-card-tap scenarios.
        CrashlyticsLogger.setIntendedVideo(id: video.id, title: video.title)
        // Also reload when:
        //   1. Different video — always load
        //   2. No current item — item was cleared by stop() (legacy path)
        //   3. Not playing — item is parked (fix12 park path): stop() keeps the
        //      AVPlayerItem alive but pauses and sets isPlaying=false. On re-tap,
        //      call load() so the park fast-path in PlaybackViewModel resumes it.
        if vm.currentVideoId != video.id || vm.player.currentItem == nil || !vm.isPlaying {
            vm.load(video: video)
        }
        currentVideo = video
        presentation = .fullScreen
        syncOrientation()
        storeLog.notice("[PlayerStateStore] play — presentation set to .fullScreen")
    }

    /// Collapse the full-screen player to the mini-player bar. Playback continues.
    public func minimize() {
        storeLog.notice("[PlayerStateStore] minimize — currentPresentation=\(String(describing: self.presentation))")
        presentation = .miniPlayer
        syncOrientation()
        let action = dismissPlayerAction
        dismissPlayerAction = nil
        storeLog.notice(
            "[PlayerStateStore] minimize — presentation set to .miniPlayer, dismissPlayerAction=\(action != nil)")
        action?()
    }

    /// Expand the mini-player back to full-screen.
    func expand() {
        storeLog.notice("[PlayerStateStore] expand — currentPresentation=\(String(describing: self.presentation))")
        presentation = .fullScreen
        syncOrientation()
        storeLog.notice("[PlayerStateStore] expand — presentation set to .fullScreen")
    }

    /// Stop playback completely and hide the player UI.
    func stop() {
        storeLog.notice("[PlayerStateStore] stop — currentPresentation=\(String(describing: self.presentation))")
        vm.stop()
        currentVideo = nil
        presentation = .hidden
        syncOrientation()
        let action = dismissPlayerAction
        dismissPlayerAction = nil
        storeLog.notice("[PlayerStateStore] stop — presentation set to .hidden, dismissPlayerAction=\(action != nil)")
        action?()
    }
}
#endif
