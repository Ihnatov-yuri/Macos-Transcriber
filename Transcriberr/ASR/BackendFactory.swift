import Darwin
import Foundation

/// Mirror of `asr/AsrFactory.kt`.
///
/// Local default: Parakeet v3 (FluidAudio / ANE) for *speech-to-text* —
/// a dedicated ASR model with real accuracy. The on-device text model
/// (`ModelCatalog`: Gemma 4 on MLX, Qwen3.5 on uzu) does all text
/// generation (summaries, cleanup, translation, titles, Super's arbiter).
/// Not `@MainActor`, for the same _SwiftData_SwiftUI crash as the other
/// store classes.
nonisolated final class BackendFactory: @unchecked Sendable {
    enum Kind: String, CaseIterable, Sendable {
        case parakeet   = "parakeet-v3"
        case parakeetV2 = "parakeet-v2"
        case parakeetUK = "parakeet-uk"
        case whisper    = "whisper-large-v3"
        /// The on-device text model picked in Settings → Models. The raw
        /// value is the old LiteRT Gemma's, so saved choices still read.
        case localText  = "gemma4-litert"
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
            case .localText:  return "On-device model (\(ModelCatalog.chosen(.general).name))"
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

        /// The label once the run is over, from the model it actually used (still pinned while the job saves its result, else the last run's).
        func finishedRunLabel(_ started: String) -> String {
            guard self == .whisper, let id = WhisperModel.inUse ?? WhisperModel.lastRunID else { return started }
            return Self.whisperLabel(WhisperModel.model(id))
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
            case .parakeet, .parakeetV2, .parakeetUK, .whisper, .localText, .ensemble: return true
            default: return false
            }
        }
        /// The Parakeet family: one FluidAudio graph, different weights.
        var isParakeet: Bool { self == .parakeet || self == .parakeetV2 || self == .parakeetUK }
        /// Engines that may TRANSCRIBE. The on-device text models are
        /// text-only.
        var supportsAudio: Bool { self != .anthropic && self != .localText }
        /// Backends that can run PostProcessor presets / title generation.
        /// Acoustic models (and the merge wrapper) can't — text work goes to the local text model.
        var supportsTextGeneration: Bool {
            switch self {
            case .parakeet, .parakeetV2, .parakeetUK, .whisper, .ensemble: return false
            default: return true
            }
        }
        /// Diarization is ALWAYS hybrid: the FluidAudio diarizer pre-pass
        /// runs for every engine (acoustic engines get labels assigned from it).
        var needsDiarizerForSpeakers: Bool { true }
        /// Live captioning cycles through these. The ensemble merge is far
        /// too slow for per-5-second live captioning.
        var supportsLive: Bool {
            supportsAudio && self != .ensemble
        }
    }

    private let prompts: PromptStore
    private let apiKeys: APIKeyStore

    /// The engine cache is read from several executors at once — the main
    /// actor (`TranscriptionRunner.runImpl`, `PostProcessor.perform`), the
    /// cooperative pool (`LiveTranscriber.start`) and the ensemble actor
    /// (`EnsembleBackend.load` resolving its sub-engines). Without the lock,
    /// two of them arriving on a cold cache would both see nil and both build
    /// and load the same CoreML models (double the ANE memory, one instance
    /// orphaned), and the concurrent writes to the class references would be
    /// undefined behaviour on top.
    private let cacheLock = NSLock()
    private var sharedParakeet: ParakeetBackend?
    private var sharedParakeetV2: ParakeetBackend?
    private var sharedParakeetUK: ParakeetBackend?
    private var sharedWhisper: WhisperBackend?
    /// Loaded text models by catalog id: Super's and the rest may differ.
    private var sharedText: [String: any LocalTextBackend] = [:]
    private var sharedEnsemble: EnsembleBackend?

    init(prompts: PromptStore, apiKeys: APIKeyStore) {
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
        case .localText:
            return textBackendLocked(ModelCatalog.selected(.general))
        case .ensemble:
            if let b = sharedEnsemble { return b }
            let b = EnsembleBackend(factory: self)
            sharedEnsemble = b
            return b
        case .openAI, .anthropic, .gemini:
            fatalError("unreachable — cloud kinds returned above")
        }
    }

    /// The text model picked for `role` (Super's arbiter, or everything
    /// else), loaded once and shared.
    func textBackend(_ role: ModelCatalog.Role) -> ASRBackend {
        cacheLock.withLock { textBackendLocked(ModelCatalog.selected(role)) }
    }

    private func textBackendLocked(_ entry: ModelEntry) -> any LocalTextBackend {
        dropUnpickedTextLocked()
        if let b = sharedText[entry.id] { return b }
        let onUse: @Sendable () -> Void = { [weak self] in self?.noteTextUse() }
        let b: any LocalTextBackend = switch entry.runtime {
        case .mlx: MLXTextBackend(entry: entry, onUse: onUse)
        case .uzu: UzuTextBackend(entry: entry, onUse: onUse)
        }
        sharedText[entry.id] = b
        return b
    }

    /// A model the user just switched away from goes now, not at the idle
    /// release: the new pick loads next to it, and 16 GB of 26B beside 7 GB
    /// of Qwen plus Whisper is more than a 32 GB Mac can spare. A call
    /// still running on it keeps it alive until it returns.
    private func dropUnpickedTextLocked() {
        let picked = Set(ModelCatalog.Role.allCases.map { ModelCatalog.selected($0).id })
        for (id, b) in sharedText where !picked.contains(id) {
            sharedText[id] = nil
            Task {
                if await !b.isBusy { await b.release() }
                Self.returnFreedMemorySoon()
            }
        }
    }

    private func takeLocalBackends() -> (EnsembleBackend?, ParakeetBackend?, ParakeetBackend?, ParakeetBackend?, WhisperBackend?, [any LocalTextBackend]) {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        let taken = (sharedEnsemble, sharedParakeet, sharedParakeetV2, sharedParakeetUK, sharedWhisper, Array(sharedText.values))
        sharedEnsemble = nil
        sharedParakeet = nil
        sharedParakeetV2 = nil
        sharedParakeetUK = nil
        sharedWhisper = nil
        sharedText = [:]
        return taken
    }

    func releaseLocalBackends() async {
        let (ens, p3, p2, uk, whisper, text) = takeLocalBackends()
        await ens?.release()
        await p3?.release()
        await p2?.release()
        await uk?.release()
        await whisper?.release()
        for b in text { await b.release() }
    }

    /// Drop the text models (and the ensemble that may hold one) while
    /// leaving the cheap ANE engines loaded: 5-16 GB of resident memory that
    /// nothing else was ever going to reclaim.
    /// Idle housekeeping: skip while a preset, auto-title or dictation polish
    /// is generating. Returns false when it skipped.
    func releaseTextIfIdle() async -> Bool {
        let text = cacheLock.withLock { Array(sharedText.values) }
        for b in text where await b.isBusy { return false }
        await releaseText()
        return true
    }

    // MARK: - Idle release
    //
    // The transcription queue is not the only thing that loads the text
    // model. Person briefs, the speech coach, presets, dictation polish and
    // the launch title catch-up all load it outside that queue; without an
    // idle release the engine stays resident until the next transcription,
    // in swap for hours.

    /// Quiet spell after the last generation before the engine goes.
    static let textIdleSeconds: UInt64 = 180
    /// Set by AppContainer: false while a transcription job is queued or
    /// running — a Super run calls the arbiter minutes apart and must not
    /// reload it between arbitrations.
    var textReleaseAllowed: (@MainActor () -> Bool)?
    private var textIdleTask: Task<Void, Never>?

    /// Every generation restarts the countdown.
    func noteTextUse() {
        cacheLock.withLock {
            textIdleTask?.cancel()
            textIdleTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: Self.textIdleSeconds * 1_000_000_000)
                guard !Task.isCancelled, let self else { return }
                await self.releaseTextIfQuiet()
            }
        }
    }

    /// The idle release, also run on a memory-pressure warning. A busy
    /// engine reschedules itself: its generation ends with noteTextUse.
    func releaseTextIfQuiet() async {
        if let allowed = textReleaseAllowed, await !allowed() {
            noteTextUse()
            return
        }
        _ = await releaseTextIfIdle()
    }

    /// Hands pages the allocator kept after a big free back to the system.
    /// Without it the dropped engine's buffers stay in the footprint (and
    /// in swap) as empty malloc regions (measured: 4.3 GB of them).
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

    func releaseText() async {
        let (ens, text) = cacheLock.withLock {
            defer { sharedEnsemble = nil; sharedText = [:] }
            return (sharedEnsemble, Array(sharedText.values))
        }
        guard !text.isEmpty || ens != nil else { return }
        await ens?.release()
        for b in text { await b.release() }
        Self.returnFreedMemory()
        AppLog.info("factory", "released the text model")
    }
}
