import AVFoundation
import Foundation
import Testing

@testable import SmartTubeIOS
@testable import SmartTubeIOSCore

// MARK: - PlaybackSpeedPersistenceTests
//
// Regression tests for XER-15: the speed picker changed `player.rate` but not
// PlaybackViewModel's own `settings` copy, so every path that re-applies
// `settings.playbackSpeed` (resume, hold-to-2× release, loop, quality switch,
// stall recovery, next video) put the old speed back.

@Suite("Playback speed survives resume and re-apply paths (XER-15)")
@MainActor
struct PlaybackSpeedPersistenceTests {

    /// A view model whose settings copy starts at 1× and whose player has an item,
    /// so `player.rate` reflects what the view model last applied.
    private func makeViewModel() -> PlaybackViewModel {
        let vm = PlaybackViewModel()
        vm.settings.playbackSpeed = 1.0
        vm.player.replaceCurrentItem(
            with: AVPlayerItem(url: URL(fileURLWithPath: "/dev/null/xer15.mp4")))
        return vm
    }

    @Test("setPlaybackSpeed updates the view model's settings copy")
    func setPlaybackSpeedUpdatesSettingsCopy() {
        let vm = makeViewModel()
        vm.setPlaybackSpeed(1.5)
        #expect(vm.settings.playbackSpeed == 1.5)
    }

    @Test("Resuming after a pause keeps the chosen speed")
    func resumeKeepsChosenSpeed() {
        let vm = makeViewModel()
        vm.isPlaying = true
        vm.setPlaybackSpeed(1.5)
        vm.togglePlayPause()  // pause
        #expect(vm.isPlaying == false)
        vm.togglePlayPause()  // resume
        #expect(vm.isPlaying == true)
        #expect(vm.player.rate == 1.5)
    }

    @Test("Speed chosen while paused is applied on resume")
    func speedChosenWhilePausedAppliedOnResume() {
        let vm = makeViewModel()
        vm.setPlaybackSpeed(1.5)
        vm.togglePlayPause()
        #expect(vm.player.rate == 1.5)
    }

    @Test("Releasing hold-to-2× restores the chosen speed, not the old one")
    func endHoldSpeedRestoresChosenSpeed() {
        let vm = makeViewModel()
        vm.isPlaying = true
        vm.setPlaybackSpeed(1.5)
        vm.beginHoldSpeed()
        #expect(vm.player.rate == 2.0)
        vm.endHoldSpeed()
        #expect(vm.player.rate == 1.5)
    }

    @Test("Looping back to the start keeps the chosen speed")
    func loopKeepsChosenSpeed() {
        let vm = makeViewModel()
        vm.settings.loopEnabled = true
        vm.isPlaying = true
        vm.setPlaybackSpeed(1.5)
        vm.player.rate = 0
        vm.handlePlaybackEnd()
        #expect(vm.player.rate == 1.5)
    }
}
