import Foundation
import SwiftData
import Observation

/// One recording a person speaks in, as plain values: the page draws these,
/// never the SwiftData relationships behind them.
nonisolated struct PersonMeeting: Identifiable, Equatable, Sendable {
    let id: UUID
    let title: String
    let date: Date
    /// Their talk time: the stretches their lines cover, overlapping lines
    /// counted once. Line timestamps include pauses, so it is generous.
    let seconds: Double
    let lines: Int
    let firstLine: Double
    /// Speaker keys that carry their name in this recording.
    let keys: Set<String>
    let lastSaid: String
    /// Words in their lines: the measure that padding does not inflate.
    var words: Int = 0
}

nonisolated enum PersonMeetings {
    /// Every recording with a line carrying `name`, newest first.
    static func load(_ name: String, repository: RecordingRepository) -> [PersonMeeting] {
        group((try? repository.segments(spokenBy: name)) ?? [])
    }

    /// The user's meetings: lines under their name, and the microphone
    /// track's ("ME") whatever name it carried when it was recorded.
    static func loadMine(_ name: String, repository: RecordingRepository) -> [PersonMeeting] {
        let named = (try? repository.segments(spokenBy: name)) ?? []
        let mic = (try? repository.segments(speakerKey: TranscriptionRunner.micSpeakerKey)) ?? []
        var seen = Set<UUID>()
        return group((named + mic).filter { seen.insert($0.id).inserted })
    }

    /// Lines of one person grouped into meetings, newest first.
    static func group(_ segments: [Segment]) -> [PersonMeeting] {
        var byRecording: [UUID: (recording: Recording, segments: [Segment])] = [:]
        for s in segments {
            guard let r = s.recording, !r.isDeleted else { continue }
            byRecording[r.id, default: (r, [])].segments.append(s)
        }
        return byRecording.values.compactMap { r, segs in
            let sorted = segs.sorted { $0.startSeconds < $1.startSeconds }
            guard let first = sorted.first, let last = sorted.last else { return nil }
            return PersonMeeting(
                id: r.id, title: r.title,
                date: Date(timeIntervalSince1970: TimeInterval(r.createdAtMillis) / 1000),
                seconds: SpeechMeasure.unionSeconds(sorted.map { (start: $0.startSeconds, end: $0.endSeconds) }),
                lines: sorted.count, firstLine: first.startSeconds,
                keys: Set(sorted.compactMap(\.speaker)), lastSaid: last.text,
                words: sorted.map { SpeechLexicon.words($0.text).count }.reduce(0, +))
        }
        .sorted { $0.date > $1.date }
    }

    /// "45 s", "12 min", "1 h 05 min".
    static func duration(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        if s < 60 { return "\(s) s" }
        if s < 3600 { return "\(s / 60) min" }
        return String(format: "%d h %02d min", s / 3600, (s / 60) % 60)
    }

    /// Talk as every page shows it: the time their lines cover, marked as
    /// approximate (timestamps include pauses), and the words, which are exact.
    static func talk(seconds: Double, words: Int) -> String {
        "~\(duration(seconds)) · \(words == 1 ? "1 word" : "\(words) words")"
    }

    static func talk(_ meetings: [PersonMeeting]) -> String {
        talk(seconds: meetings.map(\.seconds).reduce(0, +), words: meetings.map(\.words).reduce(0, +))
    }
}

/// What a person page shows from the library, read on a background context
/// and handed to the page as plain values.
nonisolated struct PersonPageData: Sendable {
    struct Candidate: Sendable {
        let hearing: Person.Hearing
        let title: String
        let date: Date
    }
    var meetings: [PersonMeeting] = []
    var speech: [MeetingSpeech] = []
    var candidates: [Candidate] = []

    /// `me` is the user's name: microphone-track lines count as theirs
    /// whatever name they carried when recorded.
    static func load(name: String, me: String, candidates: [Person.Hearing],
                     repository: RecordingRepository) -> PersonPageData {
        var out = PersonPageData()
        out.meetings = PersonMeetings.load(name, repository: repository)
        out.candidates = candidates.reversed().compactMap { h in
            guard let rec = try? repository.get(id: h.recordingId), !rec.isDeleted else { return nil }
            return Candidate(hearing: h, title: rec.title,
                             date: Date(timeIntervalSince1970: TimeInterval(rec.createdAtMillis) / 1000))
        }
        out.speech = SpeechHistory.load(name, repository: repository, meetings: out.meetings, micAs: me).meetings
        return out
    }
}

/// What the People overview shows from the library, read the same way.
nonisolated struct PeopleOverviewData: Sendable {
    /// Each saved person's meetings, by person id.
    var meetings: [UUID: [PersonMeeting]] = [:]
    /// Recordings the user was in: a microphone track, or a line under their name.
    var withMe: Set<UUID> = []
    var named: [VoiceSuggestions.Named] = []
    var groups: [VoiceSuggestions.Group] = []
    var titles: [UUID: String] = [:]
    var scanned = false

    static func load(people: [(id: UUID, name: String, centroid: [Float])], me: String,
                     repository: RecordingRepository) -> PeopleOverviewData {
        var out = PeopleOverviewData()
        // One fetch of every named line, however many people are saved.
        let byName = (try? repository.segmentsByNamedSpeaker()) ?? [:]
        for p in people { out.meetings[p.id] = PersonMeetings.group(byName[p.name.lowercased()] ?? []) }
        let mic = (try? repository.segments(speakerKey: TranscriptionRunner.micSpeakerKey)) ?? []
        out.withMe = Set((mic + (byName[me.lowercased()] ?? [])).compactMap { s -> UUID? in
            guard let r = s.recording, !r.isDeleted else { return nil }
            return r.id
        })
        // Suggestions: hand-typed names without a voice, recurring unnamed voices.
        out.named = VoiceSuggestions.named(
            byName.values.flatMap { $0 }.compactMap { s in
                guard let n = s.speakerName, let r = s.recording, !r.isDeleted else { return nil }
                return (n, r.id, max(0, s.endSeconds - s.startSeconds))
            },
            saved: Set(people.map { $0.name.lowercased() }), me: me)
        let unknown = UnknownVoiceStore.shared.load()
        out.scanned = !unknown.entries.isEmpty
        out.groups = VoiceSuggestions.groups(unknown, people: people.map { (name: $0.name, centroid: $0.centroid) },
                                             me: PeopleEmbedder.myVoice()?.centroid)
        out.titles = Dictionary(out.groups.flatMap(\.members).compactMap { m in
            (try? repository.get(id: m.recordingId)).map { (m.recordingId, $0.title) }
        }, uniquingKeysWith: { a, _ in a })
        return out
    }
}

/// Reads a person's recent meetings for their brief, one meeting at a
/// time on the text engine. App-wide, so leaving the page does not stop a
/// read that takes minutes on a local model.
@MainActor
@Observable
final class PersonBriefRunner {
    static let shared = PersonBriefRunner()

    private(set) var running: UUID?
    /// People in the current read: more than one for Refresh all.
    private(set) var batch = 0
    private(set) var progress: String?
    /// Per person: one person's failed read is not shown on another's page.
    private(set) var errors: [UUID: String] = [:]
    /// Bumped on every saved meeting, so the page re-reads the cache.
    private(set) var revision = 0
    @ObservationIgnored private var task: Task<Void, Never>?

    /// The text engine a brief runs on, and whether it leaves this Mac.
    static func engine(_ container: AppContainer) -> BackendFactory.Kind {
        let kind = container.uiPrefs.textEngine
        return kind.supportsTextGeneration ? kind : .localText
    }

    func build(person: Person, meetings: [PersonMeeting], container: AppContainer) {
        buildAll([(person, meetings)], container: container)
    }

    /// Reads several people in turn, one at a time like a single read:
    /// Refresh all on the overview.
    func buildAll(_ list: [(person: Person, meetings: [PersonMeeting])], container: AppContainer) {
        guard running == nil, let first = list.first else { return }
        running = first.person.id
        batch = list.count
        for l in list { errors[l.person.id] = nil }
        task = Task { @MainActor in
            defer { running = nil; progress = nil; task = nil; batch = 0 }
            for (n, l) in list.enumerated() {
                if Task.isCancelled { return }
                running = l.person.id
                await read(id: l.person.id, name: l.person.name, meetings: l.meetings, container: container,
                           prefix: list.count > 1 ? "\(l.person.name), \(n + 1) of \(list.count). " : "")
            }
        }
    }

    private func read(id: UUID, name: String, meetings: [PersonMeeting], container: AppContainer,
                      prefix: String) async {
        // Deleted since Refresh all started: nothing to read for them.
        guard PeopleStore.shared.load().contains(where: { $0.id == id }) else { return }
        let recent = Self.toRead(meetings)
        let store = PersonBriefStore.shared
        // Text read from meetings that were deleted since goes too.
        store.keep(only: Set(meetings.map(\.id)), for: id)
        let cached = Dictionary(store.entries(for: id).map { ($0.recordingId, $0.key) },
                                uniquingKeysWith: { $1 })
        var read = 0
        for (i, meeting) in recent.enumerated() {
            if Task.isCancelled { return }
            guard let rec = try? container.repository.get(id: meeting.id), !rec.isDeleted else { continue }
            let lines = rec.segments.sorted { $0.startSeconds < $1.startSeconds }.compactMap { s -> PersonBriefBuilder.Line? in
                let text = s.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { return nil }
                // "Speaker 2", never a raw key the model would copy ("Speaker_01").
                let who = s.speaker.map { SpeakerLabel.display(s.speakerName, key: $0) }
                    ?? s.speakerName.flatMap { $0.isEmpty ? nil : $0 } ?? "Someone"
                return .init(start: s.startSeconds, speaker: who, text: text)
            }
            let transcript = PersonBriefBuilder.transcript(lines, name: name)
            guard !transcript.isEmpty else { continue }
            let key = PersonBriefBuilder.key(transcript: transcript, name: name)
            if cached[meeting.id] == key { continue }
            // Cached under the older key, which held the name: still fresh,
            // and re-keyed so a later rename does not read it again.
            if let old = cached[meeting.id], old == PersonBriefBuilder.legacyKey(transcript: transcript, name: name),
               let entry = store.entries(for: id).first(where: { $0.recordingId == meeting.id }) {
                try? store.save(.init(recordingId: meeting.id, key: key, built: entry.built, brief: entry.brief), for: id)
                continue
            }
            progress = prefix + "Reading meeting \(i + 1) of \(recent.count): \(meeting.title)"
            let starts = lines.filter { $0.speaker.caseInsensitiveCompare(name) == .orderedSame }.map(\.start)
            // Fetched per meeting: housekeeping may release the shared
            // engine between two reads, and a held instance would then
            // load a second copy outside the factory.
            let backend = container.backendFactory.backend(for: Self.engine(container))
            do {
                if !(await backend.isReady) {
                    try await PersonBriefBuilder.bounded(seconds: 180) { try await backend.load(modelPath: nil) }
                }
                let result = try await PersonBriefBuilder.build(
                    transcript: transcript, name: name, lineStarts: starts
                ) { system, user, maxTokens in
                    try await PersonBriefBuilder.bounded(seconds: PersonBriefBuilder.timeoutSeconds) {
                        try await backend.generateText(systemInstruction: system, userMessage: user, maxTokens: maxTokens)
                    }
                }
                try Task.checkCancellation()
                // Deleted while the engine read: nothing of theirs is written back.
                guard PeopleStore.shared.load().contains(where: { $0.id == id }) else { return }
                // A brief missing a section is kept under no key, so a
                // refresh reads the meeting again.
                let previous = store.entries(for: id).first { $0.recordingId == meeting.id }?.brief
                try store.save(.init(recordingId: meeting.id, key: result.complete ? key : "",
                                     built: Date(), brief: result.brief), for: id)
                if let previous { store.carryClosed(from: previous, to: result.brief, recording: meeting.id, for: id) }
                if !result.complete { errors[id] = "Part of “\(meeting.title)” could not be read. Refresh tries it again." }
                read += 1
                revision &+= 1
            } catch is CancellationError {
                return
            } catch {
                errors[id] = "“\(meeting.title)” could not be read: \(error.localizedDescription)"
                AppLog.warn("person-brief", "\(meeting.id) failed: \(error.localizedDescription)")
                // A timed-out read means the engine is struggling; more
                // reads would only queue behind it.
                if case ASRError.chunkTimeout = error { break }
            }
        }
        AppLog.info("person-brief", "read \(read) of \(recent.count) meetings")
    }


    /// What a read covers: the last month's meetings, and always the
    /// newest one, however old.
    static func toRead(_ meetings: [PersonMeeting], now: Date = Date()) -> [PersonMeeting] {
        let since = now.addingTimeInterval(-PersonBriefBuilder.recentDays * 86_400)
        return Array(meetings.enumerated()
            .filter { $0.offset == 0 || $0.element.date >= since }
            .map(\.element)
            .prefix(PersonBriefBuilder.maxMeetings))
    }

    func cancel() { task?.cancel() }

    /// A person is being deleted: their read stops before it writes again.
    func cancel(person: UUID) {
        // In Refresh all the others go on; nothing of theirs is written
        // once they are gone (see `read`).
        if running == person, batch <= 1 { task?.cancel() }
        errors[person] = nil
    }
}

/// A person's brief across meetings, newest meeting first, each item with
/// the meeting it came from, for one period: their last meeting, the last
/// week or the last month.
struct PersonBriefView: Equatable {
    enum Period: String, CaseIterable, Identifiable {
        case lastMeeting, week, month
        var id: String { rawValue }
        var label: String {
            switch self {
            case .lastMeeting: return "Last meeting"
            case .week: return "Last week"
            case .month: return "Last month"
            }
        }
        /// "in the last week", for sentences.
        var phrase: String {
            switch self {
            case .lastMeeting: return "in the last meeting"
            case .week: return "in the last week"
            case .month: return "in the last month"
            }
        }
        var days: Double? {
            switch self {
            case .lastMeeting: return nil
            case .week: return 7
            case .month: return 30
            }
        }
    }

    struct Row: Identifiable, Equatable {
        enum Kind: String { case commitment, question, topic }
        let kind: Kind
        let item: PersonBrief.Item
        let meeting: PersonMeeting
        /// Stable across re-reads, and what Done or Not relevant is kept under.
        var id: String { PersonBriefStore.itemKey(meeting.id, kind.rawValue, (item.topic.map { $0 + ": " } ?? "") + item.text) }
    }
    /// What they mainly said in one meeting.
    struct Gist: Identifiable, Equatable {
        let text: String
        let meeting: PersonMeeting
        var id: UUID { meeting.id }
    }
    var gists: [Gist] = []
    var commitments: [Row] = []
    var questions: [Row] = []
    var topics: [Row] = []
    /// Meetings in the period, and how many of them have been read.
    var meetings: [PersonMeeting] = []
    var readMeetings = 0
    var unread: Int { meetings.count - readMeetings }
    var isEmpty: Bool { gists.isEmpty && commitments.isEmpty && questions.isEmpty && topics.isEmpty }

    static let maxCommitments = 15
    static let maxQuestions = 10
    static let maxTopics = 12
    /// Two items share at least this much of their words: the same thing
    /// said again in a later meeting, shown once, from the newest.
    static let sameItem = 0.6

    /// `closed` are the rows marked Done or Not relevant; they are counted,
    /// and listed apart (`closedRows`) so a mark can be undone.
    var closedCount = 0
    var closedRows: [Row] = []

    /// The meetings of a period, newest first. Nil is every meeting.
    static func meetings(_ all: [PersonMeeting], in period: Period?, now: Date = Date()) -> [PersonMeeting] {
        guard let period else { return all }
        guard let days = period.days else { return Array(all.prefix(1)) }
        let since = now.addingTimeInterval(-days * 86_400)
        return all.filter { $0.date >= since }
    }

    static func combine(_ entries: [PersonBriefStore.Entry], meetings all: [PersonMeeting],
                        closed: Set<String> = [], period: Period? = nil, now: Date = Date()) -> PersonBriefView {
        let byId = Dictionary(entries.map { ($0.recordingId, $0) }, uniquingKeysWith: { $1 })
        var out = PersonBriefView()
        out.meetings = meetings(all, in: period, now: now)
        var seenTopics = Set<String>()
        var seenItems: [Row.Kind: [Set<String>]] = [:]
        // Row ids key the page's ForEach and Done: the same text twice in
        // one meeting (too short to have meaning words) is shown once.
        var seenIds = Set<String>()
        var seenClosed = Set<String>()
        func words(_ s: String) -> Set<String> { PersonBriefStore.meaningWords(s) }
        /// Said before in a newer meeting already shown.
        func repeated(_ kind: Row.Kind, _ text: String) -> Bool {
            let w = words(text)
            if seenItems[kind, default: []].contains(where: { PersonBriefStore.overlap($0, w) >= sameItem }) { return true }
            seenItems[kind, default: []].append(w)
            return false
        }
        for m in out.meetings {
            guard let e = byId[m.id] else { continue }
            out.readMeetings += 1
            if let g = e.brief.gist, !g.isEmpty {
                out.gists.append(Gist(text: g.joined(separator: " "), meeting: m))
            }
            for c in e.brief.commitments {
                let row = Row(kind: .commitment, item: c, meeting: m)
                if closed.contains(row.id) {
                    if seenClosed.insert(row.id).inserted { out.closedCount += 1; out.closedRows.append(row) }
                }
                else if seenIds.insert(row.id).inserted, !repeated(.commitment, c.text) { out.commitments.append(row) }
            }
            for q in e.brief.questions {
                let row = Row(kind: .question, item: q, meeting: m)
                if closed.contains(row.id) {
                    if seenClosed.insert(row.id).inserted { out.closedCount += 1; out.closedRows.append(row) }
                }
                else if seenIds.insert(row.id).inserted, !repeated(.question, q.text) { out.questions.append(row) }
            }
            // Newest meeting first: the first word on a topic is the last said.
            for t in e.brief.topics where seenTopics.insert((t.topic ?? t.text).lowercased()).inserted {
                out.topics.append(Row(kind: .topic, item: t, meeting: m))
            }
        }
        out.commitments = Array(out.commitments.prefix(maxCommitments))
        out.questions = Array(out.questions.prefix(maxQuestions))
        out.topics = Array(out.topics.prefix(maxTopics))
        return out
    }
}

extension PersonBriefView {
    /// The brief as plain text, to paste into notes before a meeting.
    func text(for name: String, period: Period? = nil) -> String {
        func day(_ d: Date) -> String { d.formatted(date: .abbreviated, time: .omitted) }
        var out = [period.map { "\(name), \($0.label.lowercased())" } ?? name]
        if !gists.isEmpty {
            out.append("\nIn short")
            out += gists.map { "- \($0.text) (\($0.meeting.title), \(day($0.meeting.date)))" }
        }
        if !commitments.isEmpty {
            out.append("\nCommitted to")
            out += commitments.map { "- \($0.item.text) (\($0.meeting.title), \(day($0.meeting.date)))" }
        }
        if !questions.isEmpty {
            out.append("\nOpen questions")
            out += questions.map { "- \($0.item.text) (\($0.meeting.title), \(day($0.meeting.date)))" }
        }
        if !topics.isEmpty {
            out.append("\nLast said on")
            out += topics.map { "- \($0.item.topic ?? ""): \($0.item.text) (\(day($0.meeting.date)))" }
        }
        return out.joined(separator: "\n")
    }
}
