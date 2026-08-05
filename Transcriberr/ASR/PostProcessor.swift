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
        case idle, loading, running, done, failed(String)
    }

    private(set) var status: [String: Status] = [:]   // key = recordingId|presetId

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
        if status[key] == .loading || status[key] == .running {
            AppLog.info("postproc", "preset=\(presetId) already in flight — ignoring duplicate request")
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
        await setStatus(key, .loading)
        AppLog.info("postproc", "run preset=\(presetId) backend=\(kind.rawValue)")

        // Build templates. Stutters and hesitation fillers are collapsed
        // deterministically BEFORE the model sees the text — small local
        // models cannot reliably strip "for for for for" from a 27-minute
        // transcript no matter what the prompt says, and the shorter input
        // also cuts generation time.
        let transcript = TextDestutter.collapse(
            recording.segments
                .sorted { $0.startSeconds < $1.startSeconds }
                .map(\.text)
                .joined(separator: "\n")
        )
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
        // ("please provide the transcript…"). Fail fast instead.
        guard transcript.count >= 40 else {
            await setStatus(key, .failed("Transcript is empty — run transcription first."))
            AppLog.warn("postproc", "preset=\(presetId) skipped: transcript only \(transcript.count) chars")
            return
        }

        var user = preset.userTemplate
            .replacingOccurrences(of: "{transcript_with_speakers}", with: transcriptWithSpeakers)
            .replacingOccurrences(of: "{transcript}", with: transcript)
        user = snippets.substitute(user)
        // User vocabulary: exact spellings for names/terms — lets CLEAN and
        // CONTEXT-REWRITE fix entity mishearings with confidence instead of
        // leaving them ("only correct when certain" is satisfiable now).
        let runLangs = Set((recording.runLanguages ?? "").split(separator: ",").map(String.init))
        let vocab = prompts.vocabulary(for: runLangs).trimmingCharacters(in: .whitespacesAndNewlines)
        if !vocab.isEmpty {
            user = "Vocabulary (authoritative spellings — use these exact forms wherever the transcript garbles them): \(vocab.prefix(800))\n\n" + user
        }
        let system = snippets.substitute(preset.systemTemplate)

        // Token budget. Rewrite-style presets must reproduce the WHOLE
        // transcript — a flat cap truncates long recordings (a 21k-char
        // transcript was getting chopped at ~6k chars). Scale with input for
        // those; summaries stay bounded.
        let rewritePresets: Set<String> = ["clean", "context_rewrite", "translate_polish"]
        let maxTokens: Int
        if rewritePresets.contains(presetId) {
            maxTokens = min(8000, max(1000, Int(Double(user.count) * 1.25 / 3)))
        } else {
            maxTokens = 1500
        }
        // Local generation runs ~5–10 tok/s — give long rewrites the time
        // they actually need before calling them wedged.
        let timeout: TimeInterval = max(360, Double(maxTokens) / 4.0 + 120)

        do {
            await setStatus(key, .running)
            let backend = factory.backend(for: kind)
            if await !backend.isReady {
                try await backend.load(modelPath: modelDirectory)
            }
            AppLog.info("postproc", "preset=\(presetId) generating (system=\(system.count)ch user=\(user.count)ch maxTokens=\(maxTokens) timeout=\(Int(timeout))s) — long transcripts take minutes")
            let markdown = try await Self.withTimeout(seconds: timeout) {
                try await backend.generateText(
                    systemInstruction: system,
                    userMessage: user,
                    maxTokens: maxTokens
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
    }
}
