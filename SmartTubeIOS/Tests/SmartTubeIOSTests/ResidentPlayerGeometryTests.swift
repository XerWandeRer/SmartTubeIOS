import Foundation
import Testing

@testable import SmartTubeIOSCore

@Suite("Resident Player Geometry")
struct ResidentPlayerGeometryTests {
    // iPhone Air portrait: 420 x 912 pt.
    private let screen = CGSize(width: 420, height: 912)
    // Bottom-trailing mini player (189 x 106, 12 pt above an 83 pt tab bar).
    private let mini = CGRect(x: 219, y: 711, width: 189, height: 106)

    private func near(_ value: CGFloat, _ expected: CGFloat) -> Bool {
        abs(value - expected) < 0.001
    }

    private func near(_ rect: CGRect, _ expected: CGRect) -> Bool {
        near(rect.minX, expected.minX) && near(rect.minY, expected.minY)
            && near(rect.width, expected.width) && near(rect.height, expected.height)
    }

    private var landscapeVideo: CGRect {
        ResidentPlayerGeometry.videoFrame(aspectRatio: 16 / 9, screen: screen)
    }

    @Test("A 16:9 video fills the width of a portrait screen, centred")
    func videoFrameLetterboxes() {
        let frame = landscapeVideo
        #expect(near(frame.width, 420))
        #expect(near(frame.height, 236.25))
        #expect(near(frame.midY, 456))
    }

    @Test("A portrait video on a landscape screen fills the height, centred")
    func videoFramePillarboxes() {
        let frame = ResidentPlayerGeometry.videoFrame(aspectRatio: 9 / 16, screen: CGSize(width: 912, height: 420))
        #expect(near(frame.height, 420))
        #expect(near(frame.width, 236.25))
        #expect(near(frame.midX, 456))
    }

    @Test("Fit shows the video's frame; fill shows the whole screen")
    func fullScreenClipFollowsGravity() {
        let fit = ResidentPlayerGeometry.fullScreenClip(videoFrame: landscapeVideo, screen: screen, fill: 0)
        let fill = ResidentPlayerGeometry.fullScreenClip(videoFrame: landscapeVideo, screen: screen, fill: 1)
        #expect(near(fit, landscapeVideo))
        #expect(near(fill, CGRect(origin: .zero, size: screen)))
    }

    @Test("Progress 1 is the full-screen video, unscaled and square")
    func morphAtFullScreen() {
        let morph = ResidentPlayerGeometry.morph(
            progress: 1, videoFrame: landscapeVideo, fullScreenClip: landscapeVideo, mini: mini)
        #expect(near(morph.clip, landscapeVideo))
        #expect(near(morph.scale, 1))
        #expect(near(morph.cornerRadius, 0))
    }

    @Test("Progress 0 is the mini player with its corner radius")
    func morphAtMini() {
        let morph = ResidentPlayerGeometry.morph(
            progress: 0, videoFrame: landscapeVideo, fullScreenClip: landscapeVideo, mini: mini)
        #expect(near(morph.clip, mini))
        // Fitted: the 106 pt height limits it (189 / 420 would crop 0.3 pt).
        #expect(near(morph.scale, 106 / 236.25))
        #expect(near(morph.cornerRadius, MiniPlayerSnapping.cornerRadius))
    }

    @Test("Fill mode starts from a scale that covers the screen")
    func morphFromFill() {
        let full = CGRect(origin: .zero, size: screen)
        let morph = ResidentPlayerGeometry.morph(
            progress: 1, videoFrame: landscapeVideo, fullScreenClip: full, mini: mini)
        #expect(near(morph.scale, 912 / 236.25))
    }

    @Test("No intermediate frame shows bars while the mini player has the video's shape")
    func morphNeverShowsBars() {
        let portraitVideo = ResidentPlayerGeometry.videoFrame(aspectRatio: 9 / 16, screen: screen)
        // Upright mini player for the portrait video, as MiniPlayerSnapping sizes it.
        let portraitMini = CGRect(x: 302, y: 535, width: 106, height: 189)
        for (video, window) in [(landscapeVideo, mini), (portraitVideo, portraitMini)] {
            // Within a point: the mini player's size is rounded to whole points.
            for step in 0...20 {
                let morph = ResidentPlayerGeometry.morph(
                    progress: CGFloat(step) / 20, videoFrame: video, fullScreenClip: video, mini: window)
                #expect(video.width * morph.scale >= morph.clip.width - 1)
                #expect(video.height * morph.scale >= morph.clip.height - 1)
            }
        }
    }

    @Test("A video wider than the mini player's range is fitted, not cropped")
    func morphFitsAtMini() {
        // 2.39:1 video in the widest (16:9) mini player.
        let wide = ResidentPlayerGeometry.videoFrame(aspectRatio: 2.39, screen: screen)
        let morph = ResidentPlayerGeometry.morph(progress: 0, videoFrame: wide, fullScreenClip: wide, mini: mini)
        #expect(near(morph.scale, 189 / 420))
        #expect(wide.height * morph.scale < mini.height)
    }

    @Test("Progress outside 0...1 is clamped")
    func morphClampsProgress() {
        let over = ResidentPlayerGeometry.morph(
            progress: 1.4, videoFrame: landscapeVideo, fullScreenClip: landscapeVideo, mini: mini)
        let under = ResidentPlayerGeometry.morph(
            progress: -0.3, videoFrame: landscapeVideo, fullScreenClip: landscapeVideo, mini: mini)
        #expect(near(over.clip, landscapeVideo))
        #expect(near(under.clip, mini))
    }
}
