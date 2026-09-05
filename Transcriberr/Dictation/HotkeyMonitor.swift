import AppKit
import ApplicationServices

/// System-wide modifier-key monitor for the dictation hotkey.
///
/// Uses `NSEvent` global + local monitors on `flagsChanged`, which macOS
/// only delivers to processes trusted for Accessibility. The monitor is
/// passive: events are never swallowed, so the modifier keeps working as a
/// modifier everywhere. A `keyDown` while the key is held tells the caller
/// the user meant a shortcut (⌥-e, ⌘-c…), not dictation.
@MainActor
final class HotkeyMonitor {
    enum Event {
        case pressed
        case released
        case otherKeyDown
    }

    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var keyCode: UInt16?
    private var isDown = false
    private let handler: (Event) -> Void

    init(handler: @escaping (Event) -> Void) {
        self.handler = handler
    }

    /// Accessibility trust. `prompt: true` shows the system dialog that
    /// deep-links to Privacy & Security → Accessibility.
    nonisolated static func isTrusted(prompt: Bool = false) -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        return AXIsProcessTrustedWithOptions([key: prompt] as CFDictionary)
    }

    var isInstalled: Bool { globalMonitor != nil }

    /// (Re)install for the given key. Returns false when the process isn't
    /// trusted (monitors would silently receive nothing).
    @discardableResult
    func install(keyCode: UInt16) -> Bool {
        uninstall()
        guard Self.isTrusted() else { return false }
        self.keyCode = keyCode
        let mask: NSEvent.EventTypeMask = [.flagsChanged, .keyDown]
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
            self?.handle(event)
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            self?.handle(event)
            return event
        }
        AppLog.info("dictation", "hotkey monitor installed (keyCode \(keyCode))")
        return globalMonitor != nil
    }

    func uninstall() {
        if let g = globalMonitor { NSEvent.removeMonitor(g) }
        if let l = localMonitor { NSEvent.removeMonitor(l) }
        globalMonitor = nil
        localMonitor = nil
        isDown = false
    }

    private func handle(_ event: NSEvent) {
        guard let keyCode else { return }
        switch event.type {
        case .flagsChanged:
            guard event.keyCode == keyCode else { return }
            let down = Self.modifierIsDown(event, keyCode: keyCode)
            guard down != isDown else { return }
            isDown = down
            handler(down ? .pressed : .released)
        case .keyDown:
            if isDown { handler(.otherKeyDown) }
        default:
            break
        }
    }

    /// `flagsChanged` carries the new modifier state; the key that changed is
    /// `keyCode`. Left/right variants share a flag, so a press of the RIGHT
    /// key while the LEFT is already held reads as "down" (flag set) and its
    /// release as "still down" — the isDown edge filter above handles that.
    nonisolated static func modifierIsDown(_ event: NSEvent, keyCode: UInt16) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        switch keyCode {
        case 61, 58: return flags.contains(.option)
        case 54, 55: return flags.contains(.command)
        case 62, 59: return flags.contains(.control)
        case 60, 56: return flags.contains(.shift)
        case 63:     return flags.contains(.function)
        default:     return false
        }
    }
}
