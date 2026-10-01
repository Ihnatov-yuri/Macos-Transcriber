import CoreML
import os
import Foundation
import WhisperKit

/// Whisper language detection with the whole distribution.
///
/// `WhisperKit.detectLangauge` returns a probability for the winning
/// language only: its `langProbs` holds one entry. Every decision that
/// weighs a second language against it read 0 for that language, so with
/// English + Arabic selected, a chunk Whisper heard as Nynorsk (`nn`) went
/// to Arabic on the alphabetical tie-break — an English meeting was decoded
/// as Arabic on 2026-10-01. Same steps as WhisperKit's own detection, with a
/// sampler that keeps the softmax over every language token.
enum WhisperLanguageProbe {
    struct Result {
        let top: String
        /// Probability per ISO code ("en", "ar", …); sums to 1.
        let probs: [String: Double]
    }

    static func detect(pipe: WhisperKit, tokenizer: any WhisperTokenizer, samples: [Float]) async throws -> Result {
        guard pipe.textDecoder.isModelMultilingual else {
            throw WhisperError.decodingFailed("Language detection not supported for this model")
        }
        let decoderInputs = try pipe.textDecoder.prepareDecoderInputs(
            withPrompt: [tokenizer.specialTokens.startOfTranscriptToken])
        guard let audio = pipe.audioProcessor.padOrTrim(
            fromArray: samples, startAt: 0,
            toLength: pipe.featureExtractor.windowSamples ?? 480_000),
              let mel = try await pipe.featureExtractor.logMelSpectrogram(fromAudio: audio),
              let encoded = try await pipe.audioEncoder.encodeFeatures(mel)
        else { throw WhisperError.transcriptionFailed("Language detection: no encoder output") }

        let options = DecodingOptions(verbose: false)
        let sampler = DistributionSampler(
            greedy: GreedyTokenSampler(temperature: 0, eotToken: tokenizer.specialTokens.endToken,
                                       decodingOptions: options),
            languageTokens: languageCodes(tokenizer))
        let result = try await pipe.textDecoder.detectLanguage(
            from: encoded, using: decoderInputs, sampler: sampler, options: options, temperature: 0)
        guard !sampler.probs.isEmpty else {
            throw WhisperError.decodingFailed("Language detection: no language logits")
        }
        return Result(top: result.language, probs: sampler.probs)
    }

    /// Language token → ISO code ("<|en|>" → "en").
    private static func languageCodes(_ tokenizer: any WhisperTokenizer) -> [Int: String] {
        var map: [Int: String] = [:]
        for token in tokenizer.allLanguageTokens {
            let code = tokenizer.decode(tokens: [token])
                .trimmingCharacters(in: CharacterSet(charactersIn: "<|> "))
            if !code.isEmpty { map[token] = code }
        }
        return map
    }

    /// Picks like the greedy sampler, and records the softmax over the
    /// language tokens on the way (the logits it sees are already filtered
    /// to languages).
    final class DistributionSampler: TokenSampling {
        private let greedy: GreedyTokenSampler
        private let languageTokens: [Int: String]
        private(set) var probs: [String: Double] = [:]

        init(greedy: GreedyTokenSampler, languageTokens: [Int: String]) {
            self.greedy = greedy
            self.languageTokens = languageTokens
        }

        func update(tokens: [Int], logits: MLMultiArray, logProbs: [Float]) -> SamplingResult {
            probs = Self.softmax(logits: logits, over: languageTokens)
            return greedy.update(tokens: tokens, logits: logits, logProbs: logProbs)
        }

        func finalize(tokens: [Int], logProbs: [Float]) -> SamplingResult {
            greedy.finalize(tokens: tokens, logProbs: logProbs)
        }

        static func softmax(logits: MLMultiArray, over tokens: [Int: String]) -> [String: Double] {
            let count = logits.count
            var raw: [(String, Double)] = []
            raw.reserveCapacity(tokens.count)
            for (token, code) in tokens where token < count {
                let v = logits[token].doubleValue
                if v.isFinite { raw.append((code, v)) }
            }
            return softmax(raw)
        }

        static func softmax(_ raw: [(String, Double)]) -> [String: Double] {
            guard let peak = raw.map(\.1).max() else { return [:] }
            let exps = raw.map { ($0.0, exp($0.1 - peak)) }
            let total = exps.reduce(0) { $0 + $1.1 }
            guard total > 0 else { return [:] }
            return Dictionary(exps.map { ($0.0, $0.1 / total) }, uniquingKeysWith: +)
        }
    }
}

/// Chunks where the language Whisper decoded in differs from its own first
/// guess, counted per run so the finished run can say so in one line.
/// Super runs are serial (JobManager), so one shared tally is enough.
enum LanguageOverrideLog {
    struct Entry: Equatable { let from: String; let to: String; let count: Int }

    private static let tally = OSAllocatedUnfairLock(initialState: [String: Int]())

    static func record(from: String, to: String) {
        tally.withLock { $0["\(from)>\(to)", default: 0] += 1 }
    }

    static func reset() { tally.withLock { $0.removeAll() } }

    static func take() -> [Entry] {
        let all = tally.withLock { t -> [String: Int] in defer { t.removeAll() }; return t }
        return all.compactMap { key, count in
            let p = key.split(separator: ">").map(String.init)
            return p.count == 2 ? Entry(from: p[0], to: p[1], count: count) : nil
        }
        .sorted { ($0.count, $1.from) > ($1.count, $0.from) }
    }

    /// "Whisper first heard Norwegian Nynorsk in 4 parts and Turkish in
    /// 1 part, and transcribed them as English."
    static func message(_ entries: [Entry]) -> String? {
        guard !entries.isEmpty else { return nil }
        var heard: [(String, Int)] = []
        for e in entries {
            if let i = heard.firstIndex(where: { $0.0 == e.from }) { heard[i].1 += e.count }
            else { heard.append((e.from, e.count)) }
        }
        heard.sort { $0.1 > $1.1 }
        var targets: [String] = []
        for e in entries where !targets.contains(e.to) { targets.append(e.to) }
        let heardText = list(heard.map { "\(name($0.0)) in \($0.1) \($0.1 == 1 ? "part" : "parts")" })
        return "Whisper first heard \(heardText), and transcribed them as \(list(targets.map(name)))."
    }

    private static func name(_ code: String) -> String {
        Locale(identifier: "en").localizedString(forLanguageCode: code) ?? code
    }

    private static func list(_ items: [String]) -> String {
        switch items.count {
        case 0: return ""
        case 1: return items[0]
        default: return items.dropLast().joined(separator: ", ") + " and " + items.last!
        }
    }
}
