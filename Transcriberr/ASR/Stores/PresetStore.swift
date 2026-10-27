import Foundation
import Observation

/// Mirror of `asr/PresetStore.kt` and `asr/PostProcessingPresets.kt`.
/// Editable templates for the built-in post-processing presets, plus any
/// presets the user adds. Each preset is one tab in Detail, in this order.
nonisolated struct PostProcessingPreset: Sendable, Identifiable, Codable, Equatable {
    var id: String
    var name: String
    var outputTitle: String
    var systemTemplate: String
    var userTemplate: String
    var kind: Kind

    /// How a preset runs. An analysis reads the whole transcript once and
    /// writes something new about it (summary, minutes, a critique). A
    /// rewrite gives back the whole transcript changed, so it runs one
    /// window at a time: a small local model cannot copy 20k characters in
    /// one go without dropping words.
    enum Kind: String, Sendable, Codable, CaseIterable {
        case analysis, rewrite
    }

    init(id: String, name: String, outputTitle: String,
         systemTemplate: String, userTemplate: String, kind: Kind = .analysis) {
        self.id = id
        self.name = name
        self.outputTitle = outputTitle
        self.systemTemplate = systemTemplate
        self.userTemplate = userTemplate
        self.kind = kind
    }

    /// Presets saved before 4.5 have no `kind`; the three rewrite built-ins
    /// were told apart by id in PostProcessor.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        outputTitle = try c.decode(String.self, forKey: .outputTitle)
        systemTemplate = try c.decode(String.self, forKey: .systemTemplate)
        userTemplate = try c.decode(String.self, forKey: .userTemplate)
        kind = try c.decodeIfPresent(Kind.self, forKey: .kind)
            ?? (PresetStore.Builtin.rewriteIds.contains(id) ? .rewrite : .analysis)
    }

    var isBuiltin: Bool { PresetStore.Builtin.ids.contains(id) }

    /// True when the user template says where the transcript goes. Without
    /// a placeholder the model would get instructions and no transcript, so
    /// `templateWithTranscript` appends one.
    var placesTranscript: Bool {
        userTemplate.contains("{transcript_with_speakers}") || userTemplate.contains("{transcript}")
    }

    var templateWithTranscript: String {
        placesTranscript ? userTemplate
            : userTemplate.trimmingCharacters(in: .whitespacesAndNewlines)
                + "\n\nTRANSCRIPT:\n{transcript_with_speakers}"
    }
}

/// One saved state of a preset's prompts. Made when a preset runs with
/// prompts it has not run with before, on Save version, and before a reset,
/// restore or delete changes it, never per keystroke.
struct PresetRevision: Codable, Identifiable, Equatable, Sendable {
    enum Reason: String, Codable, Sendable { case run, saved, beforeReset, beforeRestore, beforeDelete }
    var id: UUID
    var presetId: String
    var savedAt: Date
    var reason: Reason
    var preset: PostProcessingPreset

    var label: String {
        switch reason {
        case .run: return "Used for a run"
        case .saved: return "Saved by you"
        case .beforeReset: return "Before reset"
        case .beforeRestore: return "Before restore"
        case .beforeDelete: return "Before delete"
        }
    }
}

@Observable
nonisolated final class PresetStore: @unchecked Sendable {
    private let defaults: UserDefaults
    private let key = "presets.v1"

    var presets: [PostProcessingPreset] {
        didSet { persist() }
    }

    /// All presets' revisions, oldest first; `historyLimit` per preset.
    private(set) var history: [PresetRevision] {
        didSet { persistHistory() }
    }
    private let historyKey = "presets.history.v1"
    static let historyLimit = 30

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        history = (defaults.data(forKey: "presets.history.v1"))
            .flatMap { try? JSONDecoder().decode([PresetRevision].self, from: $0) } ?? []
        if let data = defaults.data(forKey: key),
           let decoded = try? JSONDecoder().decode([PostProcessingPreset].self, from: data),
           !decoded.isEmpty
        {
            presets = decoded
        } else {
            presets = Builtin.all
        }
        // One-time template upgrade: the v1 built-in prompts were one-liners
        // and produced weak/truncated output. Swap the four built-ins for the
        // current templates once, preserving any user-added presets.
        if !defaults.bool(forKey: "presets.upgraded.v4") {
            defaults.set(true, forKey: "presets.upgraded.v4")
            let builtinIds = Set(Builtin.all.map(\.id))
            let userAdded = presets.filter { !builtinIds.contains($0.id) }
            presets = Builtin.all + userAdded
        }
    }

    func preset(_ id: String) -> PostProcessingPreset? { presets.first { $0.id == id } }

    /// Newest first.
    func revisions(for id: String) -> [PresetRevision] {
        history.filter { $0.presetId == id }.reversed()
    }

    /// Saves the preset's current state, unless its newest revision already
    /// holds the same prompts. Compared by value, never by encoded JSON
    /// (JSONEncoder's key order is not stable).
    @discardableResult
    func checkpoint(_ id: String, reason: PresetRevision.Reason, now: Date = Date()) -> PresetRevision? {
        guard let current = preset(id) else { return nil }
        if let last = history.last(where: { $0.presetId == id }), last.preset == current { return nil }
        let rev = PresetRevision(id: UUID(), presetId: id, savedAt: now, reason: reason, preset: current)
        var all = history + [rev]
        let mine = all.filter { $0.presetId == id }
        if mine.count > Self.historyLimit {
            let drop = Set(mine.prefix(mine.count - Self.historyLimit).map(\.id))
            all.removeAll { drop.contains($0.id) }
        }
        history = all
        return rev
    }

    /// Puts a revision's prompts back. The state it replaces is saved
    /// first; the preset keeps its place, and comes back if it was deleted.
    func restore(_ revision: PresetRevision) {
        checkpoint(revision.presetId, reason: .beforeRestore)
        if let idx = presets.firstIndex(where: { $0.id == revision.presetId }) {
            presets[idx] = revision.preset
        } else {
            presets.append(revision.preset)
        }
    }

    /// Presets deleted with history to bring them back from.
    var deletedWithHistory: [PresetRevision] {
        let live = Set(presets.map(\.id))
        var seen: Set<String> = []
        return history.reversed().filter { !live.contains($0.presetId) && seen.insert($0.presetId).inserted }
    }

    /// Puts every built-in back as shipped, in its shipped place, and
    /// returns deleted ones. Presets the user added stay, after them.
    func restoreBuiltins() {
        for p in presets where p.isBuiltin { checkpoint(p.id, reason: .beforeReset) }
        let userAdded = presets.filter { !$0.isBuiltin }
        presets = Builtin.all + userAdded
    }

    /// One built-in back to its shipped prompts and name, where it stands.
    func resetBuiltin(_ id: String) {
        guard let shipped = Builtin.all.first(where: { $0.id == id }),
              let idx = presets.firstIndex(where: { $0.id == id }) else { return }
        checkpoint(id, reason: .beforeReset)
        presets[idx] = shipped
    }

    /// A new preset at the end; returns its id. The default prompts ask
    /// for something short so a first try on Gemma comes back quickly.
    @discardableResult
    func add(name: String = "New preset") -> String {
        let preset = PostProcessingPreset(
            id: Self.newId(),
            name: uniqueName(name),
            outputTitle: uniqueName(name),
            systemTemplate: """
            You analyse voice-recording transcripts. Faithful to the source: \
            never invent facts, names, numbers, or decisions that are not in the \
            transcript. Write in the transcript's own language.
            """,
            userTemplate: """
            Describe what you want from the transcript here.

            TRANSCRIPT:
            {transcript_with_speakers}
            """
        )
        presets.append(preset)
        return preset.id
    }

    /// A copy right after the original, so a built-in can be the start of
    /// a new preset without being changed itself.
    @discardableResult
    func duplicate(_ id: String) -> String? {
        guard let idx = presets.firstIndex(where: { $0.id == id }) else { return nil }
        var copy = presets[idx]
        copy.id = Self.newId()
        copy.name = uniqueName(copy.name + " copy")
        copy.outputTitle = copy.name
        presets.insert(copy, at: idx + 1)
        return copy.id
    }

    func delete(_ id: String) {
        checkpoint(id, reason: .beforeDelete)
        presets.removeAll { $0.id == id }
    }

    /// Moves a preset one place up (-1) or down (+1); its Detail tab follows.
    func move(_ id: String, by offset: Int) {
        guard let idx = presets.firstIndex(where: { $0.id == id }) else { return }
        let target = idx + offset
        guard presets.indices.contains(target) else { return }
        presets.swapAt(idx, target)
    }

    private func uniqueName(_ base: String) -> String {
        let taken = Set(presets.map(\.name))
        guard taken.contains(base) else { return base }
        var n = 2
        while taken.contains("\(base) \(n)") { n += 1 }
        return "\(base) \(n)"
    }

    /// Ids of added presets never collide with a built-in id, now or later.
    private static func newId() -> String {
        "custom-" + UUID().uuidString.prefix(8).lowercased()
    }

    private func persistHistory() {
        if let data = try? JSONEncoder().encode(history) {
            defaults.set(data, forKey: historyKey)
        }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(presets) {
            defaults.set(data, forKey: key)
        }
    }

    enum Builtin {
        static let summary = PostProcessingPreset(
            id: "summary",
            name: "Summary",
            outputTitle: "Summary",
            systemTemplate: """
            You are an expert minute-taker summarizing voice-recording transcripts. \
            You are faithful to the source: never invent facts, names, numbers, or \
            decisions that are not in the transcript. Write in the transcript's own \
            language. The transcript comes from speech recognition, so read past \
            small transcription errors instead of quoting them.
            """,
            userTemplate: """
            Summarize the transcript below in Markdown with exactly these sections, \
            omitting any section that would be empty:

            **TL;DR** — 1–2 sentences.
            **Key points** — 4–10 bullets; attribute to speakers where it matters.
            **Decisions** — what was agreed or concluded.
            **Action items** — one bullet per task: owner → task (→ deadline if said).
            **Open questions** — unresolved threads.

            TRANSCRIPT:
            {transcript_with_speakers}
            """
        )
        static let contextRewrite = PostProcessingPreset(
            id: "context_rewrite",
            name: "Context-aware rewrite",
            outputTitle: "Context-aware rewrite",
            systemTemplate: """
            You repair speech-to-text transcripts using the WHOLE conversation as \
            context. You never paraphrase, never translate, never summarize, and \
            never drop content: your output contains every line of the input, \
            corrected. Preserve speaker labels exactly.
            """,
            userTemplate: """
            Read the entire transcript first. Then output the complete transcript \
            again, applying only these corrections:
            - Fix misrecognized words using context from elsewhere in the conversation.
            - Back-propagate the correct spelling of names, products, and technical \
              terms to every occurrence once any mention makes them clear.
            - Fix homophone errors (their/there, to/two, etc.).
            - Delete pure gibberish fragments only when clearly non-speech.
            - Copy each speaker label EXACTLY, character for character ("Yuri:" \
              stays "Yuri:", never "uri:").
            Everything else — wording, order, language — stays identical.

            TRANSCRIPT:
            {transcript_with_speakers}
            """,
            kind: .rewrite
        )
        static let clean = PostProcessingPreset(
            id: "clean",
            name: "Clean",
            outputTitle: "Clean",
            systemTemplate: """
            You are a transcript editor. You clean speech-to-text output WITHOUT \
            changing its meaning, language, or content. You never summarize, never \
            skip lines, never add content. Your output is the COMPLETE cleaned \
            transcript — same structure, same speaker labels.
            """,
            userTemplate: """
            Clean the transcript below. Apply exactly:
            - Correct punctuation, casing, and sentence boundaries.
            - Remove filler words (uh, um, you know) and false starts / stuttered \
              repetitions of words or phrases ("it's sometimes it's" -> "it's").
            - Fix obvious speech-recognition mishearings when context makes the \
              intended word certain; otherwise leave the word as-is.
            - Keep the original language. Keep every sentence.
            - Copy each speaker label EXACTLY, character for character ("Yuri:" \
              stays "Yuri:", never "uri:" or a renamed variant).
            Output the full cleaned transcript, nothing else.

            TRANSCRIPT:
            {transcript_with_speakers}
            """,
            kind: .rewrite
        )
        static let translatePolish = PostProcessingPreset(
            id: "translate_polish",
            name: "Translate & polish",
            outputTitle: "English",
            systemTemplate: """
            You translate voice-recording transcripts into idiomatic English prose. \
            You are faithful to content — nothing added, nothing dropped — while \
            producing natural, readable English. Keep proper names, product names, \
            and numbers verbatim.
            """,
            userTemplate: """
            Translate the complete transcript below into idiomatic English. Render \
            each speaker's turns as flowing prose paragraphs (keep the speaker \
            labels), not fragment-by-fragment. Translate ALL of it — do not stop early.

            TRANSCRIPT:
            {transcript_with_speakers}
            """,
            kind: .rewrite
        )
        static let minutes = PostProcessingPreset(
            id: "minutes",
            name: "Minutes",
            outputTitle: "Minutes",
            systemTemplate: """
            You are an expert minute-taker for meetings. Faithful to the \
            transcript: never invent decisions, owners, dates, or numbers. \
            Write in the transcript's own language. Speaker labels identify \
            who said what — use them for attribution.
            """,
            userTemplate: """
            Write meeting minutes from the transcript below, in Markdown, \
            omitting any section that would be empty:

            **TL;DR** — 2–3 sentences: what the meeting was about and the outcome.
            **Decisions** — one bullet per decision, with who made or confirmed it.
            **Action items by owner** — a subsection per person who owns tasks; \
            bullet each task (→ deadline if said). Include tasks assigned TO \
            them by others.
            **Risks / blockers** — anything flagged as a problem.
            **Open questions** — unresolved threads and who should answer them.

            TRANSCRIPT:
            {transcript_with_speakers}
            """
        )
        static let all = [summary, minutes, contextRewrite, clean, translatePolish]
        static let ids = Set(all.map(\.id))
        /// What PostProcessor ran chunked before presets had a `kind`; the
        /// decoder uses it for presets saved by 4.4 and earlier.
        static let rewriteIds: Set<String> = ["clean", "context_rewrite", "translate_polish"]
    }
}
