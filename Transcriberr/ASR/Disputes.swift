import Foundation

/// Finds Super's disputed words (`WordDispute`) in the finished transcript.
///
/// The vote happens per chunk, long before the text reaches the screen:
/// hygiene, seam trims, Gemma rulings, vocabulary and turn merging all edit
/// it afterwards. So a dispute is looked up by what it says, not where it
/// was: a word with the kept reading's spelling, in a segment overlapping
/// the chunk, with at least one of its two kept neighbours beside it. A
/// dispute that no longer matches anything (the word was ruled away, or the
/// user edited it) is simply not shown.
enum DisputeIndex {
    struct Hit: Hashable {
        /// Index into the dispute list the hit came from.
        let index: Int
        let dispute: WordDispute
        /// The word's letters inside the text, without the punctuation
        /// around it: what an alternative replaces.
        let range: Range<String.Index>
    }

    static func encode(_ disputes: [WordDispute]) -> String? {
        guard !disputes.isEmpty, let data = try? JSONEncoder().encode(disputes) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    static func decode(_ json: String?) -> [WordDispute] {
        guard let json, let list = try? JSONDecoder().decode([WordDispute].self, from: Data(json.utf8)) else { return [] }
        return list
    }

    static func norm(_ s: some StringProtocol) -> String {
        TranscriptHygiene.normWords(String(s)).joined()
    }

    /// Whitespace-separated words of `text`, each with its letter core.
    static func tokens(_ text: String) -> [(norm: String, core: Range<String.Index>)] {
        var out: [(String, Range<String.Index>)] = []
        var i = text.startIndex
        while i < text.endIndex {
            while i < text.endIndex, text[i].isWhitespace { i = text.index(after: i) }
            guard i < text.endIndex else { break }
            var j = i
            while j < text.endIndex, !text[j].isWhitespace { j = text.index(after: j) }
            let word = text[i..<j]
            if let first = word.firstIndex(where: { $0.isLetter || $0.isNumber }),
               let last = word.lastIndex(where: { $0.isLetter || $0.isNumber }) {
                let n = norm(word)
                if !n.isEmpty { out.append((n, first..<word.index(after: last))) }
            }
            i = j
        }
        return out
    }

    /// The disputes visible in one segment's text. Each dispute is shown at
    /// most once, each word carries at most one dispute.
    static func hits(in text: String, start: Double, end: Double,
                     disputes: [WordDispute], claimed: inout Set<Int>) -> [Hit] {
        let candidates = disputes.indices.filter { k in
            !claimed.contains(k) && disputes[k].end + 1 >= start && disputes[k].start - 1 <= end
        }
        guard !candidates.isEmpty else { return [] }
        let toks = tokens(text)
        var used = Set<Int>()
        var out: [Hit] = []
        for k in candidates {
            let d = disputes[k]
            let target = norm(d.chosen)
            guard !target.isEmpty else { continue }
            var best: (pos: Int, score: Int)?
            for (p, t) in toks.enumerated() where t.norm == target && !used.contains(p) {
                let prevOK = !d.before.isEmpty && p > 0 && toks[p - 1].norm == d.before
                let nextOK = !d.after.isEmpty && p + 1 < toks.count && toks[p + 1].norm == d.after
                let edgeOK = (d.before.isEmpty && p == 0) || (d.after.isEmpty && p == toks.count - 1)
                let score = (prevOK ? 2 : 0) + (nextOK ? 2 : 0) + (edgeOK ? 1 : 0)
                guard score >= 2 || (score >= 1 && d.before.isEmpty != d.after.isEmpty) else { continue }
                if best == nil || score > best!.score { best = (p, score) }
            }
            guard let best else { continue }
            used.insert(best.pos)
            claimed.insert(k)
            out.append(Hit(index: k, dispute: d, range: toks[best.pos].core))
        }
        return out.sorted { $0.range.lowerBound < $1.range.lowerBound }
    }

    /// Dispute `k` as the transcript places it in segment `row`: earlier
    /// segments claim their disputes first, as on screen.
    static func hit(_ k: Int, disputes: [WordDispute],
                    in segments: [(start: Double, end: Double, text: String)], row: Int) -> Hit? {
        var claimed = Set<Int>()
        for (i, s) in segments.enumerated() where i < row {
            _ = hits(in: s.text, start: s.start, end: s.end, disputes: disputes, claimed: &claimed)
        }
        let s = segments[row]
        return hits(in: s.text, start: s.start, end: s.end, disputes: disputes, claimed: &claimed)
            .first { $0.index == k }
    }

    /// Every dispute visible in a transcript, as (segment index, hit).
    static func locate(d disputes: [WordDispute],
                       in segments: [(start: Double, end: Double, text: String)]) -> [(Int, Hit)] {
        var claimed = Set<Int>()
        var out: [(Int, Hit)] = []
        for (i, s) in segments.enumerated() {
            for h in hits(in: s.text, start: s.start, end: s.end, disputes: disputes, claimed: &claimed) {
                out.append((i, h))
            }
        }
        return out
    }

    /// The alternative as it goes into the text: its letters only, so the
    /// kept word's punctuation stays where it was ("Kaico," → "Kaiko,").
    static func core(_ surface: String) -> String {
        guard let first = surface.firstIndex(where: { $0.isLetter || $0.isNumber }),
              let last = surface.lastIndex(where: { $0.isLetter || $0.isNumber }) else { return surface }
        return String(surface[first...last])
    }

    /// `text` with the hit's word replaced by the alternative reading, and
    /// the dispute flipped so the same word can be switched back.
    static func pick(_ hit: Hit, in text: String) -> (text: String, flipped: WordDispute) {
        var t = text
        t.replaceSubrange(hit.range, with: core(hit.dispute.alternative))
        var flipped = hit.dispute
        flipped.chosen = hit.dispute.alternative
        flipped.alternative = hit.dispute.chosen
        return (t, flipped)
    }
}

/// The user's rulings on disputed words, fed back into the vote: once
/// "Kaico" lost to "Kaiko" by the user's hand, the vote picks "Kaiko"
/// whenever the engines split between the two again.
enum DisputeLearning {
    static let key = "vocab.learnedChoices"
    static let limit = 2000
    static let lastIgnoredKey = "vocab.lastIgnoredChoice"

    /// "loser>winner" norm pairs.
    static func pairs(_ defaults: UserDefaults = .standard) -> Set<String> {
        Set(defaults.stringArray(forKey: key) ?? [])
    }

    enum Outcome: Equatable { case learned, undone, ignored }

    /// Records the user's pick of `winner` over `loser`. Picking back a
    /// reading they had rejected UNDOES the earlier ruling instead of
    /// learning the opposite: a click and a click back leave no rule.
    /// Only `learn` picks become rules (names and terms): a homophone or an
    /// inflection ("their"/"there", "жовтні"/"жовтня") is right in one
    /// sentence and wrong in the next, and a rule outranks every other vote.
    @discardableResult
    static func record(loser: String, winner: String, learn: Bool = true,
                       _ defaults: UserDefaults = .standard) -> Outcome {
        let l = DisputeIndex.norm(loser), w = DisputeIndex.norm(winner)
        guard !l.isEmpty, !w.isEmpty, l != w else { return .ignored }
        var list = defaults.stringArray(forKey: key) ?? []
        if list.contains("\(w)>\(l)") {
            defaults.set(list.filter { $0 != "\(w)>\(l)" }, forKey: key)
            return .undone
        }
        // The click back after a pick that taught nothing (an ordinary word
        // chosen over a name): still an undo, never a new rule.
        if defaults.string(forKey: lastIgnoredKey) == "\(w)>\(l)" {
            defaults.removeObject(forKey: lastIgnoredKey)
            return .undone
        }
        guard learn, !list.contains("\(l)>\(w)") else {
            defaults.set("\(l)>\(w)", forKey: lastIgnoredKey)
            return .ignored
        }
        list.append("\(l)>\(w)")
        defaults.set(Array(list.suffix(limit)), forKey: key)
        return .learned
    }

    /// Forgets one ruling ("loser>winner"), as `pairs` lists it.
    static func remove(_ pair: String, _ defaults: UserDefaults = .standard) {
        defaults.set((defaults.stringArray(forKey: key) ?? []).filter { $0 != pair }, forKey: key)
    }

    /// Newest first, for the Settings list.
    static func ordered(_ defaults: UserDefaults = .standard) -> [String] {
        (defaults.stringArray(forKey: key) ?? []).reversed()
    }

    /// Whether a chosen word belongs in the vocabulary too: names, coined
    /// terms and codes ("Kaiko", "KimKim", "LLMs4EU"), never an ordinary
    /// word, which would only crowd the prompts the vocabulary feeds.
    /// A capital on the first word of a sentence says nothing.
    static func isTerm(_ surface: String, sentenceStart: Bool) -> Bool {
        let w = DisputeIndex.core(surface)
        guard w.count >= 3 else { return false }
        if w.contains(where: \.isNumber) { return true }
        let uppers = w.filter(\.isUppercase).count
        if uppers >= 2 { return true }
        return uppers == 1 && w.first!.isUppercase && !sentenceStart
    }

    /// Whether `range` starts a sentence in `text`.
    static func startsSentence(_ range: Range<String.Index>, in text: String) -> Bool {
        let before = text[..<range.lowerBound].trimmingCharacters(in: .whitespaces)
        guard let last = before.last else { return true }
        return ".!?…".contains(last)
    }
}
