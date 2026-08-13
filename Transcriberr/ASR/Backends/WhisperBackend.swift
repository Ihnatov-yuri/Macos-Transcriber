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

        // While a LiteRT Gemma engine is live, heavy inference is serialized
        // across engines — concurrent GPU work wedges LiteRT's native call
        // (see InferenceGate). Pass-through when no Gemma is loaded.
        let gateStamp = await InferenceGate.shared.acquire()
        defer { Task { await InferenceGate.shared.release(gateStamp) } }
        let results = try await pipe.transcribe(audioArray: samples, decodeOptions: options)
        let text = results.map(\.text)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        var words: [ScoredWord] = []
        for result in results {
            for segment in result.segments {
                for w in segment.words ?? [] {
                    let surface = w.word.trimmingCharacters(in: .whitespaces)
                    guard !surface.isEmpty else { continue }
                    // WhisperKit starts a new "word" at punctuation, so an
                    // intra-word apostrophe (Ukrainian "Пам'ятаєш") arrives
                    // as a separate fragment "'ятаєш". Re-attach it, or the
                    // merge join renders "Пам 'ятаєш".
                    if let first = surface.first, "'’ʼ‘".contains(first),
                       surface.count > 1,
                       let prevLast = words.last?.surface.last, prevLast.isLetter {
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
