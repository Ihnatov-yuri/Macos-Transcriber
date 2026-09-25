import Foundation

/// "Super" dual-ASR merge — fully local.
///
/// Runs TWO speech-to-text engines on every chunk concurrently (defaults:
/// Parakeet v3 multilingual × Parakeet v2 English-specialist — genuinely
/// different weights), then has Gemma 4 (local MLX, TEXT mode — its reliable
/// mode) arbitrate a merged "best fit" transcript:
///   - keep what both engines agree on,
///   - resolve conflicts by contextual plausibility,
///   - never introduce content found in neither.
///
/// Sub-engines are user-selectable (Detail → RUN → MERGE A / MERGE B) and
/// stored in UserDefaults (`ensemble.engineA` / `ensemble.engineB`, shared
/// with UIPrefs). Roughly 2× the compute of a single engine plus one Gemma
/// text call per chunk — for when accuracy matters more than speed.
actor EnsembleBackend: ASRBackend {
    nonisolated let id = "ensemble"
    private(set) var isReady = false

    private unowned let factory: BackendFactory

    private var kindA: BackendFactory.Kind = .parakeet
    private var kindB: BackendFactory.Kind = .parakeetV2
    private var engineA: ASRBackend?
    private var engineB: ASRBackend?
    private var arbiter: ASRBackend?     // Gemma 4, text mode
    /// Set when Gemma wedged repeatedly this run — the remaining chunks run
    /// single-engine so the run finishes instead of stalling per chunk.
    private var gemmaBenched = false
    /// What the arbiter learned from reading the whole first-pass transcript
    /// — handed to every arbitration of this run.
    private var brief: MeetingBrief?

    init(factory: BackendFactory) {
        self.factory = factory
    }

    /// Languages of the upcoming run — set by the runner before `load` so
    /// the pair can be checked against them.
    private var runLanguages: Set<String> = []
    func setRunLanguages(_ languages: Set<String>) { runLanguages = languages }

    /// Parakeet v2 is English-only: in a non-English run it contributes a
    /// transliterated guess at half weight, which makes "Super" a slower
    /// single-engine run on the OTHER engine — and with the default pair
    /// that other engine is Parakeet v3, the weak one for Ukrainian. Swap v2
    /// for Whisper (or for v3 when Whisper is already in the pair).
    static func resolvePair(
        _ a: BackendFactory.Kind, _ b: BackendFactory.Kind, languages: Set<String>
    ) -> (BackendFactory.Kind, BackendFactory.Kind) {
        guard languages.count == 1, languages.first?.lowercased() != "english",
              a == .parakeetV2 || b == .parakeetV2 else { return (a, b) }
        let other = a == .parakeetV2 ? b : a
        let substitute: BackendFactory.Kind = other == .whisper ? .parakeet : .whisper
        AppLog.info("ensemble", "Parakeet v2 is English-only — using \(substitute.rawValue) for this \(languages.first ?? "") run")
        // Whisper leads the pair: it is the anchor for non-English audio.
        return substitute == .whisper ? (.whisper, other) : (other, substitute)
    }

    static func storedKind(_ key: String, fallback: BackendFactory.Kind) -> BackendFactory.Kind {
        guard let raw = UserDefaults.standard.string(forKey: key),
              let kind = BackendFactory.Kind(rawValue: raw)
        else { return fallback }
        return kind
    }

    // MARK: - Lifecycle

    /// `modelPath` is the Gemma model directory — used for the merge arbiter
    /// and for Gemma if it's picked as a sub-engine.
    func load(modelPath: URL?) async throws {
        let (a, b) = Self.resolvePair(
            Self.storedKind("ensemble.engineA", fallback: .parakeet),
            Self.storedKind("ensemble.engineB", fallback: .parakeetV2),
            languages: runLanguages)
        guard a != b else {
            throw ASRError.backendUnavailable(reason: "Super merge needs two different engines.")
        }
        guard a != .ensemble, b != .ensemble,
              a.isLocal, b.isLocal,
              a.supportsAudio, b.supportsAudio else {
            throw ASRError.backendUnavailable(
                reason: "Super merge sub-engines must be local speech engines (Parakeet v3/v2, Whisper, Gemma LiteRT)."
            )
        }

        // Always re-run: sub-engine loads are cheap no-ops when already
        // loaded, and the arbiter must re-resolve if Settings → text engine
        // changed mid-session.
        kindA = a
        kindB = b
        AppLog.info("ensemble", "loading \(a.rawValue) + \(b.rawValue)")
        let gen = generation

        let ea = factory.backend(for: a)
        try await ea.load(modelPath: nil)
        let eb = factory.backend(for: b)
        try await eb.load(modelPath: nil)
        try checkNotReleased(since: gen)
        engineA = ea
        engineB = eb

        // Arbiter: the configured local text engine (LiteRT Gemma is much
        // faster than MLX). Load is best-effort — without it we fall back to
        // preferring engine A rather than failing the run.
        let arbKind = Self.storedKind("ui.textEngine", fallback: .gemmaLiteRT)
        let resolvedArb: BackendFactory.Kind =
            (arbKind.supportsTextGeneration && arbKind.isLocal) ? arbKind : .gemmaLiteRT
        let arb = factory.backend(for: resolvedArb)
        if await !arb.isReady {
            try? await arb.load(modelPath: nil)
        }
        let arbReady = await arb.isReady
        try checkNotReleased(since: gen)
        arbiter = arbReady ? arb : nil
        if arbiter == nil {
            AppLog.warn("ensemble", "Gemma arbiter unavailable — merge falls back to engine A output")
        }
        gemmaBenched = false
        brief = nil
        isReady = true
    }

    /// Bumped by release(). A load that release() overtook at one of its
    /// awaits used to finish anyway and set `isReady` on a released ensemble.
    private var generation = 0

    private func checkNotReleased(since gen: Int) throws {
        guard generation == gen else {
            throw ASRError.modelLoadFailed(reason: "Super was released while loading")
        }
    }

    /// Recover from a wedged chunk: ask each engine (A, B and the arbiter,
    /// each once) to heal, and each rebuilds only if one of its own native
    /// calls is stuck. The ensemble cannot tell which engine hung, but each
    /// engine can.
    ///
    /// The first version rebuilt every LiteRT engine it found and returned.
    /// The Gemma arbiter is loaded on every Super run, so a Whisper call
    /// that hung in pass 1 (where Gemma does nothing) reloaded the idle
    /// Gemma, reset the gate under the running chunks, and retried on the
    /// same hung Whisper: 240 s per wedge, and benching never kicked in
    /// because Gemma was not a sub-engine.
    func recoverWedge(modelPath: URL?) async throws {
        var seen = Set<ObjectIdentifier>()
        var subEngineError: Error?
        for engine in [engineA, engineB, arbiter].compactMap({ $0 }) {
            guard seen.insert(ObjectIdentifier(engine)).inserted else { continue }
            do { try await engine.recoverWedge(modelPath: nil) } catch {
                AppLog.warn("ensemble", "wedge recovery of \(engine.id) failed: \(error.localizedDescription)")
                let isSubEngine = engine === engineA || engine === engineB
                if isSubEngine {
                    if subEngineError == nil { subEngineError = error }
                } else {
                    // Without an arbiter the merge keeps the voted text.
                    arbiter = nil
                }
            }
        }
        if let subEngineError { throw subEngineError }
    }

    /// The non-Gemma sub-engine (falls back to A when neither is Gemma).
    private var soloEngine: ASRBackend? { kindA == .gemmaLiteRT ? engineB : engineA }
    private var gemmaIsSubEngine: Bool { kindA == .gemmaLiteRT || kindB == .gemmaLiteRT }

    var isGemmaBenched: Bool { gemmaBenched }

    /// Called by the runner after repeated wedge recoveries: audio that
    /// reliably hangs LiteRT will keep hanging it, so stop feeding it.
    func benchGemma() {
        guard !gemmaBenched, gemmaIsSubEngine else { return }
        gemmaBenched = true
        AppLog.warn("ensemble", "Gemma benched after repeated wedges — rest of run is \(kindA == .gemmaLiteRT ? kindB.rawValue : kindA.rawValue) only")
    }

    func release() async {
        generation += 1
        engineA = nil
        engineB = nil
        arbiter = nil
        isReady = false
    }

    // MARK: - Audio in

    func transcribeChunk(
        samples: [Float],
        languages: Set<String>,
        translateTo: String?,
        diarize: Bool,
        previousContext: String?,
        speakerHints: [SpeakerHint]
    ) async throws -> String {
        guard isReady, let engineA, let engineB else {
            throw ASRError.modelLoadFailed(reason: "Ensemble backend not loaded")
        }
        if Self.isSilent(samples) { return "" }
        if gemmaBenched, let solo = soloEngine {
            return try await solo.transcribeChunk(
                samples: samples, languages: languages, translateTo: nil,
                diarize: false, previousContext: previousContext, speakerHints: [])
        }

        // FAST PATH — both sub-engines expose word confidences (Parakeet,
        // Whisper). Merge at the word level on the CPU (ROVER-style):
        // milliseconds per chunk instead of a 40–130 s Gemma call. Gemma
        // only arbitrates chunks where the engines disagree wildly.
        if let pa = engineA as? DetailedTranscribing, let pb = engineB as? DetailedTranscribing {
            async let taskA = pa.transcribeDetailed(samples: samples, languages: languages)
            async let taskB = pb.transcribeDetailed(samples: samples, languages: languages)
            // An engine that throws must leave a trace: a Whisper that failed
            // every chunk once turned Super into silent Parakeet-only output.
            let ra: Result<DetailedTranscription, Error>, rb: Result<DetailedTranscription, Error>
            do { ra = .success(try await taskA) } catch { ra = .failure(error) }
            do { rb = .success(try await taskB) } catch { rb = .failure(error) }
            for (kind, r) in [(kindA, ra), (kindB, rb)] {
                if case .failure(let e) = r { AppLog.warn("ensemble", "\(kind.rawValue) failed on this chunk: \(e.localizedDescription)") }
            }
            if case .success(let a) = ra, case .success(let b) = rb {
                return await mergeDetailed(a, b, context: previousContext, languages: languages)
            }
            // fall through to the generic text path on error
        }

        // GENERIC PATH — at least one sub-engine has no word confidences
        // (e.g. Gemma audio). Text-level compare + Gemma arbitration.
        async let taskA = engineA.transcribeChunk(
            samples: samples, languages: languages, translateTo: nil,
            diarize: false, previousContext: previousContext, speakerHints: []
        )
        async let taskB = engineB.transcribeChunk(
            samples: samples, languages: languages, translateTo: nil,
            diarize: false, previousContext: previousContext, speakerHints: []
        )
        let textA = ((try? await taskA) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let textB = ((try? await taskB) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

        if textA.isEmpty && textB.isEmpty { return "" }
        if let ruled = TranscriptHygiene.phantomResolution(textA, textB) { return Self.logPhantom(textA, textB, ruled) }
        if textA.isEmpty { return textB }
        if textB.isEmpty { return textA }

        let similarity = Self.tokenSimilarity(textA, textB)
        if similarity >= 0.85 {
            let preferA = Self.votePrior(for: kindA, languages: languages)
                >= Self.votePrior(for: kindB, languages: languages)
            AppLog.info("ensemble", String(format: "chunk agreement %.2f — skipping arbiter (%@ wins)", similarity, preferA ? "A" : "B"))
            return preferA ? textA : textB
        }
        return await gemmaMerge(textA: textA, textB: textB, context: previousContext, languages: languages)
    }

    // MARK: - Word-level confidence merge (fast path)

    /// One chunk's first-pass result for the two-pass max-quality flow:
    /// vote-merged text plus everything the second pass needs to arbitrate.
    struct RichChunk: Sendable {
        let text: String
        let agreement: Double
        let textA: String
        let textB: String
    }

    /// First pass of max-quality Super: transcribe A∥B and VOTE-merge only —
    /// no inline Gemma. Disputed chunks (low agreement) are arbitrated later
    /// by the runner with context from BOTH sides of the finished transcript.
    // MARK: - Timeline (whole-track readings)

    /// Where a chunk sits: which track (0 = system audio or the whole file,
    /// 1 = the echo-cancelled mic) and its span on the shared timeline.
    struct ChunkWindow: Sendable {
        let track: Int
        let start: Double
        let end: Double
    }

    /// Whisper's reading of each whole track, words timed on the timeline.
    private var longForm: [Int: [TimedWord]] = [:]
    /// What the far side said (system track, both engines, timed): the
    /// reference the mic track's words are checked against for echo.
    private var farSide: [TimedWord] = []

    /// On for every language but English. Measured on the reference slices
    /// with everything else equal: Ukrainian 23.0 → 21.5% and 19.7 → 15.5%
    /// WER, English 8.9 → 9.7% and 5.3 → 5.9% (Whisper alone showed the same
    /// split: no gain in English). `ensemble.whisperLongForm` overrides.
    static func longFormEnabled(languages: Set<String>) -> Bool {
        if let forced = UserDefaults.standard.object(forKey: "ensemble.whisperLongForm") as? Bool { return forced }
        return !languages.isEmpty && !languages.contains { $0.lowercased() == "english" }
    }

    /// Read whole tracks once, before pass 1, onto the shared timeline.
    ///
    /// Whisper (non-English): on a 28 s chunk WhisperKit decodes one 30 s
    /// window, then seeks to the last segment it finished and decodes the
    /// few seconds left as a SECOND window padded with ~26 s of zeros — the
    /// words before every cut are read from a scrap with nothing after it.
    /// Over a whole track the loop always has real audio ahead. Ukrainian
    /// reference slices, Whisper alone: 25.5 → 17.0% and 17.1 → 11.5% WER;
    /// English unchanged. Then English stretches forced through Ukrainian
    /// are re-read in English (`repairLanguage`).
    ///
    /// Parakeet (split-track meetings): a whole-track reading of the far
    /// side (seconds of ANE time) is the reference for removing echo from
    /// the mic by timing (`echoFiltered`), and of the mic the second
    /// opinion that points `repairLanguage` at suspect stretches.
    /// Forget the previous recording's timeline (the ensemble is shared
    /// across runs; stale words would be served for a new recording's windows).
    func clearTimeline() {
        longForm = [:]
        farSide = []
    }

    /// `onProgress` gets the Whisper readings' combined fraction (0…1) every
    /// few seconds: on a long meeting this step is most of the run (68 min
    /// of Ukrainian: 31 min), and a stage frozen at one line reads as a hang.
    /// Cancellation stops it before anything is stored.
    func prepareTimeline(tracks: [(id: Int, samples: [Float])], languages: Set<String>, splitTracks: Bool,
                         onProgress: (@Sendable (Double) -> Void)? = nil) async {
        clearTimeline()
        let whisper = (kindA == .whisper ? engineA : kindB == .whisper ? engineB : nil) as? WhisperBackend
        let parakeet = [(kindA, engineA), (kindB, engineB)]
            .first { $0.0 == .parakeet || $0.0 == .parakeetV2 }?.1 as? ParakeetBackend
        let useWhisper = Self.longFormEnabled(languages: languages) && whisper != nil
        let t0 = Date()
        var whisperTracks: [Int: (words: [TimedWord], segments: [WhisperBackend.SegmentSpan])] = [:]
        var parakeetTracks: [Int: [TimedWord]] = [:]
        let progresses = useWhisper ? tracks.map { _ in Progress() } : []
        let reporter: Task<Void, Never>? = (onProgress == nil || progresses.isEmpty) ? nil : Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                let f = progresses.map { $0.totalUnitCount > 0 ? $0.fractionCompleted : 0 }
                onProgress?(f.reduce(0, +) / Double(f.count))
            }
        }
        defer { reporter?.cancel() }
        // A failed reading is left OUT, never cached as empty: an empty
        // long-form track made Whisper's side of every chunk blank — Super
        // silently Parakeet-only. Left out, chunks read Whisper per chunk.
        await withTaskGroup(of: (Int, Bool, [TimedWord], [WhisperBackend.SegmentSpan])?.self) { group in
            for (n, t) in tracks.enumerated() {
                if useWhisper, let whisper {
                    let progress = progresses[n]
                    group.addTask {
                        do {
                            let r = try await whisper.transcribeTimedSegments(
                                samples: t.samples, languages: languages, progress: progress)
                            return (t.id, true, r.words, r.segments)
                        } catch {
                            AppLog.warn("ensemble", "long-form whisper failed on track \(t.id): \(error.localizedDescription) — per-chunk reading instead")
                            return nil
                        }
                    }
                }
                if splitTracks, let parakeet {
                    group.addTask {
                        do {
                            let r = try await parakeet.transcribeTimed(samples: t.samples, languages: languages)
                            return (t.id, false, r.words, [])
                        } catch {
                            AppLog.warn("ensemble", "whole-track parakeet failed on track \(t.id): \(error.localizedDescription)")
                            return nil
                        }
                    }
                }
            }
            for await case let (id, isWhisper, words, segments)? in group {
                if isWhisper { whisperTracks[id] = (words, segments) } else { parakeetTracks[id] = words }
            }
        }
        // Cancelled: the readings failed or are partial, and language repair
        // would spend more Whisper calls on a run nobody is waiting for.
        // Store nothing — a cancelled run must not leave words behind for
        // the next one on this shared backend.
        guard !Task.isCancelled else {
            AppLog.info("ensemble", "timeline cancelled")
            return
        }
        for (id, w) in whisperTracks {
            var words = w.words
            if let whisper, let samples = tracks.first(where: { $0.id == id })?.samples {
                words = await Self.repairLanguage(words: words, segments: w.segments,
                                                  secondOpinion: parakeetTracks[id] ?? [],
                                                  samples: samples, whisper: whisper)
            }
            longForm[id] = words
        }
        if splitTracks {
            // The repaired far side too, not only the raw one: the mic's own
            // Whisper words are the repaired reading, so an English stretch
            // spliced into the mic matched nothing on a far side that still
            // held the Ukrainian translation. The raw reading stays for the
            // mic stretches repair left alone. A word in both is harmless:
            // `echoFiltered` only asks whether ANY far-side word matches.
            farSide = ((whisperTracks[0]?.words ?? []) + (longForm[0] ?? []) + (parakeetTracks[0] ?? []))
                .sorted { $0.start < $1.start }
        }
        AppLog.info("ensemble", String(format: "timeline: whisper %d tracks / %d words, parakeet %d tracks, far side %d words, %.1fs",
                                       longForm.count, longForm.values.map(\.count).reduce(0, +),
                                       parakeetTracks.count, farSide.count, Date().timeIntervalSince(t0)))
    }

    /// Whisper forced to Ukrainian TRANSLATES English speech ("After four
    /// interviews they realized that" → "чотири інтерв'ю вони зрозуміли")
    /// or spells it in Cyrillic — 15% of the Ukrainian slices' remaining
    /// errors. Whisper's language detection spots those stretches reliably
    /// (log-prob −0.01 for that sentence), but costs an encoder pass each,
    /// so it is asked only where the two engines fall apart on a segment —
    /// what a translation looks like next to Parakeet's phonetic guess
    /// ("Авто 4 інтерв'ю"). An English verdict re-reads the segment in
    /// English and splices it in by time.
    static func repairLanguage(
        words: [TimedWord], segments: [WhisperBackend.SegmentSpan], secondOpinion: [TimedWord],
        samples: [Float], whisper: WhisperBackend
    ) async -> [TimedWord] {
        guard !secondOpinion.isEmpty else { return words }
        var out = words
        var checked = 0, repaired = 0
        for seg in segments where seg.end - seg.start >= 1.2 {
            let inSeg = { (w: TimedWord) in (w.start + w.end) / 2 >= seg.start && (w.start + w.end) / 2 < seg.end }
            let mine = out.filter(inSeg)
            guard mine.count >= 3, !mine.allSatisfy({ isLatinWord($0.word.norm) }) else { continue }
            let theirs = secondOpinion.filter {
                ($0.start + $0.end) / 2 >= seg.start - 0.3 && ($0.start + $0.end) / 2 < seg.end + 0.3
            }
            guard diceSimilarity(mine.map(\.word.norm), theirs.map(\.word.norm)) < 0.4 else { continue }
            let a = max(0, Int((seg.start - 0.2) * 16_000)), b = min(samples.count, Int((seg.end + 0.2) * 16_000))
            guard b - a >= 16_000 else { continue }
            let audio = Array(samples[a..<b])
            checked += 1
            guard let lang = try? await whisper.detectLanguage(samples: audio),
                  lang.code == "en", lang.probability >= 0.5,
                  let english = try? await whisper.transcribeTimed(samples: audio, languages: ["English"]),
                  !english.words.isEmpty
            else { continue }
            guard let spliced = splice(english.words, offset: Double(a) / 16_000, into: seg, of: out) else { continue }
            AppLog.info("ensemble", String(format: "language repair @%.1fs (en %.2f): \"%@\" → \"%@\"",
                                           seg.start, lang.probability,
                                           joinSurfaces(mine.map(\.word.surface)).prefix(60) as CVarArg,
                                           english.text.prefix(60) as CVarArg))
            out = spliced
            repaired += 1
        }
        if checked > 0 { AppLog.info("ensemble", "language repair: \(checked) segments checked, \(repaired) re-read in English") }
        return out
    }

    /// `words` with the segment's words replaced by a re-read of it
    /// (`reread` timed from `offset` on the timeline); nil when the re-read
    /// has nothing inside the segment. Only the words timed INSIDE the
    /// segment go in — the span the removal clears. The re-read's 0.2 s pads
    /// are there to give the decoder a run-up, not words: a neighbour's edge
    /// word read from them was spliced in beside the neighbour's own copy.
    /// This also keeps out what a short re-read writes over its zero padding
    /// ("Thank you." past the end of the audio), which Whisper's phantom
    /// guards only weigh on reads of 8 s or more.
    static func splice(_ reread: [TimedWord], offset: Double, into seg: WhisperBackend.SegmentSpan,
                       of words: [TimedWord]) -> [TimedWord]? {
        let inSeg = { (w: TimedWord) in (w.start + w.end) / 2 >= seg.start && (w.start + w.end) / 2 < seg.end }
        let spliced = reread
            .map { TimedWord(word: $0.word, start: $0.start + offset, end: $0.end + offset) }
            .filter(inSeg)
        guard !spliced.isEmpty else { return nil }
        return (words.filter { !inSeg($0) } + spliced).sorted { $0.start < $1.start }
    }

    /// Mic words that are the far side's words heard again. The tracks share
    /// one clock and the speaker→mic path is 30-50 ms (measured on every
    /// reference slice), so an echoed word sits at the SAME time as its
    /// original on the system track. One matching word proves nothing — two
    /// people say "yes" at once — so a word only goes as part of a run: at
    /// least `minRun` matches with at most one unmatched (garbled) word
    /// between neighbours, and the garbled ones inside the run go too. This
    /// catches the copies the sentence-level echo scrub cannot: degraded
    /// ones ("measure the power of our iPhone 4" for "measure that ROI"),
    /// and ones mixed into the same line as the user's own words.
    static func echoFiltered(_ words: [TimedWord], farSide: [TimedWord],
                             tolerance: Double = 0.6, minRun: Int = 3) -> [TimedWord] {
        guard !words.isEmpty, !farSide.isEmpty else { return words }
        let matched: [Bool] = words.map { w in
            let mid = (w.start + w.end) / 2
            // farSide is sorted by start: binary search the tolerance window.
            var lo = 0, hi = farSide.count
            while lo < hi { let m = (lo + hi) / 2; if farSide[m].start < mid - tolerance - 2 { lo = m + 1 } else { hi = m } }
            var k = lo
            while k < farSide.count, farSide[k].start <= mid + tolerance {
                let f = farSide[k]
                if !w.word.norm.isEmpty, f.word.norm == w.word.norm, abs((f.start + f.end) / 2 - mid) <= tolerance { return true }
                k += 1
            }
            return false
        }
        var drop = Set<Int>()
        var i = 0
        while i < words.count {
            guard matched[i] else { i += 1; continue }
            var last = i, count = 1, j = i + 1
            while j < words.count, j - last <= 2 {
                if matched[j] { last = j; count += 1 }
                j += 1
            }
            if count >= minRun { drop.formUnion(i...last) }
            i = last + 1
        }
        return words.enumerated().filter { !drop.contains($0.offset) }.map(\.element)
    }

    /// The long-form words whose midpoint falls inside the window.
    private func longFormWords(_ window: ChunkWindow?) -> [TimedWord]? {
        guard let window, let words = longForm[window.track] else { return nil }
        return words.filter {
            let mid = ($0.start + $0.end) / 2
            return mid >= window.start && mid < window.end
        }
    }

    private func detailed(
        _ engine: DetailedTranscribing, kind: BackendFactory.Kind,
        samples: [Float], languages: Set<String>, window: ChunkWindow?
    ) async throws -> DetailedTranscription {
        var timed: [TimedWord]
        if kind == .whisper, let cached = longFormWords(window) {
            timed = cached
        } else if let window, window.track == 1, !farSide.isEmpty {
            // Mic chunk of a split-track meeting: time the words on the
            // shared clock so echo can be matched against the far side.
            if let w = engine as? WhisperBackend {
                timed = try await w.transcribeTimed(samples: samples, languages: languages).words
            } else if let p = engine as? ParakeetBackend {
                timed = try await p.transcribeTimed(samples: samples, languages: languages).words
            } else {
                return try await engine.transcribeDetailed(samples: samples, languages: languages)
            }
            timed = timed.map { TimedWord(word: $0.word, start: $0.start + window.start, end: $0.end + window.start) }
        } else {
            return try await engine.transcribeDetailed(samples: samples, languages: languages)
        }
        if let window, window.track == 1, !farSide.isEmpty {
            let kept = Self.echoFiltered(timed, farSide: farSide)
            if kept.count < timed.count {
                AppLog.info("ensemble", String(format: "echo by timing: %@ dropped %d of %d mic words @%.0fs",
                                               kind.rawValue, timed.count - kept.count, timed.count, window.start))
            }
            timed = kept
        }
        let words = timed.map(\.word)
        return DetailedTranscription(text: Self.joinSurfaces(words.map(\.surface)), words: words)
    }

    func transcribeChunkRich(
        samples: [Float],
        languages: Set<String>,
        window: ChunkWindow? = nil
    ) async throws -> RichChunk {
        guard isReady, let engineA, let engineB else {
            throw ASRError.modelLoadFailed(reason: "Ensemble backend not loaded")
        }
        if Self.isSilent(samples) {
            return RichChunk(text: "", agreement: 1, textA: "", textB: "")
        }
        if gemmaBenched {
            return try await transcribeChunkSolo(samples: samples, languages: languages, window: window)
        }
        if let pa = engineA as? DetailedTranscribing, let pb = engineB as? DetailedTranscribing {
            async let taskA = detailed(pa, kind: kindA, samples: samples, languages: languages, window: window)
            async let taskB = detailed(pb, kind: kindB, samples: samples, languages: languages, window: window)
            // An engine that throws must leave a trace: a Whisper that failed
            // every chunk once turned Super into silent Parakeet-only output.
            let ra: Result<DetailedTranscription, Error>, rb: Result<DetailedTranscription, Error>
            do { ra = .success(try await taskA) } catch { ra = .failure(error) }
            do { rb = .success(try await taskB) } catch { rb = .failure(error) }
            for (kind, r) in [(kindA, ra), (kindB, rb)] {
                if case .failure(let e) = r { AppLog.warn("ensemble", "\(kind.rawValue) failed on this chunk: \(e.localizedDescription)") }
            }
            if case .success(let a) = ra, case .success(let b) = rb {
                if let ruled = TranscriptHygiene.phantomResolution(a.text, b.text) {
                    return RichChunk(text: Self.logPhantom(a.text, b.text, ruled), agreement: 1, textA: "", textB: "")
                }
                if a.text.isEmpty { return RichChunk(text: b.text, agreement: 1, textA: a.text, textB: b.text) }
                if b.text.isEmpty { return RichChunk(text: a.text, agreement: 1, textA: a.text, textB: b.text) }
                let priorA = Self.votePrior(for: kindA, languages: languages)
                let priorB = Self.votePrior(for: kindB, languages: languages)
                let preferredText = priorA >= priorB ? a.text : b.text
                let haveWords = !a.words.isEmpty && !b.words.isEmpty
                let similarity = haveWords
                    ? Self.diceSimilarity(a.words.map(\.norm), b.words.map(\.norm))
                    : Self.tokenSimilarity(a.text, b.text)
                let voted = haveWords
                    ? Self.roverMerge(a.words, b.words, priorA: priorA, priorB: priorB,
                                      vocabulary: Self.vocabularyNorms(languages: languages))
                    : preferredText
                return RichChunk(
                    text: voted.isEmpty ? preferredText : voted,
                    agreement: similarity,
                    textA: a.text, textB: b.text
                )
            }
        }
        // Generic fallback (an engine without word confidences).
        let textA = ((try? await engineA.transcribeChunk(
            samples: samples, languages: languages, translateTo: nil,
            diarize: false, previousContext: nil, speakerHints: [])) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let textB = ((try? await engineB.transcribeChunk(
            samples: samples, languages: languages, translateTo: nil,
            diarize: false, previousContext: nil, speakerHints: [])) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let ruled = TranscriptHygiene.phantomResolution(textA, textB) {
            return RichChunk(text: Self.logPhantom(textA, textB, ruled), agreement: 1, textA: "", textB: "")
        }
        if textA.isEmpty { return RichChunk(text: textB, agreement: 1, textA: textA, textB: textB) }
        if textB.isEmpty { return RichChunk(text: textA, agreement: 1, textA: textA, textB: textB) }
        let preferA = Self.votePrior(for: kindA, languages: languages)
            >= Self.votePrior(for: kindB, languages: languages)
        return RichChunk(
            text: preferA ? textA : textB,
            agreement: Self.tokenSimilarity(textA, textB),
            textA: textA, textB: textB)
    }

    /// Below this loudest-200-ms RMS a chunk is silence, and neither engine
    /// runs on it. Split-track meetings are the case: each track is silent
    /// while the other side talks — measured on a 42-min meeting, 22 of 98
    /// system-audio chunks were digital zero — yet Whisper spent ~2.3 s per
    /// chunk writing phantoms ("you") over them for the hygiene layer to
    /// drop. The quietest chunk with real sound in it peaked at 0.020, four
    /// times this; the phantom threshold (0.012) is kept for single lines.
    static let silentChunkPeakRMS: Float = 0.005

    static func isSilent(_ samples: [Float]) -> Bool {
        let peak = WhisperBackend.peakWindowRMS(samples) ?? 0
        guard peak < silentChunkPeakRMS else { return false }
        AppLog.info("ensemble", String(format: "chunk %.1fs silent (peak RMS %.4f) — skipping both engines", Double(samples.count) / 16_000, peak))
        return true
    }

    /// Single-engine escape hatch: a chunk whose audio wedges LiteRT twice
    /// still gets transcribed by the healthy engine instead of being lost.
    /// `window` as in the pair path: without it a mic chunk of a split-track
    /// meeting was read per chunk with the far side's echo left in, and
    /// Whisper's timeline words for the chunk went unused.
    func transcribeChunkSolo(
        samples: [Float],
        languages: Set<String>,
        window: ChunkWindow? = nil
    ) async throws -> RichChunk {
        guard isReady, let solo = soloEngine else {
            throw ASRError.modelLoadFailed(reason: "Ensemble backend not loaded")
        }
        let text: String
        if let d = solo as? DetailedTranscribing {
            let kind = kindA == .gemmaLiteRT ? kindB : kindA
            text = try await detailed(d, kind: kind, samples: samples, languages: languages, window: window).text
        } else {
            text = try await solo.transcribeChunk(
                samples: samples, languages: languages, translateTo: nil,
                diarize: false, previousContext: nil, speakerHints: [])
        }
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return RichChunk(text: t, agreement: 1, textA: t, textB: "")
    }

    /// Between the passes: the arbiter reads the WHOLE voted transcript once.
    /// Throws on timeout/failure; the run then arbitrates without a brief.
    func prepareBrief(transcript: String, vocabulary: String) async throws -> MeetingBrief? {
        guard let arbiter else { return nil }
        let built = try await MeetingBriefBuilder.build(
            transcript: transcript, vocabulary: vocabulary
        ) { system, user, maxTokens in
            try await arbiter.generateText(
                systemInstruction: system, userMessage: user, maxTokens: maxTokens)
        }
        brief = built
        return built
    }

    /// Second pass of max-quality Super: Gemma rules on a disputed chunk with
    /// surrounding-transcript context and the user's vocabulary.
    func arbitrate(
        textA: String,
        textB: String,
        context: String?,
        languages: Set<String>
    ) async -> String {
        await gemmaMerge(textA: textA, textB: textB, context: context, languages: languages)
    }

    private func mergeDetailed(
        _ a: DetailedTranscription,
        _ b: DetailedTranscription,
        context: String? = nil,
        languages: Set<String> = []
    ) async -> String {
        if let ruled = TranscriptHygiene.phantomResolution(a.text, b.text) { return Self.logPhantom(a.text, b.text, ruled) }
        if a.text.isEmpty { return b.text }
        if b.text.isEmpty { return a.text }

        let priorA = Self.votePrior(for: kindA, languages: languages)
        let priorB = Self.votePrior(for: kindB, languages: languages)
        // Where a whole-text winner is needed, take the stronger-language
        // engine's text instead of blindly preferring A.
        let preferredText = priorA >= priorB ? a.text : b.text

        // If either engine returned no scored words (some long-form paths
        // drop token timings), word-level similarity would read 0.00 and
        // EVERY chunk would escalate to slow Gemma arbitration. Fall back to
        // text-level similarity in that case.
        let haveWords = !a.words.isEmpty && !b.words.isEmpty
        let similarity = haveWords
            ? Self.diceSimilarity(a.words.map(\.norm), b.words.map(\.norm))
            : Self.tokenSimilarity(a.text, b.text)
        if !haveWords {
            AppLog.warn("ensemble", "scored words missing (A=\(a.words.count) B=\(b.words.count)) — text-level gate \(String(format: "%.2f", similarity))")
            if similarity >= 0.85 { return preferredText }
            return await gemmaMerge(textA: a.text, textB: b.text, context: context, languages: languages)
        }
        if similarity < 0.5 {
            // Diagnostic for the systematic 0.00-agreement mystery: show what
            // the two engines' normalized words actually look like.
            AppLog.warn("ensemble", "low dice \(String(format: "%.2f", similarity)) — A[0..5]=\(a.words.prefix(5).map(\.norm)) B[0..5]=\(b.words.prefix(5).map(\.norm))")
        }
        if similarity >= 0.999 {
            AppLog.info("ensemble", String(format: "agreement %.2f — preferred engine verbatim", similarity))
            return preferredText
        }
        // NOTE: no more ≥0.85 verbatim shortcut — a chunk that agrees on all
        // but one word ("OWASP 10" vs "overas 10") is precisely where the
        // vote earns its keep, and the vote costs milliseconds.
        // Wild disagreement (different language pick, hallucinated segment…)
        // is the one case worth a slow LLM look — and it's rare.
        if similarity < 0.5, arbiter != nil {
            AppLog.info("ensemble", String(format: "agreement %.2f — hard conflict, Gemma arbitrates", similarity))
            return await gemmaMerge(textA: a.text, textB: b.text, context: context, languages: languages)
        }
        let merged = Self.roverMerge(a.words, b.words, priorA: priorA, priorB: priorB,
                                     vocabulary: Self.vocabularyNorms(languages: languages))
        AppLog.info("ensemble", String(format: "agreement %.2f — confidence-voted merge (%d/%d words → %d)", similarity, a.words.count, b.words.count, merged.split(separator: " ").count))
        return merged.isEmpty ? preferredText : merged
    }

    /// ROVER-style two-system merge: align the word sequences (edit-distance
    /// DP over normalized words), then at each divergence keep the reading
    /// with the higher recognizer confidence, scaled by the per-language
    /// engine prior. Single-engine insertions survive only above a raw
    /// confidence floor (the prior governs divergent READINGS, not recall).
    /// Pure CPU, O(n·m) on ~100-word chunks — effectively instant.
    static func roverMerge(
        _ a: [ScoredWord],
        _ b: [ScoredWord],
        priorA: Float = 1,
        priorB: Float = 1,
        vocabulary: Set<String> = []
    ) -> String {
        let n = a.count, m = b.count
        guard n > 0, m > 0 else { return joinSurfaces((n > 0 ? a : b).map(\.surface)) }
        var dp = [[Int]](repeating: [Int](repeating: 0, count: m + 1), count: n + 1)
        for i in 0...n { dp[i][0] = i }
        for j in 0...m { dp[0][j] = j }
        for i in 1...n {
            for j in 1...m {
                let sub = dp[i-1][j-1] + (a[i-1].norm == b[j-1].norm ? 0 : 1)
                dp[i][j] = min(sub, dp[i-1][j] + 1, dp[i][j-1] + 1)
            }
        }
        let insertionFloor: Float = 0.55
        var i = n, j = m
        // source: 0 = aligned pair, 1 = only engine A had it, 2 = only engine B
        var reversed: [(surface: String, source: Int, norm: String)] = []
        while i > 0 || j > 0 {
            if i > 0, j > 0,
               dp[i][j] == dp[i-1][j-1] + (a[i-1].norm == b[j-1].norm ? 0 : 1)
            {
                let wa = a[i-1], wb = b[j-1]
                if wa.norm == wb.norm {
                    // Same word: the vote has nothing to decide, so take the
                    // trusted engine's SURFACE. Picking by confidence here
                    // interleaved two engines' casing and punctuation
                    // ("і Вони проводять, Вони ж зараз").
                    // With no trusted engine (equal priors) it stays what it
                    // was: the more confident reading.
                    let takeA = priorA != priorB ? priorA > priorB : wa.confidence >= wb.confidence
                    reversed.append((takeA ? wa.surface : wb.surface, 0, wa.norm))
                } else if vocabulary.contains(wa.norm) != vocabulary.contains(wb.norm) {
                    // One reading is a spelling the user has declared
                    // authoritative — that settles it.
                    reversed.append(vocabulary.contains(wa.norm) ? (wa.surface, 0, wa.norm) : (wb.surface, 0, wb.norm))
                } else if priorA != priorB,
                          Self.isLatinWord(priorA > priorB ? wa.norm : wb.norm),
                          !Self.isLatinWord(priorA > priorB ? wb.norm : wa.norm) {
                    // The trusted engine wrote a Latin-script word where the
                    // weak-language engine wrote a native-script one: that is
                    // code-switched English ("doesn't make it") against a
                    // phonetic guess ("Долин місяць"). The weak engine cannot
                    // emit Latin at all in this language, so its confidence
                    // says nothing here.
                    reversed.append(priorA > priorB ? (wa.surface, 0, wa.norm) : (wb.surface, 0, wb.norm))
                } else {
                    // Substitution → higher prior-weighted confidence wins.
                    reversed.append(wa.confidence * priorA >= wb.confidence * priorB
                                    ? (wa.surface, 0, wa.norm) : (wb.surface, 0, wb.norm))
                }
                i -= 1; j -= 1
            } else if i > 0, dp[i][j] == dp[i-1][j] + 1 {
                if a[i-1].confidence >= insertionFloor { reversed.append((a[i-1].surface, 1, a[i-1].norm)) }
                i -= 1
            } else {
                if b[j-1].confidence >= insertionFloor { reversed.append((b[j-1].surface, 2, b[j-1].norm)) }
                j -= 1
            }
        }
        // The weak-language engine's lone insertions are misalignment debris
        // ("Воно ж продається Воно пода, як практично" — Parakeet's two
        // extra words inside a Whisper sentence). A phrase the strong engine
        // skipped shows up as a RUN of insertions; only runs of 3+ survive.
        var words = Array(reversed.reversed())
        if priorA != priorB {
            let weak = priorA < priorB ? 1 : 2
            var k = 0
            while k < words.count {
                guard words[k].source == weak else { k += 1; continue }
                var end = k
                while end < words.count, words[end].source == weak { end += 1 }
                if end - k < 3 { words.removeSubrange(k..<end) } else { k = end }
            }
        }
        return joinSurfaces(dropEchoInsertions(words).map(\.surface))
    }

    /// With equal priors (English: Whisper + Parakeet) every word only one
    /// engine heard survives the vote, and on the reference slices those
    /// were mostly the SAME word again: a stutter the other engine cleaned
    /// up ("i was i was", "the the"), or one engine's split of a word the
    /// other wrote whole ("Kim Kim KimKim", "cheaper lm LLM", "R ROI"). Super
    /// scored WORSE than Whisper alone on both English slices because of
    /// them (12.5% vs 10.6%, 8.1% vs 5.8% WER). Drop a one-engine word that
    ///   - repeats its neighbour (or, as a run, the phrase beside it), or
    ///   - is a ≤ 3-letter piece at the start or end of its neighbour, or
    ///   - with the one-engine words next to it spells its neighbour.
    /// A real word only one engine caught ("Sorry for interrupting") is
    /// none of these and stays.
    /// Short words that really do stand next to a longer one sharing their
    /// letters ("on one side", "to today's") — never read as a fragment.
    static let functionWords: Set<String> = [
        "a", "i", "an", "in", "on", "to", "is", "it", "at", "as", "be", "we", "he", "me", "my", "of",
        "or", "so", "do", "no", "go", "up", "us", "if", "the", "and", "for", "you", "are", "not", "but",
        "all", "one", "can", "had", "was", "his", "her", "its", "our", "out", "too", "two", "how", "who",
        "why", "new", "now", "way", "get", "got", "has", "did", "any", "few", "own", "see", "use",
        "і", "й", "в", "у", "з", "на", "та", "а", "що", "це", "не", "як", "до", "за", "по", "ти", "я",
        "ми", "ви", "він", "їх", "там", "так", "ще", "вже", "від", "без", "при", "про",
    ]

    static func dropEchoInsertions(
        _ words: [(surface: String, source: Int, norm: String)]
    ) -> [(surface: String, source: Int, norm: String)] {
        guard words.count > 1 else { return words }
        var drop = Set<Int>()
        var k = 0
        while k < words.count {
            guard words[k].source != 0 else { k += 1; continue }
            var end = k
            while end < words.count, words[end].source == words[k].source { end += 1 }
            let run = Array(k..<end)
            let neighbours = [k - 1, end].filter { words.indices.contains($0) }.map { words[$0].norm }
            let runNorms = run.map { words[$0].norm }
            let joined = runNorms.joined()
            // A repeated phrase: the run says again what sits right before
            // or right after it ("I was I was sure").
            let r = run.count
            let before = k - r >= 0 ? words[(k - r)..<k].map(\.norm) : []
            let after = end + r <= words.count ? words[end..<(end + r)].map(\.norm) : []
            if r > 1, before == runNorms || after == runNorms || neighbours.contains(joined) {
                drop.formUnion(run)
            } else {
                for idx in run {
                    let w = words[idx].norm
                    guard !w.isEmpty else { continue }
                    let near = [idx - 1, idx + 1].filter { words.indices.contains($0) && !drop.contains($0) }
                        .map { words[$0].norm }
                    if near.contains(w)
                        || (w.count <= 3 && !Self.functionWords.contains(w)
                            && near.contains { $0.count > w.count && ($0.hasPrefix(w) || $0.hasSuffix(w)) }) {
                        drop.insert(idx)
                    }
                }
            }
            k = end
        }
        return words.enumerated().filter { !drop.contains($0.offset) }.map(\.element)
    }

    /// Join word surfaces defensively: trim stray engine whitespace (double
    /// spaces in the merged text came from Parakeet surfaces with leading
    /// spaces) and attach apostrophe-led fragments to the previous word
    /// ("Пам" + "'ятаєш" → "Пам'ятаєш", not "Пам 'ятаєш").
    static func joinSurfaces(_ surfaces: some Sequence<String>) -> String {
        var out = ""
        for raw in surfaces {
            let w = raw.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
            guard !w.isEmpty else { continue }
            if out.isEmpty {
                out = w
            } else if attachesToPrevious(w, previous: out) {
                out += w
            } else {
                out += " " + w
            }
        }
        return out
    }

    static func isLatinWord(_ norm: String) -> Bool {
        let letters = norm.unicodeScalars.filter { CharacterSet.letters.contains($0) }
        return !letters.isEmpty && letters.allSatisfy { $0.value < 0x250 }
    }

    /// A fragment that continues the previous word rather than starting a
    /// new one: "'ятаєш" after "Пам", "-менш" after "більш", ":00" after
    /// "10". A dash with a space after it is punctuation and stays apart.
    static func attachesToPrevious(_ fragment: String, previous: String?) -> Bool {
        guard let first = fragment.first, fragment.count > 1,
              let prevLast = previous?.last else { return false }
        let second = fragment[fragment.index(after: fragment.startIndex)]
        if "'’ʼ‘".contains(first) { return prevLast.isLetter && second.isLetter }
        if first == "-" { return (prevLast.isLetter || prevLast.isNumber) && (second.isLetter || second.isNumber) }
        if first == ":" { return prevLast.isNumber && second.isNumber }
        return false
    }

    /// Normalized words of the user's vocabulary (global + the run's
    /// languages). Single-word terms only — the vote is per word.
    static func vocabularyNorms(languages: Set<String>) -> Set<String> {
        let d = UserDefaults.standard
        var raw = d.string(forKey: "prompt.vocabulary") ?? ""
        if let js = d.string(forKey: "prompt.vocabulary.byLang"),
           let map = try? JSONDecoder().decode([String: String].self, from: Data(js.utf8)) {
            for lang in languages { raw += "," + (map[lang] ?? "") }
        }
        var out = Set<String>()
        for term in raw.split(whereSeparator: { $0 == "," || $0.isNewline }) {
            let words = TranscriptHygiene.normWords(String(term))
            if words.count == 1, words[0].count >= 3 { out.insert(words[0]) }
        }
        return out
    }

    private static func logPhantom(_ a: String, _ b: String, _ ruled: String) -> String {
        let phantom = TranscriptHygiene.isPhantomOnly(a) ? a : b
        AppLog.info("ensemble", "phantom \"\(phantom.prefix(40))\" from one engine — \(ruled.isEmpty ? "chunk ruled silent" : "keeping the other engine's \(ruled.count) chars")")
        return ruled
    }

    /// Per-language trust multiplier for the ROVER vote. Parakeet reports
    /// calibrated-high confidence even in languages it reads poorly, letting
    /// it outvote Whisper's correct per-word readings (Ukrainian sweep:
    /// Latin entity "NBE" lost to Cyrillic misreading "ДНБІ"). A 0.5 prior
    /// means the weak-language engine only wins a divergent word when the
    /// strong engine's own confidence is genuinely low.
    static func votePrior(for kind: BackendFactory.Kind, languages: Set<String>) -> Float {
        guard languages.count == 1, let lang = languages.first?.lowercased() else { return 1 }
        switch kind {
        case .parakeetV2 where lang != "english":   // English-specialist model
            return 0.5
        case .parakeet where lang == "ukrainian":   // documented weak spot vs Whisper
            return 0.5
        default:
            return 1
        }
    }

    // MARK: - Gemma arbitration (slow path)

    private func gemmaMerge(
        textA: String,
        textB: String,
        context: String? = nil,
        languages: Set<String> = []
    ) async -> String {
        let fallback = Self.votePrior(for: kindA, languages: languages)
            >= Self.votePrior(for: kindB, languages: languages) ? textA : textB
        guard let arbiter else { return fallback }
        // Authoritative entity spellings — the exact words engines fight over.
        var vocabBlock = ""
        let d = UserDefaults.standard
        var vocabParts: [String] = []
        if let g = d.string(forKey: "prompt.vocabulary"), !g.trimmingCharacters(in: .whitespaces).isEmpty {
            vocabParts.append(g)
        }
        if let js = d.string(forKey: "prompt.vocabulary.byLang"),
           let map = try? JSONDecoder().decode([String: String].self, from: Data(js.utf8)) {
            let keys = languages.isEmpty ? Array(map.keys) : Array(languages)
            for k in keys.sorted() { if let v = map[k], !v.isEmpty { vocabParts.append(v) } }
        }
        if !vocabParts.isEmpty {
            vocabBlock = "Vocabulary (authoritative spellings — prefer the reading matching these): \(vocabParts.joined(separator: ", ").prefix(600))\n\n"
        }
        // The bigger picture: the conversation's preceding merged text lets
        // the arbiter judge which conflicting reading fits the discussion —
        // names, topic, register — instead of judging the chunk in isolation.
        let contextBlock = context.map { tail in
            """
            Preceding transcript (context ONLY — do not repeat or transcribe it):
            …\(tail.suffix(400))

            """
        } ?? ""
        do {
            let merged = try await arbiter.generateText(
                systemInstruction: """
                You merge two automatic speech-recognition transcripts of the SAME audio segment into one best transcript. Rules:
                - Keep content the transcripts agree on.
                - Where they conflict, choose the reading that fits the preceding conversation context and is more plausible.
                - Never include content that appears in neither transcript. Never repeat the context. Never summarize, never comment.
                - Write in the language of the audio\(languages.count == 1 ? " (\(languages.first!))" : ""). Never translate. Keep names, brands and English terms that a transcript wrote in Latin script in Latin script.
                - A transcript may be empty or noise for a stretch the other one covers; keep the covered content.
                Output ONLY the merged transcript text.
                """,
                userMessage: vocabBlock + (brief?.promptBlock ?? "") + contextBlock + """
                Transcript A (\(kindA.displayName)):
                \(textA)

                Transcript B (\(kindB.displayName)):
                \(textB)
                """,
                // Bound output to ~1.3× the longer input (≈3 chars/token) so
                // the merge can't balloon past its sources.
                maxTokens: min(1200, max(160, Int(Double(max(textA.count, textB.count)) * 1.3 / 3)))
            )
            let cleaned = merged.trimmingCharacters(in: .whitespacesAndNewlines)
            AppLog.info("ensemble", "gemma merge: A=\(textA.count)ch B=\(textB.count)ch → \(cleaned.count)ch")
            return cleaned.isEmpty ? fallback : cleaned
        } catch {
            AppLog.warn("ensemble", "arbiter merge failed (\(error.localizedDescription)) — using the preferred engine's text")
            return fallback
        }
    }

    /// Dice coefficient over normalized word tokens (case/punctuation
    /// stripped): 1.0 = same words, 0 = disjoint. Word-order insensitive —
    /// fine for an agreement gate.
    static func tokenSimilarity(_ a: String, _ b: String) -> Double {
        func tokens(_ s: String) -> [String] {
            s.lowercased()
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { !$0.isEmpty }
        }
        return diceSimilarity(tokens(a), tokens(b))
    }

    static func diceSimilarity(_ ta: [String], _ tb: [String]) -> Double {
        let ta = ta.filter { !$0.isEmpty }, tb = tb.filter { !$0.isEmpty }
        guard !ta.isEmpty, !tb.isEmpty else { return 0 }
        var counts: [String: Int] = [:]
        for t in ta { counts[t, default: 0] += 1 }
        var common = 0
        for t in tb where (counts[t] ?? 0) > 0 {
            counts[t]! -= 1
            common += 1
        }
        return 2.0 * Double(common) / Double(ta.count + tb.count)
    }

    // MARK: - Text generation (not supported)

    func generateText(
        systemInstruction: String,
        userMessage: String,
        maxTokens: Int
    ) async throws -> String {
        throw ASRError.backendUnavailable(
            reason: "The merge engine is speech-to-text only. Text generation uses Gemma 4."
        )
    }
}
