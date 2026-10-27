import Foundation
import Accelerate
import FluidAudio
@preconcurrency import CoreML
import Synchronization

/// The user's voice, enrolled once from ~30 s of them reading aloud, and the
/// target-speaker voice activity built on it: where in a track the USER is
/// talking, decided by who the voice is, not by how loud the mic is.
///
/// Why: the recorder's speech timeline (<file>.me.json) is a loudness
/// comparison (mic louder than the call). It misses the user whenever the
/// far side is louder in the tap (headphones, a loud coach: it once removed
/// 27% of the user's words), it cannot tell the user talking over the
/// speakers from the speakers themselves, and it knows nothing about the
/// user's own voice coming back in the call audio. A speaker embedding
/// answers all three with one question: does this second of audio sound
/// like the enrolled voice?
///
/// Embeddings are WeSpeaker v2 (ResNet34, 256-d, L2-normalised) through
/// FluidAudio's public `DiarizerManager.extractSpeakerEmbedding`, on the ANE.
nonisolated struct Voiceprint: Codable, Equatable {
    static let currentModel = "wespeaker_v2"

    var model: String
    var created: Date
    /// Seconds of voiced enrollment audio the print was built from.
    var seconds: Double
    /// One embedding per enrollment window.
    var embeddings: [[Float]]
    /// The normalised mean of `embeddings`: what tracks are scored against.
    var centroid: [Float]

    /// How alike the enrollment windows are to their own centroid. A clean
    /// enrollment sits around 0.8; under 0.6 something else was talking.
    var selfSimilarity: Float {
        guard !embeddings.isEmpty else { return 0 }
        return embeddings.map { VoiceActivity.cosine($0, centroid) }.reduce(0, +) / Float(embeddings.count)
    }

    init(model: String = Voiceprint.currentModel, created: Date = Date(), seconds: Double, embeddings: [[Float]]) {
        self.model = model
        self.created = created
        self.seconds = seconds
        self.embeddings = embeddings
        self.centroid = VoiceActivity.normalizedMean(embeddings)
    }
}

/// Where the voice print lives: ~/Library/Application Support/Transcriberr/voice/.
/// The enrollment audio is kept beside it so a future embedding model can
/// rebuild the print without asking the user to read again.
nonisolated enum VoiceprintStore {
    static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Transcriberr/voice", isDirectory: true)
    }
    static var printURL: URL { directory.appendingPathComponent("voiceprint.json") }
    static var audioURL: URL { directory.appendingPathComponent("enrollment.f32") }

    /// The enrolled print, if any and if it was made by the model in use.
    static func load() -> Voiceprint? {
        // CLI experiments score with a print from elsewhere, never the user's.
        let url = ProcessInfo.processInfo.environment["TRANSCRIBERR_VOICEPRINT"].map { URL(fileURLWithPath: $0) } ?? printURL
        guard let data = try? Data(contentsOf: url),
              let print = try? JSONDecoder().decode(Voiceprint.self, from: data),
              print.model == Voiceprint.currentModel, !print.centroid.isEmpty else { return nil }
        return print
    }

    /// A reading this mixed (someone else talking, heavy noise) would gate
    /// meetings on the wrong voice: it is not saved.
    static let minSelfSimilarity: Float = 0.6

    struct MixedReading: LocalizedError {
        let similarity: Float
        var errorDescription: String? {
            "The reading sounded mixed (\(String(format: "%.2f", similarity)), at least 0.60 needed), as if someone else or a lot of noise was in it. Record again in a quiet room."
        }
    }

    /// A print file exists but cannot be used (damaged, or made by another
    /// embedding model): Settings says so instead of quietly showing none.
    static var isUnreadable: Bool {
        FileManager.default.fileExists(atPath: printURL.path) && load() == nil
    }

    static func save(_ print: Voiceprint, audio: [Float]) throws {
        guard print.selfSimilarity >= minSelfSimilarity else { throw MixedReading(similarity: print.selfSimilarity) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // The raw reading is the user's voice: kept on this Mac, out of
        // Time Machine (it can be re-recorded any time).
        var dir = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? dir.setResourceValues(values)
        try JSONEncoder().encode(print).write(to: printURL, options: .atomic)
        // Raw 16 kHz mono Float32: ~2 MB for 30 s, no codec in the way of a re-embed.
        try audio.withUnsafeBufferPointer { Data(buffer: $0) }.write(to: audioURL, options: .atomic)
        NotificationCenter.default.post(name: didChange, object: nil)
    }

    /// How alike a new reading must be to the saved voice to be added to it.
    static let minAddSimilarity: Float = 0.5

    struct NotYourVoice: LocalizedError {
        let similarity: Float
        var errorDescription: String? {
            String(format: "This reading does not sound like your saved voice (%.2f, at least 0.50 needed). Was someone else reading? To start over, use Record again in Settings → Audio input.", similarity)
        }
    }

    struct OtherModel: LocalizedError {
        var errorDescription: String? {
            "This reading was read with another voice model than your saved voice, so it was not added; nothing was changed."
        }
    }

    struct UnreadablePrint: LocalizedError {
        var errorDescription: String? {
            "Your saved voice cannot be read (damaged, or made by an older model). Record it again in Settings → Audio input; nothing was changed."
        }
    }

    /// Adds a reading to the saved voice instead of replacing it: more of
    /// the user's speech, from another day or microphone, without losing
    /// the first enrollment. The raw audio is appended to the enrollment
    /// so a future model re-embeds all of it.
    static func add(_ print: Voiceprint, audio: [Float]) throws {
        // The user's print is always the built-in model's (the mic gate runs
        // on it): a reading embedded by People's model would be compared
        // across models, or saved as a print `load()` refuses.
        guard print.model == Voiceprint.currentModel else { throw OtherModel() }
        // A print that exists but cannot be read is never replaced from
        // here: its enrollment audio is what a future model re-embeds.
        if isUnreadable { throw UnreadablePrint() }
        guard let old = load() else { try save(print, audio: audio); return }
        guard print.selfSimilarity >= minSelfSimilarity else { throw MixedReading(similarity: print.selfSimilarity) }
        let alike = VoiceActivity.cosine(old.centroid, print.centroid)
        guard alike >= minAddSimilarity else { throw NotYourVoice(similarity: alike) }
        let merged = Voiceprint(model: old.model, created: old.created, seconds: old.seconds + print.seconds,
                                embeddings: Array((old.embeddings + print.embeddings).suffix(maxEmbeddings)))
        try JSONEncoder().encode(merged).write(to: printURL, options: .atomic)
        let previous = (try? Data(contentsOf: audioURL)) ?? Data()
        try (previous + audio.withUnsafeBufferPointer { Data(buffer: $0) }).write(to: audioURL, options: .atomic)
        NotificationCenter.default.post(name: didChange, object: nil)
    }

    /// Embeddings kept in the user's print, the newest.
    static let maxEmbeddings = 200

    static func delete() {
        try? FileManager.default.removeItem(at: printURL)
        try? FileManager.default.removeItem(at: audioURL)
        NotificationCenter.default.post(name: didChange, object: nil)
    }

    static let didChange = Notification.Name("VoiceprintStore.didChange")
}

/// Speaker embeddings on demand, straight from the WeSpeaker CoreML model.
/// The model takes three windows per prediction (waveform 3×160000, mask
/// 3×589, embedding 3×256); FluidAudio's `extractSpeakerEmbedding` fills
/// one slot and throws the other two away. Here every slot carries a window
/// and three model instances run side by side: a 65-min meeting's two
/// tracks score in about a minute and a half instead of eight and a half.
/// One shared instance: the models load once (~30 MB downloaded on first
/// use beside the diarizer's).
actor VoiceEmbedder {
    static let shared = VoiceEmbedder()
    static let workers = 3
    static let slots = 3
    static let modelSamples = 160_000
    static let maskFrames = 589
    static let maskMargin = 4

    private var models: [MLModel] = []
    private var loading: Task<[MLModel], Error>?
    /// One caller at a time. `embed` suspends while the workers run, and the
    /// actor would let a second caller in to drive the same model instances
    /// from a second set of threads.
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func prepare() async throws {
        guard models.isEmpty else { return }
        if loading == nil {
            loading = Task {
                // One download/load for the files, then the embedding model
                // alone for the other workers: the segmentation model that
                // comes with DiarizerModels is never used here.
                let first = try await DiarizerModels.downloadIfNeeded().embeddingModel
                var loaded = [first]
                let url = DiarizerModels.defaultModelsDirectory().appendingPathComponent(ModelNames.Diarizer.embeddingFile)
                let config = MLModelConfiguration()
                config.computeUnits = .all
                for _ in 1..<Self.workers {
                    loaded.append((try? MLModel(contentsOf: url, configuration: config)) ?? first)
                }
                return loaded
            }
        }
        do {
            models = try await loading!.value
        } catch {
            loading = nil
            throw error
        }
        AppLog.info("voice", "voice embedder ready (\(Set(models.map(ObjectIdentifier.init)).count) workers)")
    }

    private func acquire() async {
        guard busy else { busy = true; return }
        await withCheckedContinuation { waiters.append($0) }
    }

    private func release() {
        if waiters.isEmpty { busy = false } else { waiters.removeFirst().resume() }
    }

    /// L2-normalised embeddings of 16 kHz mono clips, in order. Each clip is
    /// repeat-padded to the model's 10 s window under an all-ones mask, as
    /// `DiarizerManager.extractSpeakerEmbedding` does, so its voice alone
    /// decides the embedding.
    func embed(_ clips: [ArraySlice<Float>]) async throws -> [[Float]] {
        guard !clips.isEmpty else { return [] }
        try await prepare()
        await acquire()
        defer { release() }
        try Task.checkCancellation()
        // One worker per distinct instance: a worker whose own model failed
        // to load shares the first one's, and two threads never drive one.
        var seen = Set<ObjectIdentifier>()
        let distinct = models.filter { seen.insert(ObjectIdentifier($0)).inserted }
        // A shared hold like any engine's: LiteRT must never run beside it.
        let gate = try await InferenceGate.shared.acquire(owner: "voice")
        defer { Task { await InferenceGate.shared.release(gate) } }
        let cancelled = CancelFlag()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let models = distinct
                let batches = (clips.count + Self.slots - 1) / Self.slots
                let state = Mutex<(out: [[Float]], failure: Error?)>(
                    (out: [[Float]](repeating: [], count: clips.count), failure: nil))
                DispatchQueue.concurrentPerform(iterations: models.count) { w in
                    var b = w
                    while b < batches {
                        if cancelled.isSet {
                            state.withLock { $0.failure = $0.failure ?? CancellationError() }
                            return
                        }
                        let lo = b * Self.slots, hi = min(clips.count, lo + Self.slots)
                        do {
                            let e = try Self.predict(models[w], Array(clips[lo..<hi]))
                            state.withLock { for (k, v) in e.enumerated() { $0.out[lo + k] = v } }
                        } catch {
                            state.withLock { $0.failure = error }
                            return
                        }
                        b += models.count
                    }
                }
                let (out, failure) = state.withLock { ($0.out, $0.failure) }
                if let failure { cont.resume(throwing: failure) } else { cont.resume(returning: out) }
            }
            }
        } onCancel: {
            cancelled.set()
        }
    }

    /// The model's waveform slots are not independent (the conversion
    /// reads one waveform under three masks, pyannote's "one chunk, three
    /// local speakers"), so the clips share slot 0: each repeat-padded into
    /// its own third of the 10 s window, each mask covering only its third
    /// minus a margin where the convolution sees the neighbour.
    private static func predict(_ model: MLModel, _ clips: [ArraySlice<Float>]) throws -> [[Float]] {
        let wave = try MLMultiArray(shape: [NSNumber(value: slots), NSNumber(value: modelSamples)], dataType: .float32)
        let mask = try MLMultiArray(shape: [NSNumber(value: slots), NSNumber(value: maskFrames)], dataType: .float32)
        let wp = wave.dataPointer.assumingMemoryBound(to: Float.self)
        let mp = mask.dataPointer.assumingMemoryBound(to: Float.self)
        wp.update(repeating: 0, count: slots * modelSamples)
        mp.update(repeating: 0, count: slots * maskFrames)
        let part = modelSamples / slots
        // Every third carries audio. An empty third left at zero changed
        // the others' embeddings: a lone window beside two silent thirds
        // scored -0.01-0.31 against its true embedding (benchmark,
        // 2026-10-24), so a batch of 3n+1 or 3n+2 clips gave one or two
        // garbage embeddings. The spare thirds repeat the batch's own clips
        // and their outputs are dropped.
        let voiced = clips.filter { !$0.isEmpty }
        for k in 0..<slots where !voiced.isEmpty {
            let clip = k < clips.count && !clips[k].isEmpty ? clips[k] : voiced[k % voiced.count]
            let row = wp.advanced(by: k * part)
            var filled = 0
            while filled < part {
                let n = min(clip.count, part - filled)
                clip.withUnsafeBufferPointer { row.advanced(by: filled).update(from: $0.baseAddress!, count: n) }
                filled += n
            }
            guard k < clips.count, !clips[k].isEmpty else { continue }
            let lo = k * maskFrames / slots + maskMargin
            let hi = (k + 1) * maskFrames / slots - maskMargin
            mp.advanced(by: k * maskFrames + lo).update(repeating: 1, count: hi - lo)
        }
        let input = try MLDictionaryFeatureProvider(dictionary: [
            "waveform": MLFeatureValue(multiArray: wave),
            "mask": MLFeatureValue(multiArray: mask),
        ])
        guard let emb = try model.prediction(from: input).featureValue(for: "embedding")?.multiArrayValue else {
            throw DiarizerError.embeddingExtractionFailed
        }
        let dim = emb.shape.last?.intValue ?? 256
        let strides = emb.strides.map(\.intValue)
        return (0..<clips.count).map { k in
            var v = [Float](repeating: 0, count: dim)
            for d in 0..<dim { v[d] = emb[k * strides[0] + d * strides[1]].floatValue }
            let n = v.reduce(0) { $0 + $1 * $1 }.squareRoot()
            return n > 0 ? v.map { $0 / n } : v
        }
    }

    /// The voiced `enrollWindow`s of continuous speech, half overlapping.
    static func enrollClips(_ samples: [Float]) -> [ArraySlice<Float>] {
        let win = Int(VoiceActivity.enrollWindow * VoiceActivity.sampleRate)
        let floor = VoiceActivity.speechFloor(samples)
        var clips: [ArraySlice<Float>] = []
        var start = 0
        while start + win / 2 <= samples.count {
            let slice = samples[start..<min(samples.count, start + win)]
            if VoiceActivity.rms(slice) >= floor { clips.append(slice) }
            start += win / 2
        }
        return clips
    }

    /// Builds a print from enrollment audio: one embedding per voiced
    /// `enrollWindow` (half-overlapping), silence skipped.
    func enroll(_ samples: [Float]) async throws -> Voiceprint {
        let clips = Self.enrollClips(samples)
        guard clips.count >= 3 else { throw VoiceprintError.tooLittleSpeech }
        let embeddings = try await embed(clips)
        // Half-overlapping windows: each voiced second is counted twice.
        let voiced = Double(clips.map(\.count).reduce(0, +)) / VoiceActivity.sampleRate / 2
        return Voiceprint(seconds: voiced, embeddings: embeddings)
    }

    /// Similarity to `print` of every `VoiceActivity.window` of the track,
    /// one value per `VoiceActivity.hop`; nil where the track is silent or
    /// the window's starting cell is outside `only`.
    func scores(_ samples: [Float], against print: Voiceprint, only: ((Int) -> Bool)? = nil,
                onProgress: (@Sendable (Double) -> Void)? = nil) async throws -> [Float?] {
        let rate = VoiceActivity.sampleRate
        let win = Int(VoiceActivity.window * rate)
        let hop = Int(VoiceActivity.hop * rate)
        guard samples.count >= hop else { return [] }
        let floor = VoiceActivity.speechFloor(samples)
        let cells = (samples.count + hop - 1) / hop
        var voiced: [Int] = []
        for cell in 0..<cells {
            let start = cell * hop, end = min(samples.count, start + win)
            if only?(cell) ?? true, end - start >= hop,
               VoiceActivity.rms(samples[start..<end]) >= floor { voiced.append(cell) }
        }
        var out = [Float?](repeating: nil, count: cells)
        let block = 600
        var done = 0
        while done < voiced.count {
            try Task.checkCancellation()
            let part = voiced[done..<min(voiced.count, done + block)]
            let clips = part.map { samples[($0 * hop)..<min(samples.count, $0 * hop + win)] }
            let e = try await embed(clips)
            for (cell, v) in zip(part, e) {
                let s = VoiceActivity.cosine(v, print.centroid)
                // A window speaks for every hop cell it covers; a cell keeps
                // its best window, so a short word inside a long window of
                // someone else still counts.
                for c in cell..<min(cells, cell + max(1, win / hop)) {
                    out[c] = max(out[c] ?? -1, s)
                }
            }
            done += part.count
            onProgress?(Double(done) / Double(voiced.count))
        }
        return out
    }
}

/// Where the enrolled voice speaks in a split-track meeting: on the
/// echo-cancelled mic (the user, whatever the speakers played) and on the
/// system track (the user's own voice coming back in the call audio).
nonisolated struct VoiceTimeline: Equatable {
    var mic: [ClosedRange<Double>]
    var sys: [ClosedRange<Double>]

    /// Coarse call-audio pass: windows end to end (one per 1.5 s, every
    /// third hop), so no stretch of the track goes unseen.
    static let coarseStride = 3
    /// A coarse window this close to the user's voice is looked at closely.
    /// Other voices sit at most 0.32, so this lets through a few dozen
    /// windows of them per hour and every real leak (≥ 0.45).
    static let leakHint: Float = 0.30

    /// The print does not fit this recording's microphone: enrolled on the
    /// built-in mic and the meeting on AirPods, a cold, a changed model.
    struct Mismatch: LocalizedError {
        let strong: Int, ambiguous: Int
        var errorDescription: String? {
            "the voice print does not match this microphone (\(strong) clear windows, \(ambiguous) borderline)"
        }
    }

    /// Mic windows at or above the voice threshold that a print which fits
    /// must produce: about three seconds of the user's speech.
    static let minOwnWindows = 6
    /// Scores between every other voice's ceiling (0.32) and the threshold.
    static let ambiguousBand: ClosedRange<Float> = 0.33...0.399

    /// Whether the user's own mic matches the print well enough to gate on.
    /// The gate has no confidence escape, so a print that does not fit
    /// would delete the user from their own transcript. A fitting print
    /// gives clear windows (0.49-0.70 measured) far more often than
    /// borderline ones; a print that half-fits gives mostly borderline ones.
    /// Not fitting is not an error for the user: the run falls back to the
    /// loudness timeline, exactly as without a print.
    static func fits(_ micScores: [Float?]) -> (Bool, strong: Int, ambiguous: Int) {
        let s = micScores.compactMap { $0 }
        let strong = s.filter { $0 >= VoiceActivity.onThreshold }.count
        let ambiguous = s.filter { ambiguousBand.contains($0) }.count
        return (strong >= minOwnWindows && ambiguous <= strong, strong, ambiguous)
    }

    static func compute(mic: [Float], sys: [Float], print: Voiceprint,
                        onProgress: (@Sendable (Double) -> Void)? = nil) async throws -> VoiceTimeline {
        let total = Double(mic.count + sys.count)
        let micShare = total > 0 ? Double(mic.count) / total : 0.5
        let m = try await VoiceEmbedder.shared.scores(mic, against: print, onProgress: { onProgress?($0 * micShare) })
        let fit = fits(m)
        guard fit.0 else { throw Mismatch(strong: fit.strong, ambiguous: fit.ambiguous) }
        // The call audio is the others nearly always, and scoring all of it
        // at full resolution was three quarters of the pass on a speaker
        // call. Windows end to end first (a third of the work); full resolution
        // only around windows anywhere near the user's voice.
        let coarse = try await VoiceEmbedder.shared.scores(sys, against: print, only: { $0 % coarseStride == 0 })
        var near = Set<Int>()
        for c in Swift.stride(from: 0, to: coarse.count, by: coarseStride) where (coarse[c] ?? -1) >= leakHint {
            near.formUnion(max(0, c - coarseStride)...min(coarse.count - 1, c + coarseStride))
        }
        let s = near.isEmpty ? coarse.map { _ in nil }
            : try await VoiceEmbedder.shared.scores(sys, against: print, only: near.contains) { onProgress?(micShare + $0 * (1 - micShare)) }
        onProgress?(1)
        return VoiceTimeline(
            mic: VoiceActivity.intervals(m),
            sys: VoiceActivity.intervals(s, on: VoiceActivity.leakOnThreshold, off: VoiceActivity.leakOffThreshold))
    }
}

/// Which diarizer cluster is the user, in a recording with one track (a
/// plain recording, an imported file, an in-person meeting): the diarizer
/// knows who speaks when, the print knows which of them is the user.
///
/// A cluster is scored on a sample of its own speech, not the whole track:
/// non-overlapping `VoiceActivity.window` clips inside its regions, clear of
/// every other cluster's regions, at most `maxClips` spread over the
/// recording. An hour of conversation scores in seconds.
nonisolated enum ClusterVoice {
    static let maxClips = 60
    /// Fewer clean clips than this and the cluster is not scored at all.
    static let minClips = 3
    /// Seconds trimmed off each end of a region: the diarizer's boundaries
    /// are soft and the next voice starts inside them.
    static let inset = 0.25
    /// How far the user's cluster must stand above the next one. The
    /// calibration put the user at 0.49-0.70 and every other voice at most
    /// 0.32; two clusters both near the threshold are one voice split in
    /// two or a voice like the user's, and neither is named.
    static let margin: Float = 0.10
    /// The user's cluster on 3 s clips (2026-10-24): the user 0.53 at the
    /// least, every other voice at most 0.36. The 1.5 s target-speaker gate
    /// keeps VoiceActivity's 0.40.
    static let userOnThreshold: Float = 0.45

    /// Sample ranges (16 kHz) to embed per cluster.
    static func clipRanges(_ regions: [DiarizationRunner.SpeakerSegment],
                           sampleCount: Int, window: Double = VoiceActivity.window) -> [String: [Range<Int>]] {
        let rate = VoiceActivity.sampleRate, win = window
        var byCluster: [String: [ClosedRange<Double>]] = [:]
        for r in regions where r.endSeconds > r.startSeconds {
            byCluster[r.speakerId, default: []].append(r.startSeconds...r.endSeconds)
        }
        var out: [String: [Range<Int>]] = [:]
        for (key, own) in byCluster {
            let others = regions.filter { $0.speakerId != key }
            var clips: [Range<Int>] = []
            for r in own.sorted(by: { $0.lowerBound < $1.lowerBound }) {
                var a = r.lowerBound + inset
                while a + win <= r.upperBound - inset {
                    let b = a + win
                    if !others.contains(where: { $0.endSeconds > a && $0.startSeconds < b }) {
                        let lo = Int(a * rate), hi = min(sampleCount, Int(b * rate))
                        if hi - lo >= Int(VoiceActivity.hop * rate) { clips.append(lo..<hi) }
                    }
                    a = b
                }
            }
            if clips.count > maxClips {
                let step = Double(clips.count) / Double(maxClips)
                clips = (0..<maxClips).map { clips[Int(Double($0) * step)] }
            }
            out[key] = clips
        }
        return out
    }

    /// Median similarity to the print of each cluster's voiced clips; a
    /// cluster with too little clean speech is left out.
    @concurrent
    static func compute(samples: [Float], regions: [DiarizationRunner.SpeakerSegment],
                        print: Voiceprint) async throws -> [String: Float] {
        let floor = VoiceActivity.speechFloor(samples)
        let ranges = clipRanges(regions, sampleCount: samples.count, window: PeopleMatch.clipSeconds)
            .mapValues { $0.filter { VoiceActivity.rms(samples[$0]) >= floor } }
            .filter { $0.value.count >= minClips }
        let keys = ranges.keys.sorted()
        let clips = keys.flatMap { ranges[$0]!.map { samples[$0] } }
        let embeddings = try await VoiceEmbedder.shared.embed(clips)
        var out: [String: Float] = [:]
        var i = 0
        for key in keys {
            let n = ranges[key]!.count
            out[key] = median(embeddings[i..<(i + n)].map { VoiceActivity.cosine($0, print.centroid) })
            i += n
        }
        return out
    }

    /// The cluster that is the user: the best median at or above
    /// `userOnThreshold`, `margin` clear of the runner-up. Nil
    /// when no cluster sounds like the user, or two do.
    static func user(in scores: [String: Float]) -> String? {
        let ranked = scores.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
        guard let best = ranked.first, best.value >= userOnThreshold else { return nil }
        if ranked.count > 1, best.value - ranked[1].value < margin { return nil }
        return best.key
    }

    static func median(_ v: [Float]) -> Float {
        let s = v.sorted()
        guard !s.isEmpty else { return 0 }
        return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
    }
}

/// Set from a task's cancellation handler, read by the embedding workers
/// between batches: they run on dispatch threads, outside any task.
nonisolated final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
    func set() { lock.lock(); value = true; lock.unlock() }
}

enum VoiceprintError: LocalizedError {
    case tooLittleSpeech
    var errorDescription: String? {
        switch self {
        case .tooLittleSpeech: return "Not enough speech to learn your voice. Read the passage aloud for about 30 seconds."
        }
    }
}

/// Target-speaker voice activity: pure functions over similarity scores, so
/// the thresholds are unit-testable without audio or a model.
nonisolated enum VoiceActivity {
    static let sampleRate = 16_000.0
    /// Scoring window and hop. 1.5 s is enough voice for a stable embedding
    /// and short enough to follow a turn; the hop sets timeline resolution.
    static let window = 1.5
    static let hop = 0.5
    static let enrollWindow = 3.0
    /// Similarity at which a window is the user, and below which an open
    /// stretch closes again (hysteresis: a word over the far side dips but
    /// does not end the turn). Measured 2026-10-15 with a print from one
    /// meeting scored on three others (English and Ukrainian, headphones and
    /// speakers, nine other voices): the user's speech median 0.49-0.70,
    /// every other voice at most 0.32, echo residue on the mic about 0.
    static let onThreshold: Float = 0.40
    static let offThreshold: Float = 0.30
    /// The call audio is the others by construction: calling a stretch of
    /// it the user takes a clearer match.
    static let leakOnThreshold: Float = 0.45
    static let leakOffThreshold: Float = 0.35
    /// Gaps shorter than this inside the user's speech are one stretch.
    static let mergeGap = 0.75

    /// Cells → intervals in seconds, with hysteresis and gap merging.
    static func intervals(_ scores: [Float?], hop: Double = hop,
                          on: Float = onThreshold, off: Float = offThreshold) -> [ClosedRange<Double>] {
        var out: [ClosedRange<Double>] = []
        var open: Int?
        for (i, s) in scores.enumerated() {
            let v = s ?? -1
            if let o = open {
                if v < off {
                    out.append(Double(o) * hop...Double(i) * hop)
                    open = nil
                }
            } else if v >= on {
                open = i
            }
        }
        if let o = open { out.append(Double(o) * hop...Double(scores.count) * hop) }
        return merge(out, gap: mergeGap)
    }

    static func merge(_ ranges: [ClosedRange<Double>], gap: Double) -> [ClosedRange<Double>] {
        var out: [ClosedRange<Double>] = []
        for r in ranges.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            if let last = out.last, r.lowerBound - last.upperBound < gap {
                out[out.count - 1] = last.lowerBound...max(last.upperBound, r.upperBound)
            } else {
                out.append(r)
            }
        }
        return out
    }

    /// Share of [a, b] the intervals cover.
    static func coverage(_ a: Double, _ b: Double, in ranges: [ClosedRange<Double>]) -> Double {
        guard b > a else { return ranges.contains { $0.contains(a) } ? 1 : 0 }
        let covered = ranges.reduce(0.0) { $0 + max(0, min(b, $1.upperBound) - max(a, $1.lowerBound)) }
        return covered / (b - a)
    }

    // MARK: - Math

    static func cosine(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot: Float = 0, na: Float = 0, nb: Float = 0
        vDSP_dotpr(a, 1, b, 1, &dot, vDSP_Length(a.count))
        vDSP_svesq(a, 1, &na, vDSP_Length(a.count))
        vDSP_svesq(b, 1, &nb, vDSP_Length(b.count))
        let d = (na * nb).squareRoot()
        return d > 0 ? dot / d : 0
    }

    static func normalizedMean(_ vectors: [[Float]]) -> [Float] {
        guard let n = vectors.first?.count, n > 0 else { return [] }
        var sum = [Float](repeating: 0, count: n)
        for v in vectors where v.count == n { vDSP_vadd(sum, 1, v, 1, &sum, 1, vDSP_Length(n)) }
        var norm: Float = 0
        vDSP_svesq(sum, 1, &norm, vDSP_Length(n))
        let s = norm.squareRoot()
        return s > 0 ? sum.map { $0 / s } : sum
    }

    static func rms(_ x: ArraySlice<Float>) -> Float {
        guard !x.isEmpty else { return 0 }
        var r: Float = 0
        x.withUnsafeBufferPointer { vDSP_rmsqv($0.baseAddress!, 1, &r, vDSP_Length(x.count)) }
        return r
    }

    /// The level a window must reach to be worth embedding: well above the
    /// track's own quiet (20th percentile of 100 ms frames), never under an
    /// absolute floor that keeps digital silence and room tone out.
    static func speechFloor(_ samples: [Float]) -> Float {
        let frame = 1600
        guard samples.count >= frame else { return 0.003 }
        var levels: [Float] = []
        levels.reserveCapacity(samples.count / frame)
        var i = 0
        while i + frame <= samples.count {
            levels.append(rms(samples[i..<(i + frame)]))
            i += frame
        }
        levels.sort()
        let quiet = levels[levels.count / 5]
        return max(0.003, quiet * 3)
    }

    /// Where a track has sound at all: 20 ms frames at or above
    /// `speechFloor`, gaps under 0.2 s bridged, runs under 0.1 s (clicks)
    /// left out. In seconds. The diarizer drops speech under a second, so a
    /// quick "Yes." has no region; this still sees it.
    static func soundRanges(_ samples: [Float]) -> [ClosedRange<Double>] {
        let frame = 320, rate = sampleRate
        guard samples.count >= frame else { return [] }
        let floor = speechFloor(samples)
        var runs: [ClosedRange<Double>] = []
        var start: Int?, lastLoud = 0
        var i = 0
        while i + frame <= samples.count {
            if rms(samples[i..<(i + frame)]) >= floor {
                if let s = start, i - lastLoud > Int(0.2 * rate) {
                    runs.append(Double(s) / rate...Double(lastLoud + frame) / rate)
                    start = i
                } else if start == nil {
                    start = i
                }
                lastLoud = i
            }
            i += frame
        }
        if let s = start { runs.append(Double(s) / rate...Double(lastLoud + frame) / rate) }
        return runs.filter { $0.upperBound - $0.lowerBound >= 0.1 }
    }
}
