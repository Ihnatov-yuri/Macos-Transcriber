import Foundation

/// `.txt` / `.srt` / `.json` sidecars next to each audio file.
/// Identical schema to `asr/TranscriptExporter.kt`, so files round-trip
/// between the Android and Mac apps (key requirement called out in the
/// Android README's "Knowledge carried from the Mac app" section).
enum TranscriptExporter {
    static func export(
        recording: Recording,
        to directory: URL? = nil
    ) throws {
        let dir = directory ?? URL(fileURLWithPath: recording.audioPath).deletingLastPathComponent()
        let stem = URL(fileURLWithPath: recording.audioPath).deletingPathExtension().lastPathComponent

        let segments = recording.segments.sorted { $0.startSeconds < $1.startSeconds }
        try writeTxt(stem: stem, dir: dir, segments: segments)
        try writeSrt(stem: stem, dir: dir, segments: segments)
        try writeJson(stem: stem, dir: dir, recording: recording, segments: segments)
        try writeSpeakerSidecar(stem: stem, dir: dir, segments: segments)
    }

    private static func writeTxt(stem: String, dir: URL, segments: [Segment]) throws {
        let body = segments.map { seg -> String in
            let name = seg.speakerName ?? seg.speaker ?? ""
            return name.isEmpty ? seg.text : "\(name): \(seg.text)"
        }.joined(separator: "\n")
        try body.write(to: dir.appendingPathComponent("\(stem).txt"), atomically: true, encoding: .utf8)
    }

    private static func writeSrt(stem: String, dir: URL, segments: [Segment]) throws {
        try srtText(segments: segments)
            .write(to: dir.appendingPathComponent("\(stem).srt"), atomically: true, encoding: .utf8)
    }

    static func srtText(segments: [Segment]) -> String {
        var out = ""
        var cue = 0
        for seg in segments {
            // A blank line ends an SRT cue: text carrying one (an LLM chunk
            // with paragraphs) cut its own cue short.
            let text = seg.text.split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
            // A cue with no text line is malformed SRT; skip it and keep
            // the numbering sequential.
            guard !text.isEmpty else { continue }
            cue += 1
            out += "\(cue)\n\(srtTime(seg.startSeconds)) --> \(srtTime(seg.endSeconds))\n\(text)\n\n"
        }
        return out
    }

    private static func writeJson(stem: String, dir: URL, recording: Recording, segments: [Segment]) throws {
        let data = try jsonData(recording: recording, segments: segments)
        try data.write(to: dir.appendingPathComponent("\(stem).json"), options: .atomic)
    }

    /// Same document as Android's `TranscriptExporter.toJson`: identical keys,
    /// and absent values written as explicit `null` (kotlinx decodes those
    /// into its nullable fields; an empty string would not round-trip).
    static func jsonData(recording: Recording, segments: [Segment]) throws -> Data {
        let doc = TranscriptJson(
            audioPath: recording.audioPath,
            title: recording.title,
            language: recording.sourceLanguage,
            translated: recording.translateToEnglish,
            durationSeconds: recording.durationSeconds,
            backend: recording.transcribedWithBackend,
            model: recording.transcribedWithModel,
            segments: segments.map {
                JsonSegment(
                    start: $0.startSeconds,
                    end: $0.endSeconds,
                    speaker: $0.speaker,
                    speakerName: $0.speakerName,
                    language: $0.language,
                    text: $0.text
                )
            }
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(doc)
    }

    struct TranscriptJson: Codable, Equatable {
        var audioPath: String
        var title: String
        var language: String?
        var translated: Bool
        var durationSeconds: Double
        var backend: String?
        var model: String?
        var segments: [JsonSegment]

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(audioPath, forKey: .audioPath)
            try c.encode(title, forKey: .title)
            try c.encode(language, forKey: .language)
            try c.encode(translated, forKey: .translated)
            try c.encode(durationSeconds, forKey: .durationSeconds)
            try c.encode(backend, forKey: .backend)
            try c.encode(model, forKey: .model)
            try c.encode(segments, forKey: .segments)
        }
    }

    struct JsonSegment: Codable, Equatable {
        var start: Double
        var end: Double
        var speaker: String?
        var speakerName: String?
        var language: String?
        var text: String

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(start, forKey: .start)
            try c.encode(end, forKey: .end)
            try c.encode(speaker, forKey: .speaker)
            try c.encode(speakerName, forKey: .speakerName)
            try c.encode(language, forKey: .language)
            try c.encode(text, forKey: .text)
        }
    }

    private static func writeSpeakerSidecar(stem: String, dir: URL, segments: [Segment]) throws {
        // NOT uniqueKeysWithValues: every segment of a named speaker yields
        // the same (speaker → name) pair, and duplicate keys TRAP. Keep the
        // first name seen per speaker.
        let mapping = Dictionary(
            segments.compactMap { seg -> (String, String)? in
                guard let key = seg.speaker, let name = seg.speakerName, !name.isEmpty
                else { return nil }
                return (key, name)
            },
            uniquingKeysWith: { first, _ in first }
        )
        guard !mapping.isEmpty else { return }
        let data = try JSONSerialization.data(withJSONObject: mapping, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: dir.appendingPathComponent("\(stem).speakers.json"))
    }

    static func srtTime(_ s: Double) -> String {
        // Round once in whole milliseconds: truncating the fraction put 2.3 s
        // at 00:00:02,299 (binary 0.2999…), and Int() traps on NaN/inf.
        let totalMs = s.isFinite ? Int((max(0, s) * 1000).rounded()) : 0
        let h = totalMs / 3_600_000
        let m = (totalMs % 3_600_000) / 60_000
        let sec = (totalMs % 60_000) / 1000
        let ms = totalMs % 1000
        return String(format: "%02d:%02d:%02d,%03d", h, m, sec, ms)
    }
}
