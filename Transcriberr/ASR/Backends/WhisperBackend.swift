import Foundation
import WhisperKit

/// OpenAI Whisper large-v3 running locally via WhisperKit (CoreML / ANE).
///
/// The "best Whisper": strongest accuracy of the open Whisper family, ~100
/// languages. Slower than Parakeet (large encoder) but architecturally
/// independent of it — which is exactly what makes it valuable as a second
/// opinion in the Super dual-engine merge: where two *different* recognizers
/// agree, the words are almost certainly right.
///
/// Models (~3 GB) auto-download from HuggingFace (argmaxinc/whisperkit-coreml)
/// on first load; `modelPath` is ignored.
actor WhisperBackend: ASRBackend, DetailedTranscribing {
    nonisolated let id = "whisper-large-v3"
    private(set) var isReady = false

    private var pipe: WhisperKit?

    init() {}

    // MARK: - Lifecycle

    func load(modelPath: URL?) async throws {
        if isReady, pipe != nil { return }
        AppLog.info("whisper", "loading Whisper large-v3 (downloads ~3 GB on first run)…")
        do {
            let config = WhisperKitConfig(
                model: "large-v3",
                verbose: false,
                prewarm: true
            )
            let kit = try await WhisperKit(config)
            // Load now, once: `prewarm` leaves the models unloaded, and the
            // first transcribe calls — three chunks at once — would each
            // start loading them (see transcribeTimedSegments).
            if kit.modelState != .loaded { try await kit.loadModels() }
            self.pipe = kit
            self.isReady = true
            AppLog.info("whisper", "ready")
        } catch {
            AppLog.error("whisper", "load failed: \(error.localizedDescription)")
            throw ASRError.modelLoadFailed(reason: String(describing: error))
        }
    }

    func release() async {
        pipe = nil
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
        let detailed = try await transcribeDetailed(samples: samples, languages: languages)
        return detailed.text
    }

    func transcribeDetailed(
        samples: [Float],
        languages: Set<String>
    ) async throws -> DetailedTranscription {
        let timed = try await transcribeTimed(samples: samples, languages: languages)
        return DetailedTranscription(text: timed.text, words: timed.words.map(\.word))
    }

    /// A kept segment's span (seconds in the audio it was read from).
    struct SegmentSpan: Sendable { let start: Double; let end: Double }

    func transcribeTimed(
        samples: [Float],
        languages: Set<String>
    ) async throws -> (text: String, words: [TimedWord]) {
        let r = try await transcribeTimedSegments(samples: samples, languages: languages)
        return (r.text, r.words)
    }

    /// The same reading with each word's time in `samples` (seconds). Given
    /// a whole track, WhisperKit runs its own long-form loop: every 30 s
    /// window starts at the last segment it finished, so no word is ever
    /// read from a cut-off scrap (see `EnsembleBackend.prepareLongForm`).
    func transcribeTimedSegments(
        samples: [Float],
        languages: Set<String>
    ) async throws -> (text: String, words: [TimedWord], segments: [SegmentSpan]) {
        guard isReady, let pipe else {
            throw ASRError.modelLoadFailed(reason: "Whisper backend not loaded")
        }
        guard samples.count >= 8_000 else { return ("", [], []) }

        var options = DecodingOptions()
        options.task = .transcribe
        options.temperature = 0
        options.wordTimestamps = true          // per-word probabilities for the merge
        options.language = Self.languageCode(from: languages)
        // NO vocabulary prompt (`promptTokens`), deliberately. Measured on a
        // Ukrainian meeting: WhisperKit decodes prompt tokens one by one, so
        // a 40-token prompt cost +39% run time; it nearly doubled the stock
        // "Дякую за перегляд!" lines on silence, pulled English terms into
        // Cyrillic ("housekeeping" → "хаускіпінг") and dropped real speech.
        // The vocabulary acts in the word vote and the arbitration instead.

        // Shared hold: runs alongside other Whisper/Parakeet calls, but never
        // while LiteRT Gemma infers — that pairing wedges LiteRT's native
        // call (see InferenceGate). Pass-through when no Gemma is loaded.
        let gateStamp = await InferenceGate.shared.acquire()
        defer { Task { await InferenceGate.shared.release(gateStamp) } }
        // Our own TranscribeTask with its own Progress, not `pipe.transcribe`.
        // Chunks run three at a time on ONE WhisperKit (shared gate since
        // v3.8.0), and WhisperKit is a plain class whose transcribe swaps a
        // shared `progress` property at the end of every call: two calls
        // finishing together released the same object twice — a SIGSEGV in
        // swift_release_dealloc under runTranscribeTask, seen in a reference
        // run on 2026-09-23. Everything else the task touches is read-only
        // model state.
        // What `transcribe` does first: models (and the tokenizer) load
        // lazily on the first call after a prewarm.
        if pipe.modelState != .loaded { try await pipe.loadModels() }
        guard let tokenizer = pipe.tokenizer else { throw WhisperError.tokenizerUnavailable() }
        let task = pipe.setupTranscribeTask(
            currentTimings: pipe.currentTimings, progress: Progress(),
            audioProcessor: pipe.audioProcessor, audioEncoder: pipe.audioEncoder,
            featureExtractor: pipe.featureExtractor, segmentSeeker: pipe.segmentSeeker,
            textDecoder: pipe.textDecoder, tokenizer: tokenizer)
        let results = [try await task.run(audioArray: samples, decodeOptions: options, callback: nil)]

        let isUkrainian = languages.count == 1 && languages.first?.lowercased() == "ukrainian"
        let chunkSeconds = Double(samples.count) / 16_000
        var words: [TimedWord] = []
        var keptTexts: [String] = []
        var spans: [SegmentSpan] = []
        for result in results {
            for segment in result.segments {
                let segWords = segment.words ?? []
                let segText = (segWords.isEmpty
                    ? Self.stripSpecialTokens(segment.text)
                    : segWords.map(\.word).joined())
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !segText.isEmpty else { continue }
                if let reason = Self.rejectReason(
                    text: segText, avgLogprob: segment.avgLogprob,
                    noSpeechProb: segment.noSpeechProb,
                    chunkSeconds: chunkSeconds) {
                    AppLog.warn("whisper", String(
                        format: "dropping segment (%@; logprob %.2f, no-speech %.2f): %@",
                        reason, segment.avgLogprob, segment.noSpeechProb, String(segText.prefix(60))))
                    continue
                }
                // Observed, never acted on: a user who mixes languages says
                // these letters for real, and no logged run ever showed the
                // drift this was meant to catch.
                if isUkrainian, TranscriptHygiene.nonUkrainianCyrillicShare(segText) > 0.04 {
                    AppLog.info("whisper", String(
                        format: "non-Ukrainian Cyrillic in segment (logprob %.2f): %@",
                        segment.avgLogprob, String(segText.prefix(60))))
                }
                // Whisper scores its own phantoms as confident speech
                // (measured: log-prob −0.1, no-speech 0.00 on a silent
                // track), so the witness has to be the audio. Each stock
                // line is weighed over ITS OWN time range: a "Дякую." the
                // model tacked onto the quiet tail of a chunk full of real
                // speech is exactly the case a whole-chunk measurement
                // cannot see. Long chunks only — in dictation a 2-second
                // "Дякую" is the entire utterance.
                if chunkSeconds >= 8, TranscriptHygiene.isPhantomOnly(segText) {
                    let peak = Self.peakWindowRMS(
                        samples, from: Double(segment.start), to: Double(segment.end))
                    // nil = the segment lies past the end of the real audio.
                    // Whisper pads every window to 30 s with zeros, and these
                    // lines are what it writes over that padding: measured on
                    // a Ukrainian meeting, "Дякую." timed at 29.5-29.6 s in a
                    // 26 s chunk, every time. Nothing was said there.
                    let verdict = peak.map { $0 < Self.phantomPeakRMS ? "dropped as silence" : "kept" }
                        ?? "dropped — past the end of the audio (padding)"
                    AppLog.info("whisper", String(
                        format: "stock line \"%@\" @%.1f-%.1fs — peak RMS %@ → %@",
                        segText, segment.start, segment.end,
                        peak.map { String(format: "%.4f", $0) } ?? "n/a", verdict))
                    if peak.map({ $0 < Self.phantomPeakRMS }) ?? true { continue }
                }
                keptTexts.append(segText)
                spans.append(SegmentSpan(start: Double(segment.start), end: Double(segment.end)))
                for w in segWords {
                    let surface = w.word.trimmingCharacters(in: .whitespaces)
                    guard !surface.isEmpty else { continue }
                    // WhisperKit starts a new "word" at punctuation, so an
                    // intra-word apostrophe or hyphen (Ukrainian "Пам'ятаєш",
                    // "більш-менш") and a clock colon ("10:00") arrive as
                    // separate fragments "'ятаєш" / "-менш" / ":00".
                    // Re-attach them, or the merge join renders "більш -менш".
                    if EnsembleBackend.attachesToPrevious(surface, previous: words.last?.word.surface) {
                        let i = words.count - 1
                        words[i].word.surface += surface
                        words[i].word.norm = words[i].word.surface.lowercased()
                            .filter { $0.isLetter || $0.isNumber }
                        words[i].word.confidence = min(words[i].word.confidence, w.probability)
                        words[i].end = Double(w.end)
                        continue
                    }
                    words.append(TimedWord(
                        word: ScoredWord(
                            surface: surface,
                            norm: surface.lowercased().filter { $0.isLetter || $0.isNumber },
                            confidence: w.probability),
                        start: Double(w.start), end: Double(w.end)
                    ))
                }
            }
        }
        let text = keptTexts.joined(separator: " ")
        AppLog.info("whisper", String(
            format: "chunk %.1fs → %d chars, %d scored words",
            Double(samples.count) / 16_000.0, text.count, words.count
        ))
        return (text, words, spans)
    }

    /// Whisper's language guess for a stretch of audio: ISO code and its
    /// probability. One encoder pass (~0.7 s for large-v3), so callers pick
    /// the stretches worth asking about.
    func detectLanguage(samples: [Float]) async throws -> (code: String, probability: Double) {
        guard isReady, let pipe else {
            throw ASRError.modelLoadFailed(reason: "Whisper backend not loaded")
        }
        let gateStamp = await InferenceGate.shared.acquire()
        defer { Task { await InferenceGate.shared.release(gateStamp) } }
        let r = try await pipe.detectLangauge(audioArray: samples)
        return (r.language, exp(Double(r.langProbs[r.language] ?? -.infinity)))
    }

    // MARK: - Text generation (not supported — Gemma's job)

    func generateText(
        systemInstruction: String,
        userMessage: String,
        maxTokens: Int
    ) async throws -> String {
        throw ASRError.backendUnavailable(
            reason: "Whisper is speech-to-text only. Text generation uses Gemma 4."
        )
    }

    // MARK: - Helpers

    /// Below this peak a chunk holds no speech loud enough to be a phrase.
    static let phantomPeakRMS: Float = 0.012

    /// Loudest 200 ms window (RMS) over a time range, whole buffer by
    /// default. A range shorter than the window is widened around its
    /// midpoint — a 0.1 s segment measured against the whole chunk would
    /// inherit the loudest speech in it and never read as silence.
    /// Returns nil when the range starts past the end of the buffer: that
    /// is Whisper's zero padding, not audio, and the caller treats it as
    /// stronger evidence than any RMS.
    static func peakWindowRMS(_ samples: [Float], from: Double = 0, to: Double = .infinity) -> Float? {
        let win = 3_200
        var lo = 0, hi = samples.count
        if from > 0 || to.isFinite {
            guard from >= 0, to > from else { return samples.count >= win ? rawPeak(samples, 0, samples.count, win) : 0 }
            let a = Int(from * 16_000)
            guard a < samples.count - win / 2 else { return nil }   // padding
            var b = Int(to.rounded(.up) * 16_000)
            if b - a < win { let mid = (a + b) / 2; b = mid + win / 2; lo = max(0, mid - win / 2) } else { lo = a }
            hi = min(samples.count, max(b, lo + win))
        }
        guard hi - lo >= win else { return 0 }
        return rawPeak(samples, lo, hi, win)
    }

    private static func rawPeak(_ samples: [Float], _ lo: Int, _ hi: Int, _ win: Int) -> Float {
        var peak: Float = 0
        var i = lo
        while i + win <= hi {
            var e: Float = 0
            for v in samples[i..<(i + win)] { e += v * v }
            peak = max(peak, (e / Float(win)).squareRoot())
            i += win / 2
        }
        return peak
    }

    static func stripSpecialTokens(_ text: String) -> String {
        text.replacing(#/<\|[^|]*\|>/#, with: "")
    }

    /// Reasons to drop a segment outright. Deliberately few: Whisper rates
    /// its own phantoms as confident speech (log-prob −0.1, no-speech 0.00),
    /// so score rules catch little — the evidence-backed work is done by the
    /// sign-off list here, the loudness witness above and the second engine.
    ///   - a subtitle sign-off is never speech;
    ///   - the reference implementation's no-speech rule;
    ///   - a stock line with weak scores, but only in a LONG chunk: in
    ///     dictation a 2-second "Дякую" is the whole utterance, and a short
    ///     utterance scores low without being a phantom.
    static func rejectReason(
        text: String, avgLogprob: Float, noSpeechProb: Float, chunkSeconds: Double
    ) -> String? {
        if TranscriptHygiene.isOutroOnly(text) { return "subtitle sign-off" }
        if noSpeechProb > 0.6, avgLogprob < -1.0 { return "no speech" }
        if chunkSeconds >= 8, TranscriptHygiene.isPhantomOnly(text),
           noSpeechProb > 0.25 || avgLogprob < -0.55 {
            return "phantom line"
        }
        return nil
    }

    /// Whisper wants ISO-639-1 codes; nil = autodetect.
    static func languageCode(from languages: Set<String>) -> String? {
        guard languages.count == 1, let name = languages.first else { return nil }
        switch name.lowercased() {
        case "english":   return "en"
        case "arabic":    return "ar"
        case "ukrainian": return "uk"
        case "dutch":     return "nl"
        case "spanish":   return "es"
        case "french":    return "fr"
        case "german":    return "de"
        case "italian":   return "it"
        case "portuguese": return "pt"
        case "polish":    return "pl"
        case "korean":    return "ko"
        case "japanese":  return "ja"
        case "chinese":   return "zh"
        default:          return nil
        }
    }
}
