import Foundation

// MARK: - Audio Track Auto-Selection

/// The `preferredAudioLanguage` value meaning "always the creator's original track".
public let originalAudioLanguageSentinel = "original"

/// Picks the audio rendition to start on when a video loads.
///
/// Order: saved preference (or the "original" sentinel), then the device's preferred
/// languages, then the HLS DEFAULT=YES original, then English, then the first track.
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
    // Device languages before DEFAULT=YES so a dubbed DEFAULT doesn't override the
    // user's expected language (issue #54).
    for deviceLang in deviceLanguages {
        if let exact = tracks.first(where: { $0.languageCode == deviceLang }) { return exact }
        let base = deviceLang.components(separatedBy: "-").first ?? deviceLang
        if let match = tracks.first(where: { $0.languageCode.hasPrefix(base) }) { return match }
    }
    if let original = tracks.first(where: \.isOriginal) { return original }
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
