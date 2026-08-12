import Foundation
import Observation

/// Mirror of `asr/PresetStore.kt` and `asr/PostProcessingPresets.kt`.
/// Editable templates for the four built-in post-processing presets, plus any
/// user-added presets.
struct PostProcessingPreset: Sendable, Identifiable, Codable, Equatable {
    var id: String
    var name: String
    var outputTitle: String
    var systemTemplate: String
    var userTemplate: String
}

@Observable
final class PresetStore: @unchecked Sendable {
    private let defaults = UserDefaults.standard
    private let key = "presets.v1"

    var presets: [PostProcessingPreset] {
        didSet { persist() }
    }

    init() {
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

    func resetToDefaults() { presets = Builtin.all }
    func preset(_ id: String) -> PostProcessingPreset? { presets.first { $0.id == id } }

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
            """
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
            """
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
            """
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
    }
}
