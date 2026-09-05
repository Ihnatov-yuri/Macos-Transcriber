import AppKit
import ApplicationServices
import NaturalLanguage

/// Everything the formatter may know about where the text is going —
/// captured when a session STARTS (the app in front at that moment is the
/// one that receives the passage).
///
/// The Wispr-Flow idea, on-device: the active app decides the register
/// (Slack ≠ Mail ≠ Terminal), the text before the caret gives continuity
/// (language, tone, an open list), and the field's role vetoes anything
/// clever (search boxes, password fields, code).
struct DictationContext: Sendable {
    var appName: String?
    var bundleId: String?
    var windowTitle: String?
    /// AXRole of the focused element ("AXTextArea", "AXTextField", …).
    var role: String?
    /// Password fields: never read, never polish.
    var isSecure = false
    /// Single-line fields (search, URL, chat composer): no paragraphs.
    var isSingleLine: Bool { role == "AXTextField" || role == "AXComboBox" || role == "AXSearchField" }
    /// Up to ~600 characters before the caret, when the app exposes them.
    var preceding: String?

    /// Dominant language of the preceding text, as the app's language name
    /// ("English", "Dutch", …) — only when there is enough text to be sure.
    var contextLanguage: String? {
        guard let preceding, preceding.count >= 24 else { return nil }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(preceding)
        guard let lang = recognizer.dominantLanguage,
              let confidence = recognizer.languageHypotheses(withMaximum: 1)[lang], confidence >= 0.7
        else { return nil }
        switch lang {
        case .english:    return "English"
        case .dutch:      return "Dutch"
        case .ukrainian:  return "Ukrainian"
        case .german:     return "German"
        case .french:     return "French"
        case .spanish:    return "Spanish"
        case .italian:    return "Italian"
        case .portuguese: return "Portuguese"
        case .polish:     return "Polish"
        default:          return nil
        }
    }

    /// Category hints for the smart pass when the rule's tone is `.auto`.
    var inferredTone: DictationSettings.Tone {
        let id = (bundleId ?? "").lowercased()
        let name = (appName ?? "").lowercased()
        let chatty = ["slack", "messages", "whatsapp", "telegram", "discord", "signal", "teams", "imessage"]
        let formal = ["mail", "outlook", "spark", "airmail", "mimestream"]
        if chatty.contains(where: { id.contains($0) || name.contains($0) }) { return .casual }
        if formal.contains(where: { id.contains($0) || name.contains($0) }) { return .formal }
        return .neutral
    }

    // MARK: - Capture

    @MainActor
    static func capture(readText: Bool) -> DictationContext {
        var ctx = DictationContext()
        if let app = NSWorkspace.shared.frontmostApplication {
            ctx.appName = app.localizedName
            ctx.bundleId = app.bundleIdentifier
        }
        guard HotkeyMonitor.isTrusted() else { return ctx }

        let system = AXUIElementCreateSystemWide()
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success,
              let focusedRef, CFGetTypeID(focusedRef) == AXUIElementGetTypeID()
        else { return ctx }
        let element = focusedRef as! AXUIElement

        var roleRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef) == .success {
            ctx.role = roleRef as? String
        }
        var subroleRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subroleRef) == .success,
           let subrole = subroleRef as? String {
            if subrole == kAXSecureTextFieldSubrole as String { ctx.isSecure = true }
            if subrole == kAXSearchFieldSubrole as String { ctx.role = "AXSearchField" }
        }
        var windowRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXWindowAttribute as CFString, &windowRef) == .success,
           let windowRef, CFGetTypeID(windowRef) == AXUIElementGetTypeID() {
            var titleRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(windowRef as! AXUIElement, kAXTitleAttribute as CFString, &titleRef) == .success {
                ctx.windowTitle = titleRef as? String
            }
        }
        if readText, !ctx.isSecure {
            ctx.preceding = FocusedTextContext.textBeforeCaret(maxChars: 600)
        }
        return ctx
    }
}

/// Prompt for the smart pass: the passage, formatted for where it's going.
enum DictationPrompt {
    static func system(tone: DictationSettings.Tone, singleLine: Bool) -> String {
        var s = """
        You are a dictation formatter. You receive ONE passage of speech-to-text \
        output and return the same passage as polished written text for the \
        place it will be inserted. Keep the speaker's wording, meaning, language \
        and length; never answer, summarize, translate, or add content. Apply \
        spoken self-corrections ("Monday, no, Tuesday" → "Tuesday"). Fix \
        punctuation, casing and sentence boundaries. Remove hesitation fillers \
        and false starts. Output only the formatted text — no quotes, no preamble.
        """
        switch tone {
        case .casual:
            s += "\nRegister: chat message — relaxed, short sentences, no salutation or sign-off, no bullet lists unless items were clearly enumerated."
        case .formal:
            s += "\nRegister: email or document — complete sentences, proper capitalization, paragraphs where the speaker paused; keep any greeting the speaker said."
        case .neutral, .auto:
            s += "\nRegister: plain notes — complete sentences; enumerations the speaker made ('first… second…') become a list."
        }
        if singleLine {
            s += "\nThe target is a single-line field: return one line, no line breaks."
        }
        return s
    }

    static func user(passage: String, context: DictationContext, vocabulary: [String]) -> String {
        var u = ""
        if let app = context.appName {
            u += "Target app: \(app)"
            if let title = context.windowTitle, !title.isEmpty { u += " — window “\(title.prefix(80))”" }
            u += "\n"
        }
        if let preceding = context.preceding?.trimmingCharacters(in: .whitespacesAndNewlines), !preceding.isEmpty {
            u += "Text already before the cursor (for continuity only — do NOT repeat it):\n«\(preceding.suffix(400))»\n"
        }
        if !vocabulary.isEmpty {
            u += "Vocabulary (authoritative spellings): \(vocabulary.prefix(60).joined(separator: ", "))\n"
        }
        u += "\nPASSAGE:\n\(passage)"
        return u
    }
}
