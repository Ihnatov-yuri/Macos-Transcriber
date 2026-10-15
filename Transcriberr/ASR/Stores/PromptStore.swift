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

    private let defaults: UserDefaults
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

    /// Adds a term the user taught the app (a disputed word they settled),
    /// to the run language's list when there is one, else to the global
    /// list. Already there in any casing → nothing changes.
    func learnTerm(_ term: String, language: String?) {
        let t = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        func adding(_ list: String) -> String? {
            let items = list.split(whereSeparator: { $0 == "," || $0.isNewline })
                .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            guard !items.contains(where: { $0.caseInsensitiveCompare(t) == .orderedSame }) else { return nil }
            return (items + [t]).joined(separator: ", ")
        }
        var added = false
        if let language, !language.isEmpty {
            if let v = adding(vocabularyByLanguage[language] ?? "") { vocabularyByLanguage[language] = v; added = true }
        } else if let v = adding(vocabulary) {
            vocabulary = v; added = true
        }
        // Remembered with the list it went into ("Ukrainian|Kaiko", "|Kaiko"
        // for the global list), so only that entry can be taken out again.
        if added {
            defaults.set((defaults.stringArray(forKey: Self.learnedTermsKey) ?? []) + ["\(language ?? "")|\(t)"],
                         forKey: Self.learnedTermsKey)
        }
    }

    static let learnedTermsKey = "vocab.learnedTerms"

    /// Takes back a term `learnTerm` added (the user switched the word back).
    /// A term the user typed themselves is never touched.
    func forgetLearnedTerm(_ term: String) {
        var learned = defaults.stringArray(forKey: Self.learnedTermsKey) ?? []
        guard let i = learned.firstIndex(where: {
            ($0.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false).last.map(String.init) ?? $0)
                .caseInsensitiveCompare(term) == .orderedSame
        }) else { return }
        let entry = learned.remove(at: i)
        defaults.set(learned, forKey: Self.learnedTermsKey)
        let language = entry.contains("|") ? String(entry.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)[0]) : ""
        func removing(_ list: String) -> String {
            list.split(whereSeparator: { $0 == "," || $0.isNewline })
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty && $0.caseInsensitiveCompare(term) != .orderedSame }
                .joined(separator: ", ")
        }
        if !language.isEmpty {
            if let v = vocabularyByLanguage[language] { vocabularyByLanguage[language] = removing(v) }
        } else {
            vocabulary = removing(vocabulary)
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

    /// `defaults` for tests: the test host shares the app's own domain.
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
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
