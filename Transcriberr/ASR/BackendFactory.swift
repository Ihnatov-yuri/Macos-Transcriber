import Foundation

/// Mirror of `asr/AsrFactory.kt`.
///
/// Local default: Parakeet v3 (FluidAudio / ANE) for *speech-to-text* —
/// a dedicated ASR model with real accuracy. Gemma 4 (MLX) stays for all
/// text generation (summaries, cleanup, translation, titles) and remains
/// selectable as an experimental audio backend.
/// `@MainActor` dropped — same _SwiftData_SwiftUI crash story as the
/// other store classes.
final class BackendFactory: @unchecked Sendable {
    enum Kind: String, CaseIterable, Sendable {
        case parakeet   = "parakeet-v3"
        case parakeetV2 = "parakeet-v2"
        case whisper    = "whisper-large-v3"
        case gemmaLiteRT = "gemma4-litert"
        case ensemble   = "ensemble"
        case openAI     = "openai"
        case anthropic  = "anthropic"
        case gemini     = "gemini"

        var displayName: String {
            switch self {
            case .parakeet:   return "Parakeet v3 (local, ANE)"
            case .parakeetV2: return "Parakeet v2 (English, ANE)"
            case .whisper:    return "Whisper large-v3 (local, CoreML)"
            case .gemmaLiteRT: return "Gemma 4 (Google LiteRT — as on Android)"
            case .ensemble:   return "Super · dual-engine merge (local)"
            case .openAI:     return "OpenAI (GPT-4o)"
            case .anthropic:  return "Anthropic Claude"
            case .gemini:     return "Google Gemini"
            }
        }

        var isLocal: Bool {
            switch self {
            case .parakeet, .parakeetV2, .whisper, .gemmaLiteRT, .ensemble: return true
            default: return false
            }
        }
        /// Engines that may TRANSCRIBE. Gemma 4 audio is selectable but
        /// EXPERIMENTAL — its 8-bit MLX build was shown to hallucinate; it is
        /// never the default and its display name says so. Gemma's primary
        /// roles stay text-only: presets, titles, merge arbitration.
        var supportsAudio: Bool { self != .anthropic }
        /// Backends that can run PostProcessor presets / title generation.
        /// Acoustic models (and the merge wrapper) can't — text work goes to Gemma.
        var supportsTextGeneration: Bool {
            switch self {
            case .parakeet, .parakeetV2, .whisper, .ensemble: return false
            default: return true
            }
        }
        /// Diarization is ALWAYS hybrid now: the FluidAudio diarizer pre-pass
        /// runs for every engine (LiteRT Gemma consumes its regions as speaker
        /// hints; acoustic engines get labels assigned from them).
        var needsDiarizerForSpeakers: Bool { true }
        /// Live captioning cycles through these. The ensemble merge and
        /// Gemma audio (20–80 s per chunk) are far too slow for per-5-second
        /// live captioning.
        var supportsLive: Bool {
            supportsAudio && self != .ensemble && self != .gemmaLiteRT
        }
    }

    private let gemma: GemmaSettingsStore
    private let prompts: PromptStore
    private let apiKeys: APIKeyStore

    /// The engine cache is read from several executors at once — the main
    /// actor (`TranscriptionRunner.runImpl`, `PostProcessor.perform`), the
    /// cooperative pool (`LiveTranscriber.start`) and the ensemble actor
    /// (`EnsembleBackend.load` resolving its sub-engines). Two of them
    /// arriving on a cold cache both saw nil and both built and loaded the
    /// same CoreML models — double the ANE memory, one instance orphaned —
    /// and the concurrent writes to the class references were undefined
    /// behaviour on top.
    private let cacheLock = NSLock()
    private var sharedParakeet: ParakeetBackend?
    private var sharedParakeetV2: ParakeetBackend?
    private var sharedWhisper: WhisperBackend?
    private var sharedLiteRT: GemmaLiteRTBackend?
    private var sharedEnsemble: EnsembleBackend?

    init(gemma: GemmaSettingsStore, prompts: PromptStore, apiKeys: APIKeyStore) {
        self.gemma = gemma
        self.prompts = prompts
        self.apiKeys = apiKeys
    }

    func backend(for kind: Kind) -> ASRBackend {
        // Cloud backends are stateless per call — no cache, no lock.
        switch kind {
        case .openAI:    return OpenAIBackend()
        case .anthropic: return AnthropicBackend()
        case .gemini:    return GoogleGeminiBackend()
        default: break
        }
        cacheLock.lock()
        defer { cacheLock.unlock() }
        switch kind {
        case .parakeet:
            if let b = sharedParakeet { return b }
            let b = ParakeetBackend(version: .v3)
            sharedParakeet = b
            return b
        case .parakeetV2:
            if let b = sharedParakeetV2 { return b }
            let b = ParakeetBackend(version: .v2)
            sharedParakeetV2 = b
            return b
        case .whisper:
            if let b = sharedWhisper { return b }
            let b = WhisperBackend()
            sharedWhisper = b
            return b
        case .gemmaLiteRT:
            if let b = sharedLiteRT { return b }
            let b = GemmaLiteRTBackend()
            sharedLiteRT = b
            return b
        case .ensemble:
            if let b = sharedEnsemble { return b }
            let b = EnsembleBackend(factory: self)
            sharedEnsemble = b
            return b
        case .openAI, .anthropic, .gemini:
            fatalError("unreachable — cloud kinds returned above")
        }
    }

    private func takeLocalBackends() -> (EnsembleBackend?, ParakeetBackend?, ParakeetBackend?, WhisperBackend?, GemmaLiteRTBackend?) {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        let taken = (sharedEnsemble, sharedParakeet, sharedParakeetV2, sharedWhisper, sharedLiteRT)
        sharedEnsemble = nil
        sharedParakeet = nil
        sharedParakeetV2 = nil
        sharedWhisper = nil
        sharedLiteRT = nil
        return taken
    }

    func releaseLocalBackends() async {
        let (ens, p3, p2, whisper, litert) = takeLocalBackends()
        await ens?.release()
        await p3?.release()
        await p2?.release()
        await whisper?.release()
        await litert?.release()
    }

    /// Drop the LiteRT engine (and the ensemble that may hold a reference to
    /// it) while leaving the cheap ANE engines loaded.
    ///
    /// Two reasons this has to happen when the queue goes idle. The bundle is
    /// 3-5 GB of resident memory that nothing else was ever going to reclaim
    /// — `releaseLocalBackends` has no call site at all. And LiteRT's
    /// presence latches `InferenceGate.litertActive`, which serializes EVERY
    /// engine's inference process-wide; leaving it latched turned the
    /// documented three-chunks-in-flight pipeline into a single file for the
    /// rest of the session, for Parakeet runs and live captions that never
    /// touched Gemma at all.
    func releaseLiteRT() async {
        cacheLock.lock()
        let ens = sharedEnsemble
        let litert = sharedLiteRT
        sharedEnsemble = nil
        sharedLiteRT = nil
        cacheLock.unlock()
        guard litert != nil || ens != nil else { return }
        await ens?.release()
        await litert?.release()
        AppLog.info("factory", "released LiteRT engine and lifted the inference gate")
    }
}
