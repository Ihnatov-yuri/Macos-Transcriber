import Foundation
import FluidAudio

/// Speaker diarization via [FluidAudio](https://github.com/FluidInference/FluidAudio):
/// pyannote community-1 powerset segmentation + WeSpeaker embeddings +
/// VBx Bayesian-HMM clustering, all running through CoreML on the ANE.
///
/// Why FluidAudio vs the Android sherpa-onnx stack:
///   - Lower DER (~10.6% on AMI-SDM vs ~17% for pyannote 3.0 + CAM++)
///   - Language-agnostic (training is acoustic, not lexical)
///   - VBx is far more stable than AHC on multi-hour audio
///   - Native Swift package, ANE acceleration → 60× real-time on M1
///
/// Models auto-download from `huggingface.co/FluidInference/speaker-diarization-coreml`
/// the first time `prepareModels()` runs.
final class DiarizationRunner: @unchecked Sendable {
    struct SpeakerSegment: Sendable {
        let startSeconds: Double
        let endSeconds: Double
        let speakerId: String
    }

    nonisolated(unsafe) private var manager: OfflineDiarizerManager?
    /// numSpeakers the current manager was configured with (0 = auto).
    nonisolated(unsafe) private var configuredClusters: Int = -1

    init() {}

    var isReady: Bool { manager != nil }

    /// Setup for a given expected-speaker count. The count is baked into the
    /// clustering config, so a changed count rebuilds the manager (models are
    /// disk-cached — rebuild costs seconds, not a re-download).
    func prepare(numClusters: Int = 0) async throws {
        if manager == nil || configuredClusters != numClusters {
            var cfg = OfflineDiarizerConfig()
            if numClusters > 0 {
                // Exact speaker count from the user's SPEAKERS stepper —
                // the clusterer must produce exactly this many voices
                // instead of choosing its own via the distance threshold.
                cfg.clustering.numSpeakers = numClusters
            }
            let m = OfflineDiarizerManager(config: cfg)
            try await m.prepareModels()
            manager = m
            configuredClusters = numClusters
            AppLog.info("diar", "diarizer ready (numSpeakers=\(numClusters > 0 ? String(numClusters) : "auto"))")
        }
    }

    /// Run on a pre-decoded 16 kHz mono Float32 buffer.
    func run(
        samples: [Float],
        numClusters: Int = 0,
        threshold: Float = 0.5
    ) async throws -> [SpeakerSegment] {
        try await prepare(numClusters: numClusters)
        guard let manager else { return [] }

        let result = try await manager.process(audio: samples)
        return result.segments.map {
            SpeakerSegment(
                startSeconds: Double($0.startTimeSeconds),
                endSeconds: Double($0.endTimeSeconds),
                speakerId: normalize($0.speakerId)
            )
        }
    }

    /// Run directly on a file (FluidAudio's memory-mapped streaming path).
    func run(file: URL) async throws -> [SpeakerSegment] {
        try await prepare()
        guard let manager else { return [] }

        let result = try await manager.process(file)
        return result.segments.map {
            SpeakerSegment(
                startSeconds: Double($0.startTimeSeconds),
                endSeconds: Double($0.endTimeSeconds),
                speakerId: normalize($0.speakerId)
            )
        }
    }

    // MARK: - Post-processing

    /// Match each ASR segment to the diarizer cluster that overlaps it most.
    func assignSpeakers(
        segments: [RawSegment],
        diarization: [SpeakerSegment]
    ) -> [RawSegment] {
        guard !diarization.isEmpty else { return segments }
        return segments.map { seg in
            var assigned = seg
            assigned.speakerKey = bestSpeakerFor(start: seg.startSeconds, end: seg.endSeconds, in: diarization)
            return assigned
        }
    }

    private func bestSpeakerFor(start: Double, end: Double, in diar: [SpeakerSegment]) -> String? {
        var best: (String, Double)? = nil
        for d in diar {
            let overlap = max(0, min(end, d.endSeconds) - max(start, d.startSeconds))
            if overlap <= 0 { continue }
            if best == nil || overlap > best!.1 {
                best = (d.speakerId, overlap)
            }
        }
        return best?.0
    }

    /// "Hi, I'm Ahmed" / "My name is Sara" / "This is X speaking" → propagate
    /// the detected name to all same-speaker segments.
    func inferSpeakerNames(_ segments: [RawSegment]) -> [String: String] {
        var names: [String: String] = [:]
        let patterns: [Regex<Substring>] = [
            // try-and-discard pattern so failures don't crash; build at runtime
        ]
        _ = patterns
        // Case-insensitive on the phrase only — "my name is Daniel" appears
        // lowercase mid-sentence — while the captured name itself must stay
        // capitalized (that's the signal it's actually a name).
        let regexes: [NSRegularExpression] = [
            try? NSRegularExpression(
                pattern: #"\b(?i:I'?m|I am|My name is|This is)\s+([A-Z][a-zA-Z]{1,30})\b"#
            ),
        ].compactMap { $0 }

        // Words that follow "I'm …" without being names. Case-insensitive
        // matching upstream means sentence-position capitals slip through
        // ("I'm So excited" → "So") — block the common ones.
        let stoplist: Set<String> = [
            "Tired", "Sorry", "Here", "There", "Going", "Looking", "Trying",
            "Sure", "Okay", "Fine", "Right", "Wrong", "Glad", "Hungry",
            "So", "Not", "Just", "Very", "Really", "Also", "Still", "Now",
            "Actually", "Basically", "Gonna", "Done", "Good", "Great", "Happy",
            "Sad", "Busy", "Ready", "Back", "Afraid", "Curious", "Excited",
            "Thinking", "Working", "Talking", "Saying", "Asking", "Getting",
        ]

        for seg in segments {
            guard let key = seg.speakerKey, names[key] == nil else { continue }
            let range = NSRange(seg.text.startIndex..., in: seg.text)
            for rx in regexes {
                if let match = rx.firstMatch(in: seg.text, range: range),
                   match.numberOfRanges >= 2,
                   let nameRange = Range(match.range(at: 1), in: seg.text)
                {
                    let candidate = String(seg.text[nameRange])
                    if !stoplist.contains(candidate) {
                        names[key] = candidate
                        break
                    }
                }
            }
        }
        return names
    }

    // MARK: - Helpers

    /// FluidAudio yields ids like "speaker_1" — normalize to the SPEAKER_NN
    /// format the Android app (and our sidecar JSON) use.
    private func normalize(_ id: String) -> String {
        if let num = id.split(separator: "_").last.flatMap({ Int($0) }) {
            return String(format: "SPEAKER_%02d", num)
        }
        return id
    }
}
