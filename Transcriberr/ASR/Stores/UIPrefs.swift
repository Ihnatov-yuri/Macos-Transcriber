import Foundation
import Observation

/// Mirror of `asr/UiPrefs.kt`.
/// Cross-screen UI prefs (last languages, transcript view toggles, etc.)
@Observable
final class UIPrefs: @unchecked Sendable {
    private let defaults = UserDefaults.standard
    private enum Key {
        static let languages       = "ui.lastLanguages"
        static let embedding       = "ui.preferredEmbedding"
        static let vocabLanguages  = "ui.vocabLanguages"
        static let showTimestamps  = "ui.showTimestamps"
        static let proseMode       = "ui.proseMode"
        static let defaultBackend  = "ui.defaultBackend"
        static let autoTranscribe  = "ui.autoTranscribe"
        static let liveEnabled     = "ui.liveEnabled"
        static let liveEngine      = "ui.liveEngine"
        // Shared with EnsembleBackend, which reads the same keys directly.
        static let ensembleEngineA = "ensemble.engineA"
        static let ensembleEngineB = "ensemble.engineB"
        // Read directly by PostProcessor too.
        static let textEngine      = "ui.textEngine"
        // Read by TranscriptionRunner.coalesceBySpeaker directly.
        static let turnGap         = "ui.turnCoalesceGapSeconds"
        // Read by TranscriptionRunner directly.
        static let superMaxQuality = "ui.superMaxQuality"
    }

    var lastLanguages: Set<String>     { didSet { defaults.set(Array(lastLanguages), forKey: Key.languages) } }
    var preferredEmbedding: String?    { didSet { defaults.set(preferredEmbedding, forKey: Key.embedding) } }
    var vocabLanguages: Set<String>    { didSet { defaults.set(Array(vocabLanguages), forKey: Key.vocabLanguages) } }
    var showTimestamps: Bool           { didSet { defaults.set(showTimestamps, forKey: Key.showTimestamps) } }
    var proseMode: Bool                { didSet { defaults.set(proseMode, forKey: Key.proseMode) } }
    var defaultBackend: BackendFactory.Kind { didSet { defaults.set(defaultBackend.rawValue, forKey: Key.defaultBackend) } }
    var autoTranscribe: Bool           { didSet { defaults.set(autoTranscribe, forKey: Key.autoTranscribe) } }
    var liveEnabled: Bool              { didSet { defaults.set(liveEnabled, forKey: Key.liveEnabled) } }
    var liveEngine: BackendFactory.Kind { didSet { defaults.set(liveEngine.rawValue, forKey: Key.liveEngine) } }
    /// Engine that runs POST-PROCESSING (presets, titles): any Kind with
    /// supportsTextGeneration. LiteRT Gemma generates far faster than the
    /// MLX build on this hardware.
    var textEngine: BackendFactory.Kind { didSet { defaults.set(textEngine.rawValue, forKey: Key.textEngine) } }
    /// Max silence (seconds) bridged when merging adjacent same-speaker
    /// segments into one turn. 30 = smooth readable blocks (default);
    /// 2 = Samsung-style fine turns that keep every interjection separate.
    var turnCoalesceGapSeconds: Double { didSet { defaults.set(turnCoalesceGapSeconds, forKey: Key.turnGap) } }
    /// Super merge: sequential chunks WITH preceding-transcript context for
    /// Gemma arbitration (max quality) instead of the 3-wide pipeline (speed).
    var superMaxQuality: Bool { didSet { defaults.set(superMaxQuality, forKey: Key.superMaxQuality) } }
    /// Sub-engines for the "Super" dual-ASR merge (local only).
    var ensembleEngineA: BackendFactory.Kind { didSet { defaults.set(ensembleEngineA.rawValue, forKey: Key.ensembleEngineA) } }
    var ensembleEngineB: BackendFactory.Kind { didSet { defaults.set(ensembleEngineB.rawValue, forKey: Key.ensembleEngineB) } }

    init() {
        lastLanguages = Set((defaults.array(forKey: Key.languages) as? [String]) ?? [])
        preferredEmbedding = defaults.string(forKey: Key.embedding)
        vocabLanguages = Set((defaults.array(forKey: Key.vocabLanguages) as? [String]) ?? [])
        showTimestamps = (defaults.object(forKey: Key.showTimestamps) as? Bool) ?? true
        proseMode = defaults.bool(forKey: Key.proseMode)
        defaultBackend = BackendFactory.Kind(rawValue: defaults.string(forKey: Key.defaultBackend) ?? "") ?? .parakeet
        autoTranscribe = (defaults.object(forKey: Key.autoTranscribe) as? Bool) ?? true
        liveEnabled = (defaults.object(forKey: Key.liveEnabled) as? Bool) ?? true
        // Default speech-to-text engine: Parakeet v3 (dedicated ASR on ANE).
        // Gemma 4 stays as the text-generation engine and remains selectable
        // for audio experimentally.
        liveEngine = BackendFactory.Kind(rawValue: defaults.string(forKey: Key.liveEngine) ?? "") ?? .parakeet

        // First-run default: prefer the LiteRT text engine when its bundle is
        // on disk — it generates far faster than MLX Gemma. An explicit user
        // choice (stored key) always wins.
        textEngine = defaults.string(forKey: Key.textEngine)
            .flatMap(BackendFactory.Kind.init(rawValue:)) ?? .gemmaLiteRT
        superMaxQuality = defaults.bool(forKey: Key.superMaxQuality)
        let storedGap = defaults.double(forKey: Key.turnGap)
        turnCoalesceGapSeconds = storedGap > 0 ? storedGap : 30
        ensembleEngineA = BackendFactory.Kind(rawValue: defaults.string(forKey: Key.ensembleEngineA) ?? "") ?? .parakeet
        ensembleEngineB = BackendFactory.Kind(rawValue: defaults.string(forKey: Key.ensembleEngineB) ?? "") ?? .parakeetV2

        // Sanitize on EVERY launch: stored selections must be able to do
        // their job (audio-capable for transcription/live). Explicit engine
        // choices — including experimental Gemma audio — are respected.
        if !defaultBackend.supportsAudio { defaultBackend = .parakeet }
        if !textEngine.supportsTextGeneration { textEngine = .gemmaLiteRT }
        if !liveEngine.supportsLive { liveEngine = .parakeet }
        let validMerge: (BackendFactory.Kind) -> Bool = {
            $0.isLocal && $0.supportsAudio && $0 != .ensemble
        }
        if !validMerge(ensembleEngineA) { ensembleEngineA = .parakeet }
        if !validMerge(ensembleEngineB) || ensembleEngineB == ensembleEngineA {
            ensembleEngineB = ensembleEngineA == .parakeetV2 ? .parakeet : .parakeetV2
        }
    }
}
