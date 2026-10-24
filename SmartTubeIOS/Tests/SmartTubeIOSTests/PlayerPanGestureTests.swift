import Foundation
import Testing

@testable import SmartTubeIOSCore

@Suite("Player Pan Gesture")
struct PlayerPanGestureTests {
    // iPhone Air portrait: 912 pt tall → 364.8 pt of travel.
    private let travel = PlayerPanGesture.collapseTravel(screenHeight: 912)

    private func near(_ value: CGFloat, _ expected: CGFloat) -> Bool {
        abs(value - expected) < 0.001
    }

    @Test("The first movement locks the axis")
    func axisLock() {
        #expect(PlayerPanGesture.axis(for: CGVector(dx: 0, dy: 0)) == nil)
        #expect(PlayerPanGesture.axis(for: CGVector(dx: -12, dy: 5)) == .horizontal)
        #expect(PlayerPanGesture.axis(for: CGVector(dx: 4, dy: 11)) == .down)
        #expect(PlayerPanGesture.axis(for: CGVector(dx: 4, dy: -11)) == .up)
        // A perfect diagonal counts as vertical.
        #expect(PlayerPanGesture.axis(for: CGVector(dx: 10, dy: 10)) == .down)
    }

    @Test("Collapse travel is a fixed 40% of the screen height")
    func travelIsFixedFraction() {
        #expect(near(travel, 364.8))
    }

    @Test("Progress follows the finger and is clamped")
    func progressFollowsFinger() {
        #expect(near(PlayerPanGesture.progress(translation: 0, travel: travel), 1))
        #expect(near(PlayerPanGesture.progress(translation: travel / 2, travel: travel), 0.5))
        #expect(near(PlayerPanGesture.progress(translation: travel * 2, travel: travel), 0))
        #expect(near(PlayerPanGesture.progress(translation: -50, travel: travel), 1))
    }

    @Test("Projection matches UIScrollView's normal deceleration")
    func projection() {
        // 0.998 / (1000 * 0.002) = 0.499
        #expect(near(PlayerPanGesture.projectedDistance(velocity: 1000), 499))
    }

    @Test("A slow release short of half the travel springs back")
    func slowShortDragStays() {
        // The prototype collapsed after 140 pt; with fixed travel that is under half.
        #expect(!PlayerPanGesture.shouldCollapse(translation: 140, velocity: 0, travel: travel))
    }

    @Test("A slow release past half the travel collapses")
    func slowLongDragCollapses() {
        #expect(PlayerPanGesture.shouldCollapse(translation: 200, velocity: 0, travel: travel))
    }

    @Test("A quick fling collapses after a short drag")
    func flingCollapses() {
        #expect(PlayerPanGesture.shouldCollapse(translation: 60, velocity: 1200, travel: travel))
    }

    @Test("Flicking back up cancels a long drag")
    func flickUpCancels() {
        #expect(!PlayerPanGesture.shouldCollapse(translation: 250, velocity: -1000, travel: travel))
    }

    @Test("Spring velocity is relative to the animated distance")
    func springVelocity() {
        // Finger moving down at one travel per second, from 0.6 to 0: 1 / 0.6 of the distance per second.
        let velocity = PlayerPanGesture.springVelocity(velocity: travel, travel: travel, from: 0.6, to: 0)
        #expect(near(velocity, 1 / 0.6))
        // Springing back to 1 while the finger still moves down starts against the motion.
        let back = PlayerPanGesture.springVelocity(velocity: travel, travel: travel, from: 0.6, to: 1)
        #expect(near(back, -1 / 0.4))
        #expect(PlayerPanGesture.springVelocity(velocity: 500, travel: travel, from: 1, to: 1) == 0)
    }

    @Test("Horizontal swipes need 40 pt; left is next")
    func horizontalSwipe() {
        #expect(PlayerPanGesture.horizontalSwipe(translation: -30) == 0)
        #expect(PlayerPanGesture.horizontalSwipe(translation: -60) == -1)
        #expect(PlayerPanGesture.horizontalSwipe(translation: 60) == 1)
    }
}
