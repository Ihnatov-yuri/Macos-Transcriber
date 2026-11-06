import Foundation

/// How a speaker key reads when no one has named it.
nonisolated enum SpeakerLabel {
    /// "SPEAKER_01" reads as "Speaker 2"; "GUEST" as "Guest".
    static func display(_ name: String?, key: String) -> String {
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
