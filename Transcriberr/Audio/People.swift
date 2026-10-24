import Foundation

/// People whose voices the app knows, so a recording names them instead of
/// "Speaker 2". A person is learned from a speaker in one recording (Rename
/// speaker → Remember this voice) and found in later ones: after every run,
/// and on demand from Detail.
///
/// The voices are the same WeSpeaker prints as the user's own (Voiceprint),
/// kept beside it in ~/Library/Application Support/Transcriberr/voice/, out
/// of Time Machine and never copied into ~/Documents: they are biometric
/// data of people who never agreed to be enrolled, and each can be deleted.
struct Person: Codable, Identifiable, Equatable {
    var id: UUID
    var name: String
    var created: Date
    var updated: Date
    var print: Voiceprint
    /// Recordings the voice was learned from. Each one adds embeddings, so
    /// a person heard on a call and in a room matches in both.
    var sources: Int
    /// Recordings the voice was learned from (5.0.0; nil in older files),
    /// so the person page can offer the named ones not learned yet.
    var learnedFrom: [UUID]? = nil
    /// Automatic matches, newest last: the track record behind the voice
    /// confidence on the person page.
    var matches: [Hearing]? = nil
    /// Speakers that sounded like this person without clearing the bar,
    /// offered on the person page as "Was this them?".
    var candidates: [Hearing]? = nil
    /// Candidates the user said were someone else, never offered again.
    var dismissed: [String]? = nil
    /// Candidates the user said were this person: named, and not offered
    /// again even when their voice could not be learned.
    var settled: [String]? = nil
    /// Named recordings tried with nothing learnable in them (too little
    /// clean speech), so "Learn from" does not offer them again.
    var triedFrom: [UUID]? = nil

    /// For a person saved before 5.0.0: the last training then. Named
    /// recordings up to it are taken as learned (their source was not kept).
    var legacyCutoff: Date? = nil

    /// Made by the embedding model in use: only then can it be matched.
    var isComparable: Bool { print.model == Voiceprint.currentModel }
    /// Where each run of `print.embeddings` came from, in order (5.0.0), so
    /// one bad sample can be forgotten without deleting the person. Nil in
    /// older files: their embeddings are one "earlier" sample.
    var samples: [Sample]? = nil

    /// One learning: a speaker of a recording, or a reading at this Mac.
    struct Sample: Codable, Equatable, Identifiable {
        var id: UUID
        /// Nil for a reading, or for everything learned before 5.0.0.
        var recordingId: UUID?
        var date: Date
        var seconds: Double
        /// How many of the print's embeddings are this sample's.
        var count: Int
        /// Learned before samples were kept apart: source unknown.
        var earlier: Bool? = nil
    }

    /// The samples, with an older file's embeddings as one earlier sample.
    var allSamples: [Sample] {
        if let samples { return samples }
        guard !print.embeddings.isEmpty else { return [] }
        return [Sample(id: Self.earlierSampleId(id), recordingId: nil, date: created,
                       seconds: print.seconds, count: print.embeddings.count, earlier: true)]
    }

    /// Stable, so the page can forget the earlier sample by id.
    static func earlierSampleId(_ person: UUID) -> UUID {
        var bytes = person.uuid
        bytes.15 ^= 0xA5
        return UUID(uuid: bytes)
    }

    /// Adds a learning's embeddings as a new sample, then trims to the cap.
    mutating func add(_ learned: Voiceprint, from recording: UUID?, now: Date, earlier: Bool? = nil) {
        if samples == nil, learnedFrom == nil, legacyCutoff == nil { legacyCutoff = updated }
        var list = allSamples
        list.append(Sample(id: UUID(), recordingId: recording, date: now,
                           seconds: learned.seconds, count: learned.embeddings.count, earlier: earlier))
        print = Voiceprint(model: print.model, created: print.created, seconds: print.seconds + learned.seconds,
                           embeddings: print.embeddings + learned.embeddings)
        samples = list
        trim()
    }

    /// Keeps at most `maxEmbeddings`, taken from every sample in proportion
    /// (and at least `minPerSample` from each), spread evenly through each.
    /// Keeping only the newest let one long recording push out the voice
    /// heard elsewhere (seen 2026-10-23: a 146 s enrollment cut to 7 s by a
    /// 147 s learning), when the mix of microphones is the point.
    mutating func trim() {
        let list = allSamples
        let total = list.map(\.count).reduce(0, +)
        guard total > Self.maxEmbeddings, total == print.embeddings.count else { return }
        var quota = list.map { max(min($0.count, Self.minPerSample), $0.count * Self.maxEmbeddings / total) }
        while quota.reduce(0, +) > Self.maxEmbeddings, let i = quota.indices.max(by: { quota[$0] < quota[$1] }) {
            quota[i] -= 1
        }
        var kept: [[Float]] = [], trimmed: [Sample] = []
        var start = 0
        for (s, q) in zip(list, quota) {
            let own = Array(print.embeddings[start..<(start + s.count)])
            let pick = q >= own.count ? own : (0..<q).map { own[$0 * own.count / q] }
            var t = s
            t.seconds = s.seconds * Double(pick.count) / Double(max(1, s.count))
            t.count = pick.count
            if t.count > 0 { trimmed.append(t); kept += pick }
            start += s.count
        }
        print = Voiceprint(model: print.model, created: print.created,
                           seconds: trimmed.map(\.seconds).reduce(0, +), embeddings: kept)
        samples = trimmed
    }

    /// Removes one sample's embeddings. False when it is the last one: a
    /// person without a voice is deleted, not emptied.
    mutating func forget(sample id: UUID) -> Bool {
        var list = allSamples
        guard list.count > 1, let i = list.firstIndex(where: { $0.id == id }) else { return false }
        let start = list[..<i].map(\.count).reduce(0, +)
        let gone = list.remove(at: i)
        var embeddings = print.embeddings
        embeddings.removeSubrange(start..<min(embeddings.count, start + gone.count))
        print = Voiceprint(model: print.model, created: print.created,
                           seconds: max(0, print.seconds - gone.seconds), embeddings: embeddings)
        samples = list
        sources = max(1, sources - 1)
        if let rec = gone.recordingId, !list.contains(where: { $0.recordingId == rec }) {
            learnedFrom = learnedFrom?.filter { $0 != rec }
            // Forgotten on purpose: "Learn from" must not offer it straight back.
            triedFrom = Array(Set((triedFrom ?? []) + [rec]))
        }
        return true
    }

    /// How much each sample sounds like the rest of the voice: the mean
    /// similarity of its embeddings to the centroid of all the others.
    /// Empty with one sample, which has nothing to be compared with.
    var sampleAgreement: [UUID: Float] {
        let list = allSamples
        guard list.count > 1 else { return [:] }
        var out: [UUID: Float] = [:]
        var start = 0
        for s in list {
            let end = min(print.embeddings.count, start + s.count)
            let own = Array(print.embeddings[start..<end])
            let rest = Array(print.embeddings[..<start] + print.embeddings[end...])
            if !own.isEmpty, !rest.isEmpty {
                let c = VoiceActivity.normalizedMean(rest)
                out[s.id] = own.map { VoiceActivity.cosine($0, c) }.reduce(0, +) / Float(own.count)
            }
            start = end
        }
        return out
    }

    /// The sample least like the rest, when it stands out: under 0.5, or
    /// 0.15 under the others' median.
    var oddSample: UUID? {
        let a = sampleAgreement
        guard let worst = a.min(by: { $0.value < $1.value }) else { return nil }
        let others = a.filter { $0.key != worst.key }.map(\.value)
        let median = ClusterVoice.median(others)
        return worst.value < 0.5 || (!others.isEmpty && worst.value < median - 0.15) ? worst.key : nil
    }

    /// One speaker of one recording scored against this person.
    struct Hearing: Codable, Equatable, Identifiable {
        var recordingId: UUID
        var speaker: String
        var score: Float
        var date: Date
        var id: String { Self.key(recordingId, speaker) }
        static func key(_ recordingId: UUID, _ speaker: String) -> String { "\(recordingId.uuidString)|\(speaker)" }
    }

    /// At most this many embeddings per person, the newest kept: enough to
    /// span a few microphones without the file growing with every save.
    static let maxEmbeddings = 120
    /// Each sample keeps at least this many when trimmed.
    static let minPerSample = 8
    static let maxMatches = 50
    static let maxCandidates = 20
}

struct PeopleStore {
    let url: URL
    /// The user's own voice, compared against like any saved person's so a
    /// sample of the user is never filed under someone else.
    var myVoice: @Sendable () -> [Float]? = { VoiceprintStore.load()?.centroid }

    /// What their meetings said, kept beside the voices and deleted with them.
    var briefs: PersonBriefStore {
        PersonBriefStore(url: url.deletingLastPathComponent().appendingPathComponent("people-briefs.json"))
    }

    static var shared: PeopleStore {
        let path = ProcessInfo.processInfo.environment["TRANSCRIBERR_PEOPLE"]
        return PeopleStore(url: path.map { URL(fileURLWithPath: $0) }
            ?? VoiceprintStore.directory.appendingPathComponent("people.json"))
    }

    static let didChange = Notification.Name("PeopleStore.didChange")

    enum PeopleError: LocalizedError {
        case emptyName, missing, unreadable, lastSample
        case nameTaken(String)
        case notSamePerson(name: String, score: Float, closer: String?)
        var errorDescription: String? {
            switch self {
            case .emptyName: return "Enter a name for this person."
            case .missing: return "That person is no longer saved."
            case .lastSample: return "This is the only sample of their voice. Delete the person instead."
            case .nameTaken(let n): return "\(n) is already saved. Use Merge into to make them one person."
            case .notSamePerson(let name, let score, let closer):
                return closer.map { String(format: "This voice sounds more like %@ than like %@ (%.2f), so it was not added to %@.", $0, name, score, name) }
                    ?? String(format: "This voice does not sound like %@'s saved voice (%.2f, at least %.2f needed), so it was not added.", name, score, VoiceGate.sameMin)
            case .unreadable: return "The saved people file cannot be read. It was left as it is."
            }
        }
    }

    private struct File: Codable {
        var version = 1
        var people: [Person] = []
    }

    /// Everyone saved, by name. A damaged file reads as nobody; the writes
    /// below refuse to replace it.
    func load() -> [Person] {
        (try? read())?.filter(\.isComparable).sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending } ?? []
    }

    private func read() throws -> [Person] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        guard let file = try? JSONDecoder().decode(File.self, from: Data(contentsOf: url)),
              file.version == 1 else { throw PeopleError.unreadable }
        // Everyone, those of another embedding model included: every write
        // goes through here, and they must survive it (their samples can be
        // re-embedded). `load()` leaves them out.
        return file.people
    }

    private func write(_ people: [Person]) throws {
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var excluded = dir
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? excluded.setResourceValues(values)
        try JSONEncoder().encode(File(people: people)).write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }

    /// Saves a voice under `name`. A person of that name (any case) gets
    /// the new embeddings added; otherwise a new person is made.
    /// `recording` is where the voice came from, nil for a reading at this
    /// Mac; that recording's suggestions for the person are settled by it.
    @discardableResult
    func remember(_ print: Voiceprint, as name: String, from recording: UUID? = nil,
                  now: Date = Date()) throws -> Person {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw PeopleError.emptyName }
        var people = try read()
        var p: Person
        let i = people.firstIndex(where: {
            $0.isComparable && $0.name.caseInsensitiveCompare(trimmed) == .orderedSame
        })
        if let i {
            p = people[i]
            try gate(print, onto: p, among: people)
            p.add(print, from: recording, now: now)
            p.updated = now
            p.sources += 1
        } else {
            p = Person(id: UUID(), name: trimmed, created: now, updated: now, print: print, sources: 1)
            p.samples = [Person.Sample(id: UUID(), recordingId: recording, date: now,
                                       seconds: print.seconds, count: print.embeddings.count)]
            p.trim()
        }
        if let recording {
            p.learnedFrom = (p.learnedFrom ?? []).filter { $0 != recording } + [recording]
            p.candidates = p.candidates?.filter { $0.recordingId != recording }
        }
        if let i { people[i] = p } else { people.append(p) }
        try write(people)
        return p
    }

    /// Throws unless `print` is clearly the same voice as `person`: see
    /// VoiceGate. Every path that adds to a saved voice comes through here.
    func gate(_ print: Voiceprint, onto person: Person, among people: [Person]) throws {
        let others = people.filter { $0.id != person.id && $0.isComparable }.map { ($0.name, $0.print.centroid) }
            + (myVoice().map { [("you", $0)] } ?? [])
        let v = VoiceGate.check(print, against: person.print, others: others)
        guard v.accepted else {
            throw PeopleError.notSamePerson(name: person.name, score: v.score, closer: v.closer?.name)
        }
    }

    /// Whether `print` would be accepted onto saved person `id`.
    func check(_ print: Voiceprint, for id: UUID) throws {
        let people = try read()
        guard let p = people.first(where: { $0.id == id }) else { throw PeopleError.missing }
        try gate(print, onto: p, among: people)
    }

    /// Adds to one saved person by id, never by name: a page that captured
    /// the person before a long learn must not recreate them after a delete
    /// or file the voice under a name that has since changed.
    @discardableResult
    func add(_ print: Voiceprint, to id: UUID, from recording: UUID?, now: Date = Date()) throws -> Person {
        var people = try read()
        guard let i = people.firstIndex(where: { $0.id == id }) else { throw PeopleError.missing }
        var p = people[i]
        try gate(print, onto: p, among: people)
        p.add(print, from: recording, now: now)
        p.updated = now
        p.sources += 1
        if let recording {
            p.learnedFrom = (p.learnedFrom ?? []).filter { $0 != recording } + [recording]
            p.candidates = p.candidates?.filter { $0.recordingId != recording }
        }
        people[i] = p
        try write(people)
        return p
    }

    /// A named recording had nothing learnable for this person.
    func tried(_ recording: UUID, for id: UUID) throws {
        var people = try read()
        guard let i = people.firstIndex(where: { $0.id == id }) else { throw PeopleError.missing }
        people[i].triedFrom = Array(Set((people[i].triedFrom ?? []) + [recording]))
        try write(people)
    }

    /// Logs what one matching pass over a recording found: the matches as
    /// each person's track record, the near misses as their candidates.
    /// Everything earlier for that recording is replaced, so a re-run or a
    /// second Find people does not count twice.
    func log(_ found: [String: PeopleMatch.Assessment], in recording: UUID, now: Date = Date()) throws {
        var people = try read()
        guard !people.isEmpty else { return }
        for i in people.indices {
            people[i].matches = people[i].matches?.filter { $0.recordingId != recording }
            people[i].candidates = people[i].candidates?.filter { $0.recordingId != recording }
        }
        for (key, a) in found.sorted(by: { $0.key < $1.key }) {
            guard let i = people.firstIndex(where: { $0.id == a.person.id }) else { continue }
            let hearing = Person.Hearing(recordingId: recording, speaker: key, score: a.score, date: now)
            if a.accepted {
                people[i].matches = Array(((people[i].matches ?? []) + [hearing]).suffix(Person.maxMatches))
            } else if a.isNearMiss, !(people[i].dismissed ?? []).contains(hearing.id),
                      !(people[i].settled ?? []).contains(hearing.id),
                      !(people[i].learnedFrom ?? []).contains(recording) {
                people[i].candidates = Array(((people[i].candidates ?? []) + [hearing]).suffix(Person.maxCandidates))
            }
        }
        try write(people)
    }

    /// The user answered a candidate. Someone else is remembered, so the
    /// same speaker is not offered again after a re-run.
    func resolve(_ hearing: Person.Hearing, for id: UUID, wasThem: Bool) throws {
        var people = try read()
        guard let i = people.firstIndex(where: { $0.id == id }) else { throw PeopleError.missing }
        people[i].candidates = people[i].candidates?.filter { $0.id != hearing.id }
        if wasThem {
            people[i].settled = Array(((people[i].settled ?? []) + [hearing.id]).suffix(200))
        } else {
            people[i].dismissed = Array(((people[i].dismissed ?? []) + [hearing.id]).suffix(200))
        }
        try write(people)
    }

    /// A rebuilt voice replaces the person's samples (Improve on their page):
    /// one per item, in order, then trimmed to the cap. The caller has
    /// already checked that it scores better.
    func replaceVoice(of id: UUID, with items: [(recordingId: UUID?, earlier: Bool?, date: Date, print: Voiceprint)],
                      now: Date = Date()) throws {
        var people = try read()
        guard let i = people.firstIndex(where: { $0.id == id }), !items.isEmpty else { throw PeopleError.missing }
        var p = people[i]
        p.print = Voiceprint(model: p.print.model, created: p.print.created,
                             seconds: items.map(\.print.seconds).reduce(0, +),
                             embeddings: items.flatMap(\.print.embeddings))
        p.samples = items.map {
            Person.Sample(id: UUID(), recordingId: $0.recordingId, date: $0.date,
                          seconds: $0.print.seconds, count: $0.print.embeddings.count, earlier: $0.earlier)
        }
        p.trim()
        p.sources = items.count
        let recs = items.compactMap(\.recordingId)
        p.learnedFrom = Array(Set((p.learnedFrom ?? []) + recs))
        p.candidates = p.candidates?.filter { !recs.contains($0.recordingId) }
        p.updated = now
        people[i] = p
        try write(people)
    }

    /// Forgets one sample of a person's voice.
    func forget(sample: UUID, of id: UUID) throws {
        var people = try read()
        guard let i = people.firstIndex(where: { $0.id == id }) else { throw PeopleError.missing }
        guard people[i].forget(sample: sample) else { throw PeopleError.lastSample }
        people[i].updated = Date()
        try write(people)
    }

    /// Renames a person and returns the old name, for the caller to carry
    /// into the recordings that use it. A name another person has is a
    /// merge, never a rename.
    @discardableResult
    func rename(_ id: UUID, to name: String) throws -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw PeopleError.emptyName }
        var people = try read()
        guard let i = people.firstIndex(where: { $0.id == id }) else { throw PeopleError.missing }
        if people.contains(where: { $0.id != id && $0.isComparable && $0.name.caseInsensitiveCompare(trimmed) == .orderedSame }) {
            throw PeopleError.nameTaken(trimmed)
        }
        // `updated` stays: it is when the voice last changed (legacyCutoff).
        let old = people[i].name
        people[i].name = trimmed
        try write(people)
        return old
    }

    /// Joins `source` into `target`: one voice, one history. Returns the
    /// source's name, for the caller to rename in recordings. What was read
    /// from the source's meetings goes; the target's page reads them again.
    @discardableResult
    func merge(_ source: UUID, into target: UUID, now: Date = Date()) throws -> String {
        var people = try read()
        guard source != target,
              let si = people.firstIndex(where: { $0.id == source }),
              let ti = people.firstIndex(where: { $0.id == target }) else { throw PeopleError.missing }
        let s = people[si]
        var t = people[ti]
        // Merge is for one person saved twice: never for two voices.
        try gate(s.print, onto: t, among: people.filter { $0.id != s.id })
        // Sample by sample, so each stays forgettable after the merge.
        var start = 0
        for sample in s.allSamples {
            let end = min(s.print.embeddings.count, start + sample.count)
            let part = Voiceprint(model: s.print.model, created: sample.date, seconds: sample.seconds,
                                  embeddings: Array(s.print.embeddings[start..<end]))
            t.add(part, from: sample.recordingId, now: sample.date, earlier: sample.earlier)
            start = end
        }
        t.sources += s.sources
        t.learnedFrom = Array(Set((t.learnedFrom ?? []) + (s.learnedFrom ?? [])))
        let matched = Set((t.matches ?? []).map(\.id))
        t.matches = Array(((t.matches ?? []) + (s.matches ?? []).filter { !matched.contains($0.id) })
            .sorted { $0.date < $1.date }.suffix(Person.maxMatches))
        let learned = Set(t.learnedFrom ?? [])
        let asked = Set((t.candidates ?? []).map(\.id))
        t.candidates = Array(((t.candidates ?? []) + (s.candidates ?? []).filter {
            !asked.contains($0.id) && !learned.contains($0.recordingId)
        }).suffix(Person.maxCandidates))
        t.dismissed = Array(Set((t.dismissed ?? []) + (s.dismissed ?? [])))
        t.settled = Array(Set((t.settled ?? []) + (s.settled ?? [])))
        t.triedFrom = Array(Set((t.triedFrom ?? []) + (s.triedFrom ?? [])))
        t.updated = now
        people[ti] = t
        people.remove(at: si)
        try write(people)
        briefs.delete(person: source)
        return s.name
    }

    func delete(_ id: UUID) throws {
        var people = try read()
        people.removeAll { $0.id == id }
        try write(people)
        briefs.delete(person: id)
    }

    func deleteAll() throws {
        try? FileManager.default.removeItem(at: url)
        briefs.deleteAll()
        UnknownVoiceStore(url: url.deletingLastPathComponent().appendingPathComponent("unknown-voices.json")).deleteAll()
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }
}

/// Which saved person each speaker of a recording is. Pure: embeddings in,
/// names out, so the rule is tested without audio.
enum PeopleMatch {
    /// A speaker is a person when the median similarity of its clips to the
    /// person's voice is at least `VoiceActivity.onThreshold` and
    /// `ClusterVoice.margin` above the next person. The same calibration
    /// as the user's own print: 0.49-0.70 for the right voice, at most 0.32
    /// for others. Two people both close are left unnamed, never guessed.
    static func assign(_ clusters: [String: [[Float]]], people: [Person]) -> [String: Person] {
        assess(clusters, people: people).compactMapValues { $0.accepted ? $0.person : nil }
    }

    /// The closest person to one speaker, and whether the rule above names
    /// the speaker after them.
    struct Assessment: Equatable {
        var person: Person
        var score: Float
        var runnerUp: Float?
        var accepted: Bool
        /// Close enough to ask the user, not close enough to decide: over
        /// the off threshold but under the bar, or over it next to someone
        /// just as close.
        var isNearMiss: Bool { !accepted && score >= VoiceActivity.offThreshold }
    }

    /// Every scored speaker's closest person, matched or not.
    static func assess(_ clusters: [String: [[Float]]], people: [Person]) -> [String: Assessment] {
        guard !people.isEmpty else { return [:] }
        var out: [String: Assessment] = [:]
        for (key, clips) in clusters where clips.count >= ClusterVoice.minClips {
            let ranked = people.map { p in
                (p, ClusterVoice.median(clips.map { VoiceActivity.cosine($0, p.print.centroid) }))
            }.sorted { $0.1 > $1.1 }
            guard let best = ranked.first else { continue }
            let second = ranked.count > 1 ? ranked[1].1 : nil
            let accepted = best.1 >= VoiceActivity.onThreshold
                && (second.map { best.1 - $0 >= ClusterVoice.margin } ?? true)
            out[key] = Assessment(person: best.0, score: best.1, runnerUp: second, accepted: accepted)
        }
        return out
    }

    /// Speakers whose name may be set by a match: unnamed ones, and ones
    /// carrying a saved person's name (an earlier match, or a name typed
    /// before the person was saved). A name typed by hand that is no
    /// person's, and the user's own, are never touched.
    static func renamable(names: [String: String?], people: [Person], me: String) -> Set<String> {
        let known = Set(people.map { $0.name.lowercased() })
        return Set(names.compactMap { key, name in
            // Lines tagged by hand: the user already said who that is.
            if key.hasPrefix(RecordingRepository.taggedKeyPrefix) { return nil }
            guard let name, !name.isEmpty else { return key }
            if name.lowercased() == me.lowercased() { return nil }
            return known.contains(name.lowercased()) ? key : nil
        })
    }
}

/// The audio side: learn a speaker's voice from a recording, and find saved
/// people in one.
enum PeopleVoice {
    /// Who speaks when, as one string: taken before a long await and
    /// compared after, it says whether the transcript was replaced meanwhile
    /// (a re-run reuses keys like SPEAKER_00 for whoever it finds).
    @MainActor
    static func signature(_ recording: Recording) -> String {
        recording.segments.sorted { $0.startSeconds < $1.startSeconds }
            .map { "\($0.speaker ?? "")@\($0.startSeconds)" }.joined(separator: ",")
    }

    enum LearnError: LocalizedError {
        case tooLittleSpeech(seconds: Double)
        var errorDescription: String? {
            switch self {
            case .tooLittleSpeech(let s):
                return "This speaker has \(Int(s)) s of speech without anyone talking over them; at least \(Int(PeopleVoice.minLearnSeconds)) s are needed to learn a voice."
            }
        }
    }

    static let minLearnSeconds = 10.0
    static let maxLearnSeconds = 60.0

    /// One region per segment that has a speaker. Segments of the user and
    /// of others alike: overlap with anyone excludes a stretch.
    static func regions(_ segments: [Segment]) -> [DiarizationRunner.SpeakerSegment] {
        segments.compactMap { s in
            guard let key = s.speaker, s.endSeconds > s.startSeconds else { return nil }
            return DiarizationRunner.SpeakerSegment(startSeconds: s.startSeconds, endSeconds: s.endSeconds, speakerId: key)
        }
    }

    /// The speaker's clean stretches (no one else in them, edges trimmed),
    /// joined, at most `maxLearnSeconds`.
    static func cleanSpeech(of key: String, regions: [DiarizationRunner.SpeakerSegment], samples: [Float]) -> [Float] {
        let rate = VoiceActivity.sampleRate
        let others = regions.filter { $0.speakerId != key }
        // The best parts first: the longest stretches with nobody else in
        // them carry the steadiest voice; short ones are mostly edges and
        // back-channel. Taken longest first up to the cap, then in order.
        var stretches: [Range<Int>] = []
        for r in regions where r.speakerId == key {
            let a = r.startSeconds + ClusterVoice.inset, b = r.endSeconds - ClusterVoice.inset
            guard b > a, !others.contains(where: { $0.startSeconds < b && $0.endSeconds > a }) else { continue }
            let lo = max(0, Int(a * rate)), hi = min(samples.count, Int(b * rate))
            if hi > lo { stretches.append(lo..<hi) }
        }
        var chosen: [Range<Int>] = [], total = 0
        for r in stretches.sorted(by: { $0.count > $1.count }) where Double(total) < maxLearnSeconds * rate {
            chosen.append(r)
            total += r.count
        }
        var out: [Float] = []
        for r in chosen.sorted(by: { $0.lowerBound < $1.lowerBound }) { out.append(contentsOf: samples[r]) }
        return out
    }

    /// A voice print of one speaker of a recording.
    ///
    /// The recording is read here, on the main actor, and only plain values
    /// go on: as a non-isolated async function this used to run on a
    /// background thread and walk the main context's segments there, which
    /// crashed SwiftData when the person page reloaded at the same moment
    /// (2026-10-23, Learn from named recordings).
    @MainActor
    static func learn(speaker key: String, in recording: Recording) async throws -> Voiceprint {
        let all = regions(recording.segments.sorted { $0.startSeconds < $1.startSeconds })
        let src = source(for: key, in: recording, regions: all)
        // Every key carrying this speaker's name is them (folded or not).
        let name = recording.segments.first { $0.speaker == key }?.speakerName
        let keys = Set(recording.segments.filter {
            $0.speaker == key || (name != nil && $0.speakerName?.caseInsensitiveCompare(name!) == .orderedSame)
        }.compactMap(\.speaker))
        let merged = src.regions.map { r in
            keys.contains(r.speakerId)
                ? DiarizationRunner.SpeakerSegment(startSeconds: r.startSeconds, endSeconds: r.endSeconds, speakerId: key)
                : r
        }
        return try await learn(speaker: key, regions: merged, audioPath: src.path)
    }

    /// Which audio a speaker's voice is read from. A meeting recorded with
    /// the call on its own track: the microphone's lines are padded across
    /// the call's (your lines ran 1,033 s against Alex's 1,007 s in an 18-min
    /// meeting), so on the mix nobody else ever spoke "without anyone
    /// talking over them" and nothing could be learned. The call side is
    /// read from the call track, where the microphone is not; the user's
    /// own key from the mic track.
    @MainActor
    static func source(for key: String, in recording: Recording,
                       regions: [DiarizationRunner.SpeakerSegment]) -> (path: String, regions: [DiarizationRunner.SpeakerSegment]) {
        let me = TranscriptionRunner.micSpeakerKey
        let main = URL(fileURLWithPath: recording.audioPath)
        guard regions.contains(where: { $0.speakerId == me }) else { return (recording.audioPath, regions) }
        if key == me, let mic = AudioCompressor.sidecarURL(for: main, kind: "mic") {
            return (mic.path, regions.filter { $0.speakerId == me })
        }
        if key != me, let sys = AudioCompressor.sidecarURL(for: main, kind: "sys") {
            return (sys.path, regions.filter { $0.speakerId != me })
        }
        return (recording.audioPath, regions)
    }

    static func learn(speaker key: String, regions: [DiarizationRunner.SpeakerSegment],
                      audioPath: String) async throws -> Voiceprint {
        let samples = try await AudioDecoder().decodeAll(file: URL(fileURLWithPath: audioPath))
        let speech = cleanSpeech(of: key, regions: regions, samples: samples)
        let seconds = Double(speech.count) / VoiceActivity.sampleRate
        guard seconds >= minLearnSeconds else { throw LearnError.tooLittleSpeech(seconds: seconds) }
        let print = try await VoiceEmbedder.shared.enroll(speech)
        guard print.selfSimilarity >= VoiceprintStore.minSelfSimilarity else {
            throw VoiceprintStore.MixedReading(similarity: print.selfSimilarity)
        }
        return print
    }

    /// A voice print from a reading recorded at this Mac (Settings → People
    /// → Add person → Record them now), held to the same bar as the user's.
    static func learn(reading samples: [Float]) async throws -> Voiceprint {
        let print = try await VoiceEmbedder.shared.enroll(samples)
        guard print.selfSimilarity >= VoiceprintStore.minSelfSimilarity else {
            throw VoiceprintStore.MixedReading(similarity: print.selfSimilarity)
        }
        return print
    }

    /// Seconds each speaker talks in a recording, for picking who to learn.
    static func speakingTime(_ segments: [Segment]) -> [String: Double] {
        var out: [String: Double] = [:]
        for s in segments { if let key = s.speaker { out[key, default: 0] += max(0, s.endSeconds - s.startSeconds) } }
        return out
    }

    /// Each speaker's clip embeddings, as ClusterVoice takes them.
    static func clusterEmbeddings(samples: [Float], regions: [DiarizationRunner.SpeakerSegment],
                                  only keys: Set<String>) async throws -> [String: [[Float]]] {
        let floor = VoiceActivity.speechFloor(samples)
        let ranges = ClusterVoice.clipRanges(regions, sampleCount: samples.count)
            .filter { keys.contains($0.key) }
            .mapValues { $0.filter { VoiceActivity.rms(samples[$0]) >= floor } }
            .filter { $0.value.count >= ClusterVoice.minClips }
        let order = ranges.keys.sorted()
        let embeddings = try await VoiceEmbedder.shared.embed(order.flatMap { ranges[$0]!.map { samples[$0] } })
        var out: [String: [[Float]]] = [:]
        var i = 0
        for key in order {
            let n = ranges[key]!.count
            out[key] = Array(embeddings[i..<(i + n)])
            i += n
        }
        return out
    }
}

/// Names a recording's speakers after saved people. Runs after every
/// transcription (JobManager, before the run's version is saved) and from
/// Detail → Find people.
@MainActor
enum PeopleNamer {
    /// How many speakers were given a person's name.
    @discardableResult
    static func apply(to recording: Recording, repository: RecordingRepository,
                      store: PeopleStore = .shared, unknown: UnknownVoiceStore = .shared) async -> Int {
        // With no one saved yet it still runs (Find people on the overview):
        // the unnamed voices it reads feed "People you meet often".
        let people = store.load()
        let segments = recording.segments.sorted { $0.startSeconds < $1.startSeconds }
        var names: [String: String?] = [:]
        for s in segments { if let key = s.speaker, names[key] == nil { names[key] = .some(s.speakerName) } }
        let me = TranscriptionRunner.meName(UserDefaults.standard.string(forKey: "ui.myName"))
        let keys = PeopleMatch.renamable(names: names, people: people, me: me)
        guard !keys.isEmpty else {
            // Nothing to match this time: what an earlier run logged for
            // this recording points at speakers that may not exist now.
            try? store.log([:], in: recording.id)
            unknown.record([], for: recording.id)
            return 0
        }
        // The other people are read from the call track in a split-track
        // meeting (see PeopleVoice.source); keys never include the user's.
        let src = PeopleVoice.source(for: "", in: recording, regions: PeopleVoice.regions(segments))
        let regions = src.regions
        let path = src.path
        // Read now, before the long await: afterwards the transcript may
        // have been replaced (a new run, a restore) and these rows deleted.
        let withMe = segments.contains {
            $0.speaker == TranscriptionRunner.micSpeakerKey
                || $0.speakerName?.caseInsensitiveCompare(me) == .orderedSame
        }
        let time = PeopleVoice.speakingTime(segments)
        let signature = segments.map { "\($0.speaker ?? "")@\($0.startSeconds)" }.joined(separator: ",")
        do {
            let samples = try await AudioDecoder().decodeAll(file: URL(fileURLWithPath: path))
            let clusters = try await PeopleVoice.clusterEmbeddings(samples: samples, regions: regions, only: keys)
            // A speaker already carrying the person's name is not asked about.
            let found = PeopleMatch.assess(clusters, people: people).filter { key, a in
                a.accepted || (names[key] ?? nil)?.caseInsensitiveCompare(a.person.name) != .orderedSame
            }
            // The recording may have been deleted or re-run meanwhile: then
            // these speaker keys may name different people now.
            guard recording.modelContext != nil, !recording.isDeleted,
                  recording.segments.sorted(by: { $0.startSeconds < $1.startSeconds })
                    .map({ "\($0.speaker ?? "")@\($0.startSeconds)" }).joined(separator: ",") == signature
            else {
                AppLog.info("people", "transcript changed while voices were read; matching dropped")
                return 0
            }
            // Unnamed speakers no saved person matched: kept for suggestions.
            let date = Date(timeIntervalSince1970: TimeInterval(recording.createdAtMillis) / 1000)
            unknown.record(clusters.compactMap { key, clips -> UnknownVoiceStore.Entry? in
                guard (names[key] ?? nil)?.isEmpty ?? true, found[key]?.accepted != true,
                      clips.count >= ClusterVoice.minClips else { return nil }
                return .init(recordingId: recording.id, speaker: key, centroid: VoiceActivity.normalizedMean(clips),
                             seconds: time[key] ?? 0, date: date, withMe: withMe)
            }, for: recording.id)
            // People may have been renamed, merged or deleted while the audio
            // was read: name speakers after who they are now, by id.
            let now = Dictionary(store.load().map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            let matches = found.compactMapValues { $0.accepted ? now[$0.person.id] : nil }
            do { try store.log(found, in: recording.id) } catch {
                AppLog.warn("people", "match log not saved: \(error.localizedDescription)")
            }
            var named = 0
            for (key, person) in matches.sorted(by: { $0.key < $1.key })
            where (names[key] ?? nil) != person.name {
                try repository.setSpeakerName(person.name, for: key, in: recording)
                named += 1
            }
            AppLog.info("people", "\(matches.count) of \(keys.count) speakers matched a saved person, \(named) renamed")
            return named
        } catch {
            AppLog.warn("people", "matching skipped: \(error.localizedDescription)")
            return 0
        }
    }
}
