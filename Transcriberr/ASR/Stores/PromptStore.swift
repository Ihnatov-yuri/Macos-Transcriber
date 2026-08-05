import Foundation
import Observation

/// Mirror of `asr/PromptStore.kt`.
/// Holds user-editable system prompts + style (vocab, fillers, verbatim, tone).
/// `render(...)` assembles the final system instruction handed to the backend.
@Observable
final class PromptStore: @unchecked Sendable {
    enum Tone: String, CaseIterable, Sendable {
        case neutral, formal, casual, enthusiastic, technical
    }

    private let defaults = UserDefaults.standard
    private enum Key {
        static let transcribe = "prompt.transcribe"
        static let translate  = "prompt.translate"
        static let vocabulary = "prompt.vocabulary"
        static let vocabByLang = "prompt.vocabulary.byLang"
        static let fillers    = "prompt.removeFillers"
        static let verbatim   = "prompt.verbatim"
        static let tone       = "prompt.tone"
    }

    var transcribePrompt: String { didSet { defaults.set(transcribePrompt, forKey: Key.transcribe) } }
    var translatePrompt: String  { didSet { defaults.set(translatePrompt,  forKey: Key.translate) } }
    var vocabulary: String       { didSet { defaults.set(vocabulary,       forKey: Key.vocabulary) } }
    /// Language-specific term lists (key = app language name, e.g.
    /// "Ukrainian"). Injected only when a run's language matches, so a
    /// Ukrainian transcription isn't diluted with English product names.
    var vocabularyByLanguage: [String: String] {
        didSet {
            if let data = try? JSONEncoder().encode(vocabularyByLanguage) {
                defaults.set(String(decoding: data, as: UTF8.self), forKey: Key.vocabByLang)
            }
        }
    }

    /// Global vocabulary + the entries for the given run languages (all
    /// language entries when the run is auto-detect).
    func vocabulary(for languages: Set<String>) -> String {
        var parts: [String] = []
        let global = vocabulary.trimmingCharacters(in: .whitespacesAndNewlines)
        if !global.isEmpty { parts.append(global) }
        let keys = languages.isEmpty ? Array(vocabularyByLanguage.keys) : Array(languages)
        for k in keys.sorted() {
            if let v = vocabularyByLanguage[k]?.trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty {
                parts.append(v)
            }
        }
        return parts.joined(separator: ", ")
    }
    var removeFillers: Bool      { didSet { defaults.set(removeFillers,    forKey: Key.fillers) } }
    var verbatim: Bool           { didSet { defaults.set(verbatim,         forKey: Key.verbatim) } }
    var tone: Tone               { didSet { defaults.set(tone.rawValue,    forKey: Key.tone) } }

    init() {
        transcribePrompt = defaults.string(forKey: Key.transcribe) ?? Defaults.transcribe
        translatePrompt  = defaults.string(forKey: Key.translate)  ?? Defaults.translate
        vocabulary       = defaults.string(forKey: Key.vocabulary) ?? ""
        vocabularyByLanguage = defaults.string(forKey: Key.vocabByLang)
            .flatMap { try? JSONDecoder().decode([String: String].self, from: Data($0.utf8)) } ?? [:]
        removeFillers    = defaults.bool(forKey: Key.fillers)
        verbatim         = defaults.bool(forKey: Key.verbatim)
        tone             = Tone(rawValue: defaults.string(forKey: Key.tone) ?? "") ?? .neutral
    }

    /// Final system instruction for one call.
    /// `{language_hint}` is replaced by the per-call language template.
    func render(translate: Bool, languages: Set<String>, diarize: Bool) -> String {
        var base = translate ? translatePrompt : transcribePrompt

        let hint: String = {
            if translate { return "" }
            if languages.isEmpty { return "" }
            return "Speak only in \(languages.sorted().joined(separator: ", "))."
        }()
        base = base.replacingOccurrences(of: "{language_hint}", with: hint)

        if !vocabulary.isEmpty {
            let terms = vocabulary
                .split(whereSeparator: { $0 == "," || $0.isNewline })
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
                .prefix(250)
            base += "\n\nSpell these correctly when heard: \(terms.joined(separator: ", "))."
        }
        if removeFillers {
            base += "\n\nRemove filler words: um, uh, like, you know."
        }
        if verbatim {
            base += "\n\nVerbatim mode: do not smart-format."
        }
        if tone != .neutral {
            base += "\n\nTone: \(tone.rawValue)."
        }
        if diarize {
            base += "\n\nPrefix each utterance with \"Speaker N:\" where N is a stable integer per voice."
        }
        return base
    }

    private enum Defaults {
        static let transcribe = """
        You are an audio transcription engine. Output exactly what was said, \
        with sentence-case punctuation. {language_hint}
        Output ONLY the words spoken — no commentary, no preface.
        """
        static let translate = """
        Translate the speech in this audio into idiomatic English. \
        Keep proper names verbatim. Use sentence-case punctuation.
        """
    }
}
