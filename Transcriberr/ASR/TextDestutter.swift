import Foundation

/// Deterministic disfluency collapse for speech transcripts.
///
/// Small local LLMs reliably fail to strip stutters from long transcripts no
/// matter how the prompt begs ("for for for for person", "the next the next
/// conversation"), so the collapse happens in code before the text reaches
/// the model. Rules are conservative on purpose:
///  - immediate word runs of 3+ always collapse to one
///  - word doubles collapse unless the word is a legitimate English double
///    ("that that's", "had had", emphasis words) or a yes/no answered twice
///    with a comma ("Так, так", "nee, nee")
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
        "that", "had", "very", "really", "no", "yes", "yeah", "bye", "ha", "so",
    ]

    /// Yes/no words doubled with a comma between them ("Так, так", "ні, ні",
    /// "ja, ja", "nee, nee"): a deliberate answer, written that way by the
    /// engines — the seam trim (`TranscriptHygiene.trimSeamRepeat`) keeps
    /// the same pair for the same reason. Only with the comma: a bare
    /// "так так" mid-sentence is as likely a stutter of "so".
    private static let commaDoubles: Set<String> = [
        "так", "ні", "да", "нет", "ja", "nee", "nein",
    ]

    /// Pure hesitation sounds — dropped outright before stutter collapse
    /// (which also lets "how it uh how it" collapse as a phrase echo).
    /// Tic words ("like", "ну", "типу") are NOT here: they carry meaning,
    /// and the verbatim view exists to study them.
    private static let fillers: Set<String> = [
        "uh", "um", "erm", "mm", "mhm", "hmm", "mmm",
        "е", "ее", "еее", "ем", "мм", "ммм", "хм",
    ]

    private static func norm(_ t: Substring) -> String {
        t.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ",;"))
    }

    private static func endsSentence(_ t: Substring) -> Bool {
        t.hasSuffix(".") || t.hasSuffix("!") || t.hasSuffix("?")
    }

    static func collapseLine(_ line: String) -> String {
        let rawTokens = line.split(separator: " ", omittingEmptySubsequences: true)
        // Drop fillers, but carry a filler's sentence-ending punctuation back
        // to the previous word — otherwise "Okay, um. Okay" loses its
        // boundary and the stutter pass would merge a deliberate restart.
        var tokens: [Substring] = []
        for token in rawTokens {
            let n = token.lowercased().trimmingCharacters(
                in: CharacterSet(charactersIn: ",;.!?"))
            guard fillers.contains(n) else { tokens.append(token); continue }
            if endsSentence(token), let last = tokens.last, !endsSentence(last), let punct = token.last {
                var t = String(last)
                while let c = t.last, ",;".contains(c) { t.removeLast() }
                tokens[tokens.count - 1] = (t + String(punct))[...]
            }
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
            let answer = last.hasSuffix(",") && commaDoubles.contains(norm(last))
            if run >= 2 || (run == 1 && !legitDoubles.contains(norm(last)) && !answer) {
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

/// How transcript text is shown and served. The store always keeps what the
/// engines heard; `clean` is a view over it — hesitation sounds and stutters
/// collapsed by `TextDestutter` — for reading, `verbatim` for studying how
/// someone speaks (tic words, restarts). Chosen in the transcript header,
/// per call on the MCP tools.
enum TranscriptStyle: String, CaseIterable, Sendable {
    case clean, verbatim

    static let defaultsKey = "ui.transcriptStyle"

    func apply(_ text: String) -> String {
        self == .clean ? TextDestutter.collapse(text) : text
    }
}
