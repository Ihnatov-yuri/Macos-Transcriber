import AppKit
import ApplicationServices

/// What sits left of the caret in whatever app has keyboard focus, read
/// through the Accessibility API. Lets the inserter decide spacing and
/// capitalization from the real context instead of a blanket rule.
///
/// Works in Cocoa text views, Safari/WebKit fields, Mail, Notes, Xcode and
/// most Electron editors. Terminals and apps that don't expose their text
/// return nil, and the caller falls back to the plain spacing rule.
enum FocusedTextContext {
    /// Up to `maxChars` characters immediately before the caret, or nil when
    /// the focused element doesn't expose a selection range and text.
    @MainActor
    static func textBeforeCaret(maxChars: Int = 64) -> String? {
        guard HotkeyMonitor.isTrusted() else { return nil }
        let system = AXUIElementCreateSystemWide()
        // Same cap as DictationContext: this also runs on the main actor, at
        // insertion time, where a slow target app would stall the paste.
        AXUIElementSetMessagingTimeout(system, DictationContext.axTimeout)
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success,
              let focusedRef, CFGetTypeID(focusedRef) == AXUIElementGetTypeID()
        else { return nil }
        let element = focusedRef as! AXUIElement
        AXUIElementSetMessagingTimeout(element, DictationContext.axTimeout)

        var rangeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeRef) == .success,
              let rangeRef, CFGetTypeID(rangeRef) == AXValueGetTypeID()
        else { return nil }
        var selection = CFRange()
        guard AXValueGetValue(rangeRef as! AXValue, .cfRange, &selection) else { return nil }
        guard selection.location >= 0 else { return nil }

        let start = max(0, selection.location - maxChars)
        guard selection.location - start > 0 else { return "" }   // caret at the very start
        // A few units more than asked for, so a window that starts inside a
        // surrogate pair or a composed character (an emoji, an accent) can
        // be moved to the next whole character: cut there, the first
        // character read as a replacement mark.
        let lead = max(0, start - Self.alignmentSlack)
        var window = CFRange(location: lead, length: selection.location - lead)

        // Parameterized string-for-range avoids copying a whole document.
        if let param = AXValueCreate(.cfRange, &window) {
            var textRef: CFTypeRef?
            if AXUIElementCopyParameterizedAttributeValue(
                element, kAXStringForRangeParameterizedAttribute as CFString, param, &textRef
            ) == .success, let text = textRef as? String {
                // An app that returned other than the range asked for: as is.
                guard (text as NSString).length == window.length else { return text }
                return alignedTail(of: text, from: start - lead)
            }
        }
        // Fallback for elements that only expose the whole value.
        var valueRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &valueRef) == .success,
              let value = valueRef as? String
        else { return nil }
        let ns = value as NSString
        guard selection.location <= ns.length else { return nil }
        let text = ns.substring(with: NSRange(location: lead, length: selection.location - lead))
        return alignedTail(of: text, from: start - lead)
    }

    /// UTF-16 units read before the window, to find a character boundary.
    static let alignmentSlack = 8

    /// `text` from UTF-16 offset `offset` on, moved forward to the next
    /// whole composed character when `offset` falls inside one.
    nonisolated static func alignedTail(of text: String, from offset: Int) -> String {
        let ns = text as NSString
        guard offset > 0 else { return text }
        guard offset < ns.length else { return "" }
        let r = ns.rangeOfComposedCharacterSequence(at: offset)
        let from = r.location < offset ? NSMaxRange(r) : offset
        return ns.substring(from: from)
    }
}
