import Foundation

/// Heuristic per-chunk quality signal. Gemma 4 doesn't expose token-level
/// confidence yet (mlx-swift-lm hasn't surfaced log-probs through MLXLLM),
/// so we look at the *output text* for the failure shapes we've actually
/// seen in the wild:
///   - Output is very short relative to the audio window's duration
///   - Output ends mid-sentence with no terminal punctuation
///   - Output collapses into a repetitive loop ("the the the the ...")
///   - Output contains common Gemma hallucination patterns
///
/// Each signal contributes to a 0..1 score; everything ≥ `lowThreshold` is
/// flagged for the second pass in `TranscriptionRunner`.
struct ChunkConfidence: Sendable {
    let score: Double                 // 0 = clean, 1 = garbage
    let reasons: [String]

    /// Chunks at or above this score are re-run with adjusted params.
    static let lowThreshold: Double = 0.5

    var isLow: Bool { score >= Self.lowThreshold }

    static func assess(rawText: String, audioDurationSeconds: Double) -> ChunkConfidence {
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        var score: Double = 0
        var reasons: [String] = []

        // 1. Empty / near-empty output for non-silent audio (>5 s)
        let charCount = text.count
        if audioDurationSeconds > 5 && charCount < 12 {
            score += 0.6
            reasons.append("too-short(\(charCount)c/\(Int(audioDurationSeconds))s)")
        } else if audioDurationSeconds > 15 && charCount < 60 {
            // Pretty sparse for a 15+ s window
            score += 0.3
            reasons.append("sparse(\(charCount)c/\(Int(audioDurationSeconds))s)")
        }

        // 2. Repetition loops — same 3-word phrase repeated 4+ times
        if let loop = detectRepetitionLoop(text) {
            score += 0.7
            reasons.append("loop(\"\(loop.prefix(40))…\")")
        }

        // 3. Hallucinated apologies / refusals
        let lower = text.lowercased()
        let hallucinations = [
            "i cannot transcribe",
            "i am unable to",
            "as an ai",
            "sorry, i",
            "i can't help with",
        ]
        for h in hallucinations where lower.contains(h) {
            score += 0.8
            reasons.append("hallucinated(\"\(h)\")")
            break
        }

        // 4. Unterminated final sentence — only flag if the last token before
        //    whitespace is a real letter (not a number / symbol).
        if charCount > 30,
           let last = text.unicodeScalars.last,
           CharacterSet.letters.contains(last),
           !text.hasSuffix(".") && !text.hasSuffix("!") && !text.hasSuffix("?") && !text.hasSuffix("…")
        {
            score += 0.15
            reasons.append("no-terminal-punct")
        }

        // Clamp.
        score = min(1.0, score)
        return ChunkConfidence(score: score, reasons: reasons)
    }

    /// Find any 2-5 word sequence repeated ≥4 times back-to-back.
    private static func detectRepetitionLoop(_ text: String) -> String? {
        let words = text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard words.count >= 8 else { return nil }
        for ngram in 2...5 {
            guard ngram * 4 <= words.count else { continue }
            for start in 0...(words.count - ngram * 4) {
                let pattern = Array(words[start ..< start + ngram])
                var matches = 1
                var cursor = start + ngram
                while cursor + ngram <= words.count {
                    if Array(words[cursor ..< cursor + ngram]) == pattern {
                        matches += 1
                        cursor += ngram
                    } else { break }
                }
                if matches >= 4 {
                    return pattern.joined(separator: " ")
                }
            }
        }
        return nil
    }
}
