import Foundation

/// Voices of unnamed speakers, kept so the People overview can suggest the
/// people the user meets often: a voice that comes back in several of
/// their meetings is worth a name. Written by PeopleNamer, which reads
/// those speakers anyway; one entry per unnamed speaker per recording.
///
/// Like the saved voices, these are voice prints of people who never
/// agreed to it: kept in ~/Library/Application Support/Transcriberr/voice/,
/// out of Time Machine, and deleted with Delete everyone.
struct UnknownVoiceStore {
    let url: URL

    static var shared: UnknownVoiceStore {
        UnknownVoiceStore(url: PeopleStore.shared.url.deletingLastPathComponent()
            .appendingPathComponent("unknown-voices.json"))
    }

    struct Entry: Codable, Equatable {
        var recordingId: UUID
        var speaker: String
        var centroid: [Float]
        var seconds: Double
        var date: Date
        /// The user spoke in the same recording.
        var withMe: Bool
        var key: String { Person.Hearing.key(recordingId, speaker) }
    }

    struct File: Codable, Equatable {
        var version = 1
        var entries: [Entry] = []
        /// Entry keys the user answered "Not now" for.
        var dismissed: [String] = []
    }

    func load() -> File {
        guard let data = try? Data(contentsOf: url),
              let f = try? JSONDecoder().decode(File.self, from: data), f.version == 1 else { return File() }
        return f
    }

    private func save(_ f: File) throws {
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try JSONEncoder().encode(f).write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    /// Replaces what is known about one recording's unnamed speakers.
    func record(_ entries: [Entry], for recording: UUID) {
        var f = load()
        f.entries.removeAll { $0.recordingId == recording }
        f.entries += entries
        try? save(f)
    }

    /// Speakers that now have a name (saved, named or dismissed) drop out.
    func remove(keys: Set<String>) {
        var f = load()
        f.entries.removeAll { keys.contains($0.key) }
        try? save(f)
    }

    func dismiss(keys: Set<String>) {
        var f = load()
        f.dismissed = Array(Set(f.dismissed).union(keys))
        try? save(f)
    }

    func deleteAll() { try? FileManager.default.removeItem(at: url) }
}

/// Who the user meets often but has not saved, from two sources: speakers
/// named by hand in several recordings with no saved voice, and unnamed
/// voices that come back across the user's meetings. Pure, so the grouping
/// and the "people I speak a lot with" rule are tested without audio.
enum VoiceSuggestions {
    /// Two unnamed speakers are one voice at this centroid similarity.
    /// Stricter than matching a saved person (0.40 on clip medians):
    /// centroids are smoother, and a wrong merge suggests a person who
    /// does not exist.
    static let sameVoice: Float = 0.55
    /// Heard in at least this many of the user's meetings…
    static let minMeetings = 3
    /// …within this many days.
    static let recentDays = 90.0
    static let maxShown = 6

    struct Group: Equatable, Identifiable {
        var members: [UnknownVoiceStore.Entry]
        var centroid: [Float]
        var id: String { members.map(\.key).sorted().joined(separator: ",") }
        var seconds: Double { members.map(\.seconds).reduce(0, +) }
        var last: Date { members.map(\.date).max() ?? .distantPast }
    }

    /// Unnamed voices heard in at least `minMeetings` recordings with the
    /// user in the last `recentDays`, that sound like no one saved and not
    /// like the user. Most meetings first.
    static func groups(_ file: UnknownVoiceStore.File, people: [(name: String, centroid: [Float])],
                       me: [Float]?, now: Date = Date()) -> [Group] {
        let dismissed = Set(file.dismissed)
        let since = now.addingTimeInterval(-recentDays * 86_400)
        let entries = file.entries
            .filter { $0.withMe && $0.date >= since && !dismissed.contains($0.key) }
            .sorted { $0.seconds > $1.seconds }
        var groups: [Group] = []
        for e in entries {
            let best = groups.indices
                .map { (i: $0, sim: VoiceActivity.cosine(groups[$0].centroid, e.centroid)) }
                .filter { $0.sim >= sameVoice && !groups[$0.i].members.contains { $0.recordingId == e.recordingId } }
                .max { $0.sim < $1.sim }
            if let best {
                groups[best.i].members.append(e)
                groups[best.i].centroid = VoiceActivity.normalizedMean(groups[best.i].members.map(\.centroid))
            } else {
                groups.append(Group(members: [e], centroid: e.centroid))
            }
        }
        return groups
            .filter { $0.members.count >= minMeetings }
            .filter { g in
                // A voice like a saved person's is theirs to confirm on
                // their page; one like the user's is the user.
                !people.contains { VoiceActivity.cosine($0.centroid, g.centroid) >= VoiceActivity.onThreshold }
                    && (me.map { VoiceActivity.cosine($0, g.centroid) < VoiceActivity.onThreshold } ?? true)
            }
            .sorted { ($0.members.count, $0.seconds) > ($1.members.count, $1.seconds) }
    }

    struct Named: Equatable, Identifiable {
        var name: String
        var recordings: Int
        var seconds: Double
        var id: String { name.lowercased() }
    }

    /// Names typed by hand in at least two recordings that no saved person
    /// has: the user already said who they are, only the voice is missing.
    static func named(_ lines: [(name: String, recording: UUID, seconds: Double)],
                      saved: Set<String>, me: String) -> [Named] {
        var byName: [String: (display: String, recs: Set<UUID>, secs: Double)] = [:]
        for l in lines {
            let key = l.name.lowercased()
            guard !saved.contains(key), key != me.lowercased(), !isPlaceholder(l.name) else { continue }
            var v = byName[key] ?? (l.name, [], 0)
            v.recs.insert(l.recording)
            v.secs += l.seconds
            byName[key] = v
        }
        return byName.values
            .filter { $0.recs.count >= 2 && $0.secs >= 30 }
            .map { Named(name: $0.display, recordings: $0.recs.count, seconds: $0.secs) }
            .sorted { ($0.recordings, $0.seconds) > ($1.recordings, $1.seconds) }
    }

    /// "Speaker 2", "SPEAKER_01", "Me" and the like are labels, not people.
    static func isPlaceholder(_ name: String) -> Bool {
        let n = name.trimmingCharacters(in: .whitespaces).lowercased()
        if n.isEmpty || n == "me" || n == "someone" || n == "unknown" { return true }
        return n.range(of: #"^(speaker|спікер|s)[ _-]?\d+$"#, options: .regularExpression) != nil
    }
}

/// Whether a new sample is the same person as a saved voice, before it is
/// added. Calibrated on the user's voices (2026-10-23): a sample scored
/// 0.46-0.61 against the rest of its own person's voice, and at most 0.38
/// against anyone else's (two Ukrainian women on the same calls; every
/// other pair 0.11 or less). A sample is added only at `sameMin` or above
/// and `margin` above every other saved voice, the user's included.
/// Rejecting a true sample costs a little training; accepting a wrong one
/// spoils the voice, so the bar sits on the strict side.
enum VoiceGate {
    static let sameMin: Float = 0.45
    static let margin: Float = 0.10

    struct Verdict: Equatable {
        var score: Float
        var closer: (name: String, score: Float)?
        var accepted: Bool
        static func == (a: Verdict, b: Verdict) -> Bool {
            a.score == b.score && a.accepted == b.accepted && a.closer?.name == b.closer?.name
        }
    }

    /// Mean similarity of the sample's clips to a voice's centroid: the same
    /// clip-level view the matcher uses.
    static func score(_ print: Voiceprint, _ centroid: [Float]) -> Float {
        guard !print.embeddings.isEmpty else { return VoiceActivity.cosine(print.centroid, centroid) }
        return print.embeddings.map { VoiceActivity.cosine($0, centroid) }.reduce(0, +) / Float(print.embeddings.count)
    }

    static func check(_ print: Voiceprint, against voice: Voiceprint,
                      others: [(name: String, centroid: [Float])]) -> Verdict {
        let s = score(print, voice.centroid)
        let best = others.map { (name: $0.name, score: score(print, $0.centroid)) }.max { $0.score < $1.score }
        let accepted = s >= sameMin && (best.map { s - $0.score >= margin } ?? true)
        return Verdict(score: s, closer: best.flatMap { $0.score >= s - margin ? $0 : nil }, accepted: accepted)
    }

    /// From several recordings meant to be one new person, the largest set
    /// that agrees: seeded with the sample most like the others, grown one
    /// sample at a time while each scores `sameMin` against the set so far.
    /// The rest are left out, never averaged in.
    static func consistent<ID: Hashable>(_ prints: [(id: ID, print: Voiceprint)],
                                         others: [(name: String, centroid: [Float])]) -> (kept: [ID], rejected: [ID]) {
        guard prints.count > 1 else {
            // One sample has nothing to agree with; it must still not be someone else's.
            let ok = prints.first.map { p in
                !others.contains { score(p.print, $0.centroid) >= sameMin }
            } ?? false
            return ok ? (prints.map(\.id), []) : ([], prints.map(\.id))
        }
        func agreement(_ i: Int) -> Float {
            let rest = prints.indices.filter { $0 != i }.flatMap { prints[$0].print.embeddings }
            return score(prints[i].print, VoiceActivity.normalizedMean(rest))
        }
        let seed = prints.indices.max { agreement($0) < agreement($1) }!
        var kept = [seed]
        var pending = prints.indices.filter { $0 != seed }
        var grew = true
        while grew {
            grew = false
            let voice = Voiceprint(seconds: 0, embeddings: kept.flatMap { prints[$0].print.embeddings })
            if let next = pending.max(by: { score(prints[$0].print, voice.centroid) < score(prints[$1].print, voice.centroid) }),
               check(prints[next].print, against: voice, others: others).accepted {
                kept.append(next)
                pending.removeAll { $0 == next }
                grew = true
            }
        }
        // A lone seed nothing agreed with is not trusted either.
        if kept.count == 1 { return ([], prints.map(\.id)) }
        return (kept.map { prints[$0].id }, pending.map { prints[$0].id })
    }
}
