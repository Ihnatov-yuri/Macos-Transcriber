import Foundation

/// End-to-end transcription of a single audio file via Gemma 4 (or any other
/// `ASRBackend`). Mirror of Android's `asr/TranscriptionRunner.kt`.
///
///  1. Decode + VAD silence scan + VAD-aligned chunk slicing  (AudioDecoder)
///  2. Optional sherpa diarization pre-pass for hybrid mode    (DiarizationRunner)
///  3. Chunk loop:
///       - resolve speaker hints for this window
///       - backend.transcribeChunk(...)
///       - 2-min per-chunk timeout
///       - on timeout: release engine → reload → retry once
///       - tail-string carries cross-chunk continuity
///  4. Parse per-line speaker labels + assemble RawSegments
///
/// Returns `AsyncThrowingStream<ASREvent>` (swap of Kotlin's `channelFlow`).
/// One-shot claim used by the chunk-timeout race: whichever side (inference
/// or deadline) takes it first gets to resume the continuation; the loser's
/// attempt is dropped.
private final class FirstWinsClaim: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false
    func take() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if claimed { return false }
        claimed = true
        return true
    }
}

final class TranscriptionRunner: @unchecked Sendable {
    static let chunkTimeoutSeconds: TimeInterval = 120
    static let chunkTailChars = 250

    private let factory: BackendFactory
    private let prompts: PromptStore
    private let diarization: DiarizationRunner

    init(factory: BackendFactory, prompts: PromptStore, diarization: DiarizationRunner) {
        self.factory = factory
        self.prompts = prompts
        self.diarization = diarization
    }

    struct Params: Sendable {
        var file: URL
        var backend: BackendFactory.Kind
        var modelDirectory: URL?
        var languages: Set<String>
        var translateTo: String?
        var diarize: Bool
        var hybridDiarize: Bool
        var expectedSpeakers: Int
        var expectedSpeakersExact: Bool

        init(
            file: URL,
            backend: BackendFactory.Kind = .parakeet,
            modelDirectory: URL? = nil,
            languages: Set<String> = [],
            translateTo: String? = nil,
            diarize: Bool = false,
            hybridDiarize: Bool = false,
            expectedSpeakers: Int = 0,
            expectedSpeakersExact: Bool = false
        ) {
            self.file = file
            self.backend = backend
            self.modelDirectory = modelDirectory
            self.languages = languages
            self.translateTo = translateTo
            self.diarize = diarize
            self.hybridDiarize = hybridDiarize
            self.expectedSpeakers = expectedSpeakers
            self.expectedSpeakersExact = expectedSpeakersExact
        }
    }

    func run(_ params: Params) -> AsyncThrowingStream<ASREvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task { @MainActor in
                do {
                    try await self.runImpl(params, continuation: continuation)
                    continuation.finish()
                } catch is CancellationError {
                    continuation.yield(.failed(reason: "cancelled"))
                    continuation.finish(throwing: CancellationError())
                } catch {
                    continuation.yield(.failed(reason: error.localizedDescription))
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }

    @MainActor
    private func runImpl(
        _ params: Params,
        continuation: AsyncThrowingStream<ASREvent, Error>.Continuation
    ) async throws {
        AppLog.info("runner", "start \(params.file.lastPathComponent) backend=\(params.backend.rawValue) modelDir=\(params.modelDirectory?.path ?? "nil") diarize=\(params.diarize) hybrid=\(params.hybridDiarize) translate=\(params.translateTo ?? "—")")

        // ---------- decode + chunk ----------
        // Meeting recordings carry raw per-source tracks (<base>.mic.wav /
        // <base>.sys.wav). When both exist, transcribe SPLIT: each track is
        // chunked on its own (same shared timeline), everything from the mic
        // track is ground-truth "you", and diarization only has to untangle
        // the system track. Crosstalk can't blur identities across files.
        continuation.yield(.stage(text: "Decoding audio…", fraction: 0.02))
        let decoder = AudioDecoder()
        let micURL = params.file.deletingPathExtension().appendingPathExtension("mic.wav")
        let sysURL = params.file.deletingPathExtension().appendingPathExtension("sys.wav")
        let splitTracks = FileManager.default.fileExists(atPath: micURL.path)
            && FileManager.default.fileExists(atPath: sysURL.path)
        let samples: [Float]
        let chunks: [AudioDecoder.Chunk]
        let duration: Double
        var micChunkIndices: Set<Int> = []
        do {
            if splitTracks {
                let (_, micChunks, micDur) = try await decoder.decodeAndChunk(file: micURL)
                let (sysSamples, sysChunks, sysDur) = try await decoder.decodeAndChunk(file: sysURL)
                let tagged = (micChunks.map { ($0, true) } + sysChunks.map { ($0, false) })
                    .sorted { $0.0.startSeconds < $1.0.startSeconds }
                chunks = tagged.map(\.0)
                micChunkIndices = Set(tagged.enumerated().compactMap { $1.1 ? $0 : nil })
                samples = sysSamples          // diarization sees only the others
                duration = max(micDur, sysDur)
                AppLog.info("runner", "split-track meeting: \(micChunks.count) mic + \(sysChunks.count) sys chunks")
            } else {
                (samples, chunks, duration) = try await decoder.decodeAndChunk(file: params.file)
            }
        } catch {
            AppLog.error("runner", "decode failed: \(error.localizedDescription)")
            throw error
        }
        AppLog.info("runner", "decoded \(samples.count) samples = \(Int(duration))s, \(chunks.count) chunks")
        continuation.yield(.stage(
            text: "Sliced \(chunks.count) chunks (\(Int(duration))s)",
            fraction: 0.06
        ))

        // ---------- diarization pre-pass (hybrid) ----------
        // Acoustic backends (Parakeet v2/v3, ensemble) can't emit "Speaker N:"
        // labels the way LLM backends do, so whenever diarization is
        // requested with them, the FluidAudio diarizer pre-pass MUST run and
        // speakers get assigned from its regions in the finalize step.
        let needsDiarPrePass = params.diarize &&
            (params.hybridDiarize || params.backend.needsDiarizerForSpeakers)
        var diarSegments: [DiarizationRunner.SpeakerSegment] = []
        if needsDiarPrePass {
            continuation.yield(.stage(text: "Diarizing speakers…", fraction: 0.10))
            do {
                diarSegments = try await diarization.run(
                    samples: samples,
                    numClusters: splitTracks
                        ? max(0, params.expectedSpeakers - 1)
                        : params.expectedSpeakers,
                    exact: params.expectedSpeakersExact
                )
                AppLog.info("runner", "diar pre-pass produced \(diarSegments.count) regions")
            } catch {
                AppLog.error("runner", "diar pre-pass failed (continuing without hints): \(error.localizedDescription)")
                diarSegments = []
            }
        }

        // ---------- load backend ----------
        continuation.yield(.stage(text: "Loading model…", fraction: 0.14))
        let backend = factory.backend(for: params.backend)
        do {
            try await backend.load(modelPath: params.modelDirectory)
            AppLog.info("runner", "backend \(params.backend.rawValue) loaded")
        } catch {
            AppLog.error("runner", "backend load failed: \(error.localizedDescription)")
            throw error
        }

        // ---------- chunk loop ----------
        var allSegments: [RawSegment] = []
        var previousTail: String? = nil
        // Track chunks whose first-pass output looks suspicious so we can
        // re-run them in a refinement pass after the main loop.
        var lowConfidenceChunks: [(idx: Int, chunk: AudioDecoder.Chunk, parsedText: String)] = []
        let chunkBaseFraction: Double = 0.16
        let chunkSpan: Double = 0.80

        // Acoustic engines don't use cross-chunk prompt context, so their
        // chunks are independent — run a bounded PIPELINE (3 in flight) so
        // the ANE (Parakeet), GPU (Whisper / arbitration), and CPU (vote)
        // work simultaneously instead of in lockstep. LiteRT/cloud engines
        // stay sequential (single engine actor + real context use).
        let pipelineWidth: Int = {
            switch params.backend {
            case .parakeet, .parakeetV2, .whisper: return 3
            case .ensemble:
                // Max-quality toggle (Settings → Engines → Super): sequential
                // chunks so Gemma arbitration gets the preceding merged
                // transcript as context. Default = 3-wide pipeline for speed.
                return UserDefaults.standard.bool(forKey: "ui.superMaxQuality") ? 1 : 3
            default: return 1
            }
        }()
        nonisolated func hintsFor(_ chunk: AudioDecoder.Chunk) -> [SpeakerHint] {
            diarSegments.filter { seg in
                seg.endSeconds > chunk.startSeconds && seg.startSeconds < chunk.endSeconds
            }.prefix(12).map {
                SpeakerHint(
                    startSeconds: max($0.startSeconds, chunk.startSeconds) - chunk.startSeconds,
                    endSeconds: min($0.endSeconds, chunk.endSeconds) - chunk.startSeconds,
                    speakerKey: $0.speakerId
                )
            }
        }
        var pipelineResults: [Int: String] = [:]
        if pipelineWidth > 1 {
            try await withThrowingTaskGroup(of: (Int, String).self) { group in
                var submitted = 0
                func submit(_ idx: Int) {
                    let chunk = chunks[idx]
                    let hints = hintsFor(chunk)
                    group.addTask { [self] in
                        let raw = try await runChunkWithRetry(
                            backend: backend, params: params,
                            samples: chunk.samples,
                            previousContext: nil,
                            speakerHints: hints,
                            continuation: continuation
                        )
                        return (idx, raw)
                    }
                }
                while submitted < min(pipelineWidth, chunks.count) { submit(submitted); submitted += 1 }
                while let (idx, raw) = try await group.next() {
                    pipelineResults[idx] = raw
                    continuation.yield(.stage(
                        text: "Chunk \(min(pipelineResults.count, chunks.count))/\(chunks.count)",
                        fraction: chunkBaseFraction + chunkSpan * Double(pipelineResults.count) / Double(max(chunks.count, 1))
                    ))
                    if submitted < chunks.count { submit(submitted); submitted += 1 }
                }
            }
        }

        for (idx, chunk) in chunks.enumerated() {
            try Task.checkCancellation()

            let raw: String
            if pipelineWidth > 1 {
                raw = pipelineResults[idx] ?? ""
            } else {
                let progress = chunkBaseFraction + chunkSpan * Double(idx) / Double(max(chunks.count, 1))
                continuation.yield(.stage(
                    text: "Chunk \(idx + 1)/\(chunks.count) (\(formatTime(chunk.startSeconds))–\(formatTime(chunk.endSeconds)))",
                    fraction: progress
                ))
                do {
                    raw = try await runChunkWithRetry(
                        backend: backend,
                        params: params,
                        samples: chunk.samples,
                        previousContext: previousTail,
                        speakerHints: hintsFor(chunk),
                        continuation: continuation
                    )
                } catch {
                    AppLog.error("runner", "chunk \(idx + 1)/\(chunks.count) failed: \(error.localizedDescription)")
                    throw error
                }
            }
            AppLog.info("runner", "chunk \(idx + 1)/\(chunks.count) -> \(raw.count) chars")

            var parsed = parseSegments(
                rawText: raw,
                chunkStart: chunk.startSeconds,
                chunkEnd: chunk.endSeconds,
                diarize: params.diarize
            )
            // Split-track: everything from a mic chunk IS the user, by
            // construction — label it now so the finalize step (which only
            // fills nil speaker keys) leaves the ground truth alone.
            if micChunkIndices.contains(idx) {
                let myName = (UserDefaults.standard.string(forKey: "ui.myName") ?? "")
                    .trimmingCharacters(in: .whitespaces)
                parsed = parsed.map { seg in
                    var s = seg
                    s.speakerKey = "ME"
                    s.speakerName = myName.isEmpty ? "Me" : myName
                    return s
                }
            }
            // Cross-chunk near-duplicate guard: LLM engines occasionally
            // re-emit the previous chunk's tail (context echo) or loop a
            // near-identical line across consecutive chunks ("…and um
            // describe what she thinks." ×5, each differing by one word).
            // Exact-match trimming can't see those — fuzzy-match against the
            // last kept segment and drop repeats.
            var deduped: [RawSegment] = []
            for seg in parsed {
                let prev = deduped.last ?? allSegments.last
                if let prev, Self.nearDuplicate(prev.text, seg.text) {
                    AppLog.warn("runner", "dropping near-duplicate segment @\(String(format: "%.0f", seg.startSeconds))s: \(String(seg.text.prefix(60)))")
                    continue
                }
                deduped.append(seg)
            }
            parsed = deduped
            allSegments.append(contentsOf: parsed)
            // Build the cross-chunk continuation tail from the *parsed* text,
            // not the raw model output. parseSegments already discarded any
            // template markup (`<end_of_turn>` etc.), so we don't re-inject it
            // into the next chunk's `[CONTEXT]` prompt.
            let parsedJoined = parsed.map(\.text).joined(separator: " ")
            previousTail = String(parsedJoined.suffix(Self.chunkTailChars))

            // Emit per-chunk so the UI sees text appearing as it's produced.
            if !parsed.isEmpty {
                continuation.yield(.segments(chunkIndex: idx, segments: parsed))
            } else {
                AppLog.warn("runner", "chunk \(idx + 1) produced no parsed segments (raw len=\(raw.count))")
            }

            // Confidence assessment for the second-pass refinement loop.
            let confidence = ChunkConfidence.assess(
                rawText: parsedJoined,
                audioDurationSeconds: chunk.endSeconds - chunk.startSeconds
            )
            if confidence.isLow {
                AppLog.warn("runner", "chunk \(idx + 1) low confidence (score=\(String(format: "%.2f", confidence.score))) — \(confidence.reasons.joined(separator: ", "))")
                lowConfidenceChunks.append((idx, chunk, parsedJoined))
            }
        }
        AppLog.info("runner", "first pass done — \(allSegments.count) segments, \(lowConfidenceChunks.count) low-confidence chunks")

        // ---------- second pass on low-confidence chunks ----------
        if !lowConfidenceChunks.isEmpty {
            allSegments = try await refineLowConfidence(
                lowConfidenceChunks,
                allSegments: allSegments,
                params: params,
                backend: backend,
                continuation: continuation
            )
        }

        // ---------- split-track echo guard ----------
        // Without headphones the mic also hears the speakers, so the mic
        // track can contain a degraded acoustic copy of what the sys track
        // already transcribed cleanly. Drop ME segments that time-overlap a
        // sys segment with near-identical text — the digital copy wins.
        if splitTracks {
            // Sentence-level scrub: without headphones the mic hears the
            // speakers, so a ME segment is often a MIX of the user's own
            // words and an echoed copy of someone else's — whole-segment
            // comparison can't catch that. Compare sentence by sentence
            // against nearby sys text and strip only the echoed sentences.
            let sysSegs = allSegments.filter { $0.speakerKey != "ME" }
            allSegments = allSegments.compactMap { seg in
                guard seg.speakerKey == "ME" else { return seg }
                let nearby = sysSegs.filter {
                    $0.endSeconds > seg.startSeconds - 20 && $0.startSeconds < seg.endSeconds + 20
                }
                guard !nearby.isEmpty else { return seg }
                let scrubbed = Self.scrubEchoSentences(
                    from: seg.text,
                    against: nearby.map(\.text).joined(separator: " ")
                )
                if scrubbed == seg.text { return seg }
                if scrubbed.isEmpty {
                    AppLog.info("runner", "dropping fully-echoed ME segment @\(Int(seg.startSeconds))s")
                    return nil
                }
                AppLog.info("runner", "scrubbed echoed sentences from ME segment @\(Int(seg.startSeconds))s")
                var s = seg
                s.text = scrubbed
                return s
            }
        }

        // ---------- finalize ----------
        if params.diarize {
            if !diarSegments.isEmpty {
                // Fill speakers only where the backend didn't already label
                // them (Parakeet's word-level labels are more precise than
                // chunk-overlap assignment — don't overwrite those).
                let unlabeled = allSegments.contains { $0.speakerKey == nil }
                if unlabeled {
                    allSegments = allSegments.map { seg in
                        guard seg.speakerKey == nil else { return seg }
                        var s = seg
                        s.speakerKey = diarization.assignSpeakers(segments: [seg], diarization: diarSegments).first?.speakerKey
                        return s
                    }
                }
            }

            // De-chunk: the 30 s chunk windows are an implementation detail —
            // the transcript should read as SPEAKER TURNS. Merge adjacent
            // same-speaker segments into one continuous segment each.
            allSegments = Self.coalesceBySpeaker(allSegments)

            // Names from self-introductions ("Hi, I'm Ahmed") → propagate to
            // every segment of that speaker.
            let names = diarization.inferSpeakerNames(allSegments)
            if !names.isEmpty {
                AppLog.info("runner", "inferred speaker names: \(names)")
                allSegments = allSegments.map { seg in
                    var s = seg
                    if let key = s.speakerKey, let name = names[key], s.speakerName == nil {
                        s.speakerName = name
                    }
                    return s
                }
            }

            // Split-track: a sys-track cluster that ended up carrying MY
            // name is me again — platform echo/loopback of the user's own
            // voice. Fold it into ME so the user isn't counted twice.
            if splitTracks {
                let myName = (UserDefaults.standard.string(forKey: "ui.myName") ?? "")
                    .trimmingCharacters(in: .whitespaces)
                if !myName.isEmpty {
                    let doubles = Set(allSegments.compactMap { seg -> String? in
                        guard let k = seg.speakerKey, k != "ME",
                              seg.speakerName?.lowercased() == myName.lowercased() else { return nil }
                        return k
                    })
                    if !doubles.isEmpty {
                        AppLog.info("runner", "folding echo clusters \(doubles.sorted()) into ME")
                        allSegments = allSegments.map { seg in
                            var s = seg
                            if let k = s.speakerKey, doubles.contains(k) {
                                s.speakerKey = "ME"
                                s.speakerName = myName
                            }
                            return s
                        }
                        allSegments = Self.coalesceBySpeaker(allSegments)
                    }
                }
            }
        }
        continuation.yield(.stage(text: "Done.", fraction: 1.0))
        continuation.yield(.done(segments: allSegments))
    }

    /// Merge adjacent segments spoken by the same speaker into a single
    /// segment ("by-speaker, not by-chunk"). Only called on diarized runs —
    /// without speakers, chunk boundaries are the only structure we have.
    static func coalesceBySpeaker(_ segments: [RawSegment]) -> [RawSegment] {
        let sorted = segments.sorted { $0.startSeconds < $1.startSeconds }
        var out: [RawSegment] = []
        for seg in sorted {
            // User-tunable (Settings → Engines → Speaker turns): 30 s =
            // smooth blocks, 2 s = fine Samsung-style turns.
            let gap = UserDefaults.standard.double(forKey: "ui.turnCoalesceGapSeconds")
            if var last = out.last,
               last.speakerKey == seg.speakerKey,
               seg.startSeconds - last.endSeconds < (gap > 0 ? gap : 30)
            {
                last.endSeconds = max(last.endSeconds, seg.endSeconds)
                last.text += " " + seg.text
                out[out.count - 1] = last
            } else {
                out.append(seg)
            }
        }
        return out
    }

    // MARK: - Second pass

    /// For each flagged chunk, re-run transcription with a stronger context
    /// (the *parsed* text of the previous + next chunks) and replace the
    /// first-pass segments in that time window if the rerun looks better.
    @MainActor
    private func refineLowConfidence(
        _ flagged: [(idx: Int, chunk: AudioDecoder.Chunk, parsedText: String)],
        allSegments incoming: [RawSegment],
        params: Params,
        backend: ASRBackend,
        continuation: AsyncThrowingStream<ASREvent, Error>.Continuation
    ) async throws -> [RawSegment] {
        var allSegments = incoming
        continuation.yield(.stage(
            text: "Refining \(flagged.count) low-confidence chunk\(flagged.count == 1 ? "" : "s")…",
            fraction: 0.96
        ))

        for (i, entry) in flagged.enumerated() {
            try Task.checkCancellation()
            let progress = 0.96 + 0.03 * Double(i) / Double(max(flagged.count, 1))
            continuation.yield(.stage(
                text: "Refine \(i + 1)/\(flagged.count) — \(formatTime(entry.chunk.startSeconds))",
                fraction: progress
            ))

            // Build neighborhood context from segments around this chunk.
            let context = neighborContext(around: entry.chunk, in: allSegments)

            let raw: String
            do {
                raw = try await runChunkWithRetry(
                    backend: backend,
                    params: params,
                    samples: entry.chunk.samples,
                    previousContext: context,
                    speakerHints: [],
                    continuation: continuation
                )
            } catch {
                AppLog.warn("runner", "refine chunk \(entry.idx + 1) failed: \(error.localizedDescription)")
                continue
            }

            // Re-assess. Only accept the rerun if its confidence improved
            // (or at least didn't get worse).
            let firstConf = ChunkConfidence.assess(
                rawText: entry.parsedText,
                audioDurationSeconds: entry.chunk.endSeconds - entry.chunk.startSeconds
            )
            let parsed = parseSegments(
                rawText: raw,
                chunkStart: entry.chunk.startSeconds,
                chunkEnd: entry.chunk.endSeconds,
                diarize: params.diarize
            )
            let retryJoined = parsed.map(\.text).joined(separator: " ")
            let retryConf = ChunkConfidence.assess(
                rawText: retryJoined,
                audioDurationSeconds: entry.chunk.endSeconds - entry.chunk.startSeconds
            )
            if retryConf.score >= firstConf.score {
                AppLog.info("runner", "refine chunk \(entry.idx + 1) did not improve (\(String(format: "%.2f", firstConf.score)) → \(String(format: "%.2f", retryConf.score))) — keeping original")
                continue
            }
            AppLog.info("runner", "refine chunk \(entry.idx + 1) improved \(String(format: "%.2f", firstConf.score)) → \(String(format: "%.2f", retryConf.score))")

            // Splice replacement into allSegments + tell JobManager to do the
            // same in SwiftData.
            allSegments.removeAll { seg in
                seg.startSeconds >= entry.chunk.startSeconds &&
                seg.endSeconds <= entry.chunk.endSeconds
            }
            allSegments.append(contentsOf: parsed)
            allSegments.sort { $0.startSeconds < $1.startSeconds }
            continuation.yield(.replaceSegments(
                startSeconds: entry.chunk.startSeconds,
                endSeconds: entry.chunk.endSeconds,
                segments: parsed
            ))
        }
        return allSegments
    }

    /// Build a context block for the refinement pass from the segments
    /// immediately before and after this chunk.
    private func neighborContext(around chunk: AudioDecoder.Chunk, in segments: [RawSegment]) -> String? {
        let before = segments
            .filter { $0.endSeconds <= chunk.startSeconds }
            .suffix(2)
            .map(\.text)
            .joined(separator: " ")
        let after = segments
            .filter { $0.startSeconds >= chunk.endSeconds }
            .prefix(2)
            .map(\.text)
            .joined(separator: " ")
        let combined = (before + " " + after).trimmingCharacters(in: .whitespacesAndNewlines)
        return combined.isEmpty ? nil : "[REFINEMENT PASS — prior attempt was low-confidence; neighboring transcript: \(combined.prefix(400))]"
    }

    // MARK: - Chunk loop with retry

    @MainActor
    private func runChunkWithRetry(
        backend: ASRBackend,
        params: Params,
        samples: [Float],
        previousContext: String?,
        speakerHints: [SpeakerHint],
        continuation: AsyncThrowingStream<ASREvent, Error>.Continuation
    ) async throws -> String {
        // The ensemble runs two engines + a Gemma merge per chunk — give it
        // more headroom than a single engine before declaring a wedge.
        let timeout: TimeInterval = params.backend == .ensemble ? 300 : Self.chunkTimeoutSeconds
        do {
            return try await withChunkTimeout(seconds: timeout) {
                try await backend.transcribeChunk(
                    samples: samples,
                    languages: params.languages,
                    translateTo: params.translateTo,
                    diarize: params.diarize,
                    previousContext: previousContext,
                    speakerHints: speakerHints
                )
            }
        } catch ASRError.chunkTimeout {
            continuation.yield(.stage(text: "Chunk wedged — reloading model…", fraction: -1))
            await backend.release()
            try await backend.load(modelPath: params.modelDirectory)
            return try await withChunkTimeout(seconds: timeout) {
                try await backend.transcribeChunk(
                    samples: samples,
                    languages: params.languages,
                    translateTo: params.translateTo,
                    diarize: params.diarize,
                    previousContext: previousContext,
                    speakerHints: speakerHints
                )
            }
        }
    }

    /// Run `op` with a wall-clock deadline. MLX inference doesn't cooperate
    /// with Swift cancellation (it blocks its worker thread), so both sides
    /// run as detached tasks racing on a first-wins continuation.
    ///
    /// NOT a task group: a group must await ALL children before returning, so
    /// a detached 120 s deadline child pinned every chunk to the full timeout
    /// even when inference finished in 0.25 s — the runner was sleeping
    /// 99.8% of the time with Parakeet. The continuation returns the moment
    /// the winner resumes it; the loser's late resume attempt is dropped by
    /// the claim flag.
    private func withChunkTimeout<T: Sendable>(
        seconds: TimeInterval,
        _ op: @Sendable @escaping () async throws -> T
    ) async throws -> T {
        let claim = FirstWinsClaim()
        return try await withCheckedThrowingContinuation { cont in
            let work = Task.detached(priority: .userInitiated) {
                do {
                    let value = try await op()
                    if claim.take() { cont.resume(returning: value) }
                } catch {
                    if claim.take() { cont.resume(throwing: error) }
                }
            }
            Task.detached(priority: .utility) {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                if claim.take() {
                    work.cancel()          // best-effort; MLX may ignore
                    cont.resume(throwing: ASRError.chunkTimeout)
                }
            }
        }
    }

    // MARK: - Segment parsing

    /// Turn one chunk's raw text into `RawSegment`s. If diarize=true the text
    /// looks like `Speaker 1: hello\nSpeaker 2: hi` — split on speaker labels
    /// and time-distribute proportionally across the chunk window. If
    /// diarize=false, the whole chunk becomes one segment.
    private func parseSegments(
        rawText: String,
        chunkStart: Double,
        chunkEnd: Double,
        diarize: Bool
    ) -> [RawSegment] {
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return [] }
        let duration = max(0.001, chunkEnd - chunkStart)

        if !diarize {
            return [RawSegment(
                startSeconds: chunkStart,
                endSeconds: chunkEnd,
                text: text
            )]
        }

        // Split on lines starting with "Speaker N:" (allow "Speaker 1", "Spkr 2", "S1:" later if needed)
        let pattern = #/(?m)^\s*(?:Speaker|SPEAKER)\s+(\d+)\s*:\s*/#
        var ranges: [(speaker: String, range: Range<String.Index>)] = []
        for match in text.matches(of: pattern) {
            let spk = "SPEAKER_" + String(format: "%02d", Int(match.output.1) ?? 0)
            ranges.append((spk, match.range))
        }
        if ranges.isEmpty {
            return [RawSegment(startSeconds: chunkStart, endSeconds: chunkEnd, text: text)]
        }

        var out: [RawSegment] = []
        let totalChars = text.count
        for i in 0 ..< ranges.count {
            let segStart = ranges[i].range.upperBound
            let segEnd = i + 1 < ranges.count ? ranges[i + 1].range.lowerBound : text.endIndex
            let body = String(text[segStart ..< segEnd]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !body.isEmpty else { continue }
            let startFrac = Double(text.distance(from: text.startIndex, to: segStart)) / Double(totalChars)
            let endFrac = Double(text.distance(from: text.startIndex, to: segEnd)) / Double(totalChars)
            out.append(RawSegment(
                startSeconds: chunkStart + startFrac * duration,
                endSeconds: chunkStart + endFrac * duration,
                text: body,
                speakerKey: ranges[i].speaker
            ))
        }
        return out
    }

    /// Token-level Dice ≥ 0.85 on normalized words — flags echoed/looped
    /// lines that differ by a word or two.
    /// Remove sentences from `text` that fuzzily appear in `reference`
    /// (echo of the other side, transcribed twice from two tracks). The
    /// echoed copy is acoustically degraded, so the match is lenient.
    static func scrubEchoSentences(from text: String, against reference: String) -> String {
        func sentences(_ t: String) -> [String] {
            var out: [String] = []
            var cur = ""
            for ch in t {
                cur.append(ch)
                if ".!?…".contains(ch) {
                    let s = cur.trimmingCharacters(in: .whitespaces)
                    if !s.isEmpty { out.append(s) }
                    cur = ""
                }
            }
            let tail = cur.trimmingCharacters(in: .whitespaces)
            if !tail.isEmpty { out.append(tail) }
            return out
        }
        func toks(_ t: String) -> Set<String> {
            Set(t.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init))
        }
        let refSentences = sentences(reference).map { ($0, toks($0)) }
        let kept = sentences(text).filter { sent in
            let st = toks(sent)
            guard st.count >= 4 else { return true }   // short bits stay — too ambiguous
            let echoed = refSentences.contains { _, rt in
                guard !rt.isEmpty else { return false }
                let inter = Double(st.intersection(rt).count)
                let dice = 2 * inter / Double(st.count + rt.count)
                return dice >= 0.55
            }
            return !echoed
        }
        return kept.joined(separator: " ")
    }

    static func nearDuplicate(_ a: String, _ b: String) -> Bool {
        func toks(_ s: String) -> [String] {
            s.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
        }
        let ta = toks(a), tb = toks(b)
        guard ta.count >= 3, tb.count >= 3 else { return false }
        var counts: [String: Int] = [:]
        for t in ta { counts[t, default: 0] += 1 }
        var common = 0
        for t in tb where (counts[t] ?? 0) > 0 { counts[t]! -= 1; common += 1 }
        return 2.0 * Double(common) / Double(ta.count + tb.count) >= 0.85
    }

    private func formatTime(_ s: Double) -> String {
        let total = Int(s)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
