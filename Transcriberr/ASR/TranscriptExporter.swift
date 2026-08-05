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
        var out = ""
        for (idx, seg) in segments.enumerated() {
            out += "\(idx + 1)\n\(srtTime(seg.startSeconds)) --> \(srtTime(seg.endSeconds))\n\(seg.text)\n\n"
        }
        try out.write(to: dir.appendingPathComponent("\(stem).srt"), atomically: true, encoding: .utf8)
    }

    private static func writeJson(stem: String, dir: URL, recording: Recording, segments: [Segment]) throws {
        // TODO: emit the same shape as the Android exporter (segments + meta).
        let url = dir.appendingPathComponent("\(stem).json")
        let payload: [String: Any] = [
            "title": recording.title,
            "duration_seconds": recording.durationSeconds,
            "segments": segments.map { seg in
                [
                    "start": seg.startSeconds,
                    "end": seg.endSeconds,
                    "text": seg.text,
                    "speaker": seg.speaker ?? "",
                    "speakerName": seg.speakerName ?? "",
                    "language": seg.language ?? "",
                ] as [String: Any]
            },
        ]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url)
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

    private static func srtTime(_ s: Double) -> String {
        let total = max(0, s)
        let h = Int(total) / 3600
        let m = (Int(total) % 3600) / 60
        let sec = Int(total) % 60
        let ms = Int((total - floor(total)) * 1000)
        return String(format: "%02d:%02d:%02d,%03d", h, m, sec, ms)
    }
}
