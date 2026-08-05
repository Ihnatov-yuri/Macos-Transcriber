import Foundation

/// Deterministic disfluency collapse for speech transcripts.
///
/// Small local LLMs reliably fail to strip stutters from long transcripts no
/// matter how the prompt begs ("for for for for person", "the next the next
/// conversation"), so the collapse happens in code before the text reaches
/// the model. Rules are conservative on purpose:
///  - immediate word runs of 3+ always collapse to one
///  - word doubles collapse unless the word is a legitimate English double
///    ("that that's", "had had", emphasis words)
///  - immediate phrase repeats of 2–4 words always collapse ("bring in bring
///    in", "present that present that")
///  - nothing collapses across a sentence boundary, so intentional repeats
///    like "Yeah. Yeah." and "Thanks. Thanks." survive
enum TextDestutter {

    static func collapse(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { collapseLine(String($0)) }
            .joined(separator: "\n")
    }

    /// Words that repeat legitimately in fluent English at run length 2.
    private static let legitDoubles: Set<String> = [
        "that", "had", "very", "really", "no", "yeah", "bye", "ha", "so",
    ]

    /// Pure hesitation sounds — dropped outright before stutter collapse
    /// (which also lets "how it uh how it" collapse as a phrase echo).
    private static let fillers: Set<String> = [
        "uh", "um", "erm", "mm", "mhm", "hmm", "mmm",
    ]

    private static func norm(_ t: Substring) -> String {
        t.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ",;"))
    }

    private static func endsSentence(_ t: Substring) -> Bool {
        t.hasSuffix(".") || t.hasSuffix("!") || t.hasSuffix("?")
    }

    static func collapseLine(_ line: String) -> String {
        var tokens = line.split(separator: " ", omittingEmptySubsequences: true)
        tokens.removeAll { token in
            let n = token.lowercased().trimmingCharacters(
                in: CharacterSet(charactersIn: ",;.!?"))
            return fillers.contains(n)
        }
        guard tokens.count > 1 else { return tokens.joined(separator: " ") }
        var out: [Substring] = []
        var i = 0
        while i < tokens.count {
            out.append(tokens[i])
            i += 1

            // Phrase repeats: drop the next n tokens while they echo the n
            // just emitted (longest echo first).
            var collapsed = true
            while collapsed {
                collapsed = false
                for n in stride(from: 4, through: 2, by: -1) {
                    guard out.count >= n, i + n <= tokens.count else { continue }
                    let prev = out.suffix(n)
                    let next = tokens[i ..< i + n]
                    // A sentence end ANYWHERE in the first copy means the
                    // "echo" starts a new sentence ("Thank you. Thank you.")
                    // — a deliberate repeat, not a stutter.
                    guard prev.map(norm) == next.map(norm),
                          !prev.contains(where: endsSentence),
                          !next.dropLast().contains(where: endsSentence),
                          prev.allSatisfy({ !norm($0).isEmpty })
                    else { continue }
                    i += n
                    collapsed = true
                    break
                }
            }

            // Single-word stutter runs. Count repeats of the just-emitted
            // token, never across a sentence end.
            guard let last = out.last, !endsSentence(last), !norm(last).isEmpty else { continue }
            var run = 0
            while i + run < tokens.count,
                  norm(tokens[i + run]) == norm(last),
                  run == 0 || !endsSentence(tokens[i + run - 1])
            {
                run += 1
            }
            if run >= 2 || (run == 1 && !legitDoubles.contains(norm(last))) {
                // Keep the FIRST occurrence — it carries sentence-initial
                // capitalization ("For for for" → "For"). A repeat carrying
                // .!? can never match norm equality, so no punctuation is
                // lost by dropping the rest.
                i += run
            }
        }
        return out.joined(separator: " ")
    }
}
