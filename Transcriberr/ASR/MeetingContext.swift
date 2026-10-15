import AppKit
import EventKit
import Foundation

/// What the calendar knows about a meeting before a word of it is heard:
/// the invite's title, who was invited, the names and terms written in the
/// invite, and the names that keep coming up in earlier meetings with the
/// same people. A run gets these as vocabulary for that run only: the word
/// vote settles a split between the engines in their favour, the vocabulary
/// pass puts the invite's spelling on near misses, and Gemma's arbitration
/// is told what meeting it is reading.
struct MeetingContext: Codable, Sendable, Equatable {
    var title: String
    /// Display names of the other attendees (not the user).
    var attendees: [String]
    /// Lowercased email addresses of the other attendees: how earlier
    /// meetings with the same people are found.
    var emails: [String]
    /// Names and terms from the invite's title, location and notes.
    var inviteTerms: [String]
    /// Names that recur in the user's earlier recordings of meetings with
    /// these people. Transcribed text, so a hint, never a forced spelling.
    var pastTerms: [String] = []
    var pastMeetings: Int = 0
    var start: Date
    var end: Date

    /// Spellings the invite vouches for: the attendees' names, word by word
    /// as well as whole ("Kees", "van", "Dijk" — engines hear one at a time).
    var calendarTerms: [String] {
        var out: [String] = []
        // An all-hands invite lists people who mostly never speak; forty
        // names as forced spellings only invite false corrections.
        for name in attendees where attendees.count <= Self.maxNamedAttendees {
            out.append(name)
            out += name.split(separator: " ").map(String.init).filter { $0.count >= 3 && $0.first!.isUppercase }
        }
        out += inviteTerms
        return Self.dedup(out)
    }

    /// Everything that goes into the vote and Gemma's prompts.
    /// What the vote and Gemma treat as authoritative: the calendar's own
    /// spellings only. Past meetings' terms are transcribed text (an old
    /// draft's "Kaico" would cancel the user's "Kaiko" in the vote), so
    /// they reach Gemma as a hint and nowhere else.
    var allTerms: [String] { calendarTerms }

    /// Gemma's lines for this meeting: who, then the spellings, each list
    /// capped so the user's own vocabulary after it is never crowded out.
    var promptBlock: String {
        var s = promptLine + "\n"
        let spellings = calendarTerms.joined(separator: ", ")
        if !spellings.isEmpty { s += "Spellings from the invite: \(spellings.prefix(250))\n" }
        let past = pastTerms.joined(separator: ", ")
        if !past.isEmpty { s += "Names said in earlier meetings with these people (hints only): \(past.prefix(200))\n" }
        return s
    }

    /// One line for Gemma's arbitration prompt.
    var promptLine: String {
        var s = "Meeting: \(title)"
        if !attendees.isEmpty {
            s += ". Attendees: \(attendees.prefix(Self.maxNamedAttendees).joined(separator: ", "))"
            if attendees.count > Self.maxNamedAttendees { s += " and \(attendees.count - Self.maxNamedAttendees) more" }
        }
        return s + "."
    }

    static let maxNamedAttendees = 15

    static func dedup(_ terms: [String]) -> [String] {
        var seen = Set<String>()
        return terms.filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
    }

    static func encode(_ c: MeetingContext?) -> String? {
        guard let c, let data = try? JSONEncoder().encode(c) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    static func decode(_ json: String?) -> MeetingContext? {
        guard let json else { return nil }
        return try? JSONDecoder().decode(MeetingContext.self, from: Data(json.utf8))
    }

    // MARK: - Terms from invite text

    /// Video-call boilerplate every invite carries ("Join Microsoft Teams
    /// Meeting", "Meeting ID", "Passcode") and capitalized ordinary words.
    static let boilerplate: Set<String> = [
        "microsoft", "teams", "zoom", "google", "meet", "webex", "join", "meeting", "passcode", "password",
        "dial", "click", "here", "learn", "more", "help", "options", "phone", "conference", "id", "call",
        "video", "audio", "online", "link", "invite", "invitation", "calendar", "event", "agenda", "notes",
        "please", "hi", "hello", "dear", "thanks", "thank", "regards", "best", "sync", "weekly", "daily",
        "monthly", "catch", "check", "update", "review", "intro", "follow", "kick", "off", "the", "and",
        "for", "with", "about", "from", "this", "that", "your", "our", "you", "will", "can", "are", "not",
        "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday",
        "january", "february", "march", "april", "may", "june", "july", "august", "september", "october",
        "november", "december", "europe", "amsterdam", "time", "zone", "cet", "cest", "utc", "gmt", "local",
        "organizer", "organiser", "required", "optional", "attendees", "tentative", "accepted", "declined",
        "only", "need", "needed", "skype", "slack", "room", "office", "building", "floor", "teams",
    ]

    /// Names and terms in free invite text: capitalized words that do not
    /// start a sentence, CamelCase and codes ("KimKim", "LLMs4EU"), and runs
    /// of them ("Blits Insurance"). URLs, emails and boilerplate are skipped.
    static func terms(in text: String) -> [String] { dedup(termOccurrences(in: text.prefix(2000))) }

    /// Every name-like occurrence in `text`, repeats included.
    static func termOccurrences(in text: some StringProtocol) -> [String] {
        let cleaned = String(text)
            .replacingOccurrences(of: #"\S*(https?://|www\.|@)\S*"#, with: " . ", options: .regularExpression)
            .replacingOccurrences(of: #"[_=*#<>|\[\](){}"]"#, with: " . ", options: .regularExpression)
        var out: [String] = []
        for sentence in cleaned.split(whereSeparator: { ".!?\n:;".contains($0) }) {
            let words = sentence.split(separator: " ").map { $0.trimmingCharacters(in: .punctuationCharacters) }
                .filter { !$0.isEmpty }
            var run: [String] = []
            func flush() {
                if run.count > 1 { out.append(run.joined(separator: " ")) }
                out += run
                run = []
            }
            for (i, w) in words.enumerated() {
                let key = w.lowercased()
                let hasDigit = w.contains(where: \.isNumber)
                let uppers = w.filter(\.isUppercase).count
                let isTerm = w.count >= 3 && !boilerplate.contains(key) && w.first!.isLetter
                    && (uppers >= 2 || (hasDigit && w.contains(where: \.isLetter))
                        || (uppers == 1 && w.first!.isUppercase && i > 0))
                if isTerm { run.append(w) } else { flush() }
            }
            flush()
        }
        // An all-caps word of 6+ letters is shouting, not an acronym.
        return out.filter { !($0.count >= 6 && $0 == $0.uppercased() && !$0.contains(" ")) }
    }

    // MARK: - Calendar

    /// The pref key; on by default.
    static let enabledKey = "ui.meetingContext"
    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true
    }

    /// Calendar access. `ask` shows the system prompt when the user has
    /// not answered yet; it is asked when a meeting STARTS (the user is at
    /// the Mac) or when the setting is switched on, never from a run, which
    /// would sit waiting on the prompt.
    static func requestAccess(_ store: EKEventStore, ask: Bool = false) async -> Bool {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess: return true
        case .notDetermined where ask: return (try? await store.requestFullAccessToEvents()) ?? false
        default: return false
        }
    }

    /// When a recording was spoken, for recordings made in the app. A
    /// meeting's file name carries its start ("meeting_<ms>_…"); a voice
    /// recording is saved at Stop, so it started `duration` before it was
    /// created. Merged, split and imported files are nil: their timestamps
    /// say when they were made in the library, not when anyone spoke.
    static func recordedInterval(audioPath: String, createdAtMillis: Int64, duration: Double) -> DateInterval? {
        let name = URL(fileURLWithPath: audioPath).lastPathComponent
        let length = max(duration, 1)
        if name.hasPrefix("meeting_") {
            let parts = name.split(separator: "_")
            guard parts.count >= 2, let ms = Double(parts[1]), ms > 1_000_000_000_000 else { return nil }
            return DateInterval(start: Date(timeIntervalSince1970: ms / 1000), duration: length)
        }
        if name.hasPrefix("Recording_") {
            // "Recording_yyyy-MM-dd_HH-mm-ss-mmm…": the start, local time. A
            // recording recovered after a crash has its row created from the
            // file, so createdAtMillis cannot be trusted to be the stop.
            let stamp = name.dropFirst("Recording_".count).prefix(19)
            if let start = recordingStamp.date(from: String(stamp)) {
                return DateInterval(start: start, duration: length)
            }
            let end = Date(timeIntervalSince1970: Double(createdAtMillis) / 1000)
            return DateInterval(start: end.addingTimeInterval(-length), duration: length)
        }
        return nil
    }

    /// The invite the recording belongs to: a timed event with other people
    /// in it (or at least a title) that covers most of the recording, or
    /// ten minutes of it. Several candidates → the longest overlap.
    static func lookup(start: Date, end: Date, store: EKEventStore = EKEventStore(),
                       ask: Bool = false) async -> MeetingContext? {
        guard end.timeIntervalSince(start) >= 60, await requestAccess(store, ask: ask) else { return nil }
        let pred = store.predicateForEvents(withStart: start.addingTimeInterval(-3600),
                                            end: end.addingTimeInterval(3600), calendars: nil)
        let duration = end.timeIntervalSince(start)
        let best = store.events(matching: pred)
            .filter { !$0.isAllDay && $0.availability != .free }
            .map { e -> (EKEvent, TimeInterval) in
                (e, min(end, e.endDate).timeIntervalSince(max(start, e.startDate)))
            }
            .filter { $0.1 >= min(600, duration * 0.5) }
            .max { $0.1 < $1.1 }?.0
        guard let event = best else { return nil }
        let mc = context(of: event)
        // A personal block ("Gathering thoughts", "Picking up my daughter")
        // has nobody in it and nothing to spell.
        return mc.attendees.isEmpty && mc.inviteTerms.isEmpty ? nil : mc
    }

    private static let recordingStamp: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return f
    }()

    /// An invite term worth forcing as a spelling: a code, CamelCase, or a
    /// word no dictionary knows ("Kaiko", "Blits Insurance"). Title words
    /// like "Rollout" or "Planning" are not: given to the vocabulary pass,
    /// "roll out" became "Rollout" in the text.
    static func isCoined(_ term: String) -> Bool {
        term.split(separator: " ").contains { w in
            let word = String(w)
            return word.filter(\.isUppercase).count >= 2 || word.contains(where: \.isNumber)
                || !isOrdinaryWord(word)
        }
    }

    /// Known to the English or Dutch dictionary (Latin script) or the
    /// Ukrainian one (Cyrillic). Not Polish or German: the Polish checker
    /// accepts "kaiko" and "neona" as inflections.
    static func isOrdinaryWord(_ word: String) -> Bool {
        if !Thread.isMainThread { return DispatchQueue.main.sync { isOrdinaryWord(word) } }
        let w = word.lowercased()
        let cyrillic = w.unicodeScalars.contains { (0x400...0x52F).contains($0.value) }
        let checker = NSSpellChecker.shared
        return (cyrillic ? ["uk"] : ["en", "nl"]).filter { checker.availableLanguages.contains($0) }.contains {
            checker.checkSpelling(of: w, startingAt: 0, language: $0, wrap: false,
                                  inSpellDocumentWithTag: 0, wordCount: nil).location == NSNotFound
        }
    }

    static func context(of event: EKEvent) -> MeetingContext {
        var names: [String] = [], emails: [String] = []
        var people = event.attendees ?? []
        if let org = event.organizer, !people.contains(where: { $0.url == org.url }) { people.append(org) }
        for p in people where !p.isCurrentUser {
            let email = p.url.absoluteString.lowercased().replacingOccurrences(of: "mailto:", with: "")
            if email.contains("@") { emails.append(email) }
            // Rooms and groups are participants too; they are not names.
            guard p.participantType == .person || p.participantType == .unknown,
                  let name = p.name?.trimmingCharacters(in: .whitespaces), !name.isEmpty,
                  !name.contains("@") else { continue }
            names.append(name)
        }
        let text = [event.title ?? "", event.location ?? "", event.notes ?? ""].joined(separator: "\n")
        let nameWords = Set(names.flatMap { $0.lowercased().split(separator: " ").map(String.init) })
        return MeetingContext(
            title: event.title ?? "Meeting",
            attendees: dedup(names),
            emails: dedup(emails),
            inviteTerms: terms(in: text).filter { !nameWords.contains($0.lowercased()) && isCoined($0) },
            start: event.startDate, end: event.endDate)
    }

    /// Earlier events (newest first, up to `limit`) that share at least one
    /// attendee with `context`: where to look for the user's past meetings
    /// with the same people.
    static func pastEvents(sharing context: MeetingContext, days: Int = 180, limit: Int = 8,
                           store: EKEventStore = EKEventStore()) -> [DateInterval] {
        guard !context.emails.isEmpty,
              EKEventStore.authorizationStatus(for: .event) == .fullAccess else { return [] }
        let want = Set(context.emails)
        let from = context.start.addingTimeInterval(-Double(days) * 86_400)
        let pred = store.predicateForEvents(withStart: from, end: context.start.addingTimeInterval(-60), calendars: nil)
        return store.events(matching: pred)
            .filter { e in
                !e.isAllDay && (e.attendees ?? []).contains { p in
                    want.contains(p.url.absoluteString.lowercased().replacingOccurrences(of: "mailto:", with: ""))
                }
            }
            .sorted { $0.startDate > $1.startDate }
            .prefix(limit)
            .map { DateInterval(start: $0.startDate, end: max($0.startDate, $0.endDate)) }
    }

    /// Names said in earlier meetings with the same people: name-like words
    /// (`terms(in:)`) found in at least two of the transcripts, or three
    /// times in one. Most meetings first, then most mentions, at most `limit`.
    static func recurringTerms(in transcripts: [String], excluding known: [String], limit: Int = 40) -> [String] {
        let skip = Set(known.map { $0.lowercased() })
        // Known terms and their near misses ("Kaico" beside "Kaiko").
        let knownNorms = known.map { DisputeIndex.norm($0) }.filter { $0.count >= 3 }
        var nearKnown: [String: Bool] = [:]
        var docs: [String: Set<Int>] = [:], count: [String: Int] = [:], spelling: [String: String] = [:]
        for (i, t) in transcripts.enumerated() {
            for term in termOccurrences(in: t) where !term.contains(" ") {
                let k = term.lowercased()
                guard !skip.contains(k) else { continue }
                if nearKnown[k] == nil {
                    let n = DisputeIndex.norm(term)
                    nearKnown[k] = knownNorms.contains { EnsembleBackend.readingsAlike($0, n) }
                }
                guard nearKnown[k] == false else { continue }
                docs[k, default: []].insert(i)
                count[k, default: 0] += 1
                spelling[k] = spelling[k] ?? term
            }
        }
        return count.keys
            .filter { (docs[$0]?.count ?? 0) >= 2 || (count[$0] ?? 0) >= 3 }
            .sorted { (docs[$0]!.count, count[$0]!, $1) > (docs[$1]!.count, count[$1]!, $0) }
            .prefix(limit)
            .compactMap { spelling[$0] }
    }
}
