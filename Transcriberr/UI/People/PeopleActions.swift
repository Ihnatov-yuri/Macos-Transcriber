import Foundation
import Observation

/// Changes to a saved person that reach into the recordings: a name lives
/// both in people.json and on every line the person said.
@MainActor
enum PeopleActions {
    /// Renames the person and every line carrying the old name.
    static func rename(_ person: Person, to name: String, container: AppContainer) throws {
        let old = try PeopleStore.shared.rename(person.id, to: name)
        let new = name.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            rewrite(try container.repository.renameSpeakerEverywhere(old, to: new))
        } catch {
            // The recordings still say the old name: so must the person.
            _ = try? PeopleStore.shared.rename(person.id, to: old)
            throw error
        }
    }

    /// One person from two: the voice, history and lines of `source` become
    /// `target`'s.
    static func merge(_ source: Person, into target: Person, container: AppContainer) throws {
        let old = try PeopleStore.shared.merge(source.id, into: target.id)
        rewrite(try container.repository.renameSpeakerEverywhere(old, to: target.name))
    }

    /// The .txt/.srt/.json beside each audio file follow the names.
    private static func rewrite(_ recordings: [Recording]) {
        for r in recordings where !r.isDeleted { try? TranscriptExporter.export(recording: r) }
    }
}

/// Finds saved people in every recording that has speakers: names the
/// clear matches and collects the near misses each person's page asks
/// about. Recordings made before 5.0.0 were never matched with a track
/// record, so without this their pages start empty. App-wide and
/// cancellable; a recording being transcribed is skipped.
@MainActor
@Observable
final class LibraryPeopleScan {
    static let shared = LibraryPeopleScan()

    private(set) var isRunning = false
    private(set) var progress: String?
    private(set) var lastResult: String?
    @ObservationIgnored private var task: Task<Void, Never>?

    func start(container: AppContainer) {
        guard !isRunning else { return }
        isRunning = true
        lastResult = nil
        task = Task { @MainActor in
            defer { isRunning = false; progress = nil; task = nil }
            let ids = (try? container.repository.recordingIdsWithSpeakers()) ?? []
            var named = 0, scanned = 0
            for (i, id) in ids.enumerated() {
                if Task.isCancelled { break }
                // A run in flight rewrites the segments under the match.
                if container.jobManager.isActive(id) { continue }
                guard let rec = try? container.repository.get(id: id), !rec.isDeleted else { continue }
                progress = "Listening to \(i + 1) of \(ids.count): \(rec.title)"
                let n = await PeopleNamer.apply(to: rec, repository: container.repository)
                if n > 0, !rec.isDeleted { try? TranscriptExporter.export(recording: rec) }
                named += n
                scanned += 1
            }
            let waiting = PeopleStore.shared.load().map { $0.candidates?.count ?? 0 }.reduce(0, +)
            lastResult = "Listened to \(scanned) recordings, named \(named) \(named == 1 ? "speaker" : "speakers")"
                + (waiting > 0 ? ", \(waiting) waiting for you to confirm." : ".")
            AppLog.info("people", "library scan: \(scanned) recordings, \(named) named, \(waiting) candidates")
        }
    }

    func cancel() { task?.cancel() }
}

/// Saves the people "People you meet often" suggests: a hand-typed name's
/// voice from the recordings it is on, or an unnamed voice under the name
/// the user gives it, named in every recording it was heard in.
@MainActor
@Observable
final class PeopleSuggestionRunner {
    static let shared = PeopleSuggestionRunner()

    private(set) var busy: String?
    private(set) var note: (text: String, failed: Bool)?

    /// Learns a voice for a name already on lines in several recordings.
    /// Recordings learned from per Save voice: the ones with the most of
    /// the person's speech, where the voice is best represented.
    static let bestRecordings = 5

    func saveNamed(_ name: String, container: AppContainer) {
        guard busy == nil else { return }
        let best = PersonMeetings.load(name, repository: container.repository)
            .sorted { $0.seconds > $1.seconds }
            .prefix(Self.bestRecordings)
        run(name: name, steps: best.map { ($0.id, $0.keys) }, nameSpeakers: false, container: container)
    }

    /// Names an unnamed voice everywhere it was heard and learns it.
    func saveGroup(_ group: VoiceSuggestions.Group, as name: String, container: AppContainer) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard busy == nil, !trimmed.isEmpty else { return }
        let byRecording = Dictionary(grouping: group.members, by: \.recordingId).mapValues { Set($0.map(\.speaker)) }
        run(name: trimmed, steps: byRecording.map { ($0.key, $0.value) }, nameSpeakers: true, container: container)
    }

    func dismiss(_ group: VoiceSuggestions.Group) {
        UnknownVoiceStore.shared.dismiss(keys: Set(group.members.map(\.key)))
        note = nil
    }

    /// Learns every recording first, keeps only the ones that are clearly
    /// one voice (VoiceGate), and only then names and saves: a group or a
    /// typed name is a guess until the voices agree.
    private func run(name: String, steps: [(UUID, Set<String>)], nameSpeakers: Bool, container: AppContainer) {
        busy = "Listening to 1 of \(steps.count)…"
        note = nil
        Task { @MainActor in
            defer { busy = nil }
            var learnedPrints: [(id: UUID, keys: [String], print: Voiceprint, signature: String)] = []
            for (i, step) in steps.enumerated() {
                busy = "Listening to \(i + 1) of \(steps.count)…"
                guard let rec = try? container.repository.get(id: step.0), !rec.isDeleted else { continue }
                let keys = step.1.filter { k in rec.segments.contains { $0.speaker == k } }.sorted()
                let before = PeopleVoice.signature(rec)
                var prints: [Voiceprint] = []
                for k in keys {
                    guard rec.modelContext != nil else { break }
                    if let p = try? await PeopleVoice.learn(speaker: k, in: rec) { prints.append(p) }
                }
                // Deleted or re-run while its voices were read: nothing from
                // it is used, since its keys may be other people now.
                guard rec.modelContext != nil, PeopleVoice.signature(rec) == before, !prints.isEmpty else { continue }
                learnedPrints.append((step.0, keys, Voiceprint(model: prints[0].model, seconds: prints.map(\.seconds).reduce(0, +),
                                                                embeddings: prints.flatMap(\.embeddings)), before))
            }
            let store = PeopleStore.shared
            let people = store.load()
            let existing = people.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
            let others = people.filter { $0.id != existing?.id }.map { (name: $0.name, centroid: $0.print.centroid) }
                + (store.myVoice().map { [(name: "you", centroid: $0)] } ?? [])
            // A saved person: each recording is checked against their voice
            // as it is added. Someone new: the recordings must agree first.
            let kept: Set<UUID> = existing != nil
                ? Set(learnedPrints.map(\.id))
                : Set(VoiceGate.consistent(learnedPrints.map { ($0.id, $0.print) }, others: others).kept)
            var learned = 0, named = 0, refused = 0, seconds = 0.0
            for item in learnedPrints {
                guard kept.contains(item.id) else { refused += 1; continue }
                do {
                    if let id = (existing ?? store.load().first { $0.name.caseInsensitiveCompare(name) == .orderedSame })?.id {
                        try store.add(item.print, to: id, from: item.id, speakers: Person.Sample.speakers(item.keys))
                    } else {
                        try store.remember(item.print, as: name, from: item.id, speakers: Person.Sample.speakers(item.keys))
                    }
                    learned += 1
                    seconds += item.print.seconds
                } catch PeopleStore.PeopleError.notSamePerson {
                    refused += 1
                    continue
                } catch {
                    note = (error.localizedDescription, true)
                    return
                }
                // Named only where the voice was confirmed.
                if nameSpeakers, let rec = try? container.repository.get(id: item.id), rec.modelContext != nil,
                   PeopleVoice.signature(rec) == item.signature {
                    for k in item.keys { try? container.repository.setSpeakerName(name, for: k, in: rec) }
                    try? TranscriptExporter.export(recording: rec)
                    UnknownVoiceStore.shared.remove(keys: Set(item.keys.map { Person.Hearing.key(item.id, $0) }))
                    named += 1
                }
            }
            // Not offered again under "Learn from" on their page.
            let heard = Set(learnedPrints.map(\.id))
            if learned > 0, let person = store.load().first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
                for step in steps where !heard.contains(step.0) { try? store.tried(step.0, for: person.id) }
            }
            let refusedText = refused == 0 ? "" : " \(refused) \(refused == 1 ? "recording was" : "recordings were") left out: the voice there did not clearly match the others."
            let namedText = nameSpeakers ? "Named in \(named) \(named == 1 ? "recording" : "recordings"). " : ""
            note = learned == 0
                ? ("Nothing saved. \(learnedPrints.isEmpty ? "No recording had enough clean speech of \(name) to learn the voice." : "The recordings did not clearly sound like one person, so none was used.")\(refusedText)", true)
                : ("\(namedText)Saved \(name)'s voice from \(learned) \(learned == 1 ? "recording" : "recordings"), \(Int(seconds)) s.\(refusedText)", false)
        }
    }
}

/// "Improve from my recordings" on a person page: rebuilds their voice
/// from what the library already holds, and keeps the result only if it
/// scores better.
///
/// Older samples were often taken from the mixed audio before voices were
/// read from the call track, and from whatever stretches came first rather
/// than the longest clean ones. So: re-learn every meeting they are named
/// in (the best few, by how much they speak), put the readings back as
/// they are (deliberate, clean, never thrown away), keep only the samples
/// that agree with each other (VoiceGate), and compare the confidence
/// before and after on the same scale.
@MainActor
enum VoiceImprover {
    static let maxRecordings = 8

    struct Outcome {
        var before: VoiceConfidence
        var after: VoiceConfidence?
        var applied: Bool
        var used: Int
        var leftOut: Int
        var message: String
    }

    static func improve(_ person: Person, others: [(name: String, centroid: [Float])],
                        container: AppContainer, progress: (String) -> Void) async -> Outcome {
        let before = PeopleConfidence.assess(person, others: others, unmatched: ["you"])
        let meetings = PersonMeetings.load(person.name, repository: container.repository)
            .sorted { $0.seconds > $1.seconds }.prefix(maxRecordings)

        // Re-learned from each recording, on the call track, best stretches.
        var fresh: [(recordingId: UUID?, earlier: Bool?, date: Date, print: Voiceprint)] = []
        for (i, m) in meetings.enumerated() {
            progress("Listening to \(i + 1) of \(meetings.count)…")
            guard let rec = try? container.repository.get(id: m.id), rec.modelContext != nil,
                  let key = m.keys.sorted(by: { a, b in
                      // A diarized speaker over a hand-tagged one: it has more speech.
                      !a.hasPrefix(RecordingRepository.taggedKeyPrefix) && b.hasPrefix(RecordingRepository.taggedKeyPrefix)
                  }).first
            else { continue }
            let before = PeopleVoice.signature(rec)
            // Deleted or re-run in the main window meanwhile: skipped.
            if let p = try? await PeopleVoice.learn(speaker: key, in: rec),
               rec.modelContext != nil, PeopleVoice.signature(rec) == before {
                fresh.append((m.id, nil, m.date, p))
            }
        }

        // Kept as they are: readings, and what was learned before 5.0 when
        // there is nothing fresh to replace it with.
        var kept: [(recordingId: UUID?, earlier: Bool?, date: Date, print: Voiceprint)] = []
        var start = 0
        let freshIDs = Set(fresh.compactMap(\.recordingId))
        for s in person.allSamples {
            let end = min(person.print.embeddings.count, start + s.count)
            let part = Voiceprint(model: person.print.model, seconds: s.seconds,
                                  embeddings: Array(person.print.embeddings[start..<end]))
            start = end
            if s.recordingId == nil, s.earlier != true {
                kept.append((nil, nil, s.date, part))                     // a reading
            } else if let r = s.recordingId, !freshIDs.contains(r) {
                kept.append((r, s.earlier, s.date, part))                 // not re-learned
            } else if s.earlier == true, fresh.isEmpty {
                kept.append((nil, true, s.date, part))
            }
        }

        // Only what agrees: readings always stay, the rest must form one voice.
        let candidates = kept.filter { !($0.recordingId == nil && $0.earlier == nil) } + fresh
        let readings = kept.filter { $0.recordingId == nil && $0.earlier == nil }
        let indexed = candidates.enumerated().map { (id: $0.offset, print: $0.element.print) }
        let agreed = VoiceGate.consistent(indexed, others: others.filter { $0.name != "you" }
            + (PeopleStore.shared.myVoice().map { [("you", $0)] } ?? []))
        let chosen = readings + agreed.kept.sorted().map { candidates[$0] }
        let leftOut = candidates.count - agreed.kept.count

        guard !chosen.isEmpty else {
            return Outcome(before: before, after: nil, applied: false, used: 0, leftOut: leftOut,
                           message: "Nothing usable came out of the recordings, so \(person.name)'s voice is unchanged.")
        }

        // Scored on the same scale before anything is written.
        var trial = person
        trial.print = Voiceprint(model: person.print.model, created: person.print.created,
                                 seconds: chosen.map(\.print.seconds).reduce(0, +),
                                 embeddings: chosen.flatMap(\.print.embeddings))
        trial.samples = chosen.map {
            Person.Sample(id: UUID(), recordingId: $0.recordingId, date: $0.date,
                          seconds: $0.print.seconds, count: $0.print.embeddings.count, earlier: $0.earlier)
        }
        trial.trim()
        trial.sources = chosen.count
        let after = PeopleConfidence.assess(trial, others: others, unmatched: ["you"])
        guard after.score > before.score + 0.005 else {
            return Outcome(before: before, after: after, applied: false, used: chosen.count, leftOut: leftOut,
                           message: "Rebuilt from \(fresh.count) \(fresh.count == 1 ? "recording" : "recordings"), but it scored \(after.percent)% against \(before.percent)% now, so the current voice stays. A reading at this Mac, or more meetings with \(person.name), is what would help.")
        }
        do {
            try PeopleStore.shared.replaceVoice(of: person.id, with: chosen, basedOn: person)
        } catch {
            return Outcome(before: before, after: after, applied: false, used: 0, leftOut: leftOut,
                           message: error.localizedDescription)
        }
        let left = leftOut == 0 ? "" : " \(leftOut) \(leftOut == 1 ? "sample did" : "samples did") not agree with the rest and \(leftOut == 1 ? "was" : "were") left out."
        return Outcome(before: before, after: after, applied: true, used: chosen.count, leftOut: leftOut,
                       message: "Improved from \(before.percent)% to \(after.percent)%, rebuilt from \(chosen.count) \(chosen.count == 1 ? "sample" : "samples").\(left)")
    }
}

/// Settings → People → Voice model. Switching downloads the model if
/// needed, re-embeds the user's kept reading, parks every person's voice in
/// the model left (switching back is instant) and rebuilds each voice in the
/// new one from the recordings it was learned from. App-wide, so leaving
/// Settings does not stop it.
@MainActor
@Observable
final class VoiceModelSwitcher {
    static let shared = VoiceModelSwitcher()

    private(set) var busy: String?
    private(set) var progress: Double?
    private(set) var note: String?
    private(set) var failed = false
    @ObservationIgnored private var task: Task<Void, Never>?

    func switchTo(_ model: VoiceModel, container: AppContainer) {
        guard busy == nil else { return }
        failed = false
        note = nil
        busy = model == .simam && !SimAMModel.isInstalled()
            ? "Downloading the model (\(SimAMModel.totalBytes / 1_000_000) MB)…" : "Switching…"
        task = Task { @MainActor in
            defer { busy = nil; progress = nil; task = nil }
            do {
                if model == .simam {
                    try await SimAMModel.ensureDownloaded { p in Task { @MainActor in VoiceModelSwitcher.shared.progress = p } }
                    progress = nil
                }
                busy = "Learning your voice in the new model…"
                do { try await PeopleEmbedder.buildMyVoice(model) } catch {
                    AppLog.warn("voice", "own voice not rebuilt for \(model.rawValue): \(error.localizedDescription)")
                }
                try Task.checkCancellation()
                // The setting first: the store's change notice makes every
                // view reload, and they must read the new model by then.
                let previous = UserDefaults.standard.string(forKey: VoiceModel.key)
                UserDefaults.standard.set(model.rawValue, forKey: VoiceModel.key)
                let pending: [Person]
                do { pending = try PeopleStore.shared.switchVoices(to: model) } catch {
                    UserDefaults.standard.set(previous, forKey: VoiceModel.key)
                    throw error
                }
                NotificationCenter.default.post(name: PeopleStore.didChange, object: nil)
                if model == .standard { await SimAMEmbedder.shared.unload() }
                var without: [String] = []
                for (i, p) in pending.enumerated() {
                    try Task.checkCancellation()
                    busy = "Rebuilding \(p.name)'s voice (\(i + 1) of \(pending.count))…"
                    let parts = await Self.rebuild(p, model: model, container: container)
                    guard VoiceModel.current == model else { return }
                    if parts.isEmpty { without.append(p.name); continue }
                    try PeopleStore.shared.setRebuilt(p.id, parts: parts)
                }
                note = "Now using \(model.title.lowercased())."
                    + (pending.isEmpty ? "" : " Rebuilt \(pending.count - without.count) of \(pending.count) voices from their recordings.")
                    + (without.isEmpty ? "" : " No recording to rebuild \(without.joined(separator: ", ")) from: add them again on their page.")
                AppLog.info("voice", "people now on \(model.rawValue); \(pending.count) rebuilt, \(without.count) without a source")
            } catch is CancellationError {
                note = "Stopped. Voices not rebuilt yet are rebuilt the next time you switch."
            } catch {
                failed = true
                note = error.localizedDescription
            }
        }
    }

    func cancel() { task?.cancel() }

    /// One person's voice in `model`, from each recording it was learned
    /// from: the same speakers, or the ones carrying their name.
    static func rebuild(_ p: Person, model: VoiceModel,
                        container: AppContainer) async -> [(recording: UUID, speakers: String?, print: Voiceprint)] {
        var parts: [(recording: UUID, speakers: String?, print: Voiceprint)] = []
        for src in PeopleStore.rebuildSources(p) {
            guard let rec = try? container.repository.get(id: src.recording), rec.modelContext != nil else { continue }
            let present = Set(rec.segments.compactMap(\.speaker))
            let keys: [String] = (src.speakers.map { $0.split(separator: ",").map(String.init) }
                ?? Set(rec.segments.filter { $0.speakerName?.caseInsensitiveCompare(p.name) == .orderedSame }
                    .compactMap(\.speaker)).sorted())
                .filter(present.contains)
            var prints: [Voiceprint] = []
            for key in keys {
                guard rec.modelContext != nil else { break }
                if let print = try? await PeopleVoice.learn(speaker: key, in: rec), print.model == model.rawValue {
                    prints.append(print)
                }
            }
            guard !prints.isEmpty else { continue }
            parts.append((rec.id, Person.Sample.speakers(keys),
                          Voiceprint(model: model.rawValue, seconds: prints.map(\.seconds).reduce(0, +),
                                     embeddings: prints.flatMap(\.embeddings))))
        }
        return parts
    }
}
