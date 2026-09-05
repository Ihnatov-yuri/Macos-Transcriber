import Foundation

/// Deterministic text stages between the recognizer and the insertion
/// point. Pure functions — every rule here has a unit test.
///
/// Order in `process`:
///   1. vocabulary canonicalization (authoritative spellings)
///   2. destutter (fillers, "for for for", phrase echoes)
///   3. spoken commands ("new paragraph", "comma", "question mark" …)
///   4. whitespace tidy + sentence-capital carry-over
enum DictationText {

    struct Options: Sendable {
        var destutter = true
        var commands = true
        /// Canonical spellings ("KimKim", "OWASP"). Matching is exact after
        /// normalization (case, spacing, punctuation ignored) — never fuzzy.
        var vocabulary: [String] = []
    }

    static func process(_ raw: String, options: Options) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return "" }
        // Vocabulary FIRST: a name heard as two identical words ("kim kim"
        // for KimKim) would otherwise be collapsed by the stutter pass.
        if !options.vocabulary.isEmpty { text = canonicalizeVocabulary(text, terms: options.vocabulary) }
        if options.destutter { text = TextDestutter.collapse(text) }
        if options.commands { text = applyCommands(text) }
        text = tidy(text)
        // The recognizer capitalized its sentence start; if destutter dropped
        // that word ("Um so…" → "so…"), carry the capital to the new first word.
        if let rawFirst = raw.first(where: \.isLetter), rawFirst.isUppercase,
           let first = text.first, first.isLowercase {
            text = first.uppercased() + text.dropFirst()
        }
        return text
    }

    // MARK: - Spoken commands

    private enum Command {
        case punctuation(String)   // attaches to the previous word
        case newline
        case paragraph
        case openQuote
        case closeQuote
    }

    /// Multi-word forms first so "new paragraph" isn't eaten by "new".
    private static let commands: [(words: [String], command: Command)] = [
        (["new", "paragraph"],        .paragraph),
        (["next", "paragraph"],       .paragraph),
        (["new", "line"],             .newline),
        (["next", "line"],            .newline),
        (["line", "break"],           .newline),
        (["full", "stop"],            .punctuation(".")),
        (["question", "mark"],        .punctuation("?")),
        (["exclamation", "mark"],     .punctuation("!")),
        (["exclamation", "point"],    .punctuation("!")),
        (["open", "quote"],           .openQuote),
        (["open", "quotes"],          .openQuote),
        (["close", "quote"],          .closeQuote),
        (["close", "quotes"],         .closeQuote),
        (["end", "quote"],            .closeQuote),
        (["period"],                  .punctuation(".")),
        (["comma"],                   .punctuation(",")),
        (["colon"],                   .punctuation(":")),
        (["semicolon"],               .punctuation(";")),
    ]

    /// Single words that are also ordinary nouns. They only act as a
    /// command when they are NOT preceded by a determiner/preposition
    /// ("the period", "a comma", "this period", "of period") and are
    /// followed by end of text, a capitalized word, or another command.
    private static let ambiguous: Set<String> = ["period", "comma", "colon", "semicolon"]
    private static let determiners: Set<String> = [
        "the", "a", "an", "this", "that", "each", "every", "one", "first", "second",
        "last", "next", "same", "long", "short", "of", "in", "per", "his", "her",
        "my", "your", "our", "their", "its", "no", "any", "some", "another", "which",
        "what", "trial", "grace", "time", "waiting", "rest", "orbital", "menstrual",
    ]

    private static func norm(_ token: Substring) -> String {
        token.lowercased().trimmingCharacters(in: .punctuationCharacters)
    }

    private static func trailingPunctuation(_ token: Substring) -> String {
        var out = ""
        for c in token.reversed() {
            if c.isPunctuation { out.insert(c, at: out.startIndex) } else { break }
        }
        return out
    }

    private static func startsSentence(_ token: Substring?) -> Bool {
        guard let token, let first = token.first else { return true }   // end of text
        return first.isUppercase || first.isNumber
    }

    static func applyCommands(_ text: String) -> String {
        // Work line by line so an existing newline survives untouched.
        return text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { applyCommandsToLine(String($0)) }
            .joined(separator: "\n")
    }

    private static func applyCommandsToLine(_ line: String) -> String {
        let tokens = line.split(separator: " ", omittingEmptySubsequences: true)
        guard !tokens.isEmpty else { return line }
        var out = ""          // built text
        var i = 0
        // A spoken terminator / paragraph starts a new sentence; the
        // recognizer didn't know that, so it left the next word lowercase.
        var capitalizeNext = false

        func appendWord(_ raw: String) {
            var word = raw
            if capitalizeNext, let first = word.first, first.isLowercase {
                word = first.uppercased() + word.dropFirst()
            }
            capitalizeNext = false
            if out.isEmpty || out.hasSuffix("\n") || out.hasSuffix("“") {
                out += word
            } else {
                out += " " + word
            }
        }
        /// Attach punctuation to the last word, replacing a recognizer-added
        /// terminator ("period." → ".", "comma," → ",").
        func attach(_ punct: String) {
            while let last = out.last, last.isPunctuation, last != "”", last != "\"", last != ")" {
                out.removeLast()
            }
            out += punct
        }

        while i < tokens.count {
            var matched = false
            for entry in commands {
                let n = entry.words.count
                guard i + n <= tokens.count else { continue }
                let window = tokens[i ..< i + n]
                guard window.map(norm) == entry.words else { continue }
                // Inner tokens of a multi-word command must not carry
                // punctuation ("new. Paragraph" is two sentences).
                guard window.dropLast().allSatisfy({ trailingPunctuation($0).isEmpty }) else { continue }
                let next: Substring? = i + n < tokens.count ? tokens[i + n] : nil
                if n == 1, ambiguous.contains(entry.words[0]) {
                    let prev: Substring? = i > 0 ? tokens[i - 1] : nil
                    let prevIsDeterminer = prev.map { determiners.contains(norm($0)) } ?? false
                    // "the period", "a comma", "this colon" — the noun.
                    guard !prevIsDeterminer else { continue }
                    // Nothing to attach a leading "Comma." to — keep the word.
                    if out.isEmpty { continue }
                    // "period" ends a sentence, so what follows must look like
                    // a sentence start (or the end of the passage, or another
                    // command). A lowercase continuation ("that period. we
                    // lost") is the noun. Mid-sentence marks (comma, colon,
                    // semicolon) are naturally followed by lowercase words.
                    if entry.words[0] == "period" {
                        let nextIsCommand = next.map { nx in
                            commands.contains { $0.words.count == 1 && $0.words[0] == norm(nx) }
                                || ["new", "next", "open", "close", "end", "full", "question", "exclamation", "line"]
                                    .contains(norm(nx))
                        } ?? false
                        guard startsSentence(next) || nextIsCommand else { continue }
                    }
                }
                switch entry.command {
                case .punctuation(let p):
                    // A leading "full stop" has nothing to attach to — drop it.
                    if !out.isEmpty { attach(p) }
                    if [".", "?", "!"].contains(p) { capitalizeNext = true }
                case .newline:
                    out = out.trimmingCharacters(in: .whitespaces) + "\n"
                    capitalizeNext = true
                case .paragraph:
                    out = out.trimmingCharacters(in: .whitespaces) + "\n\n"
                    capitalizeNext = true
                case .openQuote:
                    appendWord("“")
                case .closeQuote:
                    // Keep the terminator inside the quotes: `word.”`
                    out += "”"
                }
                // The recognizer's own terminator on the command word
                // ("paragraph.") is dropped; its capital on the next word is
                // the sentence start we wanted anyway.
                matched = true
                i += n
                break
            }
            if matched { continue }
            appendWord(String(tokens[i]))
            i += 1
        }
        return out
    }

    // MARK: - Vocabulary

    /// Letters and digits only, lowercased — spacing/punctuation-insensitive.
    static func vocabKey(_ s: String) -> String {
        s.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    /// Replace any 1–4 word window whose normalized form equals a vocabulary
    /// term's normalized form with the term's exact spelling. Trailing
    /// punctuation on the last word of the window is preserved.
    static func canonicalizeVocabulary(_ text: String, terms: [String]) -> String {
        let table: [String: String] = Dictionary(
            terms.map { ($0.trimmingCharacters(in: .whitespaces)) }
                .filter { !$0.isEmpty }
                .map { (vocabKey($0), $0) }
                .filter { !$0.0.isEmpty },
            uniquingKeysWith: { first, _ in first }
        )
        guard !table.isEmpty else { return text }
        // Windows up to three words even for one-word terms: a camel-cased
        // name ("KimKim") is usually heard as two words.
        let maxWords = max(3, terms.map { $0.split(separator: " ").count }.max() ?? 1)

        return text.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            let tokens = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            var out: [String] = []
            var i = 0
            while i < tokens.count {
                var replaced = false
                for n in stride(from: min(maxWords, tokens.count - i), through: 1, by: -1) {
                    let window = tokens[i ..< i + n]
                    let key = vocabKey(window.joined())
                    guard let canonical = table[key] else { continue }
                    let last = window.last ?? ""
                    let punct = trailingPunctuation(last[...])
                    // Already the canonical spelling → nothing to do (avoids
                    // re-joining "Kim Kim" when the term itself has a space).
                    if window.joined(separator: " ") == canonical + punct {
                        out.append(contentsOf: window)
                    } else {
                        out.append(canonical + punct)
                    }
                    i += n
                    replaced = true
                    break
                }
                if !replaced {
                    out.append(tokens[i])
                    i += 1
                }
            }
            return out.joined(separator: " ")
        }.joined(separator: "\n")
    }

    // MARK: - Whitespace

    static func tidy(_ text: String) -> String {
        var s = text
        // No space before closing punctuation; collapse runs of spaces.
        for p in [".", ",", "!", "?", ":", ";", "”"] {
            s = s.replacingOccurrences(of: " \(p)", with: p)
        }
        s = s.replacingOccurrences(of: "“ ", with: "“")
        while s.contains("  ") { s = s.replacingOccurrences(of: "  ", with: " ") }
        // At most one blank line.
        while s.contains("\n\n\n") { s = s.replacingOccurrences(of: "\n\n\n", with: "\n\n") }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Joining passages

    /// Append a new passage to what's already in the in-app pane.
    static func join(existing: String, new: String) -> String {
        let n = new.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty else { return existing }
        guard !existing.isEmpty else { return n }
        if existing.hasSuffix("\n") { return existing + n }
        if let first = n.first, first.isPunctuation, first != "“", first != "(" {
            return existing + n
        }
        return existing + " " + n
    }

    /// Text exactly as it will be typed into the target app.
    static func forInsertion(_ text: String, spacing: DictationSettings.Spacing) -> String {
        switch spacing {
        case .trailingSpace: return text.hasSuffix("\n") ? text : text + " "
        case .leadingSpace:  return " " + text
        case .none:          return text
        }
    }

    // MARK: - Polish guard

    /// The polish step must only ever return the same passage, cleaned. A
    /// small model sometimes answers the text, summarizes, or echoes the
    /// instructions — reject those and keep the deterministic output.
    static func acceptPolished(raw: String, polished: String) -> Bool {
        let p = polished.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !p.isEmpty else { return false }
        let ratio = Double(p.count) / Double(max(1, raw.count))
        guard ratio >= 0.45 && ratio <= 1.6 else { return false }
        let lowered = p.lowercased()
        let metaPhrases = [
            "here is", "here's the", "cleaned text", "cleaned version", "as an ai",
            "the passage", "the text you", "i cannot", "i can't", "sure!", "sure,",
        ]
        if metaPhrases.contains(where: { lowered.hasPrefix($0) }) { return false }
        // Must be the same words in the same order. Word-set overlap alone is
        // fooled by an answer that reuses the question's words ("what is the
        // capital of france" → "The capital of France is Paris."), so the
        // check is the longest common word subsequence against the shorter
        // side: a cleanup keeps nearly everything in order; an answer doesn't.
        let rawWords = raw.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
        let polWords = polished.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
        guard !polWords.isEmpty, !rawWords.isEmpty else { return false }
        let lcs = longestCommonSubsequence(Array(rawWords.prefix(400)), Array(polWords.prefix(400)))
        return Double(lcs) / Double(min(rawWords.count, polWords.count)) >= 0.75
    }

    static func longestCommonSubsequence(_ a: [String], _ b: [String]) -> Int {
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        var prev = [Int](repeating: 0, count: b.count + 1)
        var cur = prev
        for i in 1 ... a.count {
            for j in 1 ... b.count {
                cur[j] = a[i - 1] == b[j - 1] ? prev[j - 1] + 1 : max(prev[j], cur[j - 1])
            }
            swap(&prev, &cur)
        }
        return prev[b.count]
    }

    /// Short title for the history entry: first few words, no terminator.
    static func title(for text: String, maxWords: Int = 6) -> String {
        let words = text.split { $0.isWhitespace }.prefix(maxWords).map(String.init)
        var t = words.joined(separator: " ")
        while let last = t.last, last.isPunctuation { t.removeLast() }
        return t.isEmpty ? "Dictation" : t
    }
}
