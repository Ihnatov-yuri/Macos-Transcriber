import AppKit
import ApplicationServices
import Carbon.HIToolbox

/// System-wide modifier-key monitor for the dictation hotkey.
///
/// Primary mechanism: a listen-only CGEvent tap at session level — the
/// same channel Karabiner-style tools use. It sees every app's key events
/// including our own, never swallows anything (the modifier keeps working
/// as a modifier everywhere), and reports exactly what it saw so the
/// Dictate screen can show "last key event" while the user tests.
/// Fallback when the tap can't be created: NSEvent global + local monitors.
///
/// Both need Accessibility trust (which implies Input Monitoring).
@MainActor
final class HotkeyMonitor {
    enum Event {
        case pressed
        case released
        case otherKeyDown
    }

    /// Human-readable trace of the last relevant event, for the UI.
    private(set) var lastTrace: String = ""

    private var tap: CFMachPort?
    private var tapSource: CFRunLoopSource?
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var keyCode: UInt16?
    private var isDown = false
    private var eventCount = 0
    private let handler: (Event) -> Void
    private let onTrace: (String) -> Void

    init(handler: @escaping (Event) -> Void, onTrace: @escaping (String) -> Void = { _ in }) {
        self.handler = handler
        self.onTrace = onTrace
    }

    /// Accessibility trust. `prompt: true` shows the system dialog that
    /// deep-links to Privacy & Security → Accessibility.
    nonisolated static func isTrusted(prompt: Bool = false) -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        return AXIsProcessTrustedWithOptions([key: prompt] as CFDictionary)
    }

    var isInstalled: Bool { tap != nil || globalMonitor != nil }
    var mechanism: String { tap != nil ? "event tap" : (globalMonitor != nil ? "NSEvent monitors" : "none") }

    /// (Re)install for the given key. Returns false when the process isn't
    /// trusted (neither mechanism would receive anything).
    @discardableResult
    func install(keyCode: UInt16) -> Bool {
        uninstall()
        guard Self.isTrusted() else { return false }
        self.keyCode = keyCode
        if installTap() {
            AppLog.info("dictation", "hotkey monitor installed (keyCode \(keyCode), event tap)")
            return true
        }
        let mask: NSEvent.EventTypeMask = [.flagsChanged, .keyDown]
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
            self?.handle(nsEvent: event)
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            self?.handle(nsEvent: event)
            return event
        }
        AppLog.warn("dictation", "event tap unavailable — hotkey monitor installed via NSEvent monitors (keyCode \(keyCode))")
        return globalMonitor != nil
    }

    func uninstall() {
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            if let tapSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), tapSource, .commonModes) }
            CFMachPortInvalidate(tap)
        }
        tap = nil
        tapSource = nil
        if let g = globalMonitor { NSEvent.removeMonitor(g) }
        if let l = localMonitor { NSEvent.removeMonitor(l) }
        globalMonitor = nil
        localMonitor = nil
        isDown = false
    }

    // MARK: - CGEvent tap

    private func installTap() -> Bool {
        let mask: CGEventMask = (1 << CGEventType.flagsChanged.rawValue) | (1 << CGEventType.keyDown.rawValue)
        let userInfo = Unmanaged.passUnretained(self).toOpaque()
        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: { _, type, event, userInfo in
                guard let userInfo else { return Unmanaged.passUnretained(event) }
                let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(userInfo).takeUnretainedValue()
                // Tap callbacks arrive on the run loop we registered (main).
                MainActor.assumeIsolated { monitor.handle(tapType: type, event: event) }
                return Unmanaged.passUnretained(event)
            },
            userInfo: userInfo
        ) else { return false }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        tap = port
        tapSource = source
        return true
    }

    private func handle(tapType: CGEventType, event: CGEvent) {
        switch tapType {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            // macOS disables a tap that stalls; we never stall, but re-arm.
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            AppLog.warn("dictation", "hotkey event tap was disabled by the system — re-enabled")
        case .flagsChanged:
            let code = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
            guard let keyCode, code == keyCode else { return }
            let down = Self.modifierIsDown(cgFlags: event.flags, keyCode: keyCode)
            trace("flagsChanged keyCode=\(code) \(down ? "down" : "up")")
            edge(down: down)
        case .keyDown:
            if isDown {
                trace("keyDown while held → combo")
                handler(.otherKeyDown)
            }
        default:
            break
        }
    }

    // MARK: - NSEvent fallback

    private func handle(nsEvent event: NSEvent) {
        guard let keyCode else { return }
        switch event.type {
        case .flagsChanged:
            guard event.keyCode == keyCode else { return }
            let down = Self.modifierIsDown(event, keyCode: keyCode)
            trace("flagsChanged keyCode=\(event.keyCode) \(down ? "down" : "up") (NSEvent)")
            edge(down: down)
        case .keyDown:
            if isDown {
                trace("keyDown while held → combo (NSEvent)")
                handler(.otherKeyDown)
            }
        default:
            break
        }
    }

    // MARK: - Shared

    private func edge(down: Bool) {
        guard down != isDown else { return }
        isDown = down
        handler(down ? .pressed : .released)
    }

    private func trace(_ s: String) {
        eventCount += 1
        lastTrace = s
        onTrace(s)
        // The first few events of a session go to the log so a "hotkey
        // does nothing" report can be diagnosed from the file alone.
        if eventCount <= 8 { AppLog.info("dictation", "hotkey event: \(s)") }
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

    nonisolated static func modifierIsDown(cgFlags flags: CGEventFlags, keyCode: UInt16) -> Bool {
        switch keyCode {
        case 61, 58: return flags.contains(.maskAlternate)
        case 54, 55: return flags.contains(.maskCommand)
        case 62, 59: return flags.contains(.maskControl)
        case 60, 56: return flags.contains(.maskShift)
        case 63:     return flags.contains(.maskSecondaryFn)
        default:     return false
        }
    }
}
