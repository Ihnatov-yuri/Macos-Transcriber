import Foundation
import CryptoKit
import AppKit

/// What one whole-transcript read tells Gemma about a recording.
///
/// Gemma READS long input well (a 40k-char Ukrainian meeting in one call,
/// under a minute) and WRITES long output badly — which is why rewrites run
/// in 2.6k-char windows. Those windows, and the Super arbitration, used to
/// know nothing about the meeting they belonged to: not who was speaking,
/// not the topic, not that "Мьюз" had been settled as "Muse" half an hour
/// earlier. The brief is that knowledge, produced once and handed to every
/// later call: small output, rich input.
struct MeetingBrief: Codable, Equatable, Sendable {
    struct Fix: Codable, Equatable, Sendable {
        var from: String
        var to: String
    }
    var topic: String = ""
    var people: [String] = []
    var terms: [String] = []
    /// Spelling unifications the model proposed AND the guards accepted.
    var fixes: [Fix] = []

    var isEmpty: Bool { topic.isEmpty && people.isEmpty && terms.isEmpty && fixes.isEmpty }

    /// The block prepended to a rewrite window or an arbitration.
    var promptBlock: String {
        var lines: [String] = []
        if !topic.isEmpty { lines.append("Topic: \(topic)") }
        if !people.isEmpty { lines.append("People: \(people.joined(separator: "; "))") }
        if !terms.isEmpty { lines.append("Names and terms as spelled in this recording: \(terms.joined(separator: "; "))") }
        guard !lines.isEmpty else { return "" }
        return "Recording brief (background ONLY — never output or mention it):\n"
            + lines.joined(separator: "\n") + "\n\n"
    }
}

enum MeetingBriefBuilder {

    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: "ui.meetingBrief") as? Bool ?? true
    }

    // MARK: - Build

    /// Tokens of transcript per read. The engine window is 32k, but what
    /// the LiteRT stack handles RELIABLY is far smaller — measured on a
    /// 72-minute Ukrainian meeting (17k tokens):
    ///   - one 17k read: 109 s, answer in the wrong language, a "FIX: чу"
    ///     loop to the token limit;
    ///   - 6k reads: wedged LiteRT's native call 5 runs out of 6;
    ///   - 3k reads: 6 sections in 47 s, stable, the best brief of the three.
    /// A long recording is therefore read in sections and merged.
    static var inputTokenBudget: Int {
        ProcessInfo.processInfo.environment["TRANSCRIBERR_BRIEF_TOKENS"].flatMap(Int.init) ?? 3_000
    }
    static let maxOutputTokens = 450

    /// Rough token count: Cyrillic/Arabic cost about twice what Latin does.
    static func estimatedTokens(_ text: String) -> Int {
        var latin = 0, other = 0
        for u in text.unicodeScalars { if u.value < 0x250 { latin += 1 } else { other += 1 } }
        return latin / 4 + other * 10 / 22 + 1
    }

    /// Split on line boundaries into sections that each fit the budget.
    static func sections(_ transcript: String, tokenBudget: Int = inputTokenBudget) -> [String] {
        guard estimatedTokens(transcript) > tokenBudget else { return [transcript] }
        var out: [String] = [], cur = "", curTokens = 0
        for line in transcript.split(separator: "\n", omittingEmptySubsequences: true) {
            // A single over-budget line (undiarized wall of text) is cut hard.
            var rest = Substring(line)
            while !rest.isEmpty {
                var piece = rest.prefix(tokenBudget * 2)
                // Cut at a word boundary so no name is split across reads.
                if piece.count < rest.count, let space = piece.lastIndex(where: \.isWhitespace),
                   space > piece.startIndex {
                    piece = rest[..<space]
                }
                rest = rest.dropFirst(piece.count)
                let t = estimatedTokens(String(piece))
                if curTokens + t > tokenBudget, !cur.isEmpty {
                    out.append(cur); cur = ""; curTokens = 0
                }
                cur += (cur.isEmpty ? "" : "\n") + piece
                curTokens += t
            }
        }
        if !cur.isEmpty { out.append(cur) }
        return out
    }

    /// Wall-clock budget for a whole build: healthy sections take ~8 s, so
    /// this only fires on a wedge, however long the recording.
    static func buildTimeout(transcript: String) -> TimeInterval {
        60 + 30 * Double(sections(transcript).count)
    }

    static let systemPrompt = """
    You read an automatic speech-recognition transcript and extract facts that help correct it. You never rewrite the transcript. Answer in EXACTLY this format, one item per line, nothing else:
    TOPIC: <one sentence, in the transcript's language>
    PEOPLE: <name — role if stated; separated by ";">
    TERMS: <ONLY proper names (companies, products, places) and foreign-language or technical terms, spelled the way they should be written; never ordinary words; separated by ";">
    FIX: <wrong spelling found in the transcript> => <correct spelling>
    Rules for FIX lines (at most 15):
    - Only for a NAME or TERM that the recognizer misspelled or spelled inconsistently, including an English name or term written phonetically in another alphabet.
    - The left side must be copied exactly from the transcript. The right side must sound the same.
    - Never fix ordinary words, grammar, or style. If unsure, leave it out.
    """

    static func userMessage(section: String, vocabulary: String) -> String {
        // The vocabulary is NOT shown to the model: given the list, it copied
        // the first entries back as this recording's "terms". It still
        // attests replacements in the guards.
        "TRANSCRIPT:\n" + section
    }

    /// One read per section, merged. Throws only when EVERY section failed;
    /// the caller treats any failure as "no brief" and carries on.
    static func build(
        transcript: String,
        vocabulary: String,
        generate: (_ system: String, _ user: String, _ maxTokens: Int) async throws -> String
    ) async throws -> MeetingBrief {
        var merged = MeetingBrief()
        var lastError: Error?
        let parts = sections(transcript)
        for (i, section) in parts.enumerated() {
            // A timed-out or cancelled build must stop issuing reads: the
            // caller moves on to arbitration on the same engine.
            try Task.checkCancellation()
            do {
                let raw = try await generate(
                    systemPrompt, userMessage(section: section, vocabulary: vocabulary), maxOutputTokens)
                merge(attested(parse(raw), in: section), into: &merged)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = error
                AppLog.warn("brief", "section \(i + 1)/\(parts.count) failed: \(error.localizedDescription)")
                // A timeout means the engine is wedged; more calls would
                // only queue behind it.
                if case ASRError.chunkTimeout = error { break }
            }
        }
        if merged.isEmpty, let lastError { throw lastError }
        merged.fixes = acceptedFixes(merged.fixes, transcript: transcript, vocabulary: vocabulary, terms: merged.terms)
        AppLog.info("brief", "brief: \(merged.people.count) people, \(merged.terms.count) terms, \(merged.fixes.count) fixes — \(merged.fixes.map { "\($0.from)→\($0.to)" }.joined(separator: ", "))")
        return merged
    }

    /// Keep only people and terms that literally occur in the text the
    /// model read. Anything else is recall from training data or the prompt.
    static func attested(_ brief: MeetingBrief, in text: String) -> MeetingBrief {
        var b = brief
        // …and a term must LOOK like one: asked for names, the model also
        // lists the nouns of the conversation ("батареї; вікна; балкон").
        b.terms = b.terms.filter { term in
            let nameLike = term.first?.isUppercase == true
                || term.unicodeScalars.contains { $0.value < 0x250 && CharacterSet.letters.contains($0) }
                || term.contains(where: \.isNumber)
            return nameLike && occurrences(of: term, in: text) > 0
        }
        b.people = b.people.filter { person in
            let name = person.split(whereSeparator: { "—–-(,".contains($0) }).first
                .map { $0.trimmingCharacters(in: .whitespaces) } ?? person
            // Diarizer placeholders are labels, not people.
            let isLabel = name.range(of: #"^(speaker|спікер)[\s_]*\d+$"#,
                                     options: [.regularExpression, .caseInsensitive]) != nil
            return !name.isEmpty && !isLabel && occurrences(of: name, in: text) > 0
        }
        return b
    }

    static func merge(_ b: MeetingBrief, into a: inout MeetingBrief) {
        // Sections of a long recording have their own subjects; the opening
        // small talk must not stand for the whole meeting.
        // Two subjects at most: the block rides on every later prompt.
        let subjects = a.topic.isEmpty ? 0 : a.topic.components(separatedBy: " / ").count
        if !b.topic.isEmpty, subjects < 2, a.topic.count + b.topic.count < 300 {
            a.topic += (a.topic.isEmpty ? "" : " / ") + b.topic
        }
        func union(_ x: [String], _ y: [String], cap: Int) -> [String] {
            var seen = Set(x.map { $0.lowercased() }), out = x
            for v in y where seen.insert(v.lowercased()).inserted { out.append(v) }
            return Array(out.prefix(cap))
        }
        a.people = union(a.people, b.people, cap: 12)
        a.terms = union(a.terms, b.terms, cap: 40)
        for f in b.fixes where !a.fixes.contains(where: { $0.from.lowercased() == f.from.lowercased() }) {
            a.fixes.append(f)
        }
    }

    // MARK: - Parse

    /// Line-based and forgiving: a small model drifts from JSON far more
    /// often than from "KEY: value". Unknown lines are ignored.
    static func parse(_ raw: String) -> MeetingBrief {
        var brief = MeetingBrief()
        func list(_ s: String) -> [String] {
            s.split(whereSeparator: { $0 == ";" || $0 == "\n" })
                .map { clean(String($0)) }
                .filter { !$0.isEmpty && $0.count <= 80 && !isPlaceholder($0) }
        }
        var previousLine = "", repeats = 0
        for line in raw.split(separator: "\n") {
            // A small model that runs out of things to say loops on its last
            // line; everything from the second repeat on is noise.
            repeats = line == previousLine ? repeats + 1 : 0
            previousLine = String(line)
            if repeats >= 2 { break }
            let l = line.trimmingCharacters(in: CharacterSet(charactersIn: " \t-*•#"))
            guard let colon = l.firstIndex(of: ":") else { continue }
            let key = l[..<colon].trimmingCharacters(in: CharacterSet(charactersIn: " *_")).uppercased()
            let value = String(l[l.index(after: colon)...])
            switch key {
            case "TOPIC":
                let t = clean(value)
                if brief.topic.isEmpty, !isPlaceholder(t) { brief.topic = String(t.prefix(240)) }
            case "PEOPLE": brief.people += list(value)
            case "TERMS":  brief.terms += list(value)
            case "FIX":
                guard let arrow = value.range(of: "=>") ?? value.range(of: "→") ?? value.range(of: "->")
                else { continue }
                let from = clean(String(value[..<arrow.lowerBound]))
                let to = clean(String(value[arrow.upperBound...]))
                if !from.isEmpty, !to.isEmpty { brief.fixes.append(.init(from: from, to: to)) }
            default: continue
            }
        }
        brief.people = Array(brief.people.prefix(12))
        brief.terms = Array(brief.terms.prefix(40))
        return brief
    }

    private static func clean(_ s: String) -> String {
        s.trimmingCharacters(in: CharacterSet(charactersIn: " \t\"'«»“”`*_.,<>"))
    }

    private static func isPlaceholder(_ s: String) -> Bool {
        let l = s.lowercased()
        return ["none", "n/a", "unknown", "not stated", "немає", "невідомо", "-", "—"].contains(l)
    }

    // MARK: - Fix guards

    /// A proposed fix edits the user's text, so the model's word is not
    /// enough. Every accepted fix must:
    ///   - be short (≤ 4 words a side) and actually change something;
    ///   - name a `from` that occurs in the transcript as whole words;
    ///   - SOUND like its replacement (consonant skeleton after a loose
    ///     Cyrillic→Latin fold) — this is what stops "Muse → Mews PMS" or a
    ///     "correction" of one ordinary word into another;
    ///   - replace it with an ATTESTED spelling: one the model also listed
    ///     under TERMS, one from the user's vocabulary, or one that already
    ///     occurs in the transcript — a bare transliteration of an ordinary
    ///     word ("так → tak") is none of these;
    ///   - not be a real word: anything the system spell checker knows in
    ///     Ukrainian, English, Dutch, German or Polish is left alone unless
    ///     it is used as a name ("менеджер" stays; "хаускіпінг", "онершіп",
    ///     "Мьюз" are not words in any dictionary);
    ///   - not touch a common word: a lowercase `from` must be term-sized
    ///     (≥ 6 letters) and rare (≤ 6 occurrences), and `from` must be capitalized, non-native
    ///     script, or rare (≤ 6 occurrences) — and must not itself be one of
    ///     the user's authoritative spellings.
    static func acceptedFixes(
        _ fixes: [MeetingBrief.Fix], transcript: String, vocabulary: String, terms: [String] = [],
        isDictionaryWord: (String) -> Bool = { MeetingBriefBuilder.isDictionaryWord($0) }
    ) -> [MeetingBrief.Fix] {
        let attested = Set(terms.map { $0.lowercased() })
        let vocab = Set(vocabulary.split(whereSeparator: { $0 == "," || $0.isNewline })
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() })
        var out: [MeetingBrief.Fix] = []
        for f in fixes.prefix(30) {
            let fromWords = f.from.split(separator: " "), toWords = f.to.split(separator: " ")
            guard (1...4).contains(fromWords.count), (1...4).contains(toWords.count),
                  f.from.count >= 3, f.to.count >= 2,
                  f.from != f.to,
                  !vocab.contains(f.from.lowercased())
            else { reject(f, "shape"); continue }
            let hits = occurrences(of: f.from, in: transcript)
            guard hits > 0 else { reject(f, "not in transcript"); continue }
            guard soundsAlike(f.from, f.to) else { reject(f, "does not sound alike"); continue }
            guard attested.contains(f.to.lowercased()) || vocab.contains(f.to.lowercased())
                    || occurrences(of: f.to, in: transcript) > 0
            else { reject(f, "replacement not attested"); continue }
            // "Capitalized" must mean a NAME, not a word that happened to open
            // a sentence: replacement is case-insensitive, so most of its
            // occurrences have to carry the capital.
            let capitalHits = occurrences(of: f.from, in: transcript, caseSensitive: true)
            let capitalized = f.from.first?.isUppercase == true && capitalHits * 2 > hits
            guard capitalized || f.from.count >= 6 else { reject(f, "short lowercase word"); continue }
            guard capitalized || !fromWords.allSatisfy({ isDictionaryWord(String($0)) })
            else { reject(f, "dictionary word"); continue }
            guard capitalized || hits <= 6 else { reject(f, "common word (\(hits)×)"); continue }
            // No chains, either way round: a replacement that another fix
            // would rewrite again, or a fix of what another fix just wrote
            // ("Мьюз → Muse" then "Muse → Mews" turned every Мьюз into Mews).
            guard !out.contains(where: {
                $0.from.lowercased() == f.to.lowercased() || $0.to.lowercased() == f.from.lowercased()
            }) else { reject(f, "chain"); continue }
            out.append(f)
            if out.count == 15 { break }
        }
        return out
    }

    private static let dictionaryLanguages: [String] = {
        let wanted: Set<String> = ["uk", "en", "nl", "de", "pl"]
        return NSSpellChecker.shared.availableLanguages.filter { wanted.contains($0) }
    }()

    /// Known to the system spell checker in any of the app's languages.
    /// Lowercased by default; `asWritten` also accepts proper nouns, which
    /// the checker only knows capitalized ("indian" fails, "Indian" passes).
    static func isDictionaryWord(_ word: String, asWritten: Bool = false) -> Bool {
        // NSSpellChecker is AppKit: main thread only. Callers sit on an
        // actor or a detached task; the main thread is never blocked on
        // them (they are awaited), so a sync hop cannot deadlock.
        if !Thread.isMainThread {
            return DispatchQueue.main.sync { isDictionaryWord(word, asWritten: asWritten) }
        }
        if asWritten, word != word.lowercased(), isDictionaryWord(word) { return true }
        let checker = NSSpellChecker.shared
        let w = asWritten ? word : word.lowercased()
        // A checker passes any word outside its own script as "no error",
        // so only ask the dictionaries that could know the word.
        let cyrillic = w.unicodeScalars.contains { (0x400...0x52F).contains($0.value) }
        return dictionaryLanguages.filter { ($0 == "uk") == cyrillic }.contains { lang in
            checker.checkSpelling(of: w, startingAt: 0, language: lang, wrap: false,
                                  inSpellDocumentWithTag: 0, wordCount: nil).location == NSNotFound
        }
    }

    private static func reject(_ f: MeetingBrief.Fix, _ why: String) {
        AppLog.info("brief", "fix rejected (\(why)): \(f.from) → \(f.to)")
    }

    private static func wholeWordRegex(_ phrase: String, caseSensitive: Bool = false) -> NSRegularExpression? {
        let escaped = NSRegularExpression.escapedPattern(for: phrase)
        return try? NSRegularExpression(
            pattern: "(?<![\\p{L}\\p{N}])\(escaped)(?![\\p{L}\\p{N}])",
            options: caseSensitive ? [] : [.caseInsensitive])
    }

    static func occurrences(of phrase: String, in text: String, caseSensitive: Bool = false) -> Int {
        guard let re = wholeWordRegex(phrase, caseSensitive: caseSensitive) else { return 0 }
        return re.numberOfMatches(in: text, range: NSRange(text.startIndex..., in: text))
    }

    /// Apply accepted fixes as whole-word replacements. Longest `from` first
    /// so "Лоджик Монітор" wins over "Монітор".
    static func apply(_ fixes: [MeetingBrief.Fix], to text: String) -> String {
        var out = text
        for f in fixes.sorted(by: { $0.from.count > $1.from.count }) {
            guard let re = wholeWordRegex(f.from) else { continue }
            out = re.stringByReplacingMatches(
                in: out, range: NSRange(out.startIndex..., in: out),
                withTemplate: NSRegularExpression.escapedTemplate(for: f.to))
        }
        return out
    }

    // MARK: - Sounds-alike

    private static let fold: [Character: String] = [
        "а": "a", "б": "b", "в": "v", "г": "g", "ґ": "g", "д": "d", "е": "e", "є": "e", "ж": "j",
        "з": "s", "и": "i", "і": "i", "ї": "i", "й": "i", "к": "k", "л": "l", "м": "m", "н": "n",
        "о": "o", "п": "p", "р": "r", "с": "s", "т": "t", "у": "u", "ф": "f", "х": "h", "ц": "s",
        "ч": "c", "ш": "s", "щ": "s", "ь": "", "ю": "u", "я": "a", "'": "", "’": "", "ʼ": "",
    ]

    /// Loose phonetic key: fold Cyrillic to Latin, merge sound-alike
    /// consonants, drop vowels and doubled letters.
    static func skeleton(_ s: String) -> String {
        var latin = ""
        for ch in s.lowercased() {
            if let m = fold[ch] { latin += m } else if ch.isLetter || ch.isNumber { latin.append(ch) }
        }
        for (a, b) in [("ph", "f"), ("ck", "k"), ("sch", "s"), ("sh", "s"), ("ch", "c"), ("th", "t"),
                       ("kh", "h"), ("zh", "j"), ("ts", "s"), ("x", "ks"), ("q", "k"), ("w", "v"),
                       ("z", "s"), ("c", "k"), ("y", "i")] {
            latin = latin.replacingOccurrences(of: a, with: b)
        }
        var out = ""
        for ch in latin where !"aeiouh".contains(ch) {
            if out.last != ch { out.append(ch) }
        }
        return out
    }

    static func soundsAlike(_ a: String, _ b: String) -> Bool {
        let ka = Array(skeleton(a)), kb = Array(skeleton(b))
        guard ka.count >= 2, kb.count >= 2 else { return false }
        let longest = max(ka.count, kb.count)
        let d = editDistance(ka, kb)
        // One slip allowed on short keys, a quarter of the key on long ones.
        return d <= max(1, longest / 4) && d < longest
    }

    static func editDistance(_ a: [Character], _ b: [Character]) -> Int {
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var prev = Array(0...b.count)
        for i in 1...a.count {
            var cur = [i] + Array(repeating: 0, count: b.count)
            for j in 1...b.count {
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            prev = cur
        }
        return prev[b.count]
    }

    // MARK: - Cache

    /// Keyed by the transcript's content: a re-run or an edit is a different
    /// key, and every preset on the same transcript shares one brief.
    static func cacheKey(transcript: String, vocabulary: String) -> String {
        let digest = SHA256.hash(data: Data((transcript + "\u{1}" + vocabulary).utf8))
        return digest.prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    private static var cacheDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Transcriberr/briefs", isDirectory: true)
    }

    static func cached(key: String) -> MeetingBrief? {
        let url = cacheDirectory.appendingPathComponent("\(key).json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(MeetingBrief.self, from: data)
    }

    static func store(_ brief: MeetingBrief, key: String) {
        let fm = FileManager.default
        try? fm.createDirectory(at: cacheDirectory, withIntermediateDirectories: true,
                                attributes: [.posixPermissions: 0o700])
        guard let data = try? JSONEncoder().encode(brief) else { return }
        let url = cacheDirectory.appendingPathComponent("\(key).json")
        try? data.write(to: url, options: .atomic)
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        // A brief names people and a topic, and is keyed by content — nothing
        // ties it to a recording that may since have been deleted. So it is
        // short-lived: 14 days, 100 files at most. A miss costs one re-read.
        if let all = try? fm.contentsOfDirectory(at: cacheDirectory, includingPropertiesForKeys: [.contentModificationDateKey]) {
            let dated = all.map { ($0, (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }
                .sorted { $0.1 > $1.1 }
            let cutoff = Date().addingTimeInterval(-14 * 86_400)
            for (i, entry) in dated.enumerated() where i >= 100 || entry.1 < cutoff {
                try? fm.removeItem(at: entry.0)
            }
        }
    }
}
