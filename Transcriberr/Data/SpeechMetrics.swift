import Foundation

/// How someone speaks in meetings, measured from the timed transcript and
/// nothing else, so the same meetings always give the same numbers. The
/// coaching on the You page proposes goals with a text model, but only
/// these numbers decide whether a goal was met.
///
/// Fillers are the weak spot: Parakeet and Whisper both tend to leave
/// "um", "uh" and "ееее" out of what they write, so filler rates read low
/// and are compared only between meetings transcribed the same way.
enum SpeechMetric: String, Codable, CaseIterable, Identifiable {
    case talkShare, pace, longestTurn, interruptions, questions, fillers, hedges
    var id: String { rawValue }

    var title: String {
        switch self {
        case .talkShare: return "Talk share"
        case .pace: return "Pace"
        case .longestTurn: return "Longest turn"
        case .interruptions: return "Cutting in"
        case .questions: return "Questions"
        case .fillers: return "Fillers"
        case .hedges: return "Hedges"
        }
    }

    var unit: String {
        switch self {
        case .talkShare: return "% of a fair share"
        case .pace: return "words/min"
        case .longestTurn: return "s"
        case .interruptions: return "per 10 min"
        case .questions: return "per 10 min of speaking"
        case .fillers, .hedges: return "per min"
        }
    }

    var explanation: String {
        switch self {
        case .talkShare: return "Share of the words spoken, against one person's fair share: 100 is exactly fair, 200 twice as much. A 1:1 and a group of six are judged alike."
        case .pace: return "Words per minute, from lines short enough to time well."
        case .longestTurn: return "The longest stretch without anyone else speaking."
        case .interruptions: return "Starting while someone else is still talking, where the transcript's timing is tight enough to tell."
        case .questions: return "Questions asked, per 10 minutes of speaking."
        case .fillers: return "Um, uh, ну, типу and the like. Speech engines leave many out, so this reads low."
        case .hedges: return "I think, maybe, kind of, мабуть, можливо and the like."
        }
    }

    /// Which way is better, for goals and colours. Pace has a band instead.
    var lowerIsBetter: Bool? {
        switch self {
        case .talkShare, .longestTurn, .interruptions, .fillers, .hedges: return true
        case .questions: return false
        case .pace: return nil
        }
    }

    func format(_ v: Double) -> String {
        switch self {
        case .talkShare, .pace, .longestTurn: return String(Int(v.rounded()))
        default: return String(format: "%.1f", v)
        }
    }
}

struct SpeechLine: Equatable {
    var start: Double
    var end: Double
    var speaker: String
    var text: String
}

/// One person in one meeting.
///
/// Calibrated on the user's library (2026-10-23): line timestamps include
/// the pauses inside a line, and a split-track meeting's microphone lines
/// run 10-60 s across the other side's speech. Seconds therefore overstate
/// talk (your mic lines read 58 words/min), so talk share counts words,
/// pace uses only tight lines (2-12 s: 122 words/min for the same voice),
/// and cutting in only counts overlaps between tight lines (2,709 of the
/// library's 5,153 raw overlaps were 5 s or longer, i.e. padding).
struct MeetingSpeech: Equatable, Identifiable {
    var recordingId: UUID
    var title: String
    var date: Date
    /// "en", "uk" or nil when the script does not tell (see `language`).
    var language: String?
    /// Everyone who said a word, them included: a quiet side of a 1:1 is
    /// still half of it.
    var participants: Int
    /// Seconds of their lines: generous, for weighting and display only.
    var talkSeconds: Double
    /// First line to last: the meeting's length.
    var spanSeconds: Double
    var words: Int
    var meetingWords: Int
    /// Words and seconds of their tight lines only, for pace.
    var paceWords: Int
    var paceSeconds: Double
    var turns: Int
    var longestTurn: Double
    var interruptions: Int
    var interrupted: Int
    var questions: Int
    var fillers: Int
    var hedges: Int
    /// Words of everyone else, by name.
    var others: [String: Double]

    var id: UUID { recordingId }
    var talkMinutes: Double { talkSeconds / 60 }
    var fairShare: Double { participants > 0 ? 100 / Double(participants) : 100 }

    func value(_ m: SpeechMetric) -> Double? {
        switch m {
        case .talkShare:
            return meetingWords >= 50 ? 100 * (Double(words) / Double(meetingWords)) / (fairShare / 100) : nil
        case .pace: return paceSeconds >= 20 ? Double(paceWords) / (paceSeconds / 60) : nil
        case .longestTurn: return turns > 0 ? longestTurn : nil
        case .interruptions: return spanSeconds >= 120 ? Double(interruptions) / (spanSeconds / 600) : nil
        case .questions: return words >= 150 ? Double(questions) / (Double(words) / SpeechMeasure.wordsPerTenMinutes) : nil
        case .fillers: return words >= 150 && SpeechLexicon.has(language) ? Double(fillers) / (Double(words) / SpeechMeasure.wordsPerMinute) : nil
        case .hedges: return words >= 150 && SpeechLexicon.has(language) ? Double(hedges) / (Double(words) / SpeechMeasure.wordsPerMinute) : nil
        }
    }
}

enum SpeechMeasure {
    /// Lines of the same speaker this close are one turn.
    static let turnGap = 1.5
    /// Lines at most this long have timestamps tight enough for pace and
    /// for telling who started while whom was talking.
    static let tightLine = 2.0...12.0
    /// Overlap between two tight lines that counts as cutting in.
    static let overlap = 0.5
    /// Rates per minute of speech are taken per words spoken, at an even
    /// pace, so padded timestamps do not water them down.
    static let wordsPerMinute = 140.0
    static var wordsPerTenMinutes: Double { wordsPerMinute * 10 }

    /// Measures `name` (any case) in one meeting; nil when they did not speak.
    static func measure(_ lines: [SpeechLine], name: String, recordingId: UUID,
                        title: String, date: Date) -> MeetingSpeech? {
        let sorted = lines.filter { $0.end > $0.start }.sorted { $0.start < $1.start }
        func isThem(_ s: String) -> Bool { s.caseInsensitiveCompare(name) == .orderedSame }
        let mine = sorted.filter { isThem($0.speaker) }
        guard !mine.isEmpty else { return nil }

        var wordsBy: [String: Int] = [:]
        for l in sorted { wordsBy[l.speaker, default: 0] += SpeechLexicon.words(l.text).count }
        let talk = mine.map { $0.end - $0.start }.reduce(0, +)
        let tight = mine.filter { tightLine.contains($0.end - $0.start) && SpeechLexicon.words($0.text).count >= 4 }

        // Turns: runs of one speaker, merged over short gaps, and ended
        // where anyone else starts (a padded line must not run on through
        // the other side's speech).
        struct Turn { var speaker: String; var start: Double; var end: Double }
        var turns: [Turn] = []
        for l in sorted {
            if var last = turns.last, last.speaker == l.speaker, l.start - last.end <= turnGap {
                last.end = max(last.end, l.end)
                turns[turns.count - 1] = last
            } else {
                if !turns.isEmpty, turns[turns.count - 1].end > l.start {
                    turns[turns.count - 1].end = max(turns[turns.count - 1].start, l.start)
                }
                turns.append(Turn(speaker: l.speaker, start: l.start, end: l.end))
            }
        }
        let theirTurns = turns.filter { isThem($0.speaker) }

        // Cutting in, from tight lines only: one pass, keeping the latest
        // end of each speaker's tight lines.
        var cutIn = 0, cutOff = 0
        var lastEnd: [String: Double] = [:]
        for l in sorted where tightLine.contains(l.end - l.start) {
            let talking = lastEnd.filter { $0.key != l.speaker && $0.value - overlap > l.start }
            if !talking.isEmpty {
                if isThem(l.speaker) { cutIn += 1 }
                else if talking.keys.contains(where: isThem) { cutOff += 1 }
            }
            lastEnd[l.speaker] = max(lastEnd[l.speaker] ?? 0, l.end)
        }

        let text = mine.map(\.text).joined(separator: " ")
        let language = SpeechLexicon.language(of: text)
        return MeetingSpeech(
            recordingId: recordingId, title: title, date: date, language: language,
            participants: max(1, wordsBy.values.filter { $0 > 0 }.count),
            talkSeconds: talk,
            spanSeconds: (sorted.map(\.end).max() ?? 0) - (sorted.first?.start ?? 0),
            words: SpeechLexicon.words(text).count,
            meetingWords: wordsBy.values.reduce(0, +),
            paceWords: tight.map { SpeechLexicon.words($0.text).count }.reduce(0, +),
            paceSeconds: tight.map { $0.end - $0.start }.reduce(0, +),
            turns: theirTurns.count, longestTurn: theirTurns.map { $0.end - $0.start }.max() ?? 0,
            interruptions: cutIn, interrupted: cutOff,
            questions: mine.map { $0.text.filter { $0 == "?" }.count }.reduce(0, +),
            fillers: SpeechLexicon.count(SpeechLexicon.fillers[language ?? ""] ?? [], in: text),
            hedges: SpeechLexicon.count(SpeechLexicon.hedges[language ?? ""] ?? [], in: text),
            others: wordsBy.filter { !isThem($0.key) }.mapValues(Double.init))
    }

    /// Meetings a number on a page is read from, newest: the headline, the
    /// sparkline and the trend all describe the same meetings.
    static let window = 10

    /// Mean of a metric over the newest `window` meetings with a value, in
    /// `language` when given; nil when none has one.
    static func average(_ m: SpeechMetric, over meetings: [MeetingSpeech], language: String? = nil) -> Double? {
        let values = series(m, over: meetings, language: language)
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }

    /// The newest `window` values, oldest first.
    static func series(_ m: SpeechMetric, over meetings: [MeetingSpeech], language: String? = nil) -> [Double] {
        Array(meetings.filter { language == nil || $0.language == language }
            .sorted { $0.date > $1.date }
            .compactMap { $0.value(m) }
            .prefix(window)
            .reversed())
    }
}

/// Words that count as fillers and hedges, per language. Only English and
/// Ukrainian have lists; other languages get no filler or hedge numbers.
nonisolated enum SpeechLexicon {
    static let fillers: [String: [String]] = [
        "en": ["um", "umm", "uh", "uhh", "erm", "er", "hmm", "you know", "i mean"],
        "uk": ["е", "ее", "еее", "ееее", "ем", "ну", "типу", "значить", "короче", "як би", "от"],
    ]
    static let hedges: [String: [String]] = [
        "en": ["i think", "maybe", "probably", "kind of", "sort of", "i guess", "perhaps", "a little bit"],
        "uk": ["мабуть", "можливо", "напевно", "я думаю", "ніби", "здається", "трошки"],
    ]

    static func has(_ language: String?) -> Bool { language.map { fillers[$0] != nil } ?? false }

    /// From the script: mostly Cyrillic is Ukrainian (the app's only
    /// Cyrillic language), mostly Latin is English.
    static func language(of text: String) -> String? {
        var cyr = 0, lat = 0
        for u in text.unicodeScalars {
            switch u.value {
            case 0x0400...0x04FF: cyr += 1
            case 0x41...0x5A, 0x61...0x7A: lat += 1
            default: break
            }
        }
        guard cyr + lat >= 20 else { return nil }
        if Double(cyr) >= 0.6 * Double(cyr + lat) { return "uk" }
        if Double(lat) >= 0.6 * Double(cyr + lat) { return "en" }
        return nil
    }

    static func words(_ text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: CharacterSet.letters.union(CharacterSet(charactersIn: "'’ʼ")).inverted)
            .filter { !$0.isEmpty }
    }

    /// Whole-word (and whole-phrase) occurrences.
    static func count(_ phrases: [String], in text: String) -> Int {
        let w = words(text)
        guard !w.isEmpty else { return 0 }
        var n = 0
        for phrase in phrases {
            let p = words(phrase)
            guard !p.isEmpty, p.count <= w.count else { continue }
            for i in 0...(w.count - p.count) where Array(w[i..<(i + p.count)]) == p { n += 1 }
        }
        return n
    }
}
