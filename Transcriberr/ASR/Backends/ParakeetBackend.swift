import Foundation
import FluidAudio

/// Real speech-to-text backend: NVIDIA Parakeet TDT 0.6B v3 running on the
/// Apple Neural Engine via FluidAudio's CoreML port.
///
/// Why this exists: Gemma 4's audio tower (E2B/E4B via MLX) demonstrably
/// hallucinates — on clean TTS audio the reference `gemma4-cli` produced
/// invented text ("The dog runs, the dog jumps…"), and on real recordings it
/// fabricated entire conversations. Parakeet is a *dedicated* ASR model:
/// ~100× realtime on ANE, state-of-the-art English WER, 25 European
/// languages (incl. Dutch + Ukrainian), automatic punctuation + capitals.
///
/// Division of labor: Parakeet produces the transcript; Gemma handles all
/// text work (summaries, cleanup, translation, rewrite, titles).
///
/// Models (~1 GB) auto-download from HuggingFace on first `load()` and are
/// cached in Application Support — `modelPath` is ignored.
actor ParakeetBackend: ASRBackend, DetailedTranscribing {
    nonisolated let id: String
    private(set) var isReady = false

    /// v3 = multilingual (25 European languages). v2 = English-specialist
    /// with different weights and the best English WER — a genuinely
    /// distinct second engine for the local dual-ASR ensemble.
    private let version: AsrModelVersion
    private var manager: AsrManager?

    init(version: AsrModelVersion = .v3) {
        self.version = version
        self.id = version == .v2 ? "parakeet-v2" : "parakeet-v3"
    }

    // MARK: - Lifecycle

    func load(modelPath: URL?) async throws {
        if isReady, manager != nil { return }
        AppLog.info("parakeet", "loading Parakeet \(version == .v2 ? "v2" : "v3") models (downloads ~1 GB on first run)…")
        do {
            var lastLoggedPct = -1
            let models = try await AsrModels.downloadAndLoad(version: version) { progress in
                let pct = Int(progress.fractionCompleted * 100)
                if pct / 10 != lastLoggedPct / 10 {   // log every 10%
                    lastLoggedPct = pct
                    AppLog.info("parakeet", "model download/load \(pct)%")
                }
            }
            let mgr = AsrManager(config: .default)
            try await mgr.loadModels(models)
            self.manager = mgr
            self.isReady = true
            AppLog.info("parakeet", "ready")
        } catch {
            AppLog.error("parakeet", "load failed: \(error.localizedDescription)")
            throw ASRError.modelLoadFailed(reason: String(describing: error))
        }
    }

    func release() async {
        if let manager { await manager.cleanup() }
        manager = nil
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
        guard isReady, let manager else {
            throw ASRError.modelLoadFailed(reason: "Parakeet backend not loaded")
        }
        // Parakeet needs a minimum window; sub-second scraps produce garbage
        // or throw. Treat them as silence.
        guard samples.count >= 8_000 else { return "" }   // < 0.5 s @ 16 kHz

        // `previousContext` and `translateTo` are prompt-level concepts for
        // LLM backends — Parakeet transcribes verbatim (translation happens
        // in post-processing via Gemma).
        var state = try TdtDecoderState()
        // Serialized against a live LiteRT engine (see InferenceGate);
        // pass-through otherwise.
        let gateStamp = await InferenceGate.shared.acquire()
        defer { Task { await InferenceGate.shared.release(gateStamp) } }
        let result = try await manager.transcribe(
            samples,
            decoderState: &state,
            language: Self.languageHint(from: languages)
        )
        AppLog.info("parakeet", String(
            format: "chunk %.1fs → %d chars (conf %.2f, %.2fs compute)",
            Double(samples.count) / 16_000.0,
            result.text.count, result.confidence, result.processingTime
        ))

        // Diarization: unlike LLM backends, Parakeet can't be *prompted* to
        // label speakers — but it returns per-token timestamps, and the
        // runner hands us the diarizer's speaker regions as `speakerHints`
        // (chunk-relative times). Intersect the two and emit the same
        // "Speaker N: …" line format Gemma produced, so the runner's
        // existing parsing/persistence path works unchanged — with
        // word-level turn boundaries instead of prompt guesses.
        if diarize, !speakerHints.isEmpty,
           let timings = result.tokenTimings, !timings.isEmpty {
            let labeled = Self.labelSpeakers(timings: timings, hints: speakerHints)
            if !labeled.isEmpty { return labeled }
        }
        return result.text
    }

    /// Assign each token to the speaker-hint region containing its midpoint
    /// (nearest region when it falls in a gap), then group consecutive
    /// same-speaker tokens into "Speaker N: …" lines.
    static func labelSpeakers(timings: [TokenTiming], hints: [SpeakerHint]) -> String {
        func speakerNumber(_ key: String) -> Int {
            // "SPEAKER_03" → 3; anything unparseable gets a stable fallback.
            if let n = key.split(separator: "_").last.flatMap({ Int($0) }) { return n }
            return abs(key.hashValue % 90) + 10
        }
        func speakerFor(mid: TimeInterval) -> Int {
            var bestKey: String?
            var bestDistance = Double.greatestFiniteMagnitude
            for h in hints {
                if mid >= h.startSeconds && mid <= h.endSeconds { return speakerNumber(h.speakerKey) }
                let d = mid < h.startSeconds ? h.startSeconds - mid : mid - h.endSeconds
                if d < bestDistance { bestDistance = d; bestKey = h.speakerKey }
            }
            return bestKey.map(speakerNumber) ?? 0
        }

        var lines: [(speaker: Int, pieces: [String])] = []
        for t in timings {
            // Punctuation-only tokens sit right on region boundaries and get
            // misassigned to the NEXT speaker (". That is great…"). They
            // belong to whoever just spoke — glue them to the current line.
            let bare = t.token.replacingOccurrences(of: "▁", with: "")
            let isPunctuationOnly = !bare.isEmpty
                && bare.allSatisfy { $0.isPunctuation || $0.isSymbol }
            let spk: Int
            if isPunctuationOnly, let last = lines.last {
                spk = last.speaker
            } else {
                spk = speakerFor(mid: (t.startTime + t.endTime) / 2)
            }
            if var last = lines.last, last.speaker == spk {
                last.pieces.append(t.token)
                lines[lines.count - 1] = last
            } else {
                lines.append((spk, [t.token]))
            }
        }
        return lines.compactMap { line in
            // SentencePiece pieces mark word starts with "▁" — join then
            // convert to spaces.
            let text = line.pieces.joined()
                .replacingOccurrences(of: "▁", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return "Speaker \(line.speaker): \(text)"
        }.joined(separator: "\n")
    }

    // MARK: - Detailed output (for the ensemble's word-level merge)

    /// Like `transcribeChunk`, but keeps per-word confidences so the
    /// ensemble can merge two engines' outputs by confidence voting (ROVER)
    /// on the CPU instead of a slow LLM call.
    func transcribeDetailed(
        samples: [Float],
        languages: Set<String>
    ) async throws -> DetailedTranscription {
        guard isReady, let manager else {
            throw ASRError.modelLoadFailed(reason: "Parakeet backend not loaded")
        }
        guard samples.count >= 8_000 else { return DetailedTranscription(text: "", words: []) }
        var state = try TdtDecoderState()
        // Serialized against a live LiteRT engine (see InferenceGate);
        // pass-through otherwise.
        let gateStamp = await InferenceGate.shared.acquire()
        defer { Task { await InferenceGate.shared.release(gateStamp) } }
        let result = try await manager.transcribe(
            samples,
            decoderState: &state,
            language: Self.languageHint(from: languages)
        )
        let words = Self.scoredWords(from: result.tokenTimings ?? [])
        if words.isEmpty && !result.text.isEmpty {
            AppLog.warn("parakeet", "no token timings for \(String(format: "%.1f", Double(samples.count) / 16_000))s chunk — ensemble falls back to text-level gate")
        }
        // Marker-independent fallback: some FluidAudio paths return token
        // timings WITHOUT SentencePiece "▁" markers, collapsing the grouping
        // into one giant pseudo-word — which zeroed the ensemble's agreement
        // score and escalated every chunk to LLM arbitration. When that
        // happens, derive words from the (properly spaced) result text with
        // the chunk-level confidence.
        if words.count <= 1, result.text.split(separator: " ").count > 3 {
            let fallback = result.text.split(whereSeparator: { $0.isWhitespace }).map { w in
                ScoredWord(
                    surface: String(w),
                    norm: w.lowercased().filter { $0.isLetter || $0.isNumber },
                    // Capped below typical per-word confidences so an engine
                    // with REAL word-level scores (Whisper) can win specific
                    // rare terms without steamrolling the whole chunk.
                    // Chunk-level confidence as-is: Parakeet calibrates it,
                    // and the old 0.88 cap systematically handicapped
                    // Parakeet in every ROVER vote against Whisper's
                    // calibrated word probabilities.
                    confidence: result.confidence
                )
            }
            if let sample = result.tokenTimings?.prefix(5).map(\.token) {
                AppLog.warn("parakeet", "token timings lacked word markers — text-derived words at chunk confidence \(String(format: "%.2f", result.confidence)); raw tokens: \(sample)")
            }
            return DetailedTranscription(text: result.text, words: fallback)
        }
        return DetailedTranscription(text: result.text, words: words)
    }

    /// Group SentencePiece tokens ("▁" marks a word start) into words,
    /// carrying the weakest piece's confidence as the word's confidence.
    static func scoredWords(from timings: [TokenTiming]) -> [ScoredWord] {
        var out: [ScoredWord] = []
        for t in timings {
            let isWordStart = t.token.hasPrefix("▁") || t.token.hasPrefix(" ")
            // Strip the word-start marker in BOTH spellings: some decoder
            // paths emit a literal leading space instead of "▁", and leaving
            // it in the surface produced double spaces in the merged text.
            let piece = t.token
                .replacingOccurrences(of: "▁", with: "")
                .trimmingCharacters(in: .whitespaces)
            guard !piece.isEmpty else { continue }
            if isWordStart || out.isEmpty {
                out.append(ScoredWord(surface: piece, norm: "", confidence: t.confidence))
            } else {
                out[out.count - 1].surface += piece
                out[out.count - 1].confidence = min(out[out.count - 1].confidence, t.confidence)
            }
        }
        for i in out.indices {
            out[i].norm = out[i].surface.lowercased().filter { $0.isLetter || $0.isNumber }
        }
        return out
    }

    // MARK: - Text generation (not supported — Gemma's job)

    func generateText(
        systemInstruction: String,
        userMessage: String,
        maxTokens: Int
    ) async throws -> String {
        throw ASRError.backendUnavailable(
            reason: "Parakeet is speech-to-text only. Text generation uses Gemma 4."
        )
    }

    // MARK: - Helpers

    /// Map the app's language names ("English", "Dutch", …) onto FluidAudio's
    /// v3 language hints. Unknown / empty → nil (auto).
    static func languageHint(from languages: Set<String>) -> Language? {
        guard languages.count == 1, let name = languages.first else { return nil }
        switch name.lowercased() {
        case "english":   return .english
        case "dutch":     return Language(rawValue: "nl")
        case "ukrainian": return .ukrainian
        case "spanish":   return .spanish
        case "french":    return .french
        case "german":    return .german
        case "italian":   return .italian
        case "portuguese": return .portuguese
        case "polish":    return .polish
        default:          return nil
        }
    }
}
