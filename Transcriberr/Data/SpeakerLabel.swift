import Foundation

/// How a speaker key reads when no one has named it.
nonisolated enum SpeakerLabel {
    /// "SPEAKER_01" reads as "Speaker 2"; "GUEST" as "Guest".
    static func display(_ name: String?, key: String) -> String {
        if let name, !name.isEmpty, name != key { return name }
        if key.hasPrefix("SPEAKER_"), let n = Int(key.dropFirst("SPEAKER_".count)) {
            return String(localized: "Speaker \(n + 1)", comment: "An unnamed speaker in a transcript, numbered")
        }
        if key == "GUEST" { return String(localized: "Guest", comment: "An unnamed speaker in a transcript who is a guest") }
        if key == TranscriptionRunner.micSpeakerKey { return String(localized: "You", comment: "The user as a speaker in a transcript") }
        return key
    }

    /// The same in English whatever the interface language: for text a
    /// text model reads (MeetingAsk passages).
    static func english(_ name: String?, key: String) -> String {
        if let name, !name.isEmpty, name != key { return name }
        if key.hasPrefix("SPEAKER_"), let n = Int(key.dropFirst("SPEAKER_".count)) { return "Speaker \(n + 1)" }
        if key == "GUEST" { return "Guest" }
        if key == TranscriptionRunner.micSpeakerKey { return "You" }
        return key
    }

    static func isPlaceholder(_ name: String) -> Bool {
        name.hasPrefix("SPEAKER_") || name == "GUEST" || name.hasPrefix(RecordingRepository.taggedKeyPrefix)
    }
}
