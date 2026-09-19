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
        ["до", "зустрічі"], ["до", "побачення"], ["дякую"], ["дякуємо"], ["угу"], ["ага"],
        ["субтитри"], ["продовження", "слідує"], ["далі", "буде"],
        // English
        ["thank", "you"], ["thanks", "for", "watching"], ["thank", "you", "for", "watching"],
        ["thank", "you", "very", "much"], ["bye"], ["you"], ["okay"],
        ["subtitles", "by", "the", "amaraorg", "community"],
        // Dutch
        ["bedankt", "voor", "het", "kijken"], ["dank", "u", "wel"], ["ondertitels", "ingediend", "door", "de", "amaraorg", "gemeenschap"],
        // German / French / Spanish / Polish
        ["vielen", "dank"], ["untertitel", "der", "amaraorg", "community"],
        ["merci"], ["merci", "davoir", "regardé", "cette", "vidéo"],
        ["gracias"], ["gracias", "por", "ver", "el", "video"],
        ["dziękuję"], ["dziękuję", "za", "uwagę"], ["napisy", "stworzone", "przez", "społeczność", "amaraorg"],
    ]

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
        let words = normWords(text)
        return !words.isEmpty && outroPhrases.contains(words)
    }

    /// True when `text` is nothing but phantom phrases (possibly repeated:
    /// "Дякую. Дякую."). Empty text is not a phantom — it is just empty.
    static func isPhantomOnly(_ text: String) -> Bool {
        let words = normWords(text)
        guard !words.isEmpty, words.count <= 14 else { return false }
        var i = 0
        outer: while i < words.count {
            // Longest phrase first so "дякую за перегляд" isn't consumed as
            // "дякую" + two unexplained words.
            for p in phantomPhrases.sorted(by: { $0.count > $1.count })
            where i + p.count <= words.count && Array(words[i..<(i + p.count)]) == p {
                i += p.count
                continue outer
            }
            return false
        }
        return true
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
}
