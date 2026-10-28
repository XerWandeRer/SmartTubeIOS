import Foundation

// MARK: - Audio Track Auto-Selection

/// The `preferredAudioLanguage` value meaning "always the creator's original track".
public let originalAudioLanguageSentinel = "original"

/// Picks the audio rendition to start on when a video loads.
///
/// Order: saved preference (or the "original" sentinel), then the creator's original,
/// then the device's preferred languages, then English, then the first track.
///
/// - Parameters:
///   - tracks: Renditions from the manifest, with `isOriginal` already resolved.
///   - preferred: `AppSettings.preferredAudioLanguage`; `nil` means "System Default".
///   - deviceLanguages: Normally `Locale.preferredLanguages`.
public func autoSelectAudioTrack(
    from tracks: [AudioTrack],
    preferred: String?,
    deviceLanguages: [String]
) -> AudioTrack? {
    if let lang = preferred {
        if lang == originalAudioLanguageSentinel {
            return tracks.first(where: \.isOriginal) ?? tracks.first
        }
        if let exact = tracks.first(where: { $0.languageCode == lang }) { return exact }
        let base = lang.components(separatedBy: "-").first ?? lang
        return tracks.first(where: { $0.languageCode.hasPrefix(base) })
            ?? tracks.first(where: \.isOriginal)
    }
    // The original before device languages: an AI dub in the device language must not
    // replace the creator's audio. Upstream (#54) puts device languages first because
    // DEFAULT=YES used to land on dubs; isOriginal now comes from acont=original.
    if let original = tracks.first(where: \.isOriginal) { return original }
    for deviceLang in deviceLanguages {
        if let exact = tracks.first(where: { $0.languageCode == deviceLang }) { return exact }
        let base = deviceLang.components(separatedBy: "-").first ?? deviceLang
        if let match = tracks.first(where: { $0.languageCode.hasPrefix(base) }) { return match }
    }
    let englishPrefixes = ["en-", "en_"]
    if let english = tracks.first(where: { $0.languageCode == "en" })
        ?? tracks.first(where: { track in
            englishPrefixes.contains(where: { track.languageCode.hasPrefix($0) })
        })
    {
        return english
    }
    return tracks.first
}

/// The `preferredAudioLanguage` to save when the user picks `track` in the player.
/// Picking the creator's original saves the "original" sentinel, not its language, so
/// the next video also opens on its own original instead of a dub in that language.
/// `nil` (the "Auto" row) clears the preference.
public func preferredAudioLanguage(forPicked track: AudioTrack?) -> String? {
    guard let track else { return nil }
    return track.isOriginal ? originalAudioLanguageSentinel : track.languageCode
}
