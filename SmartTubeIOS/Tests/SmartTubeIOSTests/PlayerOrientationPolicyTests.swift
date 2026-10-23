import Foundation
import Testing

@testable import SmartTubeIOSCore

@Suite("Player Orientation Policy")
struct PlayerOrientationPolicyTests {

    @Test("Regular videos start in landscape, Shorts in portrait")
    func guessesFromShortFlag() {
        var policy = PlayerOrientationPolicy()
        policy.begin(videoID: "regular", isShort: false)
        #expect(policy.wantsLandscape)
        policy.begin(videoID: "short", isShort: true)
        #expect(!policy.wantsLandscape)
    }

    @Test("The decoded size overrides the guess")
    func decodedSizeOverridesGuess() {
        var policy = PlayerOrientationPolicy()
        policy.begin(videoID: "v", isShort: false)
        let flipped = policy.confirmAspect(videoID: "v", width: 1080, height: 1920)
        #expect(flipped)
        #expect(!policy.wantsLandscape)
    }

    @Test("Only the first decoded size counts")
    func confirmsOncePerVideo() {
        var policy = PlayerOrientationPolicy()
        policy.begin(videoID: "v", isShort: true)
        let firstFlipped = policy.confirmAspect(videoID: "v", width: 1920, height: 1080)
        #expect(firstFlipped)
        let secondFlipped = policy.confirmAspect(videoID: "v", width: 720, height: 1280)
        #expect(!secondFlipped)
        #expect(policy.wantsLandscape)
    }

    @Test("Sizes for another video or empty sizes are ignored")
    func ignoresStaleOrEmptySizes() {
        var policy = PlayerOrientationPolicy()
        policy.begin(videoID: "new", isShort: false)
        let staleApplied = policy.confirmAspect(videoID: "old", width: 720, height: 1280)
        #expect(!staleApplied)
        let emptyApplied = policy.confirmAspect(videoID: "new", width: 0, height: 0)
        #expect(!emptyApplied)
        #expect(!policy.isAspectConfirmed)
        #expect(policy.wantsLandscape)
    }

    @Test("Re-entering the same video keeps its confirmed size")
    func reenteringKeepsConfirmedSize() {
        var policy = PlayerOrientationPolicy()
        policy.begin(videoID: "v", isShort: false)
        policy.confirmAspect(videoID: "v", width: 1080, height: 1920)
        policy.end()
        policy.begin(videoID: "v", isShort: false)
        #expect(policy.isAspectConfirmed)
        #expect(!policy.wantsLandscape)
    }

    @Test("A new video resets the confirmation")
    func newVideoResetsConfirmation() {
        var policy = PlayerOrientationPolicy()
        policy.begin(videoID: "a", isShort: false)
        policy.confirmAspect(videoID: "a", width: 1080, height: 1920)
        policy.begin(videoID: "b", isShort: false)
        #expect(!policy.isAspectConfirmed)
        #expect(policy.wantsLandscape)
    }

    @Test("The landscape lock forces landscape until the player closes")
    func lockForcesLandscapeUntilEnd() {
        var policy = PlayerOrientationPolicy()
        policy.begin(videoID: "short", isShort: true)
        policy.isLandscapeLocked = true
        #expect(policy.wantsLandscape)
        policy.end()
        #expect(!policy.wantsLandscape)
    }
}
