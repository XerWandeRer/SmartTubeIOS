import XCTest

// MARK: - MiniPlayerUITests
//
// Floating mini player (XER-12): a 16:9 window over the content with play/pause and
// close, dragged freely and snapped to one of four corners, tap to expand.
// The older bar-style tests live in PlayerAndMiniPlayerUITests.
//
// The resting corner is persisted, so these tests read the current corner instead of
// assuming one, and leave the window in the bottom-trailing corner when done.
// Screenshots are attached to the result bundle (lifetime .keepAlways) as evidence.

final class MiniPlayerUITests: XCTestCase {

    private static var sharedApp: XCUIApplication!
    private static var skipAllTests = false
    private static let skipReason = "Home feed did not load — network unavailable or feed empty"
    /// Clears the persisted corner and size at launch.
    private static let resetArgument = "--uitesting-reset-mini-player"

    override static func setUp() {
        super.setUp()
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting", "--uitesting-disable-tos-player-on-ios", Self.resetArgument]
        app.launch()
        sharedApp = app
        UITestHelpers.tapTab(named: "Home", in: app)
        if UITestHelpers.waitForVideoCards(in: app, timeout: 25) == nil {
            skipAllTests = true
        }
    }

    override static func tearDown() {
        sharedApp?.terminate()
        sharedApp = nil
        super.tearDown()
    }

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        returnToHome()
    }

    // MARK: - Elements

    private var app: XCUIApplication { Self.sharedApp }
    private var miniPlayerBar: XCUIElement { app.otherElements["miniPlayer.bar"].firstMatch }
    private var miniPlayerPlayPause: XCUIElement { app.buttons["miniPlayer.playPauseButton"].firstMatch }
    private var miniPlayerClose: XCUIElement { app.buttons["miniPlayer.closeButton"].firstMatch }
    private var backButton: XCUIElement { app.buttons["player.backButton"].firstMatch }
    private var playerTitle: XCUIElement { app.staticTexts["player.titleLabel"].firstMatch }

    // MARK: - Navigation helpers

    /// Closes the full-screen player and the mini player, then shows Home.
    private func returnToHome() {
        dismissKeyboard()
        if backButton.waitForExistence(timeout: 2), backButton.isHittable {
            backButton.tap()
            _ = miniPlayerBar.waitForExistence(timeout: 3)
        }
        if miniPlayerClose.waitForExistence(timeout: 3), miniPlayerClose.isHittable {
            miniPlayerClose.tap()
            let gone = NSPredicate(format: "exists == false")
            _ = XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: gone, object: miniPlayerBar)], timeout: 3)
        }
        UITestHelpers.tapTab(named: "Home", in: app)
        _ = UITestHelpers.waitForVideoCards(in: app, timeout: 8)
    }

    /// The keyboard covers the tab bar, so it has to go before switching tabs.
    private func dismissKeyboard() {
        let keyboard = app.keyboards.firstMatch
        guard keyboard.exists else { return }
        app.typeText("\n")
        let gone = NSPredicate(format: "exists == false")
        _ = XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: gone, object: keyboard)], timeout: 5)
    }

    private func openPlayerFromHome() throws {
        UITestHelpers.tapTab(named: "Home", in: app)
        guard let card = UITestHelpers.waitForVideoCards(in: app, timeout: 20) else {
            try captureAndSkip("No video cards on Home — network unavailable or feed empty", in: app)
        }
        guard UITestHelpers.openPlayer(from: card, in: app) else {
            try captureAndSkip("Player did not open within 15 s — network unavailable or timing-dependent", in: app)
        }
    }

    /// Reveals the player controls if needed and taps back to minimize.
    private func minimizePlayer() {
        if !backButton.exists {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            _ = backButton.waitForExistence(timeout: 2)
        }
        backButton.tap()
    }

    // MARK: - Mini player helpers

    private struct Corner: Equatable, CustomStringConvertible {
        var top: Bool
        var leading: Bool
        static let topLeading = Corner(top: true, leading: true)
        static let bottomTrailing = Corner(top: false, leading: false)
        var description: String { (top ? "top" : "bottom") + (leading ? "Leading" : "Trailing") }
    }

    private var screenFrame: CGRect { app.windows.firstMatch.frame }

    /// Opens a video, minimizes it and waits for the floating mini player.
    private func showMiniPlayer() throws {
        try openPlayerFromHome()
        minimizePlayer()
        guard miniPlayerBar.waitForExistence(timeout: 5) else {
            try captureAndSkip("miniPlayer.bar not found — mini-player may not be active in this environment", in: app)
        }
        waitForMiniPlayerToSettle()
    }

    /// Waits until the window's frame stops changing (snap / re-layout finished).
    private func waitForMiniPlayerToSettle(timeout: TimeInterval = 3) {
        var last = miniPlayerBar.frame
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            Thread.sleep(forTimeInterval: 0.3)
            let now = miniPlayerBar.frame
            if now == last { return }
            last = now
        }
    }

    private func currentCorner() -> Corner {
        let frame = miniPlayerBar.frame
        return Corner(top: frame.midY < screenFrame.midY, leading: frame.midX < screenFrame.midX)
    }

    /// A point inside `corner`'s quadrant, `fraction` of the way from the screen centre
    /// to that screen corner.
    private func point(in corner: Corner, fraction: CGFloat) -> CGPoint {
        let screen = screenFrame
        let dx = screen.width / 2 * fraction * (corner.leading ? -1 : 1)
        let dy = screen.height / 2 * fraction * (corner.top ? -1 : 1)
        return CGPoint(x: screen.midX + dx, y: screen.midY + dy)
    }

    /// Drags the window by its video area (left of centre, clear of both buttons).
    private func dragMiniPlayer(
        to target: CGPoint,
        velocity: XCUIGestureVelocity,
        hold: TimeInterval
    ) {
        let start = miniPlayerBar.coordinate(withNormalizedOffset: CGVector(dx: 0.45, dy: 0.5))
        let frame = miniPlayerBar.frame
        let startPoint = CGPoint(x: frame.minX + frame.width * 0.45, y: frame.midY)
        let end = start.withOffset(CGVector(dx: target.x - startPoint.x, dy: target.y - startPoint.y))
        start.press(forDuration: 0.05, thenDragTo: end, withVelocity: velocity, thenHoldForDuration: hold)
        waitForMiniPlayerToSettle()
    }

    /// Slow drag that ends deep inside `corner`'s quadrant and pauses before release.
    private func moveMiniPlayer(to corner: Corner) {
        guard currentCorner() != corner else { return }
        dragMiniPlayer(to: point(in: corner, fraction: 0.6), velocity: .slow, hold: 0.4)
    }

    private func attachScreenshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    // MARK: - Tests

    func testMiniPlayerFloatsAsSixteenByNineWindow() throws {
        try XCTSkipIf(Self.skipAllTests, Self.skipReason)
        try showMiniPlayer()
        // On a fresh install (no stored corner) this shows the initial bottom-trailing corner.
        attachScreenshot("mini-player-as-shown-\(currentCorner())")
        moveMiniPlayer(to: .bottomTrailing)
        attachScreenshot("floating-mini-player-bottom-trailing")

        let frame = miniPlayerBar.frame
        let screen = screenFrame
        XCTAssertEqual(frame.width, max(160, screen.width * 0.45), accuracy: 2, "Width should be 45% of the screen")
        XCTAssertEqual(frame.width / frame.height, 16.0 / 9.0, accuracy: 0.03, "Window should be 16:9")
        XCTAssertEqual(screen.maxX - frame.maxX, 12, accuracy: 2, "12 pt from the trailing safe-area edge")
        let tabBar = app.tabBars.firstMatch
        XCTAssertTrue(tabBar.waitForExistence(timeout: 5), "Tab bar must be present")
        XCTAssertEqual(tabBar.frame.minY - frame.maxY, 12, accuracy: 2, "12 pt above the tab bar")

        XCTAssertTrue(miniPlayerPlayPause.exists, "Play/pause button should be on the window")
        XCTAssertTrue(miniPlayerClose.exists, "Close button should be on the window")
        XCTAssertFalse(app.staticTexts["miniPlayer.titleLabel"].exists, "The floating window shows no title")
    }

    func testSlowDragSnapsToNearestCorner() throws {
        try XCTSkipIf(Self.skipAllTests, Self.skipReason)
        try showMiniPlayer()
        moveMiniPlayer(to: .bottomTrailing)

        dragMiniPlayer(to: point(in: .topLeading, fraction: 0.35), velocity: .slow, hold: 0.4)
        XCTAssertEqual(currentCorner(), .topLeading, "A slow release in the top-leading quadrant snaps there")
        let frame = miniPlayerBar.frame
        XCTAssertEqual(frame.minX - screenFrame.minX, 12, accuracy: 2, "Snapped 12 pt from the leading edge")
        XCTAssertFalse(playerTitle.exists, "Dragging must not expand the player")
        attachScreenshot("slow-drag-snapped-top-leading")

        // A short slow drag towards the centre stays in the same corner.
        dragMiniPlayer(to: point(in: .topLeading, fraction: 0.2), velocity: .slow, hold: 0.4)
        XCTAssertEqual(currentCorner(), .topLeading, "A short slow drag springs back to the same corner")

        moveMiniPlayer(to: .bottomTrailing)
        XCTAssertEqual(currentCorner(), .bottomTrailing)
    }

    func testFlingReachesOppositeCorner() throws {
        try XCTSkipIf(Self.skipAllTests, Self.skipReason)
        try showMiniPlayer()
        moveMiniPlayer(to: .bottomTrailing)

        // A short, fast flick that ends well inside the starting quadrant.
        let frame = miniPlayerBar.frame
        let flickEnd = CGPoint(x: frame.minX + frame.width * 0.45 - 70, y: frame.midY - 110)
        dragMiniPlayer(to: flickEnd, velocity: XCUIGestureVelocity(2500), hold: 0)
        XCTAssertEqual(currentCorner(), .topLeading, "A quick fling towards top-leading flies to the opposite corner")
        attachScreenshot("fling-reached-top-leading")

        let back = miniPlayerBar.frame
        let flickBack = CGPoint(x: back.minX + back.width * 0.45 + 70, y: back.midY + 110)
        dragMiniPlayer(to: flickBack, velocity: XCUIGestureVelocity(2500), hold: 0)
        XCTAssertEqual(currentCorner(), .bottomTrailing, "And a fling back returns to bottom-trailing")
    }

    func testDragStartingOnButtonDoesNotPressItOrExpand() throws {
        try XCTSkipIf(Self.skipAllTests, Self.skipReason)
        try showMiniPlayer()
        moveMiniPlayer(to: .bottomTrailing)
        // Let playback settle first so a starting video cannot flip the label on its own.
        let playing = NSPredicate(format: "label == 'Pause'")
        _ = XCTWaiter().wait(
            for: [XCTNSPredicateExpectation(predicate: playing, object: miniPlayerPlayPause)], timeout: 10)
        let labelBefore = miniPlayerPlayPause.label

        let start = miniPlayerPlayPause.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let end = start.withOffset(CGVector(dx: -screenFrame.width * 0.5, dy: -screenFrame.height * 0.4))
        start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.4)
        waitForMiniPlayerToSettle()

        XCTAssertTrue(miniPlayerBar.exists, "Dragging from a button must not close or expand")
        XCTAssertFalse(playerTitle.exists, "Dragging from a button must not expand the player")
        XCTAssertEqual(miniPlayerPlayPause.label, labelBefore, "Dragging from play/pause must not toggle playback")
        XCTAssertEqual(currentCorner(), .topLeading, "The drag still moves the window")
        moveMiniPlayer(to: .bottomTrailing)
    }

    func testCornerPersistsAcrossRelaunch() throws {
        try XCTSkipIf(Self.skipAllTests, Self.skipReason)
        try showMiniPlayer()
        moveMiniPlayer(to: .topLeading)
        XCTAssertEqual(currentCorner(), .topLeading)

        app.terminate()
        // Relaunch without the reset so the stored corner survives.
        let arguments = app.launchArguments
        app.launchArguments = arguments.filter { $0 != Self.resetArgument }
        defer { app.launchArguments = arguments }
        app.launch()
        UITestHelpers.tapTab(named: "Home", in: app)
        try showMiniPlayer()
        XCTAssertEqual(currentCorner(), .topLeading, "The window reappears in the corner it was left in")
        attachScreenshot("relaunch-kept-top-leading")
        moveMiniPlayer(to: .bottomTrailing)
    }

    func testMiniPlayerMovesAboveKeyboard() throws {
        try XCTSkipIf(Self.skipAllTests, Self.skipReason)
        try showMiniPlayer()
        moveMiniPlayer(to: .bottomTrailing)

        UITestHelpers.tapTab(named: "Search", in: app)
        let field = app.textFields["search.bar"].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5), "Search field should exist")
        field.tap()
        let keyboard = app.keyboards.firstMatch
        guard keyboard.waitForExistence(timeout: 5) else {
            try captureAndSkip("Software keyboard did not appear (hardware keyboard connected?)", in: app)
        }
        waitForMiniPlayerToSettle()
        attachScreenshot("keyboard-lifted-mini-player")
        // XCUITest's keyboard frame starts ~45 pt below the keyboard's visible top edge
        // (the keyboard safe area the app sees), so only bound the gap here; the
        // recording shows the window 12 pt above the visible keyboard.
        let gap = keyboard.frame.minY - miniPlayerBar.frame.maxY
        XCTAssertGreaterThanOrEqual(gap, 12 - 2, "The window must sit above the keyboard")
        XCTAssertLessThanOrEqual(gap, 12 + 60, "The window should sit just above the keyboard")

        dismissKeyboard()
        waitForMiniPlayerToSettle()
        XCTAssertEqual(currentCorner(), .bottomTrailing, "The window stays in its corner once the keyboard is gone")
        UITestHelpers.tapTab(named: "Home", in: app)
    }

    func testContentAroundMiniPlayerStaysInteractive() throws {
        try XCTSkipIf(Self.skipAllTests, Self.skipReason)
        try showMiniPlayer()
        moveMiniPlayer(to: .bottomTrailing)

        // Scroll the feed with a swipe on the half of the screen the window doesn't cover.
        let screen = screenFrame
        let window = app.windows.firstMatch
        let from = window.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.7))
        let to = window.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.35))
        let cardsBefore = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'video.card.'")).firstMatch.frame
        from.press(forDuration: 0.05, thenDragTo: to)
        let cardsAfter = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'video.card.'")).firstMatch.frame
        XCTAssertNotEqual(cardsBefore, cardsAfter, "The feed under the mini player should still scroll")

        // Tap a card that is fully visible above the window: the player opens for it.
        let cards = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'video.card.'"))
        let bar = miniPlayerBar.frame
        let candidate = cards.allElementsBoundByIndex.prefix(30).first {
            let frame = $0.frame
            return frame.minY > screen.minY + 120 && frame.maxY < bar.minY && !frame.intersects(bar)
        }
        guard let card = candidate else {
            try captureAndSkip("No video card fully visible above the mini player", in: app)
        }
        card.tap()
        XCTAssertTrue(playerTitle.waitForExistence(timeout: 10), "Tapping a card next to the mini player opens it")
    }

    func testMiniPlayerKeepsCornerAcrossRotation() throws {
        try XCTSkipIf(Self.skipAllTests, Self.skipReason)
        try showMiniPlayer()
        moveMiniPlayer(to: .topLeading)
        defer { XCUIDevice.shared.orientation = .portrait }

        XCUIDevice.shared.orientation = .landscapeLeft
        waitForMiniPlayerToSettle()
        attachScreenshot("landscape-kept-top-leading")
        XCTAssertEqual(currentCorner(), .topLeading, "Rotation keeps the window in its corner")
        XCTAssertTrue(screenFrame.contains(miniPlayerBar.frame), "The window stays fully on screen after rotation")

        XCUIDevice.shared.orientation = .portrait
        waitForMiniPlayerToSettle()
        XCTAssertEqual(currentCorner(), .topLeading, "Rotating back keeps the corner too")
        moveMiniPlayer(to: .bottomTrailing)
    }

    func testTapOnVideoExpandsAndTapOnButtonsDoesNot() throws {
        try XCTSkipIf(Self.skipAllTests, Self.skipReason)
        try showMiniPlayer()
        moveMiniPlayer(to: .bottomTrailing)

        miniPlayerPlayPause.tap()
        XCTAssertFalse(playerTitle.waitForExistence(timeout: 2), "Play/pause must not expand the player")
        XCTAssertTrue(miniPlayerBar.exists, "Play/pause keeps the mini player")
        miniPlayerPlayPause.tap()

        // The middle of the video, clear of both buttons.
        miniPlayerBar.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(playerTitle.waitForExistence(timeout: 5), "Tapping the video expands to the full-screen player")
    }

    func testPinchResizesBetweenMinimumAndFullWidth() throws {
        try XCTSkipIf(Self.skipAllTests, Self.skipReason)
        try showMiniPlayer()
        moveMiniPlayer(to: .bottomTrailing)
        let screen = screenFrame
        let defaultWidth = miniPlayerBar.frame.width

        miniPlayerBar.pinch(withScale: 4, velocity: 2)
        waitForMiniPlayerToSettle()
        attachScreenshot("pinched-to-maximum")
        let maximum = min(screen.width - 24, (screen.height / 2 * 16 / 9).rounded(.down))
        XCTAssertEqual(miniPlayerBar.frame.width, maximum, accuracy: 2, "Pinching out stops at the full width")
        XCTAssertLessThanOrEqual(miniPlayerBar.frame.height, screen.height / 2 + 1, "Never taller than half the screen")
        XCTAssertEqual(currentCorner(), .bottomTrailing, "Resizing keeps the corner")
        XCTAssertFalse(playerTitle.exists, "Pinching must not expand the player")

        // The size survives closing the mini player and minimizing again.
        miniPlayerClose.tap()
        try showMiniPlayer()
        XCTAssertEqual(miniPlayerBar.frame.width, maximum, accuracy: 2, "The chosen size is remembered")

        miniPlayerBar.pinch(withScale: 0.2, velocity: -2)
        waitForMiniPlayerToSettle()
        XCTAssertEqual(miniPlayerBar.frame.width, 160, accuracy: 2, "Pinching in stops at the minimum width")
        XCTAssertGreaterThan(defaultWidth, 160, "Sanity: the default is larger than the minimum")
    }

    /// A portrait video opened in the regular player (not the Shorts player) must get an
    /// upright window instead of being cropped into a 16:9 one.
    func testPortraitVideoGetsUprightWindow() throws {
        try XCTSkipIf(Self.skipAllTests, Self.skipReason)
        // A vertical Short (also in scripts/mytube/regress-list.tsv), opened through the regular player.
        guard let url = URL(string: "smarttube://video/6yX9tINzYf0") else { return XCTFail("bad URL") }
        app.open(url)
        guard playerTitle.waitForExistence(timeout: 15) else {
            try captureAndSkip("Player did not open from the deep link", in: app)
        }
        minimizePlayer()
        guard miniPlayerBar.waitForExistence(timeout: 5) else {
            try captureAndSkip("miniPlayer.bar not found", in: app)
        }
        // Without playback there is no decoded size to shape the window from.
        let playing = NSPredicate(format: "label == 'Pause'")
        let started = XCTWaiter().wait(
            for: [XCTNSPredicateExpectation(predicate: playing, object: miniPlayerPlayPause)], timeout: 15)
        guard started == .completed else {
            try captureAndSkip("The video did not start playing (e.g. YouTube's bot check in the simulator)", in: app)
        }
        // The aspect is polled from the player item; give it a moment to reshape.
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline, miniPlayerBar.frame.height <= miniPlayerBar.frame.width {
            Thread.sleep(forTimeInterval: 0.5)
        }
        waitForMiniPlayerToSettle()
        attachScreenshot("portrait-video-upright-window")
        let frame = miniPlayerBar.frame
        XCTAssertGreaterThan(frame.height, frame.width, "A portrait video gets a portrait window")
        XCTAssertEqual(frame.width / frame.height, 9.0 / 16.0, accuracy: 0.03, "The window is 9:16")
    }
}

// MARK: - Resident player layer (XER-14)
//
// The full-screen player and the mini player are one layer above the tabs. Expanded,
// it covers the tabs (they are hidden from VoiceOver too, but XCUITest still lists
// elements hidden that way, so these tests check hit-testing instead); minimized, only
// the mini player window is on top.

extension MiniPlayerUITests {
    func testExpandedPlayerCoversTabs() throws {
        try XCTSkipIf(Self.skipAllTests, Self.skipReason)
        try openPlayerFromHome()
        let chipBar = app.scrollViews["home.chipBar"].firstMatch
        let covered = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hittable == false"), object: chipBar)
        XCTAssertEqual(
            XCTWaiter().wait(for: [covered], timeout: 3), .completed,
            "Home must not be reachable behind the expanded player")
        attachScreenshot("expanded")
        XCTAssertEqual(
            app.buttons.matching(identifier: "player.backButton").count, 1,
            "Exactly one player is on screen")
        XCTAssertFalse(miniPlayerBar.exists, "The mini player is not an element while expanded")

        minimizePlayer()
        XCTAssertTrue(miniPlayerBar.waitForExistence(timeout: 5), "The back button minimizes the player")
        let reachable = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hittable == true"), object: chipBar)
        XCTAssertEqual(
            XCTWaiter().wait(for: [reachable], timeout: 5), .completed,
            "Home is reachable again under the mini player")
    }

    func testMiniPlayerHasNoFullScreenControls() throws {
        try XCTSkipIf(Self.skipAllTests, Self.skipReason)
        try showMiniPlayer()
        attachScreenshot("mini")
        XCTAssertFalse(playerTitle.exists, "player.titleLabel must not be visible in the mini player")
        XCTAssertFalse(backButton.exists, "player.backButton must not be visible in the mini player")
    }
}
