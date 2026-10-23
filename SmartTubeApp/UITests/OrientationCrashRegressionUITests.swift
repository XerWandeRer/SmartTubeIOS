import XCTest

// MARK: - OrientationCrashRegressionUITests
//
// Regression test for Crashlytics issue 1bce7ef11c47da56fe887213f0d7a652:
// EXC_BREAKPOINT in the requestGeometryUpdate(_:) error handler (now in PlayerOrientationController).
//
// Root cause: The error handler closure `{ error in ... }` inherited @MainActor
// isolation from the enclosing `Task { @MainActor in ... }`. On iOS 26+,
// UIWindowScene._performIOSGeometryRequestWithPreferences:errorHandler: calls the
// handler on a background GCD queue. Swift 6's _swift_task_checkIsolatedSwift
// detects the isolation violation and crashes with EXC_BREAKPOINT.
//
// Fix: Extracted error handler as a file-scope @Sendable function in
// PlayerOrientationController.swift (geometryUpdateErrorHandler), explicitly non-isolated.
//
// Opening the player requests its geometry (the video decides the orientation);
// the test then rotates the device
// landscape ↔ portrait while the video plays.

final class OrientationCrashRegressionUITests: XCTestCase {

    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
    }

    override func tearDownWithError() throws {
        #if os(iOS)
        XCUIDevice.shared.orientation = .portrait
        #endif
        app = nil
    }

    // MARK: - Tests

    /// Rotating between landscape and portrait while a video plays must not crash.
    /// This covers the requestGeometryUpdate error-handler actor-isolation fix.
    func testOrientationRotationDoesNotCrash() throws {
        app.launchArguments = [
            "--uitesting",
            "--uitesting-disable-tos-player-on-ios",
            "--uitesting-deeplink-video=dQw4w9WgXcQ",
        ]
        app.launch()

        let player = app.staticTexts["player.titleLabel"].firstMatch
        guard player.waitForExistence(timeout: 20) else {
            try captureAndSkip("Player did not open within 20 s — network unavailable or video inaccessible", in: app)
        }

        // Allow the video to start buffering before rotating.
        // Rotate the device to landscape
        #if os(iOS)
        XCUIDevice.shared.orientation = .landscapeLeft
        // Brief dwell to allow UIKit geometry update to complete and any error callback to fire.
        Thread.sleep(forTimeInterval: 1.0)

        // Rotate the device back to portrait
        #if os(iOS)
        XCUIDevice.shared.orientation = .portrait
        #endif
        Thread.sleep(forTimeInterval: 1.0)

        // A second full cycle verifies the geometry update is repeatable.
        #if os(iOS)
        XCUIDevice.shared.orientation = .landscapeRight
        #endif
        Thread.sleep(forTimeInterval: 1.0)
        #if os(iOS)
        XCUIDevice.shared.orientation = .portrait
        #endif
        #endif

        // If we reach here the app has not crashed. Confirm the player is still alive.
        XCTAssertTrue(
            player.exists,
            "Player must still exist after landscape ↔ portrait rotation cycle")
    }

    #if os(iOS)
    /// The 16:9 video locks the window to landscape: rotating the device to portrait
    /// does not rotate it back. Minimizing the player returns the window to portrait.
    func testLandscapeVideoLocksWindowUntilMinimized() throws {
        app.launchArguments = [
            "--uitesting",
            "--uitesting-disable-tos-player-on-ios",
            "--uitesting-deeplink-video=dQw4w9WgXcQ",
        ]
        app.launch()

        let player = app.staticTexts["player.titleLabel"].firstMatch
        guard player.waitForExistence(timeout: 20) else {
            try captureAndSkip("Player did not open within 20 s — network unavailable or video inaccessible", in: app)
        }
        let window = app.windows.firstMatch
        XCTAssertTrue(
            waitForWindow(window, landscape: true, timeout: 10),
            "A 16:9 video must rotate the window to landscape")

        XCUIDevice.shared.orientation = .portrait
        XCTAssertFalse(
            waitForWindow(window, landscape: false, timeout: 3),
            "Rotating the device must not rotate a landscape video's window to portrait")

        let back = app.buttons["player.backButton"].firstMatch
        if !back.exists {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        }
        XCTAssertTrue(back.waitForExistence(timeout: 5), "player.backButton must appear")
        back.tap()
        XCTAssertTrue(
            app.otherElements["miniPlayer.bar"].firstMatch.waitForExistence(timeout: 5),
            "The back button must minimize the player")
        XCTAssertTrue(
            waitForWindow(window, landscape: false, timeout: 10),
            "Minimizing a player opened in portrait must rotate the window back to portrait")
    }

    /// Waits until the window's frame is landscape (or portrait). Returns false on timeout.
    private func waitForWindow(_ window: XCUIElement, landscape: Bool, timeout: TimeInterval) -> Bool {
        let predicate = NSPredicate { _, _ in
            let frame = window.frame
            return landscape ? frame.width > frame.height : frame.height > frame.width
        }
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: nil)
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }
    #endif
}
