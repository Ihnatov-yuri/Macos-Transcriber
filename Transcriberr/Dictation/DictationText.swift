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
        /// "Monday, no, Tuesday" → "Tuesday".
        var selfCorrections = true
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
        if options.selfCorrections { text = applySelfCorrections(text) }
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
        /// "scratch that": drop everything said so far in this passage.
        case scratch
    }

    /// Multi-word forms first so "new paragraph" isn't eaten by "new".
    /// English, Dutch, German and Ukrainian — the languages Parakeet v3 is
    /// used with here. Single nouns ("period", "punt", "Punkt", "крапка")
    /// are ambiguous and go through the determiner / sentence-start checks.
    private static let commands: [(words: [String], command: Command)] = [
        // scratch / delete the passage so far
        (["scratch", "that"],         .scratch),
        (["delete", "that"],          .scratch),
        (["strike", "that"],          .scratch),
        (["undo", "that"],            .scratch),
        (["schrap", "dat"],           .scratch),
        (["verwijder", "dat"],        .scratch),
        (["streich", "das"],          .scratch),
        (["lösche", "das"],           .scratch),
        (["видали", "це"],            .scratch),
        (["скасуй", "це"],            .scratch),
        // Dutch
        (["nieuwe", "alinea"],        .paragraph),
        (["nieuwe", "paragraaf"],     .paragraph),
        (["nieuwe", "regel"],         .newline),
        (["vraagteken"],              .punctuation("?")),
        (["uitroepteken"],            .punctuation("!")),
        (["dubbele", "punt"],         .punctuation(":")),
        (["puntkomma"],               .punctuation(";")),
        (["punt"],                    .punctuation(".")),
        (["komma"],                   .punctuation(",")),
        // German
        (["neuer", "absatz"],         .paragraph),
        (["neue", "zeile"],           .newline),
        (["fragezeichen"],            .punctuation("?")),
        (["ausrufezeichen"],          .punctuation("!")),
        (["doppelpunkt"],             .punctuation(":")),
        (["semikolon"],               .punctuation(";")),
        (["strichpunkt"],             .punctuation(";")),
        (["punkt"],                   .punctuation(".")),
        // Ukrainian
        (["новий", "абзац"],          .paragraph),
        (["новий", "рядок"],          .newline),
        (["з", "нового", "рядка"],    .newline),
        (["знак", "питання"],         .punctuation("?")),
        (["знак", "оклику"],          .punctuation("!")),
        (["крапка", "з", "комою"],    .punctuation(";")),
        (["двокрапка"],               .punctuation(":")),
        (["крапка"],                  .punctuation(".")),
        (["кома"],                    .punctuation(",")),
        // English
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
    private static let ambiguous: Set<String> = [
        "period", "comma", "colon", "semicolon",
        "punt", "komma", "punkt", "крапка", "кома",
    ]
    /// Nouns need a sentence start after them to count as a terminator.
    private static let sentenceEnders: Set<String> = ["period", "punt", "punkt", "крапка"]
    private static let determiners: Set<String> = [
        "the", "a", "an", "this", "that", "each", "every", "one", "first", "second",
        "last", "next", "same", "long", "short", "of", "in", "per", "his", "her",
        "my", "your", "our", "their", "its", "no", "any", "some", "another", "which",
        "what", "trial", "grace", "time", "waiting", "rest", "orbital", "menstrual",
        // nl
        "de", "het", "een", "dit", "dat", "deze", "die", "elke", "elk", "geen", "mijn",
        "jouw", "zijn", "haar", "ons", "onze", "hun", "welke", "welk", "op", "van",
        // de
        "der", "die", "das", "ein", "eine", "einen", "einem", "einer", "dieser", "diese",
        "dieses", "diesen", "jeder", "jede", "jedes", "kein", "keine", "mein", "meine",
        "dein", "sein", "ihr", "unser", "welcher", "welche", "welches", "zum", "am",
        // uk
        "цей", "ця", "це", "цю", "той", "та", "те", "ту", "кожен", "кожна", "кожне",
        "мій", "моя", "твій", "наш", "наша", "їх", "який", "яка", "яке", "у", "в", "на",
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
                    if sentenceEnders.contains(entry.words[0]) {
                        // Any language's command may follow ("period new
                        // paragraph", "крапка новий рядок").
                        let nextIsCommand = next.map { nx in
                            commands.contains { $0.words.first == norm(nx) }
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
                case .scratch:
                    out = ""
                    capitalizeNext = false
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

    /// A passage that is nothing but a scratch command ("Scratch that.") —
    /// the caller removes the PREVIOUS passage instead of inserting anything.
    static func isScratchOnly(_ raw: String) -> Bool {
        let words = raw.lowercased()
            .split { !$0.isLetter }
            .map(String.init)
        guard !words.isEmpty, words.count <= 3 else { return false }
        return commands.contains { entry in
            if case .scratch = entry.command { return entry.words == words }
            return false
        }
    }

    // MARK: - Self-corrections

    /// Cue phrases that introduce a correction of what was just said.
    /// Matched after the recognizer's own punctuation is stripped; the cue
    /// must be set off by a comma/dash before it, or the words are just
    /// conversation ("no problem", "I mean it").
    private static let correctionCues: [[String]] = [
        ["no", "wait"], ["i", "mean"], ["no"], ["sorry"], ["actually"], ["rather"],
        ["nee"], ["ik", "bedoel"], ["ні"], ["тобто"], ["вибач"], ["nein"], ["ich", "meine"],
    ]

    private static let idiomTails: Set<String> = [
        "it", "that", "this", "them", "him", "her", "you", "me", "us", "so", "yes", "no",
        "really", "though", "then", "now", "het", "dat", "dit", "je", "це", "так",
    ]

    /// "send it Monday, no, Tuesday" → "send it Tuesday". The replacement is
    /// the words after the cue up to the next punctuation; the same number
    /// of words before the cue is dropped. Conservative: no cue, no change.
    static func applySelfCorrections(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { applySelfCorrectionsToLine(String($0)) }
            .joined(separator: "\n")
    }

    private static func applySelfCorrectionsToLine(_ line: String) -> String {
        var tokens = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard tokens.count >= 3 else { return line }
        func bare(_ t: String) -> String { t.lowercased().trimmingCharacters(in: .punctuationCharacters) }
        func endsClause(_ t: String) -> Bool { t.last.map { ",;:.!?—–-".contains($0) } ?? false }

        var i = 1
        var guardCount = 0
        while i < tokens.count, guardCount < 20 {
            guardCount += 1
            var matched = false
            for cue in correctionCues {
                let n = cue.count
                guard i + n < tokens.count, i >= 1 else { continue }
                guard tokens[i ..< i + n].map(bare) == cue else { continue }
                // The cue must follow a clause break ("Monday, no") and the
                // cue itself must end one ("no," / "no —") or be "I mean".
                let prevBreak = endsClause(tokens[i - 1])
                let cueBreak = endsClause(tokens[i + n - 1]) || cue == ["i", "mean"] || cue == ["ik", "bedoel"] || cue == ["ich", "meine"]
                guard prevBreak, cueBreak else { continue }
                // Replacement span: words after the cue until a clause end.
                var end = i + n
                while end < tokens.count {
                    end += 1
                    if endsClause(tokens[end - 1]) { break }
                }
                let replacement = Array(tokens[(i + n) ..< end])
                guard !replacement.isEmpty, replacement.count <= 6 else { continue }
                // "I mean it", "no, really": a lone function word after the
                // cue is idiom, not a correction.
                if replacement.count == 1, idiomTails.contains(bare(replacement[0])) { continue }
                // Drop the same number of words before the cue (not past the
                // start of the sentence).
                var start = i - 1
                var dropped = 1
                while dropped < replacement.count, start > 0, !endsClause(tokens[start - 1]) {
                    start -= 1
                    dropped += 1
                }
                // Carry the dropped span's trailing punctuation onto the
                // replacement's last word if the replacement has none.
                var repl = replacement
                let droppedPunct = trailingPunctuation(tokens[i - 1][...])
                if trailingPunctuation(repl[repl.count - 1][...]).isEmpty,
                   !droppedPunct.isEmpty, droppedPunct != "," {
                    repl[repl.count - 1] += droppedPunct
                }
                // Keep sentence-initial capitalization if the dropped span
                // started the sentence.
                if start == 0 || endsClause(tokens[start - 1]),
                   let first = tokens[start].first, first.isUppercase,
                   let rf = repl[0].first, rf.isLowercase {
                    repl[0] = rf.uppercased() + repl[0].dropFirst()
                }
                tokens.replaceSubrange(start ..< end, with: repl)
                i = start + repl.count
                matched = true
                break
            }
            if !matched { i += 1 }
        }
        return tokens.joined(separator: " ")
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
    ///
    /// `preceding` is what sits left of the caret in the target (read through
    /// the Accessibility API; nil when the app doesn't expose it). In `.auto`
    /// mode it decides the join: a space only when the caret follows a word or
    /// punctuation, a capital only at a sentence start. Without context,
    /// `.auto` behaves like `.trailingSpace`.
    static func forInsertion(
        _ text: String,
        spacing: DictationSettings.Spacing,
        preceding: String? = nil
    ) -> String {
        switch spacing {
        case .trailingSpace: return text.hasSuffix("\n") ? text : text + " "
        case .leadingSpace:  return " " + text
        case .none:          return text
        case .auto:
            guard let preceding else {
                return text.hasSuffix("\n") ? text : text + " "
            }
            var out = text
            let trimmed = preceding.trimmingCharacters(in: .whitespacesAndNewlines)
            let atSentenceStart = trimmed.isEmpty
                || preceding.hasSuffix("\n")
                || trimmed.last.map { ".?!…".contains($0) } == true
            if atSentenceStart, let first = out.first, first.isLowercase {
                out = first.uppercased() + out.dropFirst()
            }
            if let last = preceding.last, !last.isWhitespace, !last.isNewline,
               let first = out.first, !first.isPunctuation {
                out = " " + out
            }
            return out
        }
    }

    // MARK: - Polish guard

    /// The polish step must only ever return the same passage, cleaned. A
    /// small model sometimes answers the text, summarizes, or echoes the
    /// instructions — reject those and keep the deterministic output.
    static func acceptPolished(raw: String, polished: String, minOverlap: Double = 0.75) -> Bool {
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
        return Double(lcs) / Double(min(rawWords.count, polWords.count)) >= minOverlap
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
