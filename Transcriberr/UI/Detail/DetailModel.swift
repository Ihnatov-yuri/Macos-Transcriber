import Foundation
import Observation

/// View-model glue for `DetailView`. Owns the run-options state and forwards
/// to `TranscriptionJobManager`. Mirror of `RecordingDetailViewModel.kt`.
@Observable
@MainActor
final class DetailModel {
    let container: AppContainer
    let recording: Recording

    var languages: Set<String> { didSet { persistRunSettings() } }
    var translateToEnglish: Bool { didSet { persistRunSettings() } }
    var diarize: Bool { didSet { persistRunSettings() } }
    var hybridDiarize: Bool { didSet { persistRunSettings() } }
    var backend: BackendFactory.Kind { didSet { persistRunSettings() } }
    var expectedSpeakers: Int = 0 { didSet { persistRunSettings() } }

    var lastError: String?

    init(container: AppContainer, recording: Recording) {
        self.container = container
        self.recording = recording
        // Seed from the RECORDING's own stored run settings; only fall back
        // to app-level defaults when this recording was never configured.
        self.languages = recording.runLanguages.map { Set($0.split(separator: ",").map(String.init)) }
            ?? container.uiPrefs.lastLanguages
        self.translateToEnglish = recording.translateToEnglish
        self.diarize = recording.runDiarize
            ?? recording.segments.contains { $0.speaker != nil }
        self.hybridDiarize = recording.runHybridDiarize ?? false
        self.backend = recording.runBackend.flatMap(BackendFactory.Kind.init(rawValue:))
            .flatMap { $0.supportsAudio ? $0 : nil }
            ?? container.uiPrefs.defaultBackend
        self.expectedSpeakers = recording.runExpectedSpeakers ?? 0
    }

    /// Write the panel's state back onto the recording so it survives
    /// closing/reopening and is independent of every other recording.
    private func persistRunSettings() {
        recording.runBackend = backend.rawValue
        recording.runLanguages = languages.sorted().joined(separator: ",")
        recording.runDiarize = diarize
        recording.runHybridDiarize = hybridDiarize
        recording.runExpectedSpeakers = expectedSpeakers
        recording.translateToEnglish = translateToEnglish
        try? container.repository.save(recording)
    }

    var status: TranscriptionJobManager.Status? {
        container.jobManager.statuses[recording.id]
    }

    var isRunning: Bool {
        guard let s = status else { return false }
        return !s.failed && s.fraction < 1.0
    }

    func run() {
        lastError = nil
        container.uiPrefs.lastLanguages = languages

        // Local models self-resolve (Parakeet/Whisper auto-download; LiteRT
        // scans its durable cache) — the only gate worth surfacing early is a
        // missing LiteRT bundle, which needs an explicit download.
        let litertCached = ModelCatalog.entries.contains {
            $0.backend == .gemmaLiteRT
                && ModelCatalog.cachedRepoDirectory(huggingFaceID: $0.huggingFaceID) != nil
        }
        let needsLitert = backend == .gemmaLiteRT
            || (backend == .ensemble
                && (container.uiPrefs.ensembleEngineA == .gemmaLiteRT
                    || container.uiPrefs.ensembleEngineB == .gemmaLiteRT))
        if needsLitert && !litertCached {
            lastError = "LITERT GEMMA MODEL NOT DOWNLOADED · SETTINGS → MODELS"
            return
        }
        if backend == .ensemble,
           container.uiPrefs.ensembleEngineA == container.uiPrefs.ensembleEngineB {
            lastError = "SUPER MERGE NEEDS TWO DIFFERENT ENGINES · PICK MERGE A ≠ MERGE B"
            return
        }
        // Parakeet downloads its own models on first run — no gate needed.
        if !backend.isLocal && !container.apiKeys.isSet(apiProvider(for: backend)) {
            lastError = "\(backend.displayName.uppercased()) API KEY NOT SET · OPEN SETTINGS → API KEYS"
            return
        }

        let params = TranscriptionRunner.Params(
            file: URL(fileURLWithPath: recording.audioPath),
            backend: backend,
            modelDirectory: nil,
            languages: languages,
            translateTo: translateToEnglish ? "English" : nil,
            diarize: diarize,
            hybridDiarize: hybridDiarize,
            expectedSpeakers: expectedSpeakers
        )
        container.jobManager.enqueue(recording, params: params)
    }

    private func apiProvider(for kind: BackendFactory.Kind) -> APIKeyStore.Provider {
        switch kind {
        case .openAI:    return .openAI
        case .anthropic: return .anthropic
        case .gemini:    return .gemini
        case .parakeet, .parakeetV2, .whisper, .gemmaLiteRT, .ensemble:
            return .openAI   // unused; local backends gated above
        }
    }

    func cancel() {
        container.jobManager.cancel(recording.id)
    }
}
