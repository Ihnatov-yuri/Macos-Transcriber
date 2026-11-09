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
    var speakersExact: Bool = false { didSet { persistRunSettings() } }

    var lastError: String?

    /// What this meeting's transcript and playback take from its mic.
    private(set) var micLog: MicMuteLog
    private(set) var isApplyingMic = false

    var hasMicTrack: Bool {
        AudioCompressor.sidecarURL(for: URL(fileURLWithPath: recording.audioPath), kind: "mic") != nil
    }
    var hasMuteLog: Bool { !micLog.muted.isEmpty }
    var hasVoicePrint: Bool { VoiceprintStore.load() != nil }

    /// Rebuilds the playback mix for the new choice and transcribes again.
    /// The mic track is untouched and the old transcript stays a version,
    /// so any choice can be taken back, on any meeting with a mic track.
    func setMicMode(_ mode: MicMode) {
        guard mode != micLog.effectiveMode, !isRunning, !isApplyingMic else { return }
        isApplyingMic = true
        let main = URL(fileURLWithPath: recording.audioPath)
        micLog.mode = mode
        MicMute.setMode(mode, forMain: main)
        AppLog.info("mute", "mic mode set to \(mode.rawValue) for \(main.lastPathComponent)")
        let tracker = container.audioPostProcessTracker
        let id = recording.id
        Task { @MainActor in
            await tracker.waitUntilSettled(id)
            await tracker.markPending(id)
            await tracker.markBusy(id)
            let rebuilt = await MeetingMixRebuilder.rebuildMix(mainURL: main) ?? main
            // A failed rebuild leaves the old .m4a: encoding it again would only lose quality.
            let final = rebuilt.pathExtension == "wav"
                ? await AudioCompressor.compressRecordingFiles(mainURL: rebuilt, includeSidecars: true)
                : rebuilt
            if final != main { try? container.repository.updateAudioPath(final, for: recording) }
            await tracker.markIdle(id)
            isApplyingMic = false
            backend = Self.engineForRerun(transcribedWith: recording.transcribedWithBackend, panel: backend)
            run()
        }
    }

    /// A mic change redoes the transcript the meeting already has, so it uses
    /// the engine that made it. The panel can't say: a meeting's background
    /// Super run never touches the panel, which stays on the default engine.
    static func engineForRerun(transcribedWith: String?, panel: BackendFactory.Kind) -> BackendFactory.Kind {
        guard let made = transcribedWith.flatMap(BackendFactory.Kind.init(rawValue:)), made.supportsAudio else {
            return panel
        }
        return made
    }

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
        self.speakersExact = recording.runSpeakersExact ?? false
        self.micLog = MicMute.load(forMain: URL(fileURLWithPath: recording.audioPath)) ?? MicMuteLog()
    }

    /// Write the panel's state back onto the recording so it survives
    /// closing/reopening and is independent of every other recording.
    private func persistRunSettings() {
        recording.runBackend = backend.rawValue
        recording.runLanguages = languages.sorted().joined(separator: ",")
        recording.runDiarize = diarize
        recording.runHybridDiarize = hybridDiarize
        recording.runExpectedSpeakers = expectedSpeakers
        recording.runSpeakersExact = speakersExact
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

        // Speech models self-resolve (Parakeet/Whisper auto-download). Super
        // runs without its text model too (the merge then keeps engine A's
        // reading), so it is not gated here.
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
            expectedSpeakers: expectedSpeakers,
            expectedSpeakersExact: speakersExact
        )
        container.jobManager.enqueue(recording, params: params)
    }

    private func apiProvider(for kind: BackendFactory.Kind) -> APIKeyStore.Provider {
        switch kind {
        case .openAI:    return .openAI
        case .anthropic: return .anthropic
        case .gemini:    return .gemini
        case .parakeet, .parakeetV2, .parakeetUK, .whisper, .localText, .ensemble:
            return .openAI   // unused; local backends gated above
        }
    }

    func cancel() {
        container.jobManager.cancel(recording.id)
    }
}
