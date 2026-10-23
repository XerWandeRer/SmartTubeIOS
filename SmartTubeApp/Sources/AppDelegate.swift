#if os(iOS)
import UIKit
import OSLog
import SmartTubeIOS

private let appDelegateLog = Logger(subsystem: "com.void.smarttube.app", category: "AppDelegate")

/// Provides the per-screen orientation mask that UIKit queries on every
/// orientation-change event: `.portrait` while the Shorts player is on screen,
/// the player's mask while a full-screen player is shown, otherwise
/// `.allButUpsideDown`. All three come from `PlayerOrientationController.appMask`.
@MainActor
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        supportedInterfaceOrientationsFor window: UIWindow?
    ) -> UIInterfaceOrientationMask {
        // 1. The full-screen player's orientation is decided here, so it does not
        //    depend on which view controller hosts the player.
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
