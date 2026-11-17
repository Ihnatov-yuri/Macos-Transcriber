import Foundation

/// What a dictation becomes: the words as said (formatted by the mode), or a
/// rewrite of the WHOLE session into a shape — a professional message, a
/// letter, a bullet list.
///
/// A style works on a whole session, never on a single pause flush: a letter
/// written paragraph by paragraph would get a greeting and a sign-off at
/// every pause. Pure Foundation so the CLI can run the same prompt and guard
/// (`transcriberrcli dictstyle`).
nonisolated enum DictationStyle: String, CaseIterable, Codable, Sendable {
    case off
    case message
    case letter
    case bullets

    /// Short value for the options row and the menu.
    var label: String {
        switch self {
        case .off:     return String(localized: "As spoken", comment: "Dictation style: no rewrite, the words as said")
        case .message: return String(localized: "Message", comment: "Dictation style: rewrite as a professional message")
        case .letter:  return String(localized: "Letter", comment: "Dictation style: rewrite as a letter or email")
        case .bullets: return String(localized: "Bullets", comment: "Dictation style: rewrite as a bullet list")
        }
    }

    /// One-line explanation under the option.
    var hint: String {
        switch self {
        case .off:     return String(localized: "the words as you said them,\nformatted by the mode", comment: "Dictation style hint")
        case .message: return String(localized: "whole dictation rewritten as\na clear, professional message", comment: "Dictation style hint")
        case .letter:  return String(localized: "whole dictation rewritten as\na letter: greeting, body, closing", comment: "Dictation style hint")
        case .bullets: return String(localized: "whole dictation rewritten as\na short bullet list", comment: "Dictation style hint")
        }
    }

    /// Footer and HUD line while the text model writes.
    var workingLabel: String {
        switch self {
        case .off:     return String(localized: "Speech, then the text model formats")
        case .message: return String(localized: "Writing the message…", comment: "Dictation: the text model is rewriting as a message")
        case .letter:  return String(localized: "Writing the letter…", comment: "Dictation: the text model is rewriting as a letter")
        case .bullets: return String(localized: "Writing the bullet list…", comment: "Dictation: the text model is rewriting as bullets")
        }
    }

    // MARK: - Prompt

    /// System prompt for the rewrite. English instructions; the output stays
    /// in the language the speaker used.
    var systemPrompt: String {
        var s = """
        You are a writing assistant. You receive a dictated draft (speech-to-text \
        output, possibly with fillers, repetitions, self-corrections and loose \
        word order) and rewrite it into the requested form. Rules: keep every \
        fact, name, number, date and request the speaker gave; never invent \
        facts, names, dates or promises; apply self-corrections ("Monday, no, \
        Tuesday" means Tuesday); keep who does what exactly as the speaker \
        said (never turn "it needs doing" into a request to the reader); drop \
        fillers and false starts. Write in the \
        same language the speaker used — never translate. Never answer \
        questions in the draft; they are part of what the speaker wants to \
        say. Output only the finished text: no preamble, no quotes, no notes.
        """
        switch self {
        case .off:
            break
        case .message:
            s += """
            \nForm: a clear, professional message (a chat message or a short email \
            body). Friendly but businesslike: complete sentences, short paragraphs, \
            the main point first, slang and very casual phrasing made neutral \
            ("hey" → "Hi"). No subject line. Keep a greeting only if the speaker \
            said one, and no sign-off unless the speaker said one.
            """
        case .letter:
            s += """
            \nForm: a complete, formal letter or email, more formal than the \
            speaker's spoken register. Start with a formal greeting on its own line \
            ("Dear Mark," or its equivalent in the draft's language; with the \
            recipient's name if the speaker mentioned one, otherwise a neutral \
            formal greeting). Then the body in well-formed paragraphs with polite \
            phrasing ("Could you please…", "I would like to inform you…"), then a \
            formal closing on its own line ("Kind regards," or its equivalent). \
            Put the speaker's name under the closing only if the speaker said it. \
            No subject line unless the speaker dictated one.
            """
        case .bullets:
            s += """
            \nForm: a concise bullet list. One point per line, each starting with \
            "- ". Short phrases, not full paragraphs; group what belongs together \
            and keep the speaker's order. No title or intro line unless the \
            speaker dictated one.
            """
        }
        return s
    }

    /// User message: the draft, plus authoritative spellings.
    func userPrompt(draft: String, vocabulary: [String] = []) -> String {
        var u = ""
        if !vocabulary.isEmpty {
            u += "Vocabulary (authoritative spellings): \(vocabulary.prefix(60).joined(separator: ", "))\n\n"
        }
        u += "DRAFT:\n\(draft)"
        return u
    }

    /// The longest draft a rewrite takes, about five minutes of speech. A
    /// longer one goes in as spoken: the model's reply would hit its token
    /// budget and stop mid-sentence, and a cut-off rewrite still looks like
    /// a good one to `accept` (the ending of the dictation would be lost
    /// without a word).
    static let maxDraftCharacters = 6000

    static func canRewrite(_ draft: String) -> Bool { draft.count <= maxDraftCharacters }

    /// Token budget: room for the whole draft rewritten, even in Ukrainian
    /// (about 2.5 characters a token), plus a greeting and a closing.
    func maxTokens(forDraft draft: String) -> Int {
        draft.count / 2 + 300
    }

    // MARK: - Output

    /// Strip what models wrap around an answer: a quoted block, a code fence,
    /// a "Here is the letter:" line.
    static func tidy(_ output: String, draft: String = "") -> String {
        var t = output.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.hasPrefix("```") {
            var lines = t.components(separatedBy: "\n")
            lines.removeFirst()
            if lines.last?.trimmingCharacters(in: .whitespaces).hasPrefix("```") == true { lines.removeLast() }
            t = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let first = t.components(separatedBy: "\n").first {
            let lower = first.lowercased()
            let preambles = ["here is", "here's", "sure", "certainly", "below is"]
            // …unless the speaker said it: "Here's what we need for Friday:"
            // is a dictated title, not the model talking.
            let dictated = !draft.isEmpty && Self.startsAlike(first, draft)
            if first.hasSuffix(":"), first.count < 80, !dictated, preambles.contains(where: { lower.hasPrefix($0) }) {
                t = String(t.dropFirst(first.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        if t.count > 2, t.hasPrefix("\""), t.hasSuffix("\""), !t.dropFirst().dropLast().contains("\"") {
            t = String(t.dropFirst().dropLast())
        }
        return t
    }

    /// Whether two texts open with the same three words.
    static func startsAlike(_ a: String, _ b: String) -> Bool {
        func head(_ s: String) -> [String] {
            s.lowercased().replacingOccurrences(of: "’", with: "'")
                .split { !$0.isLetter && !$0.isNumber && $0 != "'" }.prefix(3).map(String.init)
        }
        let ha = head(a)
        return ha.count == 3 && ha == head(b)
    }

    /// Whether a rewrite can stand in for the draft. A rewrite legitimately
    /// changes words and length, so this is looser than the polish guard; it
    /// catches what must never replace the user's words: an empty or runaway
    /// reply, a refusal, a translation, or a reply about something else. Most
    /// of the draft's longer words must still be there.
    static func accept(draft: String, rewrite: String) -> Bool {
        let r = rewrite.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !r.isEmpty else { return false }
        let ratio = Double(r.count) / Double(max(1, draft.count))
        // Bullets compress, a letter adds a greeting and a closing to a
        // one-line draft.
        let ceiling = draft.count < 120 ? 6.0 : 3.0
        guard ratio >= 0.2, ratio <= ceiling else { return false }
        let lower = r.lowercased()
        // A reply that opens like a refusal is one only when the speaker did
        // not open that way: "sorry, I can't make the standup" rewritten as
        // "I'm sorry, I can't make…" is the message, not a refusal.
        let refusals = ["as an ai", "i cannot", "i can't", "i'm sorry", "i am sorry", "i'm unable"]
        let apology = ["sorry", "can't", "cannot", "unable", "afraid", "apolog"]
        let draftOpening = String(draft.lowercased().replacingOccurrences(of: "’", with: "'").prefix(60))
        let speakerApologized = apology.contains { draftOpening.contains($0) }
        let normalized = lower.replacingOccurrences(of: "’", with: "'")
        if !speakerApologized, refusals.contains(where: { normalized.hasPrefix($0) }) { return false }
        let draftWords = Set(contentWords(draft))
        guard !draftWords.isEmpty else { return true }
        let kept = Set(contentWords(r))
        // Prefix match covers inflection ("send" / "sending", "лист" / "листа").
        let found = draftWords.filter { w in
            kept.contains(w) || kept.contains { $0.hasPrefix(w.prefix(4)) }
        }
        let needed = draftWords.count <= 3 ? 1.0 / Double(draftWords.count) : 0.35
        return Double(found.count) / Double(draftWords.count) >= needed
    }

    /// Words of five letters or more: names, nouns, verbs — the content the
    /// rewrite must carry. Short function words change with the register.
    static func contentWords(_ text: String) -> [String] {
        text.lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
            .filter { $0.count >= 5 || $0.allSatisfy(\.isNumber) }
    }
}
