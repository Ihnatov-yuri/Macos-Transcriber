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
///
/// Since 5.0, NVIDIA's Nemotron 3 Diarization (via FluidAudio's
/// `Nemotron3Diarizer`) runs first. Benched 2026-10-25: AMI test DER 13.5%
/// against 24.0% for the offline pipeline (collar 0), speaker confusion 0.8%
/// against 3.0%; on the 381-clip set of real calls it ties (95.2% vs 95.5%)
/// and splits people less. It holds at most 8 voices, so the offline pipeline
/// stays as the fallback: more than 8 expected, all 8 slots used, more voices
/// than the user's upper bound, or fewer than an exact count.
final class DiarizationRunner: @unchecked Sendable {
    struct SpeakerSegment: Sendable {
        let startSeconds: Double
        let endSeconds: Double
        let speakerId: String
    }

    enum Engine: String {
        case nemotron, fluid
    }

    /// `diar.engine` = nemotron (default) | fluid. TRANSCRIBERR_DIAR_ENGINE
    /// overrides it for one CLI run (A/B without touching shared defaults).
    static let engineKey = "diar.engine"
    static var engine: Engine {
        let pick = ProcessInfo.processInfo.environment["TRANSCRIBERR_DIAR_ENGINE"]
            ?? UserDefaults.standard.string(forKey: engineKey) ?? ""
        return Engine(rawValue: pick) ?? .nemotron
    }

    static let nemotronMaxSpeakers = 8
    /// Nemotron marks speech word by word (trained on forced-alignment
    /// labels), so a speaker's pauses come out as silence. Bridging gaps up
    /// to this long gave the best AMI DER (1.0 s: 13.8%, 1.5 s: 13.5% but
    /// 3x the false alarm); without it 24% of speech reads as missed.
    static let nemotronGapSeconds = 1.0

    /// Not thread-safe (FluidAudio's own note): one run at a time.
    private let nemotronLock = NSLock()
    nonisolated(unsafe) private var nemotron: Nemotron3Diarizer?

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
        if Self.engine == .nemotron, numClusters <= Self.nemotronMaxSpeakers {
            do {
                let segments = try await runNemotron(samples: samples)
                if let reason = Self.nemotronFallback(segments, numClusters: numClusters, exact: exact) {
                    AppLog.info("diar", "nemotron: \(reason) — running the offline diarizer instead")
                } else {
                    let merged = await mergeSameVoices(segments, samples: samples)
                    AppLog.info("diar", "nemotron: \(Set(merged.map(\.speakerId)).count) voices, \(merged.count) regions")
                    return merged
                }
            } catch {
                if error is CancellationError || Task.isCancelled { throw error }
                AppLog.warn("diar", "nemotron failed: \(error.localizedDescription) — running the offline diarizer instead")
            }
        }
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

    // MARK: - Nemotron 3

    /// The 10.24 s-chunk preset on the Neural Engine. On the real-call clip
    /// set it equals the GPU-only `offline` preset (95.2% both), and the GPU
    /// stays free for Whisper's decoder. 203x realtime on an M3 Pro.
    private func runNemotron(samples: [Float]) async throws -> [SpeakerSegment] {
        if nemotron == nil {
            let config = Nemotron3Config.fast128
            let models = try await Nemotron3Models.loadFromHuggingFace(
                config: config, computeUnits: .cpuAndNeuralEngine)
            nemotron = Nemotron3Diarizer(config: config, models: models)
            AppLog.info("diar", "nemotron ready (fast128, ANE)")
        }
        guard let nemotron else { return [] }
        try Task.checkCancellation()
        let lock = nemotronLock
        let (probs, frames) = try await Task.detached(priority: .userInitiated) {
            try lock.withLock { try nemotron.processComplete(samples) }
        }.value
        let raw = Nemotron3Diarizer.segments(probabilities: probs, frameCount: frames).map {
            // 1-based like the offline diarizer's S1, S2… keys.
            SpeakerSegment(startSeconds: Double($0.startSeconds), endSeconds: Double($0.endSeconds),
                           speakerId: String(format: "SPEAKER_%02d", $0.speakerIndex + 1))
        }
        return Self.bridgeGaps(raw, maxGap: Self.nemotronGapSeconds)
    }

    /// Nemotron can open a recording that starts mid-conversation with a
    /// second slot for the voice already speaking (its speaker cache is
    /// empty on the first chunk): the reference slice en-b gave one person
    /// two labels at 0:10 and 0:21 under every preset. The 23 h of full
    /// calls never did, but a recording can start mid-sentence too, so
    /// labels whose voices match become one. Such a label is short, often
    /// under ClusterVoice.minClips clean clips, so every clip counts here.
    private func mergeSameVoices(_ diar: [SpeakerSegment], samples: [Float]) async -> [SpeakerSegment] {
        guard Set(diar.map(\.speakerId)).count > 1 else { return diar }
        do {
            let floor = VoiceActivity.speechFloor(samples)
            let ranges = ClusterVoice.clipRanges(diar, sampleCount: samples.count, window: PeopleMatch.clipSeconds)
                .mapValues { $0.filter { VoiceActivity.rms(samples[$0]) >= floor } }
                .filter { !$0.value.isEmpty }
            let order = ranges.keys.sorted()
            let flat = try await PeopleEmbedder.embed(order.flatMap { ranges[$0]!.map { samples[$0] } })
            var clips: [String: [[Float]]] = [:]
            var i = 0
            for key in order {
                clips[key] = Array(flat[i..<(i + ranges[key]!.count)])
                i += ranges[key]!.count
            }
            let (into, sims) = Self.sameVoiceMerges(clips, seconds: Self.speechSeconds(diar))
            AppLog.info("diar", "nemotron voice check: clips \(order.map { "\($0) \(clips[$0]!.count)" }.joined(separator: ", ")); \(sims)")
            guard !into.isEmpty else { return diar }
            AppLog.info("diar", "nemotron: same voice under two labels, merging \(into.sorted { $0.key < $1.key }.map { "\($0.key)→\($0.value)" })")
            return diar.map { SpeakerSegment(startSeconds: $0.startSeconds, endSeconds: $0.endSeconds,
                                             speakerId: into[$0.speakerId] ?? $0.speakerId) }
        } catch {
            if error is CancellationError { return diar }
            AppLog.warn("diar", "nemotron: voice check failed, labels kept: \(error.localizedDescription)")
            return diar
        }
    }

    /// Which label folds into which: the most alike pair at People's
    /// same-voice bar (0.62, centroid to centroid) or above
    /// merges first (the quieter into the louder, by seconds spoken), its
    /// clips pooled, until no pair passes. Also the first round's
    /// similarities, for the log. Labels without clips are left alone.
    /// Benched 2026-10-25: en-b's split label scored 0.77 from one clip;
    /// different people in AMI and the 33 call tracks at most 0.58.
    static func sameVoiceMerges(_ clips: [String: [[Float]]], seconds: [String: Double],
                                threshold: Float = VoiceSuggestions.sameVoice) -> (into: [String: String], sims: String) {
        var pools = clips.filter { !$0.value.isEmpty }
        var into: [String: String] = [:]
        var firstRound = ""
        while pools.count > 1 {
            let centroid = pools.mapValues { VoiceActivity.normalizedMean($0) }
            let keys = centroid.keys.sorted()
            var best: (a: String, b: String, sim: Float)?
            var shown: [String] = []
            for (i, a) in keys.enumerated() {
                for b in keys[(i + 1)...] {
                    let sim = VoiceActivity.cosine(centroid[a]!, centroid[b]!)
                    shown.append("\(a)~\(b) \(String(format: "%.2f", sim))")
                    if sim >= threshold, sim > (best?.sim ?? -1) { best = (a, b, sim) }
                }
            }
            if firstRound.isEmpty { firstRound = shown.joined(separator: ", ") }
            guard let best else { break }
            let (keep, drop) = (seconds[best.a] ?? 0) >= (seconds[best.b] ?? 0) ? (best.a, best.b) : (best.b, best.a)
            pools[keep]! += pools.removeValue(forKey: drop)!
            into[drop] = keep
            for (k, v) in into where v == drop { into[k] = keep }
        }
        return (into, firstRound)
    }

    /// Joins each speaker's regions that are at most `maxGap` apart.
    static func bridgeGaps(_ diar: [SpeakerSegment], maxGap: Double) -> [SpeakerSegment] {
        var out: [SpeakerSegment] = []
        for (_, regions) in Dictionary(grouping: diar, by: \.speakerId) {
            var merged: [SpeakerSegment] = []
            for r in regions.sorted(by: { $0.startSeconds < $1.startSeconds }) {
                if let last = merged.last, r.startSeconds - last.endSeconds <= maxGap {
                    merged[merged.count - 1] = SpeakerSegment(
                        startSeconds: last.startSeconds, endSeconds: max(last.endSeconds, r.endSeconds),
                        speakerId: r.speakerId)
                } else {
                    merged.append(r)
                }
            }
            out += merged
        }
        return out.sorted { ($0.startSeconds, $0.speakerId) < ($1.startSeconds, $1.speakerId) }
    }

    /// Why Nemotron's result can't stand, or nil when it can. Voices are
    /// counted without scraps (foldScraps folds those later anyway), so a
    /// stray few seconds in a spare slot doesn't send a meeting to the
    /// fallback; a full house of 8 slots does, scraps included, since
    /// voices past the 8th were squeezed into them.
    static func nemotronFallback(_ diar: [SpeakerSegment], numClusters: Int, exact: Bool) -> String? {
        let total = speechSeconds(diar)
        if total.count >= nemotronMaxSpeakers { return "all \(nemotronMaxSpeakers) speaker slots used" }
        let voices = total.count - scrapClusters(total).count
        if numClusters > 0, voices > numClusters { return "\(voices) voices, more than the \(numClusters) expected" }
        if exact, numClusters > 1, voices < numClusters { return "\(voices) of exactly \(numClusters) voices" }
        return nil
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
            if let user, let s = scores?[d.speakerId], s >= ClusterVoice.userOnThreshold {
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
