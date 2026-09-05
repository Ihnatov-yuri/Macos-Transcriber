import Foundation
import Observation
import SwiftData

/// First-wins claim for the generation timeout race (file scope because
/// Swift forbids type declarations inside generic functions).
private final class PostProcTimeoutClaim: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false
    func take() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if claimed { return false }
        claimed = true
        return true
    }
}

/// Mirror of `asr/PostProcessor.kt`.
///
/// Runs a preset template (Summary / Clean / Translate-Polish / Context-rewrite,
/// or any user-edited preset) against a backend's `generateText(...)` and
/// persists the result as an `OutputDoc`.
@Observable
final class PostProcessor: @unchecked Sendable {
    enum Status: Sendable, Equatable {
        case idle, queued, loading, running, done, failed(String)
    }

    private(set) var status: [String: Status] = [:]   // key = recordingId|presetId

    /// FIFO tail: generations run strictly one at a time. The LiteRT engine
    /// is a single shared resource — two concurrent generateText calls
    /// starve each other (seen live: a parallel CLEAN returned 0 chars).
    @MainActor private var queueTail: Task<Void, Never>?

    private let factory: BackendFactory
    private let prompts: PromptStore
    private let presets: PresetStore
    private let snippets: SnippetStore

    init(
        factory: BackendFactory,
        prompts: PromptStore,
        presets: PresetStore,
        snippets: SnippetStore
    ) {
        self.factory = factory
        self.prompts = prompts
        self.presets = presets
        self.snippets = snippets
    }

    @MainActor
    func run(
        presetId: String,
        recording: Recording,
        backend rawKind: BackendFactory.Kind,
        modelDirectory: URL? = nil
    ) async {
        // Presets are TEXT generation. If the caller hands us a speech-only
        // backend (Parakeet/Whisper), route to the user's configured text
        // engine (Settings → Engines → Post-processing).
        let configured = UserDefaults.standard.string(forKey: "ui.textEngine")
            .flatMap(BackendFactory.Kind.init(rawValue:))
            .flatMap { $0.supportsTextGeneration ? $0 : nil } ?? .gemmaLiteRT
        let kind: BackendFactory.Kind = rawKind.supportsTextGeneration ? rawKind : configured
        let key = "\(recording.id)|\(presetId)"
        // Gemma text generation on a long transcript takes minutes. Repeated
        // GENERATE presses were queueing extra multi-minute runs behind the
        // first on the same actor — swallow duplicates while one is in flight.
        if [.queued, .loading, .running].contains(status[key] ?? .idle) {
            AppLog.info("postproc", "preset=\(presetId) already queued/in flight — ignoring duplicate request")
            return
        }
        guard let preset = presets.preset(presetId) else {
            await setStatus(key, .failed("Unknown preset \(presetId)"))
            AppLog.error("postproc", "unknown preset \(presetId)")
            return
        }
        if kind == .gemmaLiteRT,
           !ModelCatalog.entries.contains(where: {
               $0.backend == .gemmaLiteRT
                   && ModelCatalog.cachedRepoDirectory(huggingFaceID: $0.huggingFaceID) != nil
           }) {
            await setStatus(key, .failed("LiteRT Gemma model not downloaded — Settings → Models."))
            return
        }
        // Enqueue behind whatever is already generating and return — the
        // button press must not block the UI for the whole queue.
        setStatus(key, .queued)
        AppLog.info("postproc", "queued preset=\(presetId) backend=\(kind.rawValue)")
        let prior = queueTail
        queueTail = Task { @MainActor [weak self] in
            await prior?.value
            await self?.perform(preset: preset, recording: recording, kind: kind,
                                modelDirectory: modelDirectory, key: key)
        }
        return
    }

    @MainActor
    private func perform(
        preset: PostProcessingPreset,
        recording: Recording,
        kind: BackendFactory.Kind,
        modelDirectory: URL?,
        key: String
    ) async {
        let presetId = preset.id
        guard recording.modelContext != nil else {
            setStatus(key, .failed("Recording was deleted."))
            return
        }
        setStatus(key, .loading)
        AppLog.info("postproc", "run preset=\(presetId) backend=\(kind.rawValue)")

        // Build templates. Stutters and hesitation fillers are collapsed
        // deterministically BEFORE the model sees the text — small local
        // models cannot reliably strip "for for for for" from a 27-minute
        // transcript no matter what the prompt says, and the shorter input
        // also cuts generation time.
        let rawTranscript = recording.segments
            .sorted { $0.startSeconds < $1.startSeconds }
            .map(\.text)
            .joined(separator: "\n")
        let transcript = TextDestutter.collapse(rawTranscript)
        let transcriptWithSpeakers = TextDestutter.collapse(
            recording.segments
                .sorted { $0.startSeconds < $1.startSeconds }
                .map { seg in
                    let name = seg.speakerName ?? seg.speaker ?? ""
                    return name.isEmpty ? seg.text : "\(name): \(seg.text)"
                }
                .joined(separator: "\n")
        )

        // Guard: presets on an empty/near-empty transcript produce garbage
        // ("please provide the transcript…"). Fail fast instead. Measured on
        // the RAW text so a short-but-real recording isn't misreported as
        // empty just because destutter shrank it.
        guard rawTranscript.count >= 40 else {
            await setStatus(key, .failed("Transcript is empty — run transcription first."))
            AppLog.warn("postproc", "preset=\(presetId) skipped: transcript only \(transcript.count) chars")
            return
        }

        // User vocabulary: exact spellings for names/terms — lets CLEAN and
        // CONTEXT-REWRITE fix entity mishearings with confidence instead of
        // leaving them ("only correct when certain" is satisfiable now).
        let runLangs = Set((recording.runLanguages ?? "").split(separator: ",").map(String.init))
        let vocab = prompts.vocabulary(for: runLangs).trimmingCharacters(in: .whitespacesAndNewlines)
        let vocabPrefix = vocab.isEmpty ? ""
            : "Vocabulary (authoritative spellings — use these exact forms wherever the transcript garbles them): \(vocab.prefix(800))\n\n"
        let system = snippets.substitute(preset.systemTemplate)

        // Rewrite-style presets must reproduce the WHOLE transcript. A small
        // local model cannot faithfully copy 20k+ chars in one generation —
        // attention drifts, words drop, endings turn telegraphic. So they run
        // CHUNKED: one speaker-turn window at a time, each with the tail of
        // the already-processed text as history. Summaries stay single-shot.
        let rewritePresets: Set<String> = ["clean", "context_rewrite", "translate_polish"]

        do {
            setStatus(key, .running)
            let backend = factory.backend(for: kind)
            if await !backend.isReady {
                // Bounded: a wedged load would otherwise block the FIFO
                // forever and pin every queued preset at QUEUED.
                try await Self.withTimeout(seconds: 180) {
                    try await backend.load(modelPath: modelDirectory)
                }
            }
            let markdown: String
            if rewritePresets.contains(presetId) {
                markdown = try await runChunked(
                    preset: preset,
                    backend: backend,
                    system: system,
                    vocabPrefix: vocabPrefix,
                    transcriptWithSpeakers: transcriptWithSpeakers,
                    transcript: transcript
                )
            } else {
                var user = preset.userTemplate
                    .replacingOccurrences(of: "{transcript_with_speakers}", with: transcriptWithSpeakers)
                    .replacingOccurrences(of: "{transcript}", with: transcript)
                user = vocabPrefix + snippets.substitute(user)
                let maxTokens = 1500
                let timeout: TimeInterval = max(360, Double(maxTokens) / 4.0 + 120)
                AppLog.info("postproc", "preset=\(presetId) single-shot (user=\(user.count)ch maxTokens=\(maxTokens) timeout=\(Int(timeout))s)")
                markdown = try await Self.withTimeout(seconds: timeout) {
                    try await backend.generateText(
                        systemInstruction: system,
                        userMessage: user,
                        maxTokens: maxTokens
                    )
                }
            }
            // An empty/token generation must never replace a stored output —
            // seen live: a wedged long-context run returned "" and silently
            // wiped the previous CLEAN document.
            let trimmed = markdown.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.count >= 40 else {
                throw NSError(
                    domain: "PostProcessor", code: -2,
                    userInfo: [NSLocalizedDescriptionKey:
                        "Model returned \(trimmed.count) chars — kept the previous output. Try again."]
                )
            }
            try persist(markdown: markdown, preset: preset, recording: recording)
            AppLog.info("postproc", "preset=\(presetId) done (\(markdown.count) chars)")
            await setStatus(key, .done)
        } catch {
            AppLog.error("postproc", "preset=\(presetId) failed: \(error.localizedDescription)")
            await setStatus(key, .failed(error.localizedDescription))
        }
    }

    /// Chunked rewrite: split into speaker-turn windows, process each with
    /// the tail of the ALREADY-PROCESSED output as history ("a step before"),
    /// stitch the results. Short spans are where a small model is faithful;
    /// history keeps names, spellings, and sentence flow continuous across
    /// window boundaries. A dud window falls back to its (already
    /// destuttered) source text so content is never lost.
    private static let chunkMaxChars = 2600
    private static let historyTailChars = 400

    @MainActor
    private func runChunked(
        preset: PostProcessingPreset,
        backend: any ASRBackend,
        system: String,
        vocabPrefix: String,
        transcriptWithSpeakers: String,
        transcript: String
    ) async throws -> String {
        let source = preset.userTemplate.contains("{transcript_with_speakers}")
            ? transcriptWithSpeakers : transcript
        let windows = Self.windows(source, maxChars: Self.chunkMaxChars)
        guard !windows.isEmpty else {
            throw NSError(
                domain: "PostProcessor", code: -4,
                userInfo: [NSLocalizedDescriptionKey:
                    "No speech content left after cleanup — nothing to rewrite."]
            )
        }
        var stitched: [String] = []
        var failures = 0
        for (i, w) in windows.enumerated() {
            var user = preset.userTemplate
                .replacingOccurrences(of: "{transcript_with_speakers}", with: w)
                .replacingOccurrences(of: "{transcript}", with: w)
            user = snippets.substitute(user)
            if let prev = stitched.last {
                let tail = String(prev.suffix(Self.historyTailChars))
                user = """
                CONTEXT — the already-processed text immediately before this \
                part. Use it only for continuity (names, spellings, sentence \
                flow); do NOT repeat or re-output any of it:
                «\(tail)»

                """ + user
            }
            user = vocabPrefix + user
            let maxTokens = min(2500, max(600, w.count * 125 / 300 + 200))
            let timeout: TimeInterval = max(180, Double(maxTokens) / 4.0 + 90)
            AppLog.info("postproc", "preset=\(preset.id) chunk \(i + 1)/\(windows.count) (\(w.count)ch maxTokens=\(maxTokens))")
            do {
                let out = try await Self.withTimeout(seconds: timeout) {
                    try await backend.generateText(
                        systemInstruction: system,
                        userMessage: user,
                        maxTokens: maxTokens
                    )
                }
                let trimmed = out.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.count >= max(40, w.count / 10) {
                    stitched.append(trimmed)
                } else {
                    AppLog.warn("postproc", "chunk \(i + 1)/\(windows.count) returned \(trimmed.count)ch — keeping source text for this span")
                    stitched.append(w)
                    failures += 1
                }
            } catch ASRError.chunkTimeout {
                // A timed-out native generation keeps running (inference does
                // not observe Swift cancellation) — continuing would starve
                // every following chunk against it. Abort the whole run.
                AppLog.error("postproc", "chunk \(i + 1)/\(windows.count) timed out — aborting run (engine busy/wedged)")
                throw ASRError.chunkTimeout
            } catch {
                AppLog.warn("postproc", "chunk \(i + 1)/\(windows.count) failed (\(error.localizedDescription)) — keeping source text for this span")
                stitched.append(w)
                failures += 1
            }
        }
        guard failures < windows.count else {
            throw NSError(
                domain: "PostProcessor", code: -3,
                userInfo: [NSLocalizedDescriptionKey: "All \(windows.count) chunks failed — engine wedged?"]
            )
        }
        return stitched.joined(separator: "\n")
    }

    /// Pack speaker-turn lines into ≤ maxChars windows without splitting a
    /// turn; a single oversized turn is split at sentence boundaries.
    static func windows(_ text: String, maxChars: Int) -> [String] {
        var pieces: [String] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            if line.count <= maxChars { pieces.append(String(line)); continue }
            var current = ""
            for s in line.split(separator: ". ", omittingEmptySubsequences: true) {
                let str = String(s)
                let sentence = (str.hasSuffix(".") || str.hasSuffix("?") || str.hasSuffix("!") || str.hasSuffix("…"))
                    ? str : str + "."
                if current.count + sentence.count + 1 > maxChars, !current.isEmpty {
                    pieces.append(current); current = ""
                }
                current += (current.isEmpty ? "" : " ") + sentence
            }
            if !current.isEmpty { pieces.append(current) }
        }
        // Safety: a piece with no sentence punctuation at all (unpunctuated
        // ASR output, CJK text) can still exceed maxChars — hard-split at
        // whitespace so no window ever overruns the model's budget.
        pieces = pieces.flatMap { piece -> [String] in
            guard piece.count > maxChars else { return [piece] }
            var out: [String] = []
            var cur = ""
            for word in piece.split(separator: " ", omittingEmptySubsequences: true) {
                if cur.count + word.count + 1 > maxChars, !cur.isEmpty {
                    out.append(cur); cur = ""
                }
                cur += (cur.isEmpty ? "" : " ") + word
            }
            if !cur.isEmpty { out.append(cur) }
            return out
        }
        var windows: [String] = []
        var cur = ""
        for p in pieces {
            if cur.count + p.count + 1 > maxChars, !cur.isEmpty {
                windows.append(cur); cur = ""
            }
            cur += (cur.isEmpty ? "" : "\n") + p
        }
        if !cur.isEmpty { windows.append(cur) }
        return windows
    }

    /// All status mutations hop to the main actor — the dictionary drives
    /// SwiftUI, and off-main writes to an @Observable are unreliable (and
    /// racy) for view updates.
    @MainActor
    private func setStatus(_ key: String, _ value: Status) {
        status[key] = value
    }

    /// Wall-clock guard so a wedged MLX generation can't hang a preset
    /// forever (first-wins race; the loser's resume attempt is dropped).
    private static func withTimeout<T: Sendable>(
        seconds: TimeInterval,
        _ op: @Sendable @escaping () async throws -> T
    ) async throws -> T {
        let claim = PostProcTimeoutClaim()
        return try await withCheckedThrowingContinuation { cont in
            let work = Task.detached(priority: .userInitiated) {
                do {
                    let v = try await op()
                    if claim.take() { cont.resume(returning: v) }
                } catch {
                    if claim.take() { cont.resume(throwing: error) }
                }
            }
            Task.detached(priority: .utility) {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                if claim.take() {
                    work.cancel()
                    cont.resume(throwing: ASRError.chunkTimeout)
                }
            }
        }
    }

    /// Replace any existing OutputDoc for this preset and persist via the
    /// recording's SwiftData context.
    private func persist(
        markdown: String,
        preset: PostProcessingPreset,
        recording: Recording
    ) throws {
        guard let ctx = recording.modelContext else {
            // No context — recording must have been deleted underneath us.
            throw NSError(
                domain: "PostProcessor",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Recording is no longer attached to a SwiftData context."]
            )
        }

        // Delete any existing output for this preset (from the context, not
        // just the relationship array — the array filter doesn't propagate
        // a context delete on its own).
        let staleDocs = recording.outputs.filter { $0.presetId == preset.id }
        for doc in staleDocs {
            ctx.delete(doc)
        }
        // Defensive: drop them from the in-memory relationship as well so the
        // immediate next read sees a clean slate.
        recording.outputs.removeAll { $0.presetId == preset.id }

        let doc = OutputDoc(
            presetId: preset.id,
            title: preset.outputTitle,
            markdown: markdown
        )
        doc.recording = recording
        ctx.insert(doc)
        recording.outputs.append(doc)
        try ctx.save()
        // The file-based shadow copy. This is the ONLY production path that
        // writes an OutputDoc (RecordingRepository.replaceOutput is the
        // tested twin nobody calls), so without this line generated
        // summaries/minutes never reached ~/Documents/Transcriberr Backups
        // — restore-backups had nothing to restore for them.
        BackupService.backupOutput(doc, recordingId: recording.id)
    }
}
