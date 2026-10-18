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
    /// (maxSpeakers, threshold) the current manager was configured with.
    nonisolated(unsafe) private var configuredClusters: Int = -1
    nonisolated(unsafe) private var configuredThreshold: Double = -1

    init() {}

    var isReady: Bool { manager != nil }

    /// Setup for a given expected-speaker count. The count is baked into the
    /// clustering config, so a changed count rebuilds the manager (models are
    /// disk-cached — rebuild costs seconds, not a re-download).
    func prepare(numClusters: Int = 0, threshold: Double = 0.6) async throws {
        if manager == nil || configuredClusters != numClusters || configuredThreshold != threshold {
            var cfg = OfflineDiarizerConfig()
            if numClusters > 0 {
                // UPPER BOUND, deliberately not an exact quota. Forcing an
                // exact count manufactures speakers: a forced 5-way split of
                // a 2-voice meeting invents three phantoms by splitting real
                // voices. "5 speakers" means "at most 5" — the clusterer may
                // still find fewer. (Exact mode narrows the threshold instead
                // — see run(samples:numClusters:exact:).)
                cfg.clustering.maxSpeakers = numClusters
            }
            cfg.clustering.threshold = threshold
            let m = OfflineDiarizerManager(config: cfg)
            try await m.prepareModels()
            manager = m
            configuredClusters = numClusters
            configuredThreshold = threshold
            AppLog.info("diar", "diarizer ready (maxSpeakers=\(numClusters > 0 ? String(numClusters) : "auto") threshold=\(threshold))")
        }
    }

    /// Run on a pre-decoded 16 kHz mono Float32 buffer.
    ///
    /// exact=true: "the room really has numClusters voices" — if the first
    /// pass distinguishes fewer, re-run with a finer distance threshold (a
    /// gentler force than a hard quota: it lets genuinely different voices
    /// split, but never slices one voice into phantoms to fill a quota).
    /// Gives up honestly after three attempts.
    func run(
        samples: [Float],
        numClusters: Int = 0,
        exact: Bool = false
    ) async throws -> [SpeakerSegment] {
        let thresholds: [Double] = (exact && numClusters > 1) ? [0.6, 0.45, 0.34] : [0.6]
        var out: [SpeakerSegment] = []
        var succeeded = false
        for (attempt, th) in thresholds.enumerated() {
            let segments: [SpeakerSegment]
            do {
                try await prepare(numClusters: numClusters, threshold: th)
                guard let manager else { return out }
                segments = try await manager.process(audio: samples).segments.map {
                    SpeakerSegment(
                        startSeconds: Double($0.startTimeSeconds),
                        endSeconds: Double($0.endTimeSeconds),
                        speakerId: normalize($0.speakerId)
                    )
                }
            } catch {
                // A finer retry failing must not cost the pass that already
                // worked. Cancellation, and a first attempt failing, still throw.
                if !succeeded || error is CancellationError || Task.isCancelled { throw error }
                AppLog.warn("diar", "exact mode retry at threshold \(th) failed: \(error.localizedDescription) — keeping the previous result")
                return out
            }
            succeeded = true
            out = segments
            let found = Set(out.map(\.speakerId)).count
            if !exact || numClusters <= 1 || found >= numClusters {
                if attempt > 0 {
                    AppLog.info("diar", "exact mode reached \(found)/\(numClusters) voices at threshold \(th)")
                }
                return out
            }
            AppLog.info("diar", "exact mode: found \(found)/\(numClusters) voices at threshold \(th) — retrying finer")
        }
        AppLog.warn("diar", "exact mode could not distinguish \(numClusters) voices — keeping the honest result")
        return out
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

    /// A cluster this small is a scrap of someone else's voice, not a person.
    static let scrapSeconds = 8.0
    static let scrapShare = 0.03

    /// Folds scrap clusters into their neighbours. VBx leaves a cluster of
    /// a few seconds in most meetings (measured 2026-10-16 on three: 4.1,
    /// 4.5 and 5.4 s, while every real voice spoke 24 s or more), and each
    /// became a speaker of its own with three or four words. A cluster under
    /// `scrapSeconds` AND under `scrapShare` of all speech gives each of its
    /// regions to the speaker of the nearest region of a real cluster.
    ///
    /// One track with a voice print (`scores`, see ClusterVoice): the user
    /// may say only a few seconds (one question in a talk), so the user's
    /// cluster is never a scrap. And nearness is no reason to give another
    /// voice's scrap to the user: a scrap goes to the user's cluster only
    /// when it sounds like the user, otherwise to the nearest other voice,
    /// and stays as it is when there is none.
    static func foldScraps(_ diar: [SpeakerSegment], scores: [String: Float]? = nil) -> [SpeakerSegment] {
        let total = speechSeconds(diar)
        let user = userCluster(diar, scores: scores)
        let scraps = scrapClusters(total).subtracting(user.map { [$0] } ?? [])
        guard !scraps.isEmpty, scraps.count < total.count else { return diar }
        let real = diar.filter { !scraps.contains($0.speakerId) }
        AppLog.info("diar", "folding scrap clusters \(scraps.sorted().map { "\($0) (\(String(format: "%.1f", total[$0]!)) s)" }) into their neighbours")
        return diar.map { d in
            guard scraps.contains(d.speakerId) else { return d }
            let target: String?
            if let user, let s = scores?[d.speakerId], s >= VoiceActivity.onThreshold {
                target = user
            } else {
                target = real.filter { $0.speakerId != user }.min(by: { gap($0, d) < gap($1, d) })?.speakerId
            }
            guard let target else { return d }
            return SpeakerSegment(startSeconds: d.startSeconds, endSeconds: d.endSeconds, speakerId: target)
        }
    }

    private static func speechSeconds(_ diar: [SpeakerSegment]) -> [String: Double] {
        var total: [String: Double] = [:]
        for d in diar { total[d.speakerId, default: 0] += d.endSeconds - d.startSeconds }
        return total
    }

    private static func scrapClusters(_ total: [String: Double]) -> Set<String> {
        let all = total.values.reduce(0, +)
        return Set(total.filter { $0.value < scrapSeconds && $0.value < scrapShare * all }.keys)
    }

    /// The cluster the voice print names as the user, among the clusters in
    /// `diar`. When a scrap of the user's own voice also scores high and
    /// spoils the margin (ClusterVoice.user names nobody then), the pick is
    /// made again without the scraps; and when the user says so little that
    /// every cluster sounding like them is a scrap, with the best of them
    /// only. Folded or not, the same diarization gives the same answer.
    static func userCluster(_ diar: [SpeakerSegment], scores: [String: Float]?) -> String? {
        guard let scores else { return nil }
        let total = speechSeconds(diar)
        // No regions (labels came with the segments): every scored cluster.
        let present = total.isEmpty ? scores : scores.filter { total[$0.key] != nil }
        if let user = ClusterVoice.user(in: present) { return user }
        let scraps = scrapClusters(total)
        var real = present.filter { !scraps.contains($0.key) }
        if let user = ClusterVoice.user(in: real) { return user }
        guard let best = present.sorted(by: { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }).first
        else { return nil }
        real[best.key] = best.value
        return ClusterVoice.user(in: real)
    }

    /// Seconds between two regions (0 when they touch or overlap).
    static func gap(_ a: SpeakerSegment, _ b: SpeakerSegment) -> Double {
        max(0, max(a.startSeconds, b.startSeconds) - min(a.endSeconds, b.endSeconds))
    }

    /// The speaker of the diarizer region nearest to `start`…`end`, and how
    /// far it is.
    static func nearest(_ start: Double, _ end: Double, in diar: [SpeakerSegment]) -> (speaker: String, gap: Double)? {
        let probe = SpeakerSegment(startSeconds: start, endSeconds: end, speakerId: "")
        return diar.map { ($0.speakerId, gap($0, probe)) }.min { $0.1 < $1.1 }
    }

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
            // Ukrainian self-introductions.
            try? NSRegularExpression(
                pattern: #"(?i:мене звати|мене звуть)\s+([А-ЯІЇЄҐ][а-яіїєґ'’]{1,30})"#
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

        // Addressee rule: in a TWO-person conversation, greeting someone by
        // name ("Привіт, Лана" / "Hi, Lana") names the OTHER speaker — the
        // one obvious inference self-introductions can't make.
        let keys = Array(Set(segments.compactMap(\.speakerKey)))
        if keys.count == 2,
           let greetRx = try? NSRegularExpression(
               pattern: #"(?i:привіт|вітаю|добрий день|здравствуй|привет|hi|hello|hey)[,!]?\s+([A-ZА-ЯІЇЄҐ][a-zа-яіїєґё'’]{1,30})"#
           ) {
            for seg in segments {
                guard let key = seg.speakerKey else { continue }
                let other = keys[0] == key ? keys[1] : keys[0]
                guard names[other] == nil else { continue }
                let range = NSRange(seg.text.startIndex..., in: seg.text)
                if let match = greetRx.firstMatch(in: seg.text, range: range),
                   match.numberOfRanges >= 2,
                   let nameRange = Range(match.range(at: 1), in: seg.text)
                {
                    let candidate = String(seg.text[nameRange])
                    if !stoplist.contains(candidate), candidate != names[key] {
                        names[other] = candidate
                        AppLog.info("diar", "addressee rule: \(other) → \(candidate)")
                    }
                }
            }
        }
        return names
    }

    // MARK: - Helpers

    /// FluidAudio yields ids like "speaker_1" (streaming) or "S1" (offline)
    /// — normalize both to the SPEAKER_NN format the Android app (and our
    /// sidecar JSON) use. Splitting on "_" alone left "S1" as is, so the
    /// runner's keys and the backends' "Speaker N" labels never matched.
    private func normalize(_ id: String) -> String {
        let digits = id.reversed().prefix(while: { $0.isASCII && $0.isNumber })
        if !digits.isEmpty, let num = Int(String(digits.reversed())) {
            return String(format: "SPEAKER_%02d", num)
        }
        return id
    }
}
