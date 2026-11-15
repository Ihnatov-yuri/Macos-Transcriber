import Foundation

/// "Correct a word once, everywhere." A hand edit to one transcript line is
/// read as a word swap ("post en el" → "PostNL"); the same swap can then be
/// made in every other line of the recording that has the old words.
///
/// Only a short, single swap counts: a rewritten sentence, a deleted
/// clause or an added remark is an edit to that line alone.
nonisolated enum TranscriptCorrection {

    struct Change: Equatable {
        /// The words as they were, as they stood in the line.
        let old: String
        /// What the user typed instead.
        let new: String
    }

    /// The longest swap read as a correction, in words on either side.
    static let maxWords = 4

    /// The one word swap that turns `before` into `after`, or nil when the
    /// edit is something else. Punctuation and case around the changed words
    /// are ignored, so "Klaar met post en el." → "Klaar met PostNL." is
    /// "post en el" → "PostNL".
    static func change(from before: String, to after: String) -> Change? {
        let a = words(before), b = words(after)
        guard a != b else { return nil }
        // Common head and tail, compared without case or punctuation.
        var head = 0
        while head < a.count, head < b.count, key(a[head]) == key(b[head]) { head += 1 }
        var tail = 0
        while tail < a.count - head, tail < b.count - head,
              key(a[a.count - 1 - tail]) == key(b[b.count - 1 - tail]) { tail += 1 }
        var old = Array(a[head ..< a.count - tail])
        var new = Array(b[head ..< b.count - tail])
        // A pure case or punctuation change on the same words ("postnl" →
        // "PostNL") is a swap too: the keys matched, so the spans came out
        // empty. Find the first word whose surface changed.
        if old.isEmpty, new.isEmpty, a.count == b.count,
           let i = a.indices.first(where: { bare(a[$0]) != bare(b[$0]) }) {
            // A capital put on the first word of a sentence is grammar, not
            // a name: offering it everywhere would capitalise every "yes".
            let wa = bare(a[i]), wb = bare(b[i])
            let firstLetterOnly = wa.dropFirst() == wb.dropFirst()
            let startsSentence = i == 0 || a[i - 1].last.map { ".!?…".contains($0) } == true
            if firstLetterOnly, startsSentence { return nil }
            old = [a[i]]
            new = [b[i]]
        }
        guard !old.isEmpty, !new.isEmpty,
              old.count <= maxWords, new.count <= maxWords else { return nil }
        let rawOld = old.joined(separator: " ")
        let o = bare(rawOld)
        guard let core = rawOld.range(of: o) else { return nil }
        // Only the punctuation the old words stood in goes ("Kaykoh," →
        // "Kaiko,"); what the user typed as part of the word stays: "C#",
        // "U.S", "C++".
        let lead = rawOld[..<core.lowerBound], trail = rawOld[core.upperBound...]
        var n = new.joined(separator: " ")
        if !lead.isEmpty, n.hasPrefix(lead) { n.removeFirst(lead.count) }
        if !trail.isEmpty, n.hasSuffix(trail) { n.removeLast(trail.count) }
        n = n.trimmingCharacters(in: .whitespaces)
        guard o.contains(where: \.isLetter), !n.isEmpty, o != n else { return nil }
        return Change(old: o, new: n)
    }

    /// Where `old` stands in `text` as whole words, case ignored.
    static func ranges(of old: String, in text: String) -> [Range<String.Index>] {
        guard !old.isEmpty else { return [] }
        var out: [Range<String.Index>] = []
        var from = text.startIndex
        while from < text.endIndex,
              let r = text.range(of: old, options: [.caseInsensitive], range: from ..< text.endIndex) {
            if isBoundary(text, before: r.lowerBound), isBoundary(text, after: r.upperBound) {
                out.append(r)
                from = r.upperBound
            } else {
                from = text.index(after: r.lowerBound)
            }
        }
        return out
    }

    /// `text` with every whole-word `old` replaced by `new`. When the found
    /// words start with a capital (a sentence start) and `new` is written in
    /// lower case, the capital is kept.
    static func replacing(_ old: String, with new: String, in text: String) -> String {
        var out = text
        for r in ranges(of: old, in: text).reversed() {
            let found = text[r]
            var replacement = new
            if found.first?.isUppercase == true, new == new.lowercased(), let first = new.first {
                replacement = first.uppercased() + new.dropFirst()
            }
            out.replaceSubrange(r, with: replacement)
        }
        return out
    }

    // MARK: - Words

    private static func words(_ s: String) -> [String] {
        s.split(whereSeparator: \.isWhitespace).map(String.init)
    }

    /// A word without the punctuation around it.
    private static func bare(_ w: String) -> String {
        w.trimmingCharacters(in: .punctuationCharacters.union(.symbols).union(.whitespaces))
    }

    private static func key(_ w: String) -> String { bare(w).lowercased() }

    private static func isWordChar(_ c: Character) -> Bool { c.isLetter || c.isNumber }

    /// An apostrophe between letters is inside a word: "can't", "сім'я",
    /// "сім’я".
    private static func isApostrophe(_ c: Character) -> Bool { c == "'" || c == "’" || c == "ʼ" }

    private static func isBoundary(_ text: String, before i: String.Index) -> Bool {
        guard i > text.startIndex else { return true }
        let p = text.index(before: i)
        if isWordChar(text[p]) { return false }
        if isApostrophe(text[p]), p > text.startIndex, text[text.index(before: p)].isLetter { return false }
        return true
    }

    private static func isBoundary(_ text: String, after i: String.Index) -> Bool {
        guard i < text.endIndex else { return true }
        if isWordChar(text[i]) { return false }
        let n = text.index(after: i)
        if isApostrophe(text[i]), n < text.endIndex, text[n].isLetter { return false }
        return true
    }
}
