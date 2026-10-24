import XCTest

// AGENT-POST-RUN-CHECK: ui-tests-with-logs
//
// After every run of this file, load .github/skills/ui-tests-with-logs/SKILL.md
// and inspect the extracted device log.
//
// LEGITIMATE skip:
//   - Network unavailable or Home feed returned no cards.
//     Device log should show: "[loadAsync] start" followed by a network error.
//   - Quality button never became enabled within 20s — formats did not load.
//     Device log should show: "availableFormats after initial dedup: raw=0" or
//     "[tryAllStreams] muxed 360p" with no subsequent availableFormats update.
//
// BUG skip (must fix before closing):
//   - Quality button exists=false (button still hidden rather than disabled).
//     This would be a regression of #186.
//
// Log events to verify for #186:
//   ✓ [loadAsync] availableFormats after initial dedup: raw=N deduped=M
//   ✓ Quality button exists AND (isEnabled==true when formats loaded)
//
// RED FLAGS in device log:
//   - availableFormats after initial dedup: raw=0 → quality picker will be empty
//   - [qualityPicker] → picker opened but no items → regression in format parsing
//   - [webView/HLS] synthesized #EXTINF … for master manifest (210KB) → YTHLSProxyLoader
//     treating master as variant; causes CoreMediaErrorDomain -12642 and WKWebView path fails
//   - [webView/HLS] ❌ AVPlayerItem failed: …error -12642 → master manifest was EXTINF-mangled
//     (regression of #205 proxy fix + YTHLSProxyLoader master guard)

// MARK: - QuickAccessRowUITests
//
// Regression test for GitHub issue #52: quick-access row should appear
// below the progress bar with speed/quality/audio-track/sleep-timer buttons.
//
// Opens the player from the home feed (same approach as PlayerControlsUITests)
// to ensure a real video is loaded before checking for the quick-access row.

final class QuickAccessRowUITests: XCTestCase {

    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = [
            "--uitesting",
            "--uitesting-disable-tos-player-on-ios",
            "--uitesting-show-controls",
            "--uitesting-disable-sponsorblock",
        ]
        app.launch()
    }

    override func tearDownWithError() throws {
        app = nil
    }

    // MARK: - Helpers

    /// Opens a video from the home feed and waits for the player to appear.
    /// Skips the test if the network is unavailable.
    private func openPlayerFromHome() throws {
        UITestHelpers.tapTab(named: "Home", in: app)
        guard let card = UITestHelpers.waitForVideoCards(in: app, timeout: 20) else {
            try captureAndSkip("No video cards on Home — network unavailable or feed empty", in: app)
        }
        guard UITestHelpers.openPlayer(from: card, in: app) else {
            try captureAndSkip("Player did not open within 15 s — network unavailable or timing-dependent", in: app)
        }
        _ = app.staticTexts["player.titleLabel"].firstMatch.waitForExistence(timeout: 5)
    }

    /// Taps the player center to reveal controls, retrying up to 5 times.
    /// With --uitesting-show-controls the controls overlay stays up permanently,
    /// so in practice this should return on the first check.
    private func showControls() {
        let playPause = app.buttons["player.playPauseButton"].firstMatch
        for _ in 0..<5 {
            if playPause.exists { return }
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            Thread.sleep(forTimeInterval: 1.0)
        }
    }

    func testQuickAccessSpeedButtonVisibleInPlayer() throws {
        try openPlayerFromHome()
        showControls()
        XCTAssertTrue(
            app.buttons["player.quickAccess.speed"].waitForExistence(timeout: 10),
            "Quick-access speed button should be visible below the progress bar")
    }

    func testQuickAccessSpeedButtonOpensPicker() throws {
        try openPlayerFromHome()
        showControls()
        let speedBtn = app.buttons["player.quickAccess.speed"]
        guard speedBtn.waitForExistence(timeout: 10) else {
            try captureAndSkip(
                "player.quickAccess.speed not found — may need landscape mode or controls were auto-hidden", in: app)
        }
        // Use a coordinate tap so the UIKit touch event goes directly to the button
        // frame, bypassing any accessibility chain wrapping from the .contain modifier.
        speedBtn.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        // Check for the picker via a broad descendants search, then fall back to
        // a "Cancel" button which is always present inside every picker overlay.
        let pickerByID = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier == 'player.speedPicker'"))
            .firstMatch
        let cancelBtn = app.buttons["Cancel"].firstMatch
        let pickerAppeared =
            pickerByID.waitForExistence(timeout: 5)
            || cancelBtn.waitForExistence(timeout: 2)
        XCTAssertTrue(
            pickerAppeared,
            "Tapping quick-access speed button should open the speed picker overlay")
    }

    func testQuickAccessRowHasAccessibilityIdentifier() throws {
        try openPlayerFromHome()
        showControls()
        XCTAssertTrue(
            app.otherElements["player.quickAccessRow"].waitForExistence(timeout: 10),
            "Quick-access row should have accessibility identifier 'player.quickAccessRow'")
    }

    func testQuickAccessSleepTimerButtonVisible() throws {
        try openPlayerFromHome()
        showControls()
        XCTAssertTrue(
            app.buttons["player.quickAccess.sleepTimer"].waitForExistence(timeout: 10),
            "Quick-access sleep timer button should be visible")
    }

    // MARK: - #186 regression: quality button always visible

    /// Verifies the quality button is always present in the quick-access row
    /// regardless of whether `availableFormats` has loaded yet.
    /// Regression for #186: previously the button was removed from the view
    /// hierarchy when `availableFormats` was empty, making it permanently
    /// absent for muxed-only or slow-loading videos.
    func testQualityButtonAlwaysVisibleInPlayer() throws {
        try openPlayerFromHome()
        showControls()
        let qualityBtn = app.buttons["player.quickAccess.quality"]
        XCTAssertTrue(
            qualityBtn.waitForExistence(timeout: 15),
            "Quality quick-access button should always be present in the player controls")
        // Wait for formats to load and the button to become enabled, then verify
        // tapping it opens the quality picker.
        let enabled = NSPredicate(format: "isEnabled == true")
        let enabledExpectation = XCTNSPredicateExpectation(predicate: enabled, object: qualityBtn)
        let result = XCTWaiter().wait(for: [enabledExpectation], timeout: 20)
        guard result == .completed else {
            try captureAndSkip("Quality button never became enabled within 20 s — formats may not have loaded", in: app)
        }
        qualityBtn.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let pickerAppeared = app.buttons["Cancel"].firstMatch.waitForExistence(timeout: 5)
        XCTAssertTrue(pickerAppeared, "Tapping the enabled quality button should open the quality picker")
    }

    // MARK: - XER-15 regression: chosen speed survives pause, quality switch and next video

    /// Before the fix, resume, quality switches and the next video re-applied the
    /// speed that was current when the player view appeared, so 1.5× fell back to 1×.
    /// The quick-access label reads the stored setting, so the test measures the
    /// real rate from how fast `player.currentTimeLabel` advances.
    func testChosenSpeedSurvivesPauseQualitySwitchAndNextVideo() throws {
        app.terminate()
        app.launchArguments.append("--uitesting-reset-settings")
        app.launch()
        try openPlayerFromHome()
        showControls()

        let speedBtn = app.buttons["player.quickAccess.speed"]
        guard speedBtn.waitForExistence(timeout: 10) else {
            try captureAndSkip("player.quickAccess.speed not found", in: app)
        }
        try assertRate(near: 1.0, "1× baseline before choosing a speed")

        speedBtn.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let picker = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier == 'player.speedPicker'")).firstMatch
        XCTAssertTrue(picker.waitForExistence(timeout: 5), "speed picker should open")
        // The picker's identifier propagates to its header too; the rows live in its scroll view.
        let rows = app.scrollViews["player.speedPicker"].firstMatch
        let option = rows.buttons.matching(NSPredicate(format: "label BEGINSWITH '1.5'")).firstMatch
        XCTAssertTrue(option.waitForExistence(timeout: 5), "1.5× option should be listed")
        if !option.isHittable { rows.swipeUp() }
        option.tap()
        try assertRate(near: 1.5, "right after choosing 1.5×")

        revealControls()
        let playPause = app.buttons["player.playPauseButton"].firstMatch
        XCTAssertTrue(playPause.waitForExistence(timeout: 5))
        playPause.tap()
        playPause.tap()
        try assertRate(near: 1.5, "after pause and resume")

        try switchQualityIfPossible()

        revealControls()
        let title = app.staticTexts["player.titleLabel"].firstMatch
        let oldTitle = title.label
        let nextBtn = app.buttons["player.nextBtn"].firstMatch
        guard nextBtn.waitForExistence(timeout: 10), nextBtn.isEnabled else {
            try captureAndSkip("player.nextBtn missing or disabled — no next video", in: app)
        }
        nextBtn.tap()
        let titleChanged = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label != %@", oldTitle), object: title)
        XCTAssertEqual(XCTWaiter().wait(for: [titleChanged], timeout: 20), .completed, "next video should load")
        try assertRate(near: 1.5, "on the next video")
    }

    /// Picks a quality other than the current one, which re-creates the player item
    /// through PlaybackQualityManager. Records an activity and returns when the
    /// stream offers nothing to switch to.
    private func switchQualityIfPossible() throws {
        revealControls()
        let qualityBtn = app.buttons["player.quickAccess.quality"]
        let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isEnabled == true"), object: qualityBtn)
        guard qualityBtn.waitForExistence(timeout: 10), XCTWaiter().wait(for: [enabled], timeout: 20) == .completed
        else {
            XCTContext.runActivity(named: "Quality button not enabled — quality switch step skipped") { _ in }
            return
        }
        revealControls()
        qualityBtn.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let picker = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier == 'player.qualityPicker'")).firstMatch
        XCTAssertTrue(picker.waitForExistence(timeout: 5), "quality picker should open")
        let rows = app.scrollViews["player.qualityPicker"].firstMatch
        let formats = rows.buttons.matching(NSPredicate(format: "label MATCHES '^[0-9]+p.*'"))
        guard formats.firstMatch.exists else {
            app.buttons["Cancel"].firstMatch.tap()
            XCTContext.runActivity(named: "No explicit formats listed — quality switch step skipped") { _ in }
            return
        }
        // Auto is selected after a settings reset, so any explicit format is a switch.
        let target = formats.firstMatch
        XCTContext.runActivity(named: "Switching quality to \(target.label)") { _ in }
        target.tap()
        try assertRate(near: 1.5, "after switching quality to \(target.label)")
    }

    /// Measures the playback rate as video seconds per wall-clock second while the
    /// current-time label advances `span` seconds. A stall makes the rate read low,
    /// never high, so a pass at 1.5× cannot come from buffering noise.
    private func assertRate(
        near expected: Double, _ context: String, span: Int = 15, file: StaticString = #filePath, line: UInt = #line
    ) throws {
        // Wait until playback is actually advancing, so loading time is not counted.
        guard let start = waitForTimeLabelToTick(timeout: 30) else {
            try captureAndSkip("current time never advanced (\(context)) — playback did not start", in: app)
        }
        let wallStart = Date()
        let deadline = wallStart.addingTimeInterval(Double(span) * 2.5)
        var now = start
        var samples: [String] = []
        while now < start + span && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
            let reading = currentTimeSeconds()
            if reading != now {
                let elapsed = Date().timeIntervalSince(wallStart)
                samples.append(String(format: "%.1f:%@", elapsed, reading.map(String.init) ?? "nil"))
            }
            now = reading ?? now
        }
        let wall = Date().timeIntervalSince(wallStart)
        let rate = Double(now - start) / wall
        let message = String(format: "%@: measured %.2f× (%d s of video in %.1f s)", context, rate, now - start, wall)
        XCTContext.runActivity(named: message + " samples " + samples.joined(separator: " ")) { _ in }
        // 1× and 1.5× are 0.5 apart; ±0.2 covers the 1 s label granularity and query latency.
        XCTAssertEqual(rate, expected, accuracy: 0.2, message, file: file, line: line)
    }

    /// Returns the label value right after it changes, or nil on timeout.
    private func waitForTimeLabelToTick(timeout: TimeInterval) -> Int? {
        let deadline = Date().addingTimeInterval(timeout)
        var last = currentTimeSeconds()
        while Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
            let reading = currentTimeSeconds()
            if let reading, let last, reading > last { return reading }
            last = reading ?? last
        }
        return nil
    }

    /// On iOS the controls auto-hide again after play/pause even with
    /// --uitesting-show-controls. One tap on the video surface brings them back
    /// (a single tap only toggles controls; seeking needs a double tap).
    private func revealControls() {
        let playPause = app.buttons["player.playPauseButton"].firstMatch
        guard !playPause.exists else { return }
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35)).tap()
        _ = playPause.waitForExistence(timeout: 2)
    }

    /// Parses `player.currentTimeLabel` ("m:ss" or "h:mm:ss") into seconds.
    private func currentTimeSeconds() -> Int? {
        let label = app.staticTexts["player.currentTimeLabel"].firstMatch
        if !label.exists { revealControls() }
        guard let text = (try? label.snapshot())?.label else { return nil }
        let parts = text.split(separator: ":").compactMap { Int($0) }
        guard !parts.isEmpty else { return nil }
        return parts.reduce(0) { $0 * 60 + $1 }
    }
}
