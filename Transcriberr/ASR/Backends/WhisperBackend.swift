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
        guard isReady, let pipe else {
            throw ASRError.modelLoadFailed(reason: "Whisper backend not loaded")
        }
        guard samples.count >= 8_000 else { return DetailedTranscription(text: "", words: []) }

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

        // While a LiteRT Gemma engine is live, heavy inference is serialized
        // across engines — concurrent GPU work wedges LiteRT's native call
        // (see InferenceGate). Pass-through when no Gemma is loaded.
        let gateStamp = await InferenceGate.shared.acquire()
        defer { Task { await InferenceGate.shared.release(gateStamp) } }
        let results = try await pipe.transcribe(audioArray: samples, decodeOptions: options)

        let isUkrainian = languages.count == 1 && languages.first?.lowercased() == "ukrainian"
        var words: [ScoredWord] = []
        var keptTexts: [String] = []
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
                    noSpeechProb: segment.noSpeechProb, ukrainian: isUkrainian) {
                    AppLog.warn("whisper", String(
                        format: "dropping segment (%@; logprob %.2f, no-speech %.2f): %@",
                        reason, segment.avgLogprob, segment.noSpeechProb, String(segText.prefix(60))))
                    continue
                }
                if TranscriptHygiene.isPhantomOnly(segText) {
                    AppLog.info("whisper", String(
                        format: "stock line kept as speech (logprob %.2f, no-speech %.2f): %@",
                        segment.avgLogprob, segment.noSpeechProb, segText))
                }
                keptTexts.append(segText)
                for w in segWords {
                    let surface = w.word.trimmingCharacters(in: .whitespaces)
                    guard !surface.isEmpty else { continue }
                    // WhisperKit starts a new "word" at punctuation, so an
                    // intra-word apostrophe or hyphen (Ukrainian "Пам'ятаєш",
                    // "більш-менш") and a clock colon ("10:00") arrive as
                    // separate fragments "'ятаєш" / "-менш" / ":00".
                    // Re-attach them, or the merge join renders "більш -менш".
                    if EnsembleBackend.attachesToPrevious(surface, previous: words.last?.surface) {
                        let i = words.count - 1
                        words[i].surface += surface
                        words[i].norm = words[i].surface.lowercased()
                            .filter { $0.isLetter || $0.isNumber }
                        words[i].confidence = min(words[i].confidence, w.probability)
                        continue
                    }
                    words.append(ScoredWord(
                        surface: surface,
                        norm: surface.lowercased().filter { $0.isLetter || $0.isNumber },
                        confidence: w.probability
                    ))
                }
            }
        }
        var text = keptTexts.joined(separator: " ")
        // Whisper scores its own phantoms as confident speech (measured:
        // log-prob −0.1, no-speech 0.00 on a silent track), so a chunk that
        // is NOTHING but a stock line needs an independent witness: the
        // audio itself. A spoken "Дякую" has a loud voiced burst; the quiet
        // side of a split-track meeting does not.
        if TranscriptHygiene.isPhantomOnly(text) {
            let peak = Self.peakWindowRMS(samples)
            let drop = peak < Self.phantomPeakRMS
            AppLog.info("whisper", String(
                format: "stock-line-only chunk \"%@\" — peak RMS %.4f → %@",
                String(text.prefix(30)), peak, drop ? "dropped as silence" : "kept"))
            if drop { text = ""; words = [] }
        }
        AppLog.info("whisper", String(
            format: "chunk %.1fs → %d chars, %d scored words",
            Double(samples.count) / 16_000.0, text.count, words.count
        ))
        return DetailedTranscription(text: text, words: words)
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

    /// Loudest 200 ms window of the chunk (RMS).
    static func peakWindowRMS(_ samples: [Float]) -> Float {
        let win = 3_200
        guard samples.count >= win else { return 0 }
        var peak: Float = 0
        var i = 0
        while i + win <= samples.count {
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

    /// Whisper's own evidence that a segment is not speech. The thresholds
    /// are the reference implementation's (no-speech 0.6 / log-prob −1.0);
    /// stock phantom lines are held to a much stricter bar because they are
    /// exactly what the model emits when it is guessing.
    static func rejectReason(
        text: String, avgLogprob: Float, noSpeechProb: Float, ukrainian: Bool
    ) -> String? {
        if noSpeechProb > 0.6, avgLogprob < -1.0 { return "no speech" }
        if TranscriptHygiene.isPhantomOnly(text), noSpeechProb > 0.25 || avgLogprob < -0.55 {
            return "phantom line"
        }
        if ukrainian, TranscriptHygiene.nonUkrainianCyrillicShare(text) > 0.04, avgLogprob < -0.4 {
            return "language drift"
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
