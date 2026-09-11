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
            // And resync: the release almost certainly happened while we were
            // deaf. Without this, `isDown` stayed true forever, so the next
            // press was filtered out as "already down" and the hotkey looked
            // dead for a whole press/release cycle — with any hold session in
            // flight left hanging until the watchdog.
            resyncModifierState()
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

    /// Recompute the hotkey's real state from the system and emit whatever
    /// edge we missed.
    func resyncModifierState() {
        guard let keyCode else { return }
        let flags = CGEventSource.flagsState(.combinedSessionState)
        let down = Self.modifierIsDown(cgFlags: flags, keyCode: keyCode)
        guard down != isDown else { return }
        trace("resync → \(down ? "down" : "up")")
        edge(down: down)
    }

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
    /// `keyCode`.
    ///
    /// The device-DEPENDENT bits are what makes a left/right pair separable.
    /// Testing only the shared flag (`.maskCommand` and friends) meant the
    /// twin masked the release: with the hotkey on Right ⌘, holding R⌘ to
    /// talk and then pressing L⌘ before letting R⌘ go left the shared flag
    /// set, so the release read as "still down", the edge filter swallowed
    /// it, and no `.released` ever arrived — hold mode then ran to the
    /// 180-second watchdog and inserted three minutes of speech, with
    /// `isDown` stuck true so the next press was swallowed too.
    ///
    /// `(thisKey, itsTwin, sharedFlag)` bit masks, in the raw representation
    /// shared by `NSEvent.modifierFlags` and `CGEventFlags`.
    private nonisolated static func bits(for keyCode: UInt16) -> (own: UInt64, twin: UInt64, shared: UInt64)? {
        switch keyCode {
        case 55: return (0x08, 0x10, UInt64(NSEvent.ModifierFlags.command.rawValue))   // left ⌘
        case 54: return (0x10, 0x08, UInt64(NSEvent.ModifierFlags.command.rawValue))   // right ⌘
        case 58: return (0x20, 0x40, UInt64(NSEvent.ModifierFlags.option.rawValue))    // left ⌥
        case 61: return (0x40, 0x20, UInt64(NSEvent.ModifierFlags.option.rawValue))    // right ⌥
        case 56: return (0x02, 0x04, UInt64(NSEvent.ModifierFlags.shift.rawValue))     // left ⇧
        case 60: return (0x04, 0x02, UInt64(NSEvent.ModifierFlags.shift.rawValue))     // right ⇧
        case 59: return (0x01, 0x2000, UInt64(NSEvent.ModifierFlags.control.rawValue)) // left ⌃
        case 62: return (0x2000, 0x01, UInt64(NSEvent.ModifierFlags.control.rawValue)) // right ⌃
        case 63: return (0, 0, UInt64(NSEvent.ModifierFlags.function.rawValue))        // fn — no side bits
        default: return nil
        }
    }

    nonisolated static func modifierIsDown(rawFlags: UInt64, keyCode: UInt16) -> Bool {
        guard let b = bits(for: keyCode) else { return false }
        // Not every keyboard reports the device-dependent bits (remappers and
        // some external boards report only the shared flag). Trust the side
        // bits when this keyboard is using them, otherwise fall back.
        if b.own != 0, rawFlags & (b.own | b.twin) != 0 {
            return rawFlags & b.own != 0
        }
        return rawFlags & b.shared != 0
    }

    nonisolated static func modifierIsDown(_ event: NSEvent, keyCode: UInt16) -> Bool {
        modifierIsDown(rawFlags: UInt64(event.modifierFlags.rawValue), keyCode: keyCode)
    }

    nonisolated static func modifierIsDown(cgFlags flags: CGEventFlags, keyCode: UInt16) -> Bool {
        modifierIsDown(rawFlags: flags.rawValue, keyCode: keyCode)
    }
}
