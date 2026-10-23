#if os(iOS)
import UIKit
import OSLog
import SmartTubeIOS

private let appDelegateLog = Logger(subsystem: "com.void.smarttube.app", category: "AppDelegate")

/// Provides the per-screen orientation mask that UIKit queries on every
/// orientation-change event. Returns `.allButUpsideDown` so that
/// `UIWindowScene.requestGeometryUpdate` can successfully request landscape
/// when the player opens and portrait when it closes, and `.portrait` while the
/// Shorts player is on screen. Both come from `PlayerOrientationController.appMask`.
@MainActor
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        supportedInterfaceOrientationsFor window: UIWindow?
    ) -> UIInterfaceOrientationMask {
        // .allButUpsideDown except while Shorts play, so that:
        // 1. UIKit's intersection with the view controller hierarchy does not
        //    restrict to portrait-only while the full-screen player cover is
        //    being presented (PresentationHostingController caches the supported
        //    mask at creation time, before PlayerView.onAppear fires).
        // 2. PlayerOrientationController can successfully request
        //    landscape when the player opens and portrait when it closes.
        // 3. The Shorts player (a plain SwiftUI fullScreenCover) stays portrait.
        let mask = PlayerOrientationController.shared.appMask
        appDelegateLog.notice(
            "[AppDelegate] supportedInterfaceOrientationsFor — returning mask=\(mask.rawValue)"
        )
        return mask
    }
}
#endif
