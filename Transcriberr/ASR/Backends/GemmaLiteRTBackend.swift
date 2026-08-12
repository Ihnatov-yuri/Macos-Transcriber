import Foundation
import LiteRTLM

/// Gemma 4 via **LiteRT-LM** — Google's own runtime, the same engine and the
/// same Google-made `.litertlm` model bundles that power the Android
/// Transcriber app, where Gemma audio demonstrably works well.
///
/// Direct Swift port of Android's `Gemma4Backend.kt`. Why this exists when
/// the app already has a Gemma MLX backend: the community MLX quantizations
/// are broken for audio (8-bit hallucinates; 4-bit/bf16 don't load in the
/// Swift MLX port), while Google's LiteRT bundles are quantized BY Google
/// WITH the audio tower validated. Same model, working runtime.
///
/// Key Android learnings carried over:
///   - the audio encoder must run on CPU (`audioBackend: .cpu`) even when
///     text decode is on GPU — the .litertlm bundles constrain it
///   - Google's exact "Transcribe … in {L} into {L} text" template, language
///     named twice, anchored in the USER message next to the audio
///   - temperature 0.1 / topK 1 for ASR
///   - preamble stripping + repetition-tail trimming on the output
actor GemmaLiteRTBackend: ASRBackend {
    nonisolated let id = "gemma4-litert"
    private(set) var isReady = false

    private var engine: Engine?

    init() {}

    // MARK: - Lifecycle

    /// `modelPath` may be the `.litertlm` file itself or a directory
    /// containing one (the HF snapshot dir). nil → resolve the default
    /// cached bundle so the ensemble can self-load this backend.
    func load(modelPath: URL?) async throws {
        if isReady, engine != nil { return }
        guard let file = Self.resolveModelFile(from: modelPath) else {
            throw ASRError.modelMissing(backend: id)
        }
        AppLog.info("litert", "loading \(file.lastPathComponent)")

        // GPU (Metal) for text decode first, CPU fallback — mirroring
        // Android's Auto path. Audio encoder pinned to CPU per the bundle's
        // constraint ("Model requires one of [cpu]").
        var failures: [String] = []
        for gpu in [true, false] {
            do {
                let config = try EngineConfig(
                    modelPath: file.path,
                    backend: gpu ? .gpu : .cpu(),
                    audioBackend: .cpu(),
                    // 32K, not the Android default of 8192: whole-transcript
                    // presets (CLEAN of a 40-min recording ≈ 10k tokens in +
                    // 8k out) must fit INPUT + OUTPUT in this window — at 8192
                    // the input alone overflowed it and CLEAN truncated at ~9%.
                    maxNumTokens: 32768,
                    cacheDir: NSTemporaryDirectory()
                )
                let e = Engine(engineConfig: config)
                try await e.initialize()
                self.engine = e
                self.isReady = true
                AppLog.info("litert", "engine ready on \(gpu ? "GPU" : "CPU")")
                return
            } catch {
                failures.append("\(gpu ? "GPU" : "CPU"): \(error.localizedDescription)")
                AppLog.warn("litert", "engine init failed on \(gpu ? "GPU" : "CPU"): \(error.localizedDescription)")
            }
        }
        throw ASRError.modelLoadFailed(reason: "LiteRT engine init failed — \(failures.joined(separator: "; "))")
    }

    func release() async {
        engine = nil
        isReady = false
    }

    /// Find the .litertlm bundle: explicit file → dir scan → default cache.
    nonisolated static func resolveModelFile(from path: URL?) -> URL? {
        func litertFile(in dir: URL) -> URL? {
            // Repos ship device-specific variants (…_qualcomm_*, …-web); the
            // generic bundle has the shortest name — prefer it.
            (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil))?
                .filter { $0.pathExtension == "litertlm" }
                .min { $0.lastPathComponent.count < $1.lastPathComponent.count }
        }
        if let path {
            if path.pathExtension == "litertlm" { return path }
            if let f = litertFile(in: path) { return f }
        }
        // Default: any cached litert-community bundle (E4B preferred).
        for entry in ModelCatalog.entries
        where entry.backend == .gemmaLiteRT {
            if let dir = ModelCatalog.cachedRepoDirectory(huggingFaceID: entry.huggingFaceID),
               let f = litertFile(in: dir) {
                return f
            }
        }
        return nil
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
        guard isReady, let engine else {
            throw ASRError.modelLoadFailed(reason: "LiteRT Gemma not loaded")
        }
        guard samples.count >= 8_000 else { return "" }
        // LiteRT bundles cap audio at ~30 s; Android uses 28 s chunks.
        let maxSamples = 16_000 * 28
        let trimmed = samples.count > maxSamples ? Array(samples.prefix(maxSamples)) : samples

        let wavURL = try Self.writeTempWav16(samples: trimmed, sampleRate: 16_000)
        defer { try? FileManager.default.removeItem(at: wavURL) }

        // Same exclusivity as generateText — ASR and text generations share
        // one engine and must never interleave conversations on it.
        await acquireEngine()
        defer { releaseEngine() }

        let sampler = try SamplerConfig(topK: 1, topP: 0.95, temperature: 0.1)
        let conversation = try await engine.createConversation(with: ConversationConfig(
            systemMessage: Message(Self.systemInstruction(diarize: diarize)),
            samplerConfig: sampler
        ))
        let message = Message(contents: [
            Content.audioFile(wavURL.path),
            Content.text(Self.userMessage(
                languages: languages, translateTo: translateTo,
                diarize: diarize, previousContext: previousContext,
                speakerHints: speakerHints
            )),
        ])
        let response = try await conversation.sendMessage(message)
        let raw = response.toString.trimmingCharacters(in: .whitespacesAndNewlines)
        var cleaned = Self.trimRepetitionTail(Self.stripPreamble(raw))
        // Boundary-echo strip: despite the fenced prompt, Gemma sometimes
        // re-transcribes the continuity hint at the chunk start. If the
        // opening words fuzzily match the context tail, drop them.
        if let tail = previousContext, !tail.isEmpty {
            cleaned = Self.stripContextEcho(cleaned, contextTail: String(tail.suffix(120)))
        }
        AppLog.info("litert", "chunk \(String(format: "%.1f", Double(trimmed.count) / 16_000))s → \(cleaned.count) chars")
        return cleaned
    }

    // MARK: - Text generation

    // MARK: - Engine lock (non-reentrant)
    //
    // This actor's methods suspend at `await`, and Swift actors are
    // REENTRANT at suspension points — so an ensemble arbitration and a
    // preset generation could interleave two conversations on the single
    // LiteRT engine, starving one into an empty response. Log-proven: every
    // 0-char generation coincided with a concurrent gemma merge. One
    // generation at a time, strict FIFO.
    private var engineBusy = false
    private var engineWaiters: [CheckedContinuation<Void, Never>] = []

    private func acquireEngine() async {
        if !engineBusy { engineBusy = true; return }
        await withCheckedContinuation { engineWaiters.append($0) }
    }

    private func releaseEngine() {
        if engineWaiters.isEmpty { engineBusy = false }
        else { engineWaiters.removeFirst().resume() }
    }

    func generateText(
        systemInstruction: String,
        userMessage: String,
        maxTokens: Int
    ) async throws -> String {
        guard isReady, let engine else {
            throw ASRError.modelLoadFailed(reason: "LiteRT Gemma not loaded")
        }
        await acquireEngine()
        defer { releaseEngine() }
        func attempt() async throws -> String {
            let sampler = try SamplerConfig(topK: 40, topP: 0.95, temperature: 0.4)
            let conversation = try await engine.createConversation(with: ConversationConfig(
                systemMessage: Message(systemInstruction),
                samplerConfig: sampler
            ))
            let response = try await conversation.sendMessage(Message(userMessage))
            return response.toString.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        var out = try await attempt()
        if out.isEmpty {
            // Defense in depth: a fresh conversation on a now-exclusive
            // engine — if the first attempt was poisoned by earlier state,
            // this one isn't.
            AppLog.warn("litert", "empty generation — retrying once on exclusive engine")
            out = try await attempt()
        }
        return out
    }

    // MARK: - Prompts (ported from Gemma4Backend.kt)

    nonisolated static func systemInstruction(diarize: Bool) -> String {
        var s = """
        You are a professional transcription engine. You convert speech to \
        accurate written text exactly as spoken, in the spoken language. You \
        never answer questions found in the audio, never summarize, and never \
        add commentary.
        """
        if diarize {
            s += "\nWhen asked to label speakers, the \"Speaker N:\" prefixes are part of the required output format."
        }
        return s
    }

    nonisolated static func userMessage(
        languages: Set<String>,
        translateTo: String?,
        diarize: Bool,
        previousContext: String?,
        speakerHints: [SpeakerHint]
    ) -> String {
        let names = languages.sorted()
        var core: String
        if let target = translateTo {
            let source = names.isEmpty ? "the source language"
                : names.count == 1 ? names[0]
                : "one of " + names.joined(separator: " or ")
            core = "Translate the following speech segment in \(source) into natural \(target) text. "
        } else if names.count == 1 {
            // Google's template — language named twice (in → into) on purpose.
            core = "Transcribe the following speech segment in \(names[0]) into \(names[0]) text. "
        } else if names.isEmpty {
            core = "Transcribe the following speech segment into text in its spoken language. "
        } else {
            core = "Transcribe the following speech segment into text. The speech is in \(names.joined(separator: " or ")); detect which and transcribe in that language exactly as heard. "
        }
        core += """
        Produce properly formatted written text with full punctuation: end \
        every sentence with a period or question mark, insert commas at \
        natural pauses, and capitalize sentence starts and proper nouns. \
        Only output the transcription, with no preamble and no surrounding \
        quotes. When transcribing numbers, write the digits.
        """
        // User vocabulary (Settings → Style & Vocabulary): names and terms
        // spelled exactly — the Android app's proven mechanism for fixing
        // "Kaiserscraft"-style entity mishearings at transcription time.
        var vocabParts: [String] = []
        if let g = UserDefaults.standard.string(forKey: "prompt.vocabulary"),
           !g.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { vocabParts.append(g) }
        if let js = UserDefaults.standard.string(forKey: "prompt.vocabulary.byLang"),
           let byLang = try? JSONDecoder().decode([String: String].self, from: Data(js.utf8)) {
            let keys = languages.isEmpty ? Array(byLang.keys) : Array(languages)
            for k in keys.sorted() {
                if let v = byLang[k], !v.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    vocabParts.append(v)
                }
            }
        }
        let vocab = vocabParts.joined(separator: ", ")
        if !vocab.isEmpty {
            core += "\nVocabulary (spell exactly when these appear): \(vocab.prefix(600))"
        }
        if let tail = previousContext?.suffix(250), !tail.isEmpty {
            core += """


            === CONTEXT (DO NOT TRANSCRIBE OR REPEAT THESE LINES) ===
            Continuity hint — the previous chunk's final words were: \(tail)
            === END CONTEXT ===

            Now transcribe ONLY the audio in the current chunk. Do NOT echo, \
            paraphrase, or quote any text from the CONTEXT block.
            """
        }
        if diarize {
            if !speakerHints.isEmpty {
                core += "\n\nThis audio has multiple speakers. Voice analysis identifies these turns (times relative to this segment):\n"
                for h in speakerHints.prefix(12) {
                    let n = (h.speakerKey.split(separator: "_").last.flatMap { Int($0) } ?? 0) + 1
                    core += String(format: "- %.1f–%.1fs: Speaker %d\n", h.startSeconds, h.endSeconds, n)
                }
                core += "\nUse exactly these speaker labels. Prefix each spoken turn with the matching \"Speaker N: \" tag, one turn per line. Do not invent new speakers; do not renumber."
            } else {
                core += "\n\nThis audio has multiple speakers. Prefix each spoken segment with \"Speaker 1: \", \"Speaker 2: \", etc., assigned in order of first appearance, one turn per line."
            }
        }
        return core
    }

    // MARK: - Output cleanup (ported essentials)

    nonisolated static func stripPreamble(_ text: String) -> String {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        for (open, close) in [("\"", "\""), ("“", "”"), ("'", "'")] {
            if s.hasPrefix(open), s.hasSuffix(close), s.count > 2 {
                s = String(s.dropFirst(open.count).dropLast(close.count))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                break
            }
        }
        if let rx = try? NSRegularExpression(
            pattern: #"^(?:sure[!,. ]*\s*|okay[!,. ]*\s*|here(?:'s| is| are)[^\n:]*[:.\-—]\s*|the (?:transcription|translation)[^\n:]*[:.\-—]\s*|transcription[:.\-—]\s*|translation[:.\-—]\s*)"#,
            options: [.caseInsensitive]
        ) {
            let r = NSRange(s.startIndex..., in: s)
            s = rx.stringByReplacingMatches(in: s, range: r, withTemplate: "")
        }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Drop a trailing "Speaker N: Speaker N: …" runaway loop (empty or
    /// duplicated bodies), the dominant degenerate-decoding failure observed
    /// on Android. Conservative: unique non-empty turns are never touched.
    nonisolated static func trimRepetitionTail(_ text: String) -> String {
        guard text.count >= 30,
              let rx = try? NSRegularExpression(pattern: #"\bSpeaker\s+\d+\s*:"#, options: [.caseInsensitive])
        else { return text }
        let ns = text as NSString
        let matches = rx.matches(in: text, range: NSRange(location: 0, length: ns.length))
        guard matches.count >= 2 else { return text }
        var bodies: [String] = []
        for (i, m) in matches.enumerated() {
            let start = m.range.location + m.range.length
            let end = i + 1 < matches.count ? matches[i + 1].range.location : ns.length
            bodies.append(ns.substring(with: NSRange(location: start, length: end - start))
                .trimmingCharacters(in: .whitespacesAndNewlines))
        }
        guard let last = bodies.last,
              last.isEmpty || (bodies.count >= 2 && last == bodies[bodies.count - 2])
        else { return text }
        var runStart = matches.count - 1
        for i in stride(from: matches.count - 2, through: 0, by: -1) {
            let isEmpty = bodies[i].isEmpty
            let isDup = !bodies[i].isEmpty && bodies[i] == bodies[i + 1]
            if isEmpty || isDup { runStart = i } else { break }
        }
        AppLog.warn("litert", "trimming repetition tail (\(matches.count - runStart) markers)")
        return ns.substring(to: matches[runStart].range.location)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// If the output's first sentence/line is mostly words from the context
    /// tail, it's an echo of the continuity hint — remove it.
    nonisolated static func stripContextEcho(_ text: String, contextTail: String) -> String {
        func toks(_ s: String) -> Set<String> {
            Set(s.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { $0.count > 1 })
        }
        let tailToks = toks(contextTail)
        guard !tailToks.isEmpty else { return text }
        // Examine the first line (or sentence) only.
        let firstBreak = text.firstIndex(where: { $0 == "\n" }) ?? text.firstIndex(of: ".").map(text.index(after:)) ?? text.endIndex
        let head = String(text[..<firstBreak])
        let headToks = toks(head.replacingOccurrences(of: #"^\s*Speaker \d+:\s*"#, with: "", options: .regularExpression))
        guard headToks.count >= 3 else { return text }
        let overlap = Double(headToks.intersection(tailToks).count) / Double(headToks.count)
        if overlap >= 0.8 {
            AppLog.warn("litert", "stripped context echo: \(String(head.prefix(60)))")
            return String(text[firstBreak...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return text
    }

    /// 16-bit PCM WAV (what the Android backend feeds LiteRT).
    nonisolated static func writeTempWav16(samples: [Float], sampleRate: Int) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("litert-chunk-\(UUID().uuidString).wav")
        let pcmLen = samples.count * 2
        var data = Data(capacity: 44 + pcmLen)
        func le32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        func le16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        data.append(contentsOf: Array("RIFF".utf8)); le32(UInt32(36 + pcmLen))
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8)); le32(16)
        le16(1); le16(1); le32(UInt32(sampleRate)); le32(UInt32(sampleRate * 2)); le16(2); le16(16)
        data.append(contentsOf: Array("data".utf8)); le32(UInt32(pcmLen))
        for s in samples {
            let clamped = max(-1, min(1, s))
            le16(UInt16(bitPattern: Int16(clamped * 32767)))
        }
        try data.write(to: url)
        return url
    }
}
