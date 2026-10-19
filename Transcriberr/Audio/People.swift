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

    /// At most this many embeddings per person, the newest kept: enough to
    /// span a few microphones without the file growing with every save.
    static let maxEmbeddings = 120
}

struct PeopleStore {
    let url: URL

    static var shared: PeopleStore {
        let path = ProcessInfo.processInfo.environment["TRANSCRIBERR_PEOPLE"]
        return PeopleStore(url: path.map { URL(fileURLWithPath: $0) }
            ?? VoiceprintStore.directory.appendingPathComponent("people.json"))
    }

    static let didChange = Notification.Name("PeopleStore.didChange")

    enum PeopleError: LocalizedError {
        case emptyName, missing, unreadable
        var errorDescription: String? {
            switch self {
            case .emptyName: return "Enter a name for this person."
            case .missing: return "That person is no longer saved."
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
        (try? read())?.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending } ?? []
    }

    private func read() throws -> [Person] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        guard let file = try? JSONDecoder().decode(File.self, from: Data(contentsOf: url)),
              file.version == 1 else { throw PeopleError.unreadable }
        // A person enrolled by another embedding model cannot be compared.
        return file.people.filter { $0.print.model == Voiceprint.currentModel }
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
    @discardableResult
    func remember(_ print: Voiceprint, as name: String, now: Date = Date()) throws -> Person {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw PeopleError.emptyName }
        var people = try read()
        if let i = people.firstIndex(where: { $0.name.caseInsensitiveCompare(trimmed) == .orderedSame }) {
            var p = people[i]
            let merged = Array((p.print.embeddings + print.embeddings).suffix(Person.maxEmbeddings))
            p.print = Voiceprint(created: p.print.created, seconds: p.print.seconds + print.seconds,
                                 embeddings: merged)
            p.updated = now
            p.sources += 1
            people[i] = p
            try write(people)
            return p
        }
        let p = Person(id: UUID(), name: trimmed, created: now, updated: now, print: print, sources: 1)
        people.append(p)
        try write(people)
        return p
    }

    func rename(_ id: UUID, to name: String) throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw PeopleError.emptyName }
        var people = try read()
        guard let i = people.firstIndex(where: { $0.id == id }) else { throw PeopleError.missing }
        people[i].name = trimmed
        people[i].updated = Date()
        try write(people)
    }

    func delete(_ id: UUID) throws {
        var people = try read()
        people.removeAll { $0.id == id }
        try write(people)
    }

    func deleteAll() throws {
        try? FileManager.default.removeItem(at: url)
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
        guard !people.isEmpty else { return [:] }
        var out: [String: Person] = [:]
        for (key, clips) in clusters where clips.count >= ClusterVoice.minClips {
            let ranked = people.map { p in
                (p, ClusterVoice.median(clips.map { VoiceActivity.cosine($0, p.print.centroid) }))
            }.sorted { $0.1 > $1.1 }
            guard let best = ranked.first, best.1 >= VoiceActivity.onThreshold else { continue }
            if ranked.count > 1, best.1 - ranked[1].1 < ClusterVoice.margin { continue }
            out[key] = best.0
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
        var out: [Float] = []
        for r in regions where r.speakerId == key {
            let a = r.startSeconds + ClusterVoice.inset, b = r.endSeconds - ClusterVoice.inset
            guard b > a, !others.contains(where: { $0.startSeconds < b && $0.endSeconds > a }) else { continue }
            let lo = max(0, Int(a * rate)), hi = min(samples.count, Int(b * rate))
            guard hi > lo else { continue }
            out.append(contentsOf: samples[lo..<hi])
            if Double(out.count) >= maxLearnSeconds * rate { break }
        }
        return out
    }

    /// A voice print of one speaker of a recording.
    static func learn(speaker key: String, in recording: Recording) async throws -> Voiceprint {
        let regions = regions(recording.segments.sorted { $0.startSeconds < $1.startSeconds })
        let samples = try await AudioDecoder().decodeAll(file: URL(fileURLWithPath: recording.audioPath))
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
                      store: PeopleStore = .shared) async -> Int {
        let people = store.load()
        guard !people.isEmpty else { return 0 }
        let segments = recording.segments.sorted { $0.startSeconds < $1.startSeconds }
        var names: [String: String?] = [:]
        for s in segments { if let key = s.speaker, names[key] == nil { names[key] = .some(s.speakerName) } }
        let me = TranscriptionRunner.meName(UserDefaults.standard.string(forKey: "ui.myName"))
        let keys = PeopleMatch.renamable(names: names, people: people, me: me)
        guard !keys.isEmpty else { return 0 }
        let regions = PeopleVoice.regions(segments)
        let path = recording.audioPath
        do {
            let samples = try await AudioDecoder().decodeAll(file: URL(fileURLWithPath: path))
            let clusters = try await PeopleVoice.clusterEmbeddings(samples: samples, regions: regions, only: keys)
            let matches = PeopleMatch.assign(clusters, people: people)
            // The recording may have been deleted or re-run meanwhile.
            guard recording.modelContext != nil, !recording.isDeleted else { return 0 }
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
