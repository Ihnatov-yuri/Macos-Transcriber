import Foundation
import CryptoKit
import NaturalLanguage

/// What one person said that matters later: what they committed to, the
/// questions they raised that stayed open, and the last thing they said on
/// each topic. Read from their meetings by the text engine, one meeting at
/// a time, and cached per meeting so a refresh reads only what is new.
struct PersonBrief: Codable, Equatable, Sendable {
    struct Item: Codable, Equatable, Hashable, Sendable {
        var text: String
        /// Where in the recording they said it, when the model's time
        /// matched one of their lines.
        var seconds: Double?
        /// Topics only: the topic's name.
        var topic: String?
    }
    var commitments: [Item] = []
    var questions: [Item] = []
    var topics: [Item] = []
    /// What they mainly said in the meeting, in a sentence or two per
    /// section read. Missing in briefs read before prompt version 3.
    var gist: [String]? = nil

    var isEmpty: Bool { commitments.isEmpty && questions.isEmpty && topics.isEmpty && (gist ?? []).isEmpty }
}

enum PersonBriefBuilder {
    /// Bumped when the prompt changes, so cached reads are redone.
    static let promptVersion = 6
    /// Meetings read per brief: everything in the last `recentDays`, and
    /// always the newest one, newest first up to `maxMeetings`. Older ones
    /// say little about what is open now, and each costs a read on a local
    /// model.
    static let maxMeetings = 15
    static let recentDays = 31.0
    static let maxOutputTokens = 520
    static let timeoutSeconds: TimeInterval = 120

    struct Line: Equatable {
        var start: Double
        var speaker: String
        var text: String
    }

    /// "Write in the language of the transcript" alone did not hold: a
    /// Ukrainian meeting came back entirely in English, the language of the
    /// prompt. The rule names the language when the text makes it clear.
    static func systemPrompt(name: String, language: String? = nil) -> String {
        let languageRule = language.map { "Write in \($0), the language of the transcript, even though these instructions are in English." }
            ?? "Write in the language of the transcript."
        return """
        You read part of a meeting transcript. Each line is "[time] Speaker: words". Report only what \(name) said. Answer in EXACTLY this format, one item per line, nothing else:
        GIST: <one or two plain sentences: what \(name) mainly said, reported, proposed or asked for in this part>
        COMMIT: [time] <a task \(name) took on, written as a short to-do, with for whom and by when if stated>
        QUESTION: [time] <a question \(name) asked or raised that is not answered in the transcript, as one clear question>
        TOPIC: [time] <topic in 1-4 words> => <\(name)'s view or update on it, in one clear sentence of your own>
        Rules:
        - [time] is copied from the line where \(name) said it.
        - Only \(name)'s own words count, never what others said.
        - Rewrite speech as clean written sentences: no fillers, false starts or quotes.
        - A COMMIT is something \(name) will do. Waiting for others, hopes and wishes are not.
        - Leave out greetings, small talk, jokes and banter.
        - \(languageRule)
        - Exactly 1 GIST line, first. At most 5 COMMIT, 5 QUESTION and 6 TOPIC lines. Leave out any kind there is nothing of. Never invent.
        """
    }

    /// The person's lines with the line before each of theirs, so a reply
    /// keeps the question it answers. Everything else is left out: it
    /// costs reads and invites the model to report other people.
    static func transcript(_ lines: [Line], name: String) -> String {
        var keep = IndexSet()
        for (i, l) in lines.enumerated() where l.speaker.caseInsensitiveCompare(name) == .orderedSame {
            keep.insert(i)
            if i > 0 { keep.insert(i - 1) }
        }
        return keep.map { i in
            let l = lines[i]
            return "[\(stamp(l.start))] \(l.speaker): \(l.text)"
        }.joined(separator: "\n")
    }

    static func stamp(_ seconds: Double) -> String {
        let t = Int(max(0, seconds))
        return t >= 3600
            ? String(format: "%d:%02d:%02d", t / 3600, (t / 60) % 60, t % 60)
            : String(format: "%02d:%02d", t / 60, t % 60)
    }

    /// What the cache is keyed on: the input and the prompt.
    static func key(transcript: String, name: String) -> String {
        let digest = SHA256.hash(data: Data("\(promptVersion)|\(name)|\(transcript)".utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// One read per section, merged. `complete` is false when a section
    /// failed: such a brief is shown but not cached, so a refresh reads the
    /// meeting again. A timeout is rethrown, even after a good section: the
    /// engine is wedged and the caller must recover it. On the main actor,
    /// like its callers: it only orders the reads, `generate` does the work.
    @MainActor
    static func build(
        transcript: String,
        name: String,
        lineStarts: [Double],
        generate: (_ system: String, _ user: String, _ maxTokens: Int) async throws -> String
    ) async throws -> (brief: PersonBrief, complete: Bool) {
        var merged = PersonBrief()
        var lastError: Error?
        let parts = MeetingBriefBuilder.sections(transcript)
        // One language for the whole meeting: sections of a mixed meeting
        // would otherwise each answer in their own.
        let system = systemPrompt(name: name, language: language(of: transcript))
        for (i, section) in parts.enumerated() {
            try Task.checkCancellation()
            do {
                let raw = try await generate(system, "TRANSCRIPT:\n" + section, maxOutputTokens)
                merge(parse(raw, lineStarts: lineStarts, name: name), into: &merged)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                AppLog.warn("person-brief", "section \(i + 1)/\(parts.count) failed: \(error.localizedDescription)")
                if case ASRError.chunkTimeout = error { throw error }
                lastError = error
            }
        }
        if merged.isEmpty, let lastError { throw lastError }
        return (merged, lastError == nil)
    }

    /// The transcript's main language by name, only among the app's
    /// languages (never Russian: Ukrainian text must not be read as it), and
    /// only when the recognizer is sure. Timestamps and speaker labels are
    /// left out of the read.
    static func language(of transcript: String) -> String? {
        let words = transcript.replacingOccurrences(
            of: #"(?m)^\[[\d:]+\] [^:\n]*: "#, with: "", options: .regularExpression)
        guard words.count >= 40 else { return nil }
        let names: [NLLanguage: String] = [
            .english: "English", .ukrainian: "Ukrainian", .dutch: "Dutch", .german: "German",
            .french: "French", .spanish: "Spanish", .italian: "Italian", .portuguese: "Portuguese",
            .polish: "Polish", .arabic: "Arabic",
        ]
        let recognizer = NLLanguageRecognizer()
        recognizer.languageConstraints = Array(names.keys)
        recognizer.processString(words)
        guard let lang = recognizer.dominantLanguage,
              let confidence = recognizer.languageHypotheses(withMaximum: 1)[lang], confidence >= 0.6
        else { return nil }
        return names[lang]
    }

    /// A wall-clock bound that also gives way to cancellation: Stop on the
    /// page must end the read now, not when the engine answers. A task
    /// group would wait for a native call that ignores cancellation, so the
    /// work runs detached and the first of answer, timeout or cancel wins.
    static func bounded<T: Sendable>(
        seconds: TimeInterval, _ op: @Sendable @escaping () async throws -> T
    ) async throws -> T {
        let claim = BoundedClaim()
        let work = Box<Task<Void, Never>>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<T, Error>) in
                claim.set(cont)
                work.value = Task.detached(priority: .userInitiated) {
                    do { claim.resume(Result<T, Error>.success(try await op())) } catch { claim.resume(Result<T, Error>.failure(error)) }
                }
                Task.detached(priority: .utility) {
                    try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                    // Claimed before the work is cancelled: the cancelled
                    // work would otherwise report a CancellationError first,
                    // and a wedged engine would pass for Stop.
                    claim.resume(Result<T, Error>.failure(ASRError.chunkTimeout))
                    work.value?.cancel()
                }
            }
        } onCancel: {
            claim.resume(Result<T, Error>.failure(CancellationError()))
            work.value?.cancel()
        }
    }

    /// Reads the model's lines. A time is kept only when it lands within
    /// half a minute of one of the person's lines, and is moved onto it.
    static func parse(_ raw: String, lineStarts: [Double], name: String? = nil) -> PersonBrief {
        var b = PersonBrief()
        for rawLine in raw.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "-*• "))
            guard let colon = line.firstIndex(of: ":") else { continue }
            let tag = line[..<colon].trimmingCharacters(in: .whitespaces).uppercased()
            var body = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            var seconds: Double?
            if let (t, rest) = leadingTime(body) {
                seconds = snap(t, to: lineStarts)
                body = rest
            }
            switch tag {
            case "GIST", "SUMMARY":
                if let text = clean(body) { b.gist = (b.gist ?? []) + [text] }
            case "COMMIT":
                if let text = clean(body).flatMap({ task($0, name: name) }) {
                    b.commitments.append(.init(text: text, seconds: seconds))
                }
            case "QUESTION":
                if let text = clean(body) { b.questions.append(.init(text: text, seconds: seconds)) }
            case "TOPIC":
                let halves = body.components(separatedBy: "=>")
                guard halves.count == 2, let topic = clean(halves[0]), let text = clean(halves[1]) else { continue }
                b.topics.append(.init(text: text, seconds: seconds, topic: topic.prefix(1).uppercased() + topic.dropFirst()))
            default:
                continue
            }
        }
        return b
    }

    static func merge(_ b: PersonBrief, into a: inout PersonBrief) {
        func union(_ x: [PersonBrief.Item], _ y: [PersonBrief.Item]) -> [PersonBrief.Item] {
            var seen = Set(x.map { $0.text.lowercased() })
            return x + y.filter { seen.insert($0.text.lowercased()).inserted }
        }
        a.commitments = union(a.commitments, b.commitments)
        a.questions = union(a.questions, b.questions)
        if let g = b.gist, !g.isEmpty {
            // A sentence or two per section, in the order of the meeting.
            a.gist = (a.gist ?? []) + g.filter { !(a.gist ?? []).contains($0) }
        }
        // A later section's word on a topic replaces an earlier one.
        var topics = a.topics
        for t in b.topics {
            topics.removeAll { $0.topic?.lowercased() == t.topic?.lowercased() }
            topics.append(t)
        }
        a.topics = topics
    }

    private static func leadingTime(_ s: String) -> (Double, String)? {
        guard s.hasPrefix("["), let close = s.firstIndex(of: "]") else { return nil }
        let parts = s[s.index(after: s.startIndex)..<close].split(separator: ":").map { Int($0) }
        // Bounded: these numbers come from a model, and a runaway one would
        // overflow the arithmetic below.
        guard (2...3).contains(parts.count), parts.allSatisfy({ $0.map { (0..<100_000).contains($0) } ?? false })
        else { return nil }
        let n = parts.map { $0! }
        let t = n.count == 3 ? n[0] * 3600 + n[1] * 60 + n[2] : n[0] * 60 + n[1]
        return (Double(t), String(s[s.index(after: close)...]).trimmingCharacters(in: .whitespaces))
    }

    private static func snap(_ t: Double, to starts: [Double]) -> Double? {
        guard let best = starts.min(by: { abs($0 - t) < abs($1 - t) }), abs(best - t) <= 30 else { return nil }
        return best
    }

    /// A commitment as a to-do: "Lana will share the video" reads "Share
    /// the video". One that names the person anywhere else ("Send an
    /// email to Lana") is a task someone else took on for them, which the
    /// model misread as theirs (Gemma 4, 2026-10-24); it is dropped.
    static func task(_ text: String, name: String?) -> String? {
        guard let first = name?.split(separator: " ").first.map(String.init), !first.isEmpty else { return text }
        var t = text
        for lead in ["\(first) will ", "\(first) is going to ", "\(first) to ", "\(first) should "]
        where t.lowercased().hasPrefix(lead.lowercased()) {
            let rest = t.dropFirst(lead.count)
            t = rest.prefix(1).uppercased() + rest.dropFirst()
            break
        }
        let words = Set(SpeechLexicon.words(t).map { $0.lowercased() })
        if words.contains(first.lowercased()) { return nil }
        return t.count >= 2 ? t : nil
    }

    /// What Gemma 4 left on real answers (2026-10-23): the speaker's name
    /// copied in front ("Lana: I will…") and times it could not shape
    /// ("[0:0:0:7] Meeting intro").
    private static func clean(_ s: String) -> String? {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.hasPrefix("["), let close = t.firstIndex(of: "]"),
           t[t.index(after: t.startIndex)..<close].allSatisfy({ $0.isNumber || $0 == ":" }) {
            t = String(t[t.index(after: close)...]).trimmingCharacters(in: .whitespaces)
        }
        if let colon = t.firstIndex(of: ":"), t.distance(from: t.startIndex, to: colon) <= 30,
           t[..<colon].split(separator: " ").count <= 3, t[..<colon].first?.isUppercase == true,
           !t[..<colon].contains(where: \.isNumber) {
            let rest = t[t.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if rest.count >= 2 { t = rest }
        }
        t = t.trimmingCharacters(in: CharacterSet(charactersIn: "\"“”<>"))
            .trimmingCharacters(in: .whitespaces)
        guard t.count >= 2 else { return nil }
        let lower = t.lowercased()
        // The model filling a kind it was told to leave out.
        if ["none", "n/a", "nothing", "-", "немає", "нічого"].contains(lower) { return nil }
        return t
    }
}

/// Briefs per person and meeting, beside the voices in
/// ~/Library/Application Support/Transcriberr/voice/: they describe people
/// who never agreed to it, and go when the person is deleted.
struct PersonBriefStore {
    let url: URL

    /// Beside people.json, wherever TRANSCRIBERR_PEOPLE puts it.
    static var shared: PersonBriefStore { PeopleStore.shared.briefs }

    struct Entry: Codable, Equatable {
        var recordingId: UUID
        var key: String
        var built: Date
        var brief: PersonBrief
    }

    private struct File: Codable {
        var version = 1
        var people: [UUID: [Entry]] = [:]
        /// Items marked Done or Not relevant, per person (keys of `itemKey`).
        var closed: [UUID: [String]]? = nil
    }

    static func itemKey(_ recording: UUID, _ kind: String, _ text: String) -> String {
        "\(recording.uuidString)|\(kind)|\(text.lowercased())"
    }

    func closed(for person: UUID) -> Set<String> { Set(read().closed?[person] ?? []) }

    func setClosed(_ key: String, _ isClosed: Bool, for person: UUID) throws {
        var file = read()
        var list = Set(file.closed?[person] ?? [])
        if isClosed { list.insert(key) } else { list.remove(key) }
        var all = file.closed ?? [:]
        all[person] = Array(list)
        file.closed = all
        try write(file)
    }

    /// A meeting was read again: the model words the same item a little
    /// differently each time, so Done marks move to the new item that says
    /// the same thing (most words shared), or they would come back.
    func carryClosed(from old: PersonBrief, to new: PersonBrief, recording: UUID, for person: UUID) {
        let closed = self.closed(for: person)
        guard !closed.isEmpty else { return }
        func words(_ s: String) -> Set<String> { Self.meaningWords(s) }
        let kinds: [(String, [PersonBrief.Item], [PersonBrief.Item])] = [
            ("commitment", old.commitments, new.commitments), ("question", old.questions, new.questions),
        ]
        for (kind, olds, news) in kinds {
            for o in olds where closed.contains(Self.itemKey(recording, kind, o.text)) {
                let ow = words(o.text)
                guard let best = news.max(by: { a, b in
                    Self.overlap(ow, words(a.text)) < Self.overlap(ow, words(b.text))
                }), Self.overlap(ow, words(best.text)) >= 0.5 else { continue }
                try? setClosed(Self.itemKey(recording, kind, best.text), true, for: person)
            }
        }
    }

    /// The words that carry an item's meaning: "I will send the plan" and
    /// "Send the plan" are the same item, so the wording of a promise
    /// ("will", "I'll", "going") does not count.
    static func meaningWords(_ s: String) -> Set<String> {
        let wording: Set<String> = ["will", "i'll", "i’ll", "we'll", "going", "shall", "the", "and", "for", "with", "that", "this"]
        return Set(SpeechLexicon.words(s).filter { $0.count > 2 && !wording.contains($0) })
    }

    static func overlap(_ a: Set<String>, _ b: Set<String>) -> Double {
        let u = a.union(b).count
        return u == 0 ? 0 : Double(a.intersection(b).count) / Double(u)
    }

    /// Drops what was read from recordings that are gone.
    func keep(only recordings: Set<UUID>, for person: UUID) {
        var file = read()
        guard let list = file.people[person] else { return }
        let kept = list.filter { recordings.contains($0.recordingId) }
        guard kept.count != list.count else { return }
        file.people[person] = kept
        try? write(file)
    }

    private func read() -> File {
        guard let data = try? Data(contentsOf: url),
              let file = try? JSONDecoder().decode(File.self, from: data), file.version == 1 else { return File() }
        return file
    }

    private func write(_ file: File) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(file).write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    func entries(for person: UUID) -> [Entry] { read().people[person] ?? [] }

    /// Everyone's, from one read of the file.
    func all() -> (entries: [UUID: [Entry]], closed: [UUID: [String]]) {
        let f = read()
        return (f.people, f.closed ?? [:])
    }

    func save(_ entry: Entry, for person: UUID) throws {
        var file = read()
        var list = (file.people[person] ?? []).filter { $0.recordingId != entry.recordingId }
        list.append(entry)
        file.people[person] = list
        try write(file)
    }

    func delete(person: UUID) {
        var file = read()
        let hadEntries = file.people.removeValue(forKey: person) != nil
        let hadClosed = file.closed?.removeValue(forKey: person) != nil
        guard hadEntries || hadClosed else { return }
        try? write(file)
    }

    func deleteAll() { try? FileManager.default.removeItem(at: url) }
}

/// First result wins; later ones are dropped. Cancellation can arrive
/// before the continuation exists, so it is remembered and applied then.
private final class BoundedClaim: @unchecked Sendable {
    private let lock = NSLock()
    private var cont: Any?
    private var early: Error?
    private var done = false

    func set<T: Sendable>(_ c: CheckedContinuation<T, Error>) {
        lock.lock()
        if done, let early { lock.unlock(); c.resume(throwing: early); return }
        cont = c
        lock.unlock()
    }

    func resume<T: Sendable>(_ result: Result<T, Error>) {
        lock.lock()
        guard !done else { lock.unlock(); return }
        done = true
        guard let c = cont as? CheckedContinuation<T, Error> else {
            if case .failure(let e) = result { early = e }
            lock.unlock()
            return
        }
        cont = nil
        lock.unlock()
        c.resume(with: result)
    }
}

private final class Box<V>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: V?
    var value: V? {
        get { lock.lock(); defer { lock.unlock() }; return _value }
        set { lock.lock(); _value = newValue; lock.unlock() }
    }
}
