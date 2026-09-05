import Foundation
import NaturalLanguage

/// Names learned from the user's own transcripts.
///
/// The library already holds hours of the user's meetings — the people,
/// companies, products and places they actually say. A capitalized word
/// that is not a sentence start, appears in more than one recording, and
/// isn't an ordinary word is almost always a name worth spelling right.
/// Harvested terms feed dictation (vocabulary canonicalization + the smart
/// pass) automatically and are offered in Settings for promotion into the
/// permanent vocabulary.
enum VocabularyHarvester {

    struct Term: Codable, Identifiable, Equatable, Sendable {
        var id: String { key }
        /// Normalized key (letters/digits, lowercased).
        let key: String
        /// The spelling seen most often.
        let spelling: String
        /// Distinct recordings the term appeared in.
        let recordings: Int
        let occurrences: Int
    }

    /// Ordinary words that happen to be capitalized mid-sentence in ASR
    /// output (days, months, "I", pronouns after a dropped period…). The
    /// lowercase-frequency rule below catches the rest.
    private static let stop: Set<String> = [
        "i", "im", "ive", "id", "ill", "ok", "okay", "yes", "no", "yeah", "the", "a", "an", "and",
        "but", "so", "or", "if", "then", "when", "what", "why", "how", "who", "where", "this", "that",
        "these", "those", "it", "its", "we", "you", "he", "she", "they", "them", "our", "your", "my",
        "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday",
        "january", "february", "march", "april", "may", "june", "july", "august", "september",
        "october", "november", "december", "speaker", "hello", "hi", "hey", "thanks", "thank",
        "bye", "good", "morning", "afternoon", "evening", "today", "tomorrow", "yesterday",
        "english", "dutch", "ukrainian", "german", "french", "spanish", "europe", "european",
        "ja", "nee", "de", "het", "een", "en", "maar", "dus", "ik", "je", "we", "wij", "zij",
        "так", "ні", "і", "а", "але", "я", "ми", "ви", "вони", "це", "що", "як",
        // fillers / discourse words the recognizer capitalizes
        "uh", "um", "hmm", "mhm", "mmhmm", "oops", "however", "anyway", "right", "well",
        "тобто", "дякую", "добре", "навірно", "напевно", "угу", "ага", "гаразд", "ну",
        "привіт", "зрозуміло", "будь", "ласка", "давай", "давайте", "тепер",
        "oké", "hoor", "nou", "eigenlijk", "gewoon", "dankjewel", "bedankt", "prima",
    ]

    /// One sentence's worth of tokens → candidate names (single words and
    /// runs of consecutive capitalized words such as "Blits Insurance").
    /// Candidate names with whether each was the first word of its sentence
    /// (where a capital is just grammar). Sentence-initial mentions still
    /// count towards frequency once a term has mid-sentence evidence.
    static func candidatesDetailed(in text: String) -> [(term: String, sentenceInitial: Bool)] {
        var out: [(String, Bool)] = []
        for sentence in text.split(whereSeparator: { ".!?\n".contains($0) }) {
            let words = sentence.split(separator: " ", omittingEmptySubsequences: true)
                .map { $0.trimmingCharacters(in: .punctuationCharacters) }
                .filter { !$0.isEmpty }
            var run: [String] = []
            var runInitial = false
            func flush() {
                if !run.isEmpty { out.append((run.joined(separator: " "), runInitial && run.count == 1)) }
                run.removeAll()
                runInitial = false
            }
            func looksLikeName(_ w: String) -> Bool {
                guard let first = w.first, first.isUppercase, w.count >= 2 else { return false }
                return w.dropFirst().contains(where: { $0.isLowercase || $0.isNumber })
            }
            func isAcronym(_ w: String) -> Bool {
                w.count >= 3 && w.count <= 6 && w.contains(where: { $0.isLetter })
                    && w.allSatisfy { $0.isUppercase || $0.isNumber }
            }
            for (i, w) in words.enumerated() {
                if isAcronym(w) || looksLikeName(w) {
                    // "Ask KimKim", "Then Kaiko": a capitalized sentence opener
                    // must not glue itself onto the name that follows.
                    if i == 0, !isAcronym(w), openers.contains(w.lowercased()) {
                        out.append((w, true))
                        continue
                    }
                    if run.isEmpty { runInitial = (i == 0) && !isAcronym(w) }
                    run.append(w)
                } else {
                    flush()
                }
            }
            flush()
        }
        return out
    }

    /// Names that are NOT merely sentence-initial capitals — what a single
    /// passage can vouch for on its own (used for one-tap suggestions).
    static func candidates(in text: String) -> [String] {
        candidatesDetailed(in: text).filter { !$0.sentenceInitial }.map(\.term)
    }

    /// Ordinary words that open sentences with a capital and would otherwise
    /// be glued onto a following name.
    private static let openers: Set<String> = [
        "then", "ask", "so", "and", "but", "also", "now", "well", "okay", "ok", "please", "let",
        "maybe", "actually", "yes", "no", "just", "send", "call", "tell", "check", "make", "get",
        "put", "look", "see", "thanks", "thank", "hi", "hello", "dear", "hey", "great", "good",
        "sure", "right", "wait", "sorry", "today", "tomorrow", "yesterday", "after", "before",
        "during", "since", "with", "without", "for", "from", "to", "in", "on", "at", "by", "of",
        "the", "a", "an", "this", "that", "these", "those", "our", "your", "my", "his", "her",
        "their", "its", "we", "you", "they", "he", "she", "it", "i", "if", "when", "while",
        "because", "about", "over", "under", "into", "onto", "next", "last", "first", "second",
        "meanwhile", "however", "still", "yet", "even", "only", "later", "earlier", "here", "there",
        "dan", "dus", "maar", "en", "ook", "nu", "oké", "ja", "nee", "vraag", "bel", "stuur",
        "тоді", "також", "але", "і", "зараз", "так", "ні", "потім", "спитай", "надішли",
    ]

    static func key(_ s: String) -> String { s.lowercased().filter { $0.isLetter || $0.isNumber } }

    /// Harvest from (recordingId, text) pairs. `minRecordings` = how many
    /// distinct recordings a term must appear in.
    static func harvest(
        _ items: [(recording: UUID, text: String)],
        existingVocabulary: [String],
        minRecordings: Int = 2,
        limit: Int = 200
    ) -> [Term] {
        let existing = Set(existingVocabulary.map(key))
        var recordingsByKey: [String: Set<UUID>] = [:]
        var spellings: [String: [String: Int]] = [:]
        var lowercaseSeen: [String: Int] = [:]
        var occurrences: [String: Int] = [:]
        var midSentence: [String: Int] = [:]

        for item in items {
            // Lowercase frequency of every word, to reject ordinary words
            // that merely got capitalized somewhere ("Meeting", "Project").
            for w in item.text.split(whereSeparator: { !$0.isLetter && !$0.isNumber }) {
                if w.first?.isLowercase == true { lowercaseSeen[key(String(w)), default: 0] += 1 }
            }
            for (cand, initial) in candidatesDetailed(in: item.text) {
                let k = key(cand)
                guard k.count >= 3, !stop.contains(k), !existing.contains(k) else { continue }
                // Contractions ("That's", "I'm"), runs with a filler or a
                // repeated word ("Uh I'm", "Kim KimKim"), and runs longer
                // than three words are not names.
                if cand.contains("'") || cand.contains("’") { continue }
                let parts = cand.split(separator: " ").map { key(String($0)) }
                if parts.count > 3 || parts.contains(where: { stop.contains($0) }) { continue }
                if parts.count > 1, zip(parts, parts.dropFirst()).contains(where: { $0 == $1 || $1.hasPrefix($0) || $0.hasPrefix($1) }) { continue }
                if !initial { midSentence[k, default: 0] += 1 }
                recordingsByKey[k, default: []].insert(item.recording)
                spellings[k, default: [:]][cand, default: 0] += 1
                occurrences[k, default: 0] += 1
            }
        }

        var terms: [Term] = []
        for (k, recs) in recordingsByKey where recs.count >= minRecordings {
            // Mostly seen at sentence starts → grammar, not a name.
            let occ = occurrences[k] ?? 0
            guard let mid = midSentence[k], mid >= max(1, occ / 5) else { continue }
            // Seen lowercase at least as often as capitalized → ordinary word.
            if let low = lowercaseSeen[k], low >= occ { continue }
            // Multi-word runs: every word must not be a common lowercase word.
            guard let best = spellings[k]?.max(by: { $0.value < $1.value })?.key else { continue }
            let parts = best.split(separator: " ").map { key(String($0)) }
            if parts.count > 1, parts.allSatisfy({ (lowercaseSeen[$0] ?? 0) > 3 }) { continue }
            terms.append(Term(key: k, spelling: best, recordings: recs.count, occurrences: occ))
        }
        return terms
            .sorted { ($0.recordings, $0.occurrences, $0.spelling) > ($1.recordings, $1.occurrences, $1.spelling) }
            .prefix(limit)
            .map { $0 }
    }
}
