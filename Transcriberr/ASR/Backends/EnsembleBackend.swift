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

    init(factory: BackendFactory) {
        self.factory = factory
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
        let a = Self.storedKind("ensemble.engineA", fallback: .parakeet)
        let b = Self.storedKind("ensemble.engineB", fallback: .parakeetV2)
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

        let ea = factory.backend(for: a)
        try await ea.load(modelPath: nil)
        let eb = factory.backend(for: b)
        try await eb.load(modelPath: nil)
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
        arbiter = await arb.isReady ? arb : nil
        if arbiter == nil {
            AppLog.warn("ensemble", "Gemma arbiter unavailable — merge falls back to engine A output")
        }
        gemmaBenched = false
        isReady = true
    }

    /// A wedged chunk means (in practice) the LiteRT sub-engine hung —
    /// recover the sub-engines individually instead of releasing the whole
    /// ensemble under concurrently running chunks.
    func recoverWedge(modelPath: URL?) async throws {
        if let g = engineA as? GemmaLiteRTBackend { try await g.recoverWedge(modelPath: nil) }
        if let g = engineB as? GemmaLiteRTBackend { try await g.recoverWedge(modelPath: nil) }
        if let g = arbiter as? GemmaLiteRTBackend { try await g.recoverWedge(modelPath: nil) }
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
            if let a = try? await taskA, let b = try? await taskB {
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
    func transcribeChunkRich(
        samples: [Float],
        languages: Set<String>
    ) async throws -> RichChunk {
        guard isReady, let engineA, let engineB else {
            throw ASRError.modelLoadFailed(reason: "Ensemble backend not loaded")
        }
        if gemmaBenched {
            return try await transcribeChunkSolo(samples: samples, languages: languages)
        }
        if let pa = engineA as? DetailedTranscribing, let pb = engineB as? DetailedTranscribing {
            async let taskA = pa.transcribeDetailed(samples: samples, languages: languages)
            async let taskB = pb.transcribeDetailed(samples: samples, languages: languages)
            if let a = try? await taskA, let b = try? await taskB {
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
                    ? Self.roverMerge(a.words, b.words, priorA: priorA, priorB: priorB)
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
        if textA.isEmpty { return RichChunk(text: textB, agreement: 1, textA: textA, textB: textB) }
        if textB.isEmpty { return RichChunk(text: textA, agreement: 1, textA: textA, textB: textB) }
        let preferA = Self.votePrior(for: kindA, languages: languages)
            >= Self.votePrior(for: kindB, languages: languages)
        return RichChunk(
            text: preferA ? textA : textB,
            agreement: Self.tokenSimilarity(textA, textB),
            textA: textA, textB: textB)
    }

    /// Single-engine escape hatch: a chunk whose audio wedges LiteRT twice
    /// still gets transcribed by the healthy engine instead of being lost.
    func transcribeChunkSolo(
        samples: [Float],
        languages: Set<String>
    ) async throws -> RichChunk {
        guard isReady, let solo = soloEngine else {
            throw ASRError.modelLoadFailed(reason: "Ensemble backend not loaded")
        }
        let text: String
        if let d = solo as? DetailedTranscribing {
            text = try await d.transcribeDetailed(samples: samples, languages: languages).text
        } else {
            text = try await solo.transcribeChunk(
                samples: samples, languages: languages, translateTo: nil,
                diarize: false, previousContext: nil, speakerHints: [])
        }
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return RichChunk(text: t, agreement: 1, textA: t, textB: "")
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
        let merged = Self.roverMerge(a.words, b.words, priorA: priorA, priorB: priorB)
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
        priorB: Float = 1
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
        var reversed: [String] = []
        while i > 0 || j > 0 {
            if i > 0, j > 0,
               dp[i][j] == dp[i-1][j-1] + (a[i-1].norm == b[j-1].norm ? 0 : 1)
            {
                // Match or substitution → higher prior-weighted confidence wins.
                reversed.append(a[i-1].confidence * priorA >= b[j-1].confidence * priorB
                                ? a[i-1].surface : b[j-1].surface)
                i -= 1; j -= 1
            } else if i > 0, dp[i][j] == dp[i-1][j] + 1 {
                if a[i-1].confidence >= insertionFloor { reversed.append(a[i-1].surface) }
                i -= 1
            } else {
                if b[j-1].confidence >= insertionFloor { reversed.append(b[j-1].surface) }
                j -= 1
            }
        }
        return joinSurfaces(reversed.reversed())
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
            } else if let first = w.first, "'’ʼ‘".contains(first), w.count > 1,
                      let last = out.last, last.isLetter {
                out += w
            } else {
                out += " " + w
            }
        }
        return out
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
        guard let arbiter else { return textA }
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
                Output ONLY the merged transcript text.
                """,
                userMessage: vocabBlock + contextBlock + """
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
            return cleaned.isEmpty ? textA : cleaned
        } catch {
            AppLog.warn("ensemble", "arbiter merge failed (\(error.localizedDescription)) — using engine A")
            return textA
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
