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
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success,
              let focusedRef, CFGetTypeID(focusedRef) == AXUIElementGetTypeID()
        else { return nil }
        let element = focusedRef as! AXUIElement

        var rangeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeRef) == .success,
              let rangeRef, CFGetTypeID(rangeRef) == AXValueGetTypeID()
        else { return nil }
        var selection = CFRange()
        guard AXValueGetValue(rangeRef as! AXValue, .cfRange, &selection) else { return nil }
        guard selection.location >= 0 else { return nil }

        let start = max(0, selection.location - maxChars)
        var window = CFRange(location: start, length: selection.location - start)
        guard window.length > 0 else { return "" }   // caret at the very start

        // Parameterized string-for-range avoids copying a whole document.
        if let param = AXValueCreate(.cfRange, &window) {
            var textRef: CFTypeRef?
            if AXUIElementCopyParameterizedAttributeValue(
                element, kAXStringForRangeParameterizedAttribute as CFString, param, &textRef
            ) == .success, let text = textRef as? String {
                return text
            }
        }
        // Fallback for elements that only expose the whole value.
        var valueRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &valueRef) == .success,
              let value = valueRef as? String
        else { return nil }
        let utf16 = Array(value.utf16)
        guard selection.location <= utf16.count else { return nil }
        return String(decoding: utf16[start ..< selection.location], as: UTF16.self)
    }
}
