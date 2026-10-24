import Foundation
import Testing

@testable import SmartTubeIOSCore

@Suite("Mini Player Snapping")
struct MiniPlayerSnappingTests {
    // iPhone Air portrait: 420 x 912 pt, safe area top 68, tab bar + home indicator 83.
    private let screen = CGSize(width: 420, height: 912)
    private let obstructions = MiniPlayerInsets(top: 68, leading: 0, bottom: 83, trailing: 0)
    private var size: CGSize { MiniPlayerSnapping.size(screenWidth: screen.width) }

    /// Avoids exact floating-point equality (and the literal-type pitfalls of `==`).
    private func near(_ value: CGFloat, _ expected: CGFloat) -> Bool {
        abs(value - expected) < 0.001
    }

    private func anchor(_ corner: MiniPlayerCorner) -> CGPoint {
        MiniPlayerSnapping.anchor(for: corner, size: size, screen: screen, obstructions: obstructions)
    }

    @Test("Size is 45% of the screen width at 16:9")
    func sizeIsFractionOfScreen() {
        #expect(size == CGSize(width: 189, height: 106))
    }

    @Test("Size never drops below the minimum width")
    func sizeHasMinimum() {
        let small = MiniPlayerSnapping.size(screenWidth: 300)
        #expect(small.width == 160)
        #expect(small.height == 90)
    }

    @Test("Anchors keep 12 pt from the safe area and from the tab bar")
    func anchorsKeepMargins() {
        let topLeading = anchor(.topLeading)
        #expect(near(topLeading.x - size.width / 2, 12))
        #expect(near(topLeading.y - size.height / 2, 68 + 12))

        let bottomTrailing = anchor(.bottomTrailing)
        #expect(near(bottomTrailing.x + size.width / 2, 420 - 12))
        #expect(near(bottomTrailing.y + size.height / 2, 912 - 83 - 12))
    }

    @Test("Side safe-area insets move the anchors inward (landscape)")
    func anchorsRespectSideInsets() {
        let landscape = CGSize(width: 912, height: 420)
        let insets = MiniPlayerInsets(top: 0, leading: 68, bottom: 70, trailing: 68)
        let landscapeSize = MiniPlayerSnapping.size(screenWidth: landscape.width)
        let leading = MiniPlayerSnapping.anchor(
            for: .bottomLeading, size: landscapeSize, screen: landscape, obstructions: insets)
        let trailing = MiniPlayerSnapping.anchor(
            for: .topTrailing, size: landscapeSize, screen: landscape, obstructions: insets)
        #expect(near(leading.x - landscapeSize.width / 2, 68 + 12))
        #expect(near(trailing.x + landscapeSize.width / 2, 912 - 68 - 12))
        #expect(near(trailing.y - landscapeSize.height / 2, 12))
    }

    @Test("A taller bottom obstruction (keyboard) lifts only the bottom anchors")
    func keyboardLiftsBottomAnchors() {
        var withKeyboard = obstructions
        withKeyboard.bottom = 336
        let lifted = MiniPlayerSnapping.anchor(
            for: .bottomLeading, size: size, screen: screen, obstructions: withKeyboard)
        #expect(near(lifted.y + size.height / 2, 912 - 336 - 12))
        let top = MiniPlayerSnapping.anchor(for: .topLeading, size: size, screen: screen, obstructions: withKeyboard)
        #expect(top == anchor(.topLeading))
    }

    @Test("Anchors never cross when the space is too small")
    func anchorsDoNotCross() {
        let tiny = CGSize(width: 320, height: 200)
        let crowded = MiniPlayerInsets(top: 60, leading: 0, bottom: 120, trailing: 0)
        let tinySize = MiniPlayerSnapping.size(screenWidth: tiny.width)
        let top = MiniPlayerSnapping.anchor(for: .topLeading, size: tinySize, screen: tiny, obstructions: crowded)
        let bottom = MiniPlayerSnapping.anchor(for: .bottomLeading, size: tinySize, screen: tiny, obstructions: crowded)
        #expect(bottom.y >= top.y)
    }

    @Test("Projection matches UIScrollView's normal deceleration")
    func projectionUsesScrollViewFormula() {
        let projected = MiniPlayerSnapping.project(CGPoint(x: 100, y: 100), velocity: CGVector(dx: 1000, dy: -500))
        // 0.998 / (1000 * 0.002) = 0.499 s of travel at the release velocity.
        #expect(abs(projected.x - 599) < 0.001)
        #expect(abs(projected.y - (100 - 249.5)) < 0.001)
    }

    @Test("Quadrants map to corners, split at midX / midY")
    func quadrantsMapToCorners() {
        #expect(MiniPlayerSnapping.corner(for: CGPoint(x: 10, y: 10), screen: screen) == .topLeading)
        #expect(MiniPlayerSnapping.corner(for: CGPoint(x: 400, y: 10), screen: screen) == .topTrailing)
        #expect(MiniPlayerSnapping.corner(for: CGPoint(x: 10, y: 900), screen: screen) == .bottomLeading)
        #expect(MiniPlayerSnapping.corner(for: CGPoint(x: 400, y: 900), screen: screen) == .bottomTrailing)
        // Off-screen projections still pick the quadrant they point into.
        #expect(MiniPlayerSnapping.corner(for: CGPoint(x: -500, y: 2000), screen: screen) == .bottomLeading)
    }

    @Test("A slow release stays at the nearest corner")
    func slowReleaseStaysNearby() {
        let nearBottomTrailing = CGPoint(x: 260, y: 520)
        let corner = MiniPlayerSnapping.targetCorner(
            releasedAt: nearBottomTrailing, velocity: CGVector(dx: -40, dy: -60), screen: screen)
        #expect(corner == .bottomTrailing)
    }

    @Test("A quick fling reaches the opposite corner")
    func flingReachesOppositeCorner() {
        let corner = MiniPlayerSnapping.targetCorner(
            releasedAt: anchor(.bottomTrailing), velocity: CGVector(dx: -1500, dy: -2500), screen: screen)
        #expect(corner == .topLeading)
    }

    @Test("Rubber band leaves on-screen positions untouched")
    func rubberBandInside() {
        let inside = CGPoint(x: 200, y: 400)
        #expect(MiniPlayerSnapping.rubberBanded(inside, size: size, screen: screen) == inside)
    }

    @Test("Rubber band damps overshoot with slope 0.3 and keeps the body on screen")
    func rubberBandDampsOvershoot() {
        let lower = size.width / 2
        let small = MiniPlayerSnapping.rubberBanded(CGPoint(x: lower - 10, y: 400), size: size, screen: screen)
        // Near the edge the resistance is ~0.3: 10 pt of finger travel moves it ~3 pt.
        #expect(small.x < lower - 2.5 && small.x > lower - 3.0)

        let far = MiniPlayerSnapping.rubberBanded(CGPoint(x: -5000, y: 5000), size: size, screen: screen)
        #expect(far.x > 0)
        #expect(far.y < screen.height)
    }
}
