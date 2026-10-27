import Darwin
import Foundation

/// Mirror of `asr/AsrFactory.kt`.
///
/// Local default: Parakeet v3 (FluidAudio / ANE) for *speech-to-text* —
/// a dedicated ASR model with real accuracy. Gemma 4 (MLX) stays for all
/// text generation (summaries, cleanup, translation, titles) and remains
/// selectable as an experimental audio backend.
/// `@MainActor` dropped — same _SwiftData_SwiftUI crash story as the
/// other store classes.
nonisolated final class BackendFactory: @unchecked Sendable {
    enum Kind: String, CaseIterable, Sendable {
        case parakeet   = "parakeet-v3"
        case parakeetV2 = "parakeet-v2"
        case parakeetUK = "parakeet-uk"
        case whisper    = "whisper-large-v3"
        case gemmaLiteRT = "gemma4-litert"
        case ensemble   = "ensemble"
        case openAI     = "openai"
        case anthropic  = "anthropic"
        case gemini     = "gemini"

        var displayName: String {
            switch self {
            case .parakeet:   return "\(Self.parakeetV3Name) (local, ANE)"
            case .parakeetV2: return "Parakeet v2 (English, ANE)"
            case .parakeetUK: return "\(ParakeetUKModel.displayName) (Ukrainian, ANE)"
            case .whisper:
                // A run pins its model by language; outside one there are two.
                return WhisperModel.inUse.map { Self.whisperLabel(WhisperModel.model($0)) }
                    ?? "Whisper (local, CoreML)"
            case .gemmaLiteRT: return "Gemma 4 (Google LiteRT — as on Android)"
            case .ensemble:   return "Super · dual-engine merge (local)"
            case .openAI:     return "OpenAI (GPT-4o)"
            case .anthropic:  return "Anthropic Claude"
            case .gemini:     return "Google Gemini"
            }
        }

        /// The name a run in these languages is saved under (Detail →
        /// VERSIONS). Taken when the job starts: the run's Whisper pin is
        /// released before the job stores its version.
        func runLabel(languages: Set<String>) -> String {
            self == .whisper ? Self.whisperLabel(WhisperModel.forRun(languages)) : displayName
        }

        private static func whisperLabel(_ m: WhisperModel) -> String { "Whisper \(m.name) (local, CoreML)" }

        /// Name of the Parakeet v3 weights in FluidAudio's model folder. A fine-tune installed in place of the
        /// stock files (the folder name is fixed by FluidAudio) names itself with `display_name` in the
        /// folder's config.json; stock has none and stays "Parakeet v3". Read once per launch.
        static let parakeetV3Name: String = {
            ParakeetUKModel.migrateInPlaceInstall()
            let config = ParakeetUKModel.stockDirectory.appendingPathComponent("config.json")
            guard let data = try? Data(contentsOf: config),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let name = json["display_name"] as? String, !name.isEmpty
            else { return "Parakeet v3" }
            return name
        }()

        var isLocal: Bool {
            switch self {
            case .parakeet, .parakeetV2, .parakeetUK, .whisper, .gemmaLiteRT, .ensemble: return true
            default: return false
            }
        }
        /// The Parakeet family: one FluidAudio graph, different weights.
        var isParakeet: Bool { self == .parakeet || self == .parakeetV2 || self == .parakeetUK }
        /// Engines that may TRANSCRIBE. Gemma 4 audio is selectable but
        /// EXPERIMENTAL — its 8-bit MLX build was shown to hallucinate; it is
        /// never the default and its display name says so. Gemma's primary
        /// roles stay text-only: presets, titles, merge arbitration.
        var supportsAudio: Bool { self != .anthropic }
        /// Backends that can run PostProcessor presets / title generation.
        /// Acoustic models (and the merge wrapper) can't — text work goes to Gemma.
        var supportsTextGeneration: Bool {
            switch self {
            case .parakeet, .parakeetV2, .parakeetUK, .whisper, .ensemble: return false
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
    private var sharedParakeetUK: ParakeetBackend?
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
        case .parakeetUK:
            if let b = sharedParakeetUK { return b }
            let b = ParakeetBackend(ukFineTune: true)
            sharedParakeetUK = b
            return b
        case .whisper:
            if let b = sharedWhisper { return b }
            let b = WhisperBackend()
            sharedWhisper = b
            return b
        case .gemmaLiteRT:
            if let b = sharedLiteRT { return b }
            let b = GemmaLiteRTBackend(onUse: { [weak self] in self?.noteLiteRTUse() })
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

    private func takeLocalBackends() -> (EnsembleBackend?, ParakeetBackend?, ParakeetBackend?, ParakeetBackend?, WhisperBackend?, GemmaLiteRTBackend?) {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        let taken = (sharedEnsemble, sharedParakeet, sharedParakeetV2, sharedParakeetUK, sharedWhisper, sharedLiteRT)
        sharedEnsemble = nil
        sharedParakeet = nil
        sharedParakeetV2 = nil
        sharedParakeetUK = nil
        sharedWhisper = nil
        sharedLiteRT = nil
        return taken
    }

    func releaseLocalBackends() async {
        let (ens, p3, p2, uk, whisper, litert) = takeLocalBackends()
        await ens?.release()
        await p3?.release()
        await p2?.release()
        await uk?.release()
        await whisper?.release()
        await litert?.release()
    }

    /// Drop the LiteRT engine (and the ensemble that may hold a reference to
    /// it) while leaving the cheap ANE engines loaded.
    ///
    /// Two reasons this has to happen when the queue goes idle. The bundle is
    /// 3-5 GB of resident memory that nothing else was ever going to reclaim
    /// — `releaseLocalBackends` has no call site at all. And LiteRT's
    /// presence latches `InferenceGate.litertActive`; since the gate became
    /// a readers-writer lock that no longer serializes the other engines
    /// against each other, but it still costs every inference call an actor
    /// hop for the rest of the session.
    /// Idle housekeeping: skip while a preset, auto-title or dictation polish
    /// is generating. Returns false when it skipped.
    func releaseLiteRTIfIdle() async -> Bool {
        let litert = cacheLock.withLock { sharedLiteRT }
        if let litert, await litert.isBusy { return false }
        await releaseLiteRT()
        return true
    }

    // MARK: - Idle release
    //
    // The transcription queue used to be the only thing that released
    // LiteRT. Person briefs, the speech coach, presets, dictation polish and
    // the launch title catch-up all load it outside that queue, and the
    // engine then stayed resident until the next transcription: 2.5 GB of
    // GPU memory plus the CPU copy's pages, in swap for hours.

    /// Quiet spell after the last generation before the engine goes.
    static let liteRTIdleSeconds: UInt64 = 180
    /// Set by AppContainer: false while a transcription job is queued or
    /// running — a Super run calls Gemma minutes apart and must not reload
    /// it between arbitrations.
    var liteRTReleaseAllowed: (@MainActor () -> Bool)?
    private var liteRTIdleTask: Task<Void, Never>?

    /// Every generation restarts the countdown.
    func noteLiteRTUse() {
        cacheLock.withLock {
            liteRTIdleTask?.cancel()
            liteRTIdleTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: Self.liteRTIdleSeconds * 1_000_000_000)
                guard !Task.isCancelled, let self else { return }
                await self.releaseLiteRTIfQuiet()
            }
        }
    }

    /// The idle release, also run on a memory-pressure warning. A busy
    /// engine reschedules itself: its generation ends with noteLiteRTUse.
    func releaseLiteRTIfQuiet() async {
        if let allowed = liteRTReleaseAllowed, await !allowed() {
            noteLiteRTUse()
            return
        }
        _ = await releaseLiteRTIfIdle()
    }

    /// Hands pages the allocator kept after a big free back to the system.
    /// Without it the dropped engine's buffers stayed in the footprint (and
    /// in swap) as empty malloc regions: 4.3 GB of them on 26 Oct.
    static func returnFreedMemory() {
        _ = malloc_zone_pressure_relief(nil, 0)
    }

    /// For an engine dropped while a caller's local still holds it: by a
    /// second later that call has returned and the buffers are free.
    static func returnFreedMemorySoon() {
        Task.detached(priority: .utility) {
            try? await Task.sleep(for: .seconds(2))
            returnFreedMemory()
        }
    }

    func releaseLiteRT() async {
        let (ens, litert) = cacheLock.withLock {
            defer { sharedEnsemble = nil; sharedLiteRT = nil }
            return (sharedEnsemble, sharedLiteRT)
        }
        guard litert != nil || ens != nil else { return }
        await ens?.release()
        await litert?.release()
        Self.returnFreedMemory()
        AppLog.info("factory", "released LiteRT engine and lifted the inference gate")
    }
}
