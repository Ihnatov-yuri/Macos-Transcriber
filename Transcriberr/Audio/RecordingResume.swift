import Foundation

/// A recording that a crash, a force quit or a power cut stopped, offered at
/// the next launch: carry on recording, and Stop joins the two parts into
/// one recording, as if nothing had happened in between.
nonisolated struct InterruptedRecording: Identifiable, Equatable, Sendable {
    /// The recovered recording's id.
    let id: UUID
    let isMeeting: Bool
    let startedAt: Date
    let seconds: Double

    var endedAt: Date { startedAt.addingTimeInterval(seconds) }
}

nonisolated enum RecordingResume {

    /// How long after a crash carrying on still makes sense. Older ones stay
    /// in the Library as recovered recordings, without the question.
    static let window: TimeInterval = 6 * 3600

    /// The recovered recording to offer, if any: the one that stopped last,
    /// and only when it stopped within `window` of `now`. The WAV's own
    /// length dates the stop (the repair rewrote the header, so the file's
    /// modification date is the launch, not the crash).
    static func offer(from recovered: [InterruptedRecording], now: Date = Date()) -> InterruptedRecording? {
        recovered
            .filter { $0.seconds >= 1 && now.timeIntervalSince($0.endedAt) <= window }
            .max { $0.endedAt < $1.endedAt }
    }

    /// The fields of a recovered library row.
    @MainActor
    static func interrupted(_ recording: Recording) -> InterruptedRecording {
        InterruptedRecording(
            id: recording.id,
            isMeeting: URL(fileURLWithPath: recording.audioPath).lastPathComponent.hasPrefix("meeting_"),
            startedAt: Date(timeIntervalSince1970: Double(recording.createdAtMillis) / 1000),
            seconds: recording.durationSeconds)
    }

    /// The title of the joined recording: what a recording started then
    /// would have been called.
    static func joinedTitle(_ r: InterruptedRecording) -> String {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .short
        return "\(r.isMeeting ? "Meeting" : "Recording") \(f.string(from: r.startedAt))"
    }

    /// "23 minutes", "1 hour 5 minutes", "40 seconds". Each unit is one
    /// localized string with an Int count, so the catalog carries the plurals.
    static func lengthText(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        if s < 60 { return String(localized: "\(s) seconds", comment: "Length of an interrupted recording") }
        let m = s / 60
        if m < 60 { return String(localized: "\(m) minutes", comment: "Length of an interrupted recording") }
        let h = m / 60, rest = m % 60
        if rest == 0 { return String(localized: "\(h) hours", comment: "Length of an interrupted recording") }
        // Two strings, so each count takes its own plural form ("1 hour 5 minutes").
        return String(localized: "\(h) hours", comment: "Length of an interrupted recording")
            + " " + String(localized: "\(rest) minutes", comment: "Length of an interrupted recording")
    }

    /// The launch question's text.
    static func message(_ r: InterruptedRecording) -> String {
        let t = DateFormatter()
        t.dateStyle = .none
        t.timeStyle = .short
        let length = lengthText(r.seconds)
        let until = t.string(from: r.endedAt)
        return r.isMeeting
            ? String(localized: "Transcriberr closed while a meeting was recording. The \(length) up to \(until) are saved. Continue recording, and Stop joins the new part to it as one meeting.",
                     comment: "Launch question after a crash; first value is a length like 23 minutes, second a time")
            : String(localized: "Transcriberr closed while a recording was recording. The \(length) up to \(until) are saved. Continue recording, and Stop joins the new part to it as one recording.",
                     comment: "Launch question after a crash; first value is a length like 23 minutes, second a time")
    }
}
