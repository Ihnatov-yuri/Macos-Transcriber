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
        case .openAI:    return OpenAIBackend()
        case .anthropic: return AnthropicBackend()
        case .gemini:    return GoogleGeminiBackend()
        }
    }

    func releaseLocalBackends() async {
        await sharedEnsemble?.release()
        sharedEnsemble = nil
        await sharedParakeet?.release()
        sharedParakeet = nil
        await sharedParakeetV2?.release()
        sharedParakeetV2 = nil
        await sharedWhisper?.release()
        sharedWhisper = nil
        await sharedLiteRT?.release()
        sharedLiteRT = nil
    }
}
