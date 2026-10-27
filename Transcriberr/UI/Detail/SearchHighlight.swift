import Foundation

/// Where a Library search's words occur in a transcript line, so the
/// recording it found can mark them. Same matching as the Library's
/// `localizedStandardContains`: case- and accent-insensitive, locale-aware,
/// the whole query as one phrase.
nonisolated enum SearchHighlight {
    static func ranges(of query: String, in text: String) -> [NSRange] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, !text.isEmpty else { return [] }
        let ns = text as NSString
        var out: [NSRange] = []
        var from = 0
        while from < ns.length {
            let r = ns.range(of: q, options: [.caseInsensitive, .diacriticInsensitive],
                             range: NSRange(location: from, length: ns.length - from), locale: .current)
            guard r.location != NSNotFound, r.length > 0 else { break }
            out.append(r)
            from = r.location + r.length
        }
        return out
    }

    static func matches(_ query: String, _ text: String) -> Bool {
        !ranges(of: query, in: text).isEmpty
    }
}
