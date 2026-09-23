import Foundation

/// Text-level guards against the defects a Whisper-anchored run shows on
/// real meetings — measured on Ukrainian split-track recordings, where one
/// track is near-silent whenever the other side talks:
///   - PHANTOMS: on silence Whisper emits a stock closing line ("Дякую.",
///     "Дякую за перегляд!") learned from subtitle data, while Parakeet
///     returns nothing or a stray number ("100"). 30 of 44 "hard conflicts"
///     in one day's log were exactly this pair, each costing a Gemma call
///     and leaving a fake "Дякую." in the transcript.
///   - SEAMS: chunks share a 1 s recap, so the word spoken across a boundary
///     is transcribed by both chunks ("…дивувати." / "дивувати. І от…").
enum TranscriptHygiene {

    static func normWords(_ text: String) -> [String] {
        text.lowercased()
            .split(whereSeparator: { !($0.isLetter || $0.isNumber || $0 == "'" || $0 == "’" || $0 == "ʼ") })
            .map { $0.filter { $0.isLetter || $0.isNumber } }
            .filter { !$0.isEmpty }
    }

    // MARK: - Phantom phrases

    /// Stock lines Whisper produces from silence/noise, as normalized word
    /// sequences. Every one of them is also something a person can really
    /// say, so a match alone never deletes text — callers need a second
    /// signal (the other engine heard nothing, or Whisper's own no-speech /
    /// log-prob scores are poor).
    private static let phantomPhrases: [[String]] = [
        // Ukrainian
        ["дякую", "за", "перегляд"], ["дякую", "за", "увагу"], ["дякуємо", "за", "перегляд"],
        ["дякую", "вам", "за", "перегляд"], ["дякую", "що", "дивитесь"], ["дякую", "за", "підписку"],
        ["до", "зустрічі"], ["до", "побачення"], ["дякую"], ["дякуємо"],
        ["субтитри"], ["продовження", "слідує"], ["далі", "буде"],
        // English
        ["thank", "you"], ["thanks", "for", "watching"], ["thank", "you", "for", "watching"],
        ["thank", "you", "very", "much"],
        ["subtitles", "by", "the", "amaraorg", "community"],
        // Dutch
        ["bedankt", "voor", "het", "kijken"], ["dank", "u", "wel"], ["ondertitels", "ingediend", "door", "de", "amaraorg", "gemeenschap"],
        // German / French / Spanish / Polish
        ["vielen", "dank"], ["untertitel", "der", "amaraorg", "community"],
        ["merci"], ["merci", "davoir", "regardé", "cette", "vidéo"],
        ["gracias"], ["gracias", "por", "ver", "el", "video"],
        ["dziękuję"], ["dziękuję", "za", "uwagę"], ["napisy", "stworzone", "przez", "społeczność", "amaraorg"],
    ]

    /// One-word turns Whisper also loops on in silence ("Угу, угу, угу").
    /// Real far more often than the lines above, so they only ever count as
    /// phantoms against an engine that heard NOTHING.
    private static let backchannels: Set<String> = ["угу", "ага", "bye", "you", "okay", "ok", "mhm"]

    private static let phrasesLongestFirst = phantomPhrases.sorted { $0.count > $1.count }

    /// Subtitle sign-offs. Unlike "Дякую", nobody says these in a meeting or
    /// a dictation — they exist only in the subtitle files Whisper learned
    /// from — so a segment that is nothing else is dropped on sight.
    private static let outroPhrases: [[String]] = phantomPhrases.filter {
        $0.contains("перегляд") || $0.contains("watching") || $0.contains("amaraorg")
            || $0.contains("підписку") || $0.contains("дивитесь") || $0.contains("kijken")
            || $0 == ["продовження", "слідує"] || $0 == ["субтитри"]
            || $0.contains("regardé") || $0 == ["gracias", "por", "ver", "el", "video"]
    }

    static func isOutroOnly(_ text: String) -> Bool {
        consists(of: outroPhrases.sorted { $0.count > $1.count }, normWords(text))
    }

    /// `words` is a non-empty concatenation of phrases from `table`
    /// (longest first, so "дякую за перегляд" isn't read as "дякую" + two
    /// unexplained words).
    private static func consists(of table: [[String]], _ words: [String]) -> Bool {
        guard !words.isEmpty, words.count <= 14 else { return false }
        var i = 0
        outer: while i < words.count {
            for p in table where i + p.count <= words.count && Array(words[i..<(i + p.count)]) == p {
                i += p.count
                continue outer
            }
            return false
        }
        return true
    }

    static func isBackchannelOnly(_ text: String) -> Bool {
        let words = normWords(text)
        return !words.isEmpty && words.count <= 14 && words.allSatisfy(backchannels.contains)
    }

    /// True when `text` is nothing but phantom phrases (possibly repeated:
    /// "Дякую. Дякую."). Empty text is not a phantom — it is just empty.
    static func isPhantomOnly(_ text: String) -> Bool {
        consists(of: phrasesLongestFirst, normWords(text)) || isBackchannelOnly(text)
    }

    /// What an acoustic engine "hears" in silence: nothing, or a lone number
    /// / one stray short token (Parakeet's "100").
    static func isEffectivelySilent(_ text: String) -> Bool {
        let words = normWords(text)
        if words.isEmpty { return true }
        if words.count == 1, let w = words.first {
            return w.allSatisfy(\.isNumber) || w.count <= 2
        }
        return false
    }

    /// Cross-engine ruling on a chunk where exactly ONE engine produced only
    /// a stock phantom line. nil = not that situation, merge as usual.
    ///   - other engine heard nothing            → silence, ""
    ///   - other engine echoes the line ("дякую вам") → real speech, nil
    ///   - other engine heard ≥ 3 different words → its text; the phantom was
    ///     Whisper giving up on quiet speech ("Дякую." vs "Логіку шукає, логіку")
    ///   - other engine heard 1–2 stray words    → crosstalk residue, ""
    /// Two engines both saying "Дякую" never reaches this — that is speech.
    static func phantomResolution(_ a: String, _ b: String) -> String? {
        let pa = isPhantomOnly(a), pb = isPhantomOnly(b)
        guard pa != pb else { return nil }
        let phantom = pa ? a : b, other = pa ? b : a
        if isEffectivelySilent(other) { return "" }
        // "Okay." against "Right." is two engines hearing one short real
        // turn differently — not a phantom. Merge as usual.
        if isBackchannelOnly(phantom) { return nil }
        let otherWords = normWords(other)
        if !Set(normWords(phantom)).isDisjoint(with: otherWords) { return nil }
        return otherWords.count >= 3 ? other.trimmingCharacters(in: .whitespacesAndNewlines) : ""
    }

    // MARK: - Script drift

    /// Whisper sometimes slides from Ukrainian into a neighbouring Cyrillic
    /// language for a segment. These letters do not exist in the Ukrainian
    /// alphabet, so their share of a segment is a cheap, reliable drift tell.
    static func nonUkrainianCyrillicShare(_ text: String) -> Double {
        let letters = text.lowercased().filter(\.isLetter)
        guard letters.count >= 12 else { return 0 }
        let foreign = letters.filter { "ыэъё".contains($0) }.count
        return Double(foreign) / Double(letters.count)
    }

    // MARK: - Chunk seams

    /// Remove from the head of `next` the words that merely repeat the tail
    /// of `previous` — the 1 s recap both chunks transcribed. Conservative:
    /// at most 6 words, and a single repeated word must be ≥ 4 letters so a
    /// genuine "так, так" / "ні. Ні" across a boundary survives.
    static func trimSeamRepeat(previous: String, next: String) -> String {
        let prev = normWords(previous)
        let pieces = next.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard !prev.isEmpty, pieces.count > 1 else { return next }
        // Norm words of the first few pieces, each remembering its piece: a
        // hyphenated piece ("Пост-делівері,") is two words but one piece.
        var head: [(word: String, piece: Int)] = []
        for (i, piece) in pieces.prefix(6).enumerated() {
            for w in normWords(piece) { head.append((w, i)) }
        }
        var best = 0   // number of PIECES to drop
        for k in stride(from: min(8, head.count, prev.count), through: 1, by: -1) {
            guard Array(prev.suffix(k)) == head.prefix(k).map(\.word) else { continue }
            // The match must end on a piece boundary.
            if k < head.count, head[k].piece == head[k - 1].piece { continue }
            if k == 1, head[0].word.count < 4 { continue }
            best = head[k - 1].piece + 1
            break
        }
        guard best > 0, best < pieces.count else { return next }
        return pieces.dropFirst(best).joined(separator: " ")
    }

    // MARK: - Vocabulary spellings

    /// The user's vocabulary with its casing (global + the run's languages).
    static func vocabularyTerms(languages: Set<String>) -> [String] {
        let d = UserDefaults.standard
        var raw = d.string(forKey: "prompt.vocabulary") ?? ""
        if let js = d.string(forKey: "prompt.vocabulary.byLang"),
           let map = try? JSONDecoder().decode([String: String].self, from: Data(js.utf8)) {
            for lang in languages { raw += "," + (map[lang] ?? "") }
        }
        var seen = Set<String>()
        return raw.split(whereSeparator: { $0 == "," || $0.isNewline })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    /// Put the user's own spelling on names the engines wrote differently.
    /// The word vote only consults the vocabulary where the two engines
    /// DISAGREE; when both write "Kim Kim" (49 times in this user's
    /// library), nothing downstream ever sees it. Deterministic and narrow —
    /// a sound-alike match on its own rewrote "this" into "Thomas" and
    /// "like" into "Alex" in a dry run over the library, so:
    ///   - JOINED: 2-3 tokens separated by a single space whose letters,
    ///     concatenated, are exactly a multi-letter term ("Kim Kim" →
    ///     "KimKim", "Web RTC" → "WebRTC"). The letters must match exactly,
    ///     so this never changes what was heard, only how it is written.
    ///   - NEAR MISS: one capitalized token of ≥ 4 letters, in the term's
    ///     script and starting with the term's letter, that is not a
    ///     dictionary word (as written — "Indian" is one, "indian" is not)
    ///     and not itself a term, whose sound skeleton is as long as exactly
    ///     ONE coined term's and differs in one place ("Kinkim" → "KimKim").
    ///     Ties ("Blitzy": "Blits"/"Blitsy") change nothing, and neither do
    ///     the term's own inflections or possessive ("Нідерландах",
    ///     "MasterCard's"). Measured over the library before these guards:
    ///     "LinkedIn" → "London", "Europhone" → "Grafana".
    static func applyVocabulary(
        _ text: String, terms: [String],
        isDictionaryWord: (String) -> Bool = { MeetingBriefBuilder.isDictionaryWord($0, asWritten: true) }
    ) -> String {
        guard !terms.isEmpty, !text.isEmpty else { return text }
        let termSet = Set(terms.map { $0.lowercased() })
        func letters(_ s: String) -> String { s.lowercased().filter { $0.isLetter || $0.isNumber } }
        // Terms written as one token ("KimKim", "WebRTC", "LLMs4EU").
        var joinable: [String: String] = [:]
        for t in terms where !t.contains(" ") && letters(t).count >= 4 { joinable[letters(t)] = t }
        // Near-miss targets are coined terms only (KimKim, LLMs4EU, Kaiko).
        // A term that is itself a word or a common name ("Victor",
        // "Nicole") would pull in different people — "Victoria", "Nicola".
        // An inner capital or a digit makes a term coined by construction —
        // and the spell checker waves such words through ("KimKim",
        // "LLMs4EU" both "pass"), so it cannot be asked.
        let coined = { (t: String) in t.dropFirst().contains { $0.isUppercase || $0.isNumber } }
        let nearTargets = terms.filter {
            !$0.contains(" ") && MeetingBriefBuilder.skeleton($0).count >= 4 && (coined($0) || !isDictionaryWord($0))
        }

        // Tokens keep their exact surrounding text so rewriting is lossless.
        let ns = text as NSString
        guard let re = try? NSRegularExpression(pattern: "[\\p{L}\\p{N}]+(?:['’ʼ][\\p{L}\\p{N}]+)*") else { return text }
        let tokens = re.matches(in: text, range: NSRange(location: 0, length: ns.length)).map(\.range)
        guard !tokens.isEmpty else { return text }
        var out = ""
        var cursor = 0
        var i = 0
        while i < tokens.count {
            let r = tokens[i]
            // JOINED: longest run first.
            var joined: (count: Int, term: String)?
            for n in stride(from: 3, through: 2, by: -1) where i + n <= tokens.count {
                let run = tokens[i..<(i + n)]
                let spaced = zip(run, run.dropFirst()).allSatisfy { a, b in
                    ns.substring(with: NSRange(location: a.upperBound, length: b.location - a.upperBound)) == " "
                }
                guard spaced else { continue }
                let key = run.map { letters(ns.substring(with: $0)) }.joined()
                if let term = joinable[key] { joined = (n, term); break }
            }
            if var j = joined {
                // The word vote can keep BOTH engines' forms side by side
                // ("Kim Kim KimKim" — one engine split the name, the other
                // did not). The spelled-out copy is the same word: keep one.
                let after = i + j.count
                if after < tokens.count,
                   ns.substring(with: tokens[after]) == j.term,
                   ns.substring(with: NSRange(location: tokens[after - 1].upperBound,
                                              length: tokens[after].location - tokens[after - 1].upperBound)) == " " {
                    j.count += 1
                }
                let last = tokens[i + j.count - 1]
                out += ns.substring(with: NSRange(location: cursor, length: r.location - cursor)) + j.term
                cursor = last.upperBound
                AppLog.info("vocab", "joined \"\(ns.substring(with: NSRange(location: r.location, length: last.upperBound - r.location)))\" → \(j.term)")
                i += j.count
                continue
            }
            let word = ns.substring(with: r)
            if let fix = nearMissTerm(for: word, targets: nearTargets, termSet: termSet, isDictionaryWord: isDictionaryWord) {
                out += ns.substring(with: NSRange(location: cursor, length: r.location - cursor)) + fix
                cursor = r.upperBound
                AppLog.info("vocab", "respelled \"\(word)\" → \(fix)")
            }
            i += 1
        }
        out += ns.substring(from: cursor)
        return out
    }

    private static func nearMissTerm(
        for word: String, targets: [String], termSet: Set<String>,
        isDictionaryWord: (String) -> Bool
    ) -> String? {
        guard word.count >= 4, word.first?.isUppercase == true,
              !termSet.contains(word.lowercased()) else { return nil }
        let cyrillic = { (s: String) in s.unicodeScalars.contains { (0x400...0x52F).contains($0.value) } }
        let key = Array(MeetingBriefBuilder.skeleton(word))
        guard key.count >= 4 else { return nil }
        let lower = Array(word.lowercased())
        var best: [String] = []
        var bestDistance = Int.max
        for t in targets where cyrillic(t) == cyrillic(word) {
            let tl = Array(t.lowercased())
            guard tl.first == lower.first else { continue }
            // An inflection or possessive of the term is the term, used right.
            let shared = zip(lower, tl).prefix { $0 == $1 }.count
            guard shared < tl.count - 2 else { continue }
            let tk = Array(MeetingBriefBuilder.skeleton(t))
            guard tk.count == key.count else { continue }
            let d = MeetingBriefBuilder.editDistance(key, tk)
            guard d <= 1 else { continue }
            // Break skeleton ties on the spelled letters.
            let spelled = MeetingBriefBuilder.editDistance(Array(word.lowercased()), Array(t.lowercased()))
            let score = d * 100 + spelled
            if score < bestDistance { bestDistance = score; best = [t] }
            else if score == bestDistance { best.append(t) }
        }
        guard best.count == 1, let term = best.first, term != word else { return nil }
        // Last, because it is the slow check (system spell checker).
        return isDictionaryWord(word) ? nil : term
    }
}
