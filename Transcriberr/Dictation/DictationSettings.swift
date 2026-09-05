import Foundation
import Observation

/// Dictation preferences. Process-wide like the other store classes;
/// the controller reads them at the moment a session starts, so a change
/// in Settings applies to the NEXT utterance without a restart.
///
/// Declared without actor isolation for the same `_SwiftData_SwiftUI`
/// reason as every other `@Observable` store in the app.
@Observable
final class DictationSettings: @unchecked Sendable {

    /// Modifier keys that can act as the global dictation key. Modifier-only
    /// hotkeys never collide with an app's own shortcuts, and a *right-hand*
    /// modifier is rarely used on its own — the same choice Wispr Flow and
    /// Superwhisper make.
    enum Hotkey: String, CaseIterable, Sendable {
        case rightOption, rightCommand, rightControl, rightShift, fn, off

        var label: String {
            switch self {
            case .rightOption:  return "Right ⌥ Option"
            case .rightCommand: return "Right ⌘ Command"
            case .rightControl: return "Right ⌃ Control"
            case .rightShift:   return "Right ⇧ Shift"
            case .fn:           return "fn / 🌐 Globe"
            case .off:          return "Off"
            }
        }

        /// Short glyph for badges and the HUD.
        var glyph: String {
            switch self {
            case .rightOption:  return "R⌥"
            case .rightCommand: return "R⌘"
            case .rightControl: return "R⌃"
            case .rightShift:   return "R⇧"
            case .fn:           return "FN"
            case .off:          return "—"
            }
        }

        /// Hardware key code delivered in `flagsChanged` events.
        var keyCode: UInt16? {
            switch self {
            case .rightOption:  return 61
            case .rightCommand: return 54
            case .rightControl: return 62
            case .rightShift:   return 60
            case .fn:           return 63
            case .off:          return nil
            }
        }
    }

    enum Mode: String, CaseIterable, Sendable {
        /// Press and hold the key; release to transcribe and insert.
        case hold
        /// Tap to start, tap again to stop. Text is flushed at every pause,
        /// so long hands-free dictation appears paragraph by paragraph.
        case toggle

        var label: String {
            switch self {
            case .hold:   return "Hold to talk"
            case .toggle: return "Tap to start / stop"
            }
        }
    }

    enum Spacing: String, CaseIterable, Sendable {
        /// "Hello world. " — consecutive dictations chain naturally.
        case trailingSpace
        /// " Hello world." — for inserting into the middle of existing text.
        case leadingSpace
        case none

        var label: String {
            switch self {
            case .trailingSpace: return "Add a space after"
            case .leadingSpace:  return "Add a space before"
            case .none:          return "No extra spacing"
            }
        }
    }

    static let defaultPolishPrompt = """
    You are a dictation editor. You receive ONE short passage of speech-to-text \
    output. Return the same passage as clean written text: fix punctuation, \
    casing and sentence boundaries; remove hesitation fillers and false \
    starts; keep the speaker's wording, language, meaning and length. Never \
    answer, summarize, translate, or add anything. Output only the text.
    """

    private let defaults = UserDefaults.standard
    private enum Key {
        static let hotkey            = "dictation.hotkey"
        static let mode              = "dictation.mode"
        static let engine            = "dictation.engine"
        static let languages         = "dictation.languages"
        static let polish            = "dictation.polish"
        static let polishPrompt      = "dictation.polishPrompt"
        static let spokenCommands    = "dictation.spokenCommands"
        static let destutter         = "dictation.destutter"
        static let applyVocabulary   = "dictation.applyVocabulary"
        static let spacing           = "dictation.spacing"
        static let restoreClipboard  = "dictation.restoreClipboard"
        static let keepHistory       = "dictation.keepHistory"
        static let showMenuBar       = "dictation.showMenuBar"
        static let showHUD           = "dictation.showHUD"
        static let pauseFlushSeconds = "dictation.pauseFlushSeconds"
        static let playSounds        = "dictation.playSounds"
    }

    var hotkey: Hotkey { didSet { defaults.set(hotkey.rawValue, forKey: Key.hotkey) } }
    var mode: Mode { didSet { defaults.set(mode.rawValue, forKey: Key.mode) } }
    /// Speech engine for dictation. Anything `supportsLive` — batch decode of
    /// one utterance is even cheaper than a live chunk.
    var engine: BackendFactory.Kind { didSet { defaults.set(engine.rawValue, forKey: Key.engine) } }
    /// Empty = auto-detect.
    var languages: Set<String> { didSet { defaults.set(Array(languages), forKey: Key.languages) } }
    /// Run the utterance through the text engine (Gemma) before inserting.
    /// Off by default: it costs seconds and can rewrite.
    var polish: Bool { didSet { defaults.set(polish, forKey: Key.polish) } }
    var polishPrompt: String { didSet { defaults.set(polishPrompt, forKey: Key.polishPrompt) } }
    /// "new paragraph", "comma", "question mark" … become punctuation.
    var spokenCommands: Bool { didSet { defaults.set(spokenCommands, forKey: Key.spokenCommands) } }
    /// Deterministic filler/stutter collapse (same pass presets use).
    var destutter: Bool { didSet { defaults.set(destutter, forKey: Key.destutter) } }
    /// Canonical spellings from Settings → Style & Vocabulary.
    var applyVocabulary: Bool { didSet { defaults.set(applyVocabulary, forKey: Key.applyVocabulary) } }
    var spacing: Spacing { didSet { defaults.set(spacing.rawValue, forKey: Key.spacing) } }
    /// Put whatever was on the clipboard back after the paste lands.
    var restoreClipboard: Bool { didSet { defaults.set(restoreClipboard, forKey: Key.restoreClipboard) } }
    /// Save every dictation as a Recording in the "Dictation" folder.
    var keepHistory: Bool { didSet { defaults.set(keepHistory, forKey: Key.keepHistory) } }
    var showMenuBar: Bool { didSet { defaults.set(showMenuBar, forKey: Key.showMenuBar) } }
    var showHUD: Bool { didSet { defaults.set(showHUD, forKey: Key.showHUD) } }
    /// Toggle mode: silence (seconds) after speech that flushes a passage.
    var pauseFlushSeconds: Double { didSet { defaults.set(pauseFlushSeconds, forKey: Key.pauseFlushSeconds) } }
    var playSounds: Bool { didSet { defaults.set(playSounds, forKey: Key.playSounds) } }

    init() {
        hotkey = Hotkey(rawValue: defaults.string(forKey: Key.hotkey) ?? "") ?? .rightOption
        mode = Mode(rawValue: defaults.string(forKey: Key.mode) ?? "") ?? .hold
        engine = BackendFactory.Kind(rawValue: defaults.string(forKey: Key.engine) ?? "") ?? .parakeet
        languages = Set((defaults.array(forKey: Key.languages) as? [String]) ?? ["English"])
        polish = defaults.bool(forKey: Key.polish)
        let storedPrompt = defaults.string(forKey: Key.polishPrompt) ?? ""
        polishPrompt = storedPrompt.isEmpty ? Self.defaultPolishPrompt : storedPrompt
        spokenCommands = (defaults.object(forKey: Key.spokenCommands) as? Bool) ?? true
        destutter = (defaults.object(forKey: Key.destutter) as? Bool) ?? true
        applyVocabulary = (defaults.object(forKey: Key.applyVocabulary) as? Bool) ?? true
        spacing = Spacing(rawValue: defaults.string(forKey: Key.spacing) ?? "") ?? .trailingSpace
        restoreClipboard = (defaults.object(forKey: Key.restoreClipboard) as? Bool) ?? true
        keepHistory = defaults.bool(forKey: Key.keepHistory)
        showMenuBar = (defaults.object(forKey: Key.showMenuBar) as? Bool) ?? true
        showHUD = (defaults.object(forKey: Key.showHUD) as? Bool) ?? true
        let storedPause = defaults.double(forKey: Key.pauseFlushSeconds)
        pauseFlushSeconds = storedPause > 0 ? min(4, max(0.8, storedPause)) : 1.5
        playSounds = (defaults.object(forKey: Key.playSounds) as? Bool) ?? true

        // Sanitize: the stored engine must be able to transcribe a single
        // utterance quickly (rules out the dual-engine merge and Gemma audio).
        if !engine.supportsLive { engine = .parakeet }
    }
}
