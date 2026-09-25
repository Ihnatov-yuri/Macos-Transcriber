import AppKit
import Foundation
import Observation
import SwiftData

/// Hand-rolled DI container.
/// Mirrors `data/AppContainer.kt` in the Android app: one per process,
/// owns everything that's expensive or stateful (engines, recorders, repos).
/// `@MainActor` removed deliberately. macOS 26.5's _SwiftData_SwiftUI
/// `EmbeddedDynamicPropertyBox` crashes (`swift_task_isMainExecutorImpl` →
/// `objc_opt_class` at 0x1e) when an `@MainActor @Observable` class is
/// placed into the SwiftUI environment alongside `.modelContainer()`. The
/// class still needs `@unchecked Sendable` so it can ride the environment
/// safely — every property below is actually accessed only from MainActor
/// in practice, but the *type* must not declare actor isolation.
@Observable
final class AppContainer: @unchecked Sendable {
    /// The one live container, for entry points that SwiftUI doesn't hand
    /// an environment to (App Intents).
    nonisolated(unsafe) static weak var shared: AppContainer?

    // MARK: - Persistence
    let modelContainer: ModelContainer
    let repository: RecordingRepository
    /// Shared with `RecordModel`'s background post-processing task so
    /// `RecordingRepository.merge` can wait out an in-flight rebuild/compress
    /// on either source recording instead of racing its file reads.
    let audioPostProcessTracker = AudioPostProcessTracker()

    // MARK: - Stores (persistent preferences)
    let gemmaSettings: GemmaSettingsStore
    let promptStore: PromptStore
    let presetStore: PresetStore
    let snippetStore: SnippetStore
    let uiPrefs: UIPrefs
    let apiKeys: APIKeyStore

    // MARK: - Audio
    let recorder: WavRecorder
    let meetingRecorder: MeetingRecorder
    let audioPlayer: AudioPlayerController

    // MARK: - ASR
    let backendFactory: BackendFactory
    let modelDownloader: ModelDownloader
    let diarizationRunner: DiarizationRunner
    let transcriptionRunner: TranscriptionRunner
    let postProcessor: PostProcessor
    let jobManager: TranscriptionJobManager

    // MARK: - Dictation
    let dictationSettings: DictationSettings
    let dictation: DictationController

    // MARK: - Updates
    let updates = UpdateChecker()

    // MARK: - Cross-screen signals
    /// Bumped by File → New Recording (⌘N). AppShell watches it to switch to
    /// the Record section; RecordView consumes `pendingNewRecording` to
    /// actually start recording once it's on screen. The counter alone
    /// wasn't enough — a RecordView created AFTER the bump never sees a
    /// change, and for a season the menu item did nothing at all because
    /// nothing observed either.
    private(set) var newRecordingRequested = 0
    /// Bumped when the menu bar (or a shortcut) wants the Dictate screen.
    private(set) var dictatePaneRequested = 0
    var pendingNewRecording = false

    init() {
        let schema = Schema(TranscriberrSchema.models)
        let config = ModelConfiguration("Transcriberr", schema: schema)
        let mc: ModelContainer
        do {
            mc = try ModelContainer(for: schema, configurations: config)
        } catch {
            fatalError("ModelContainer init failed: \(error)")
        }
        modelContainer = mc
        // MAIN context, not a private one: the UI's @Query lives on the
        // main context, and a season of bugs (library delete, version
        // restore, orphaned segment rows, unsaved titles) all traced back to
        // the repository mutating view-context objects from a parallel
        // context — a silent no-op in SwiftData. One shared context ends
        // that entire class.
        repository = RecordingRepository(
            context: MainActor.assumeIsolated { mc.mainContext },
            postProcessTracker: audioPostProcessTracker
        )

        gemmaSettings = GemmaSettingsStore()
        promptStore   = PromptStore()
        presetStore   = PresetStore()
        snippetStore  = SnippetStore()
        uiPrefs       = UIPrefs()
        apiKeys       = APIKeyStore()

        recorder = WavRecorder()
        meetingRecorder = MeetingRecorder()
        audioPlayer = AudioPlayerController()

        backendFactory = BackendFactory(
            gemma: gemmaSettings,
            prompts: promptStore,
            apiKeys: apiKeys
        )
        modelDownloader = ModelDownloader()
        diarizationRunner = DiarizationRunner()
        transcriptionRunner = TranscriptionRunner(
            factory: backendFactory,
            prompts: promptStore,
            diarization: diarizationRunner
        )
        postProcessor = PostProcessor(
            factory: backendFactory,
            prompts: promptStore,
            presets: presetStore,
            snippets: snippetStore
        )
        // Same `assumeIsolated` shape as the main ModelContext above: the
        // job manager is `@MainActor` now, and this init only ever runs from
        // the App's own init, which is already on the main actor.
        let runnerForJobs = transcriptionRunner
        let repoForJobs = repository
        jobManager = MainActor.assumeIsolated {
            TranscriptionJobManager(runner: runnerForJobs, repository: repoForJobs)
        }

        dictationSettings = DictationSettings()
        dictation = DictationController(
            settings: dictationSettings,
            factory: backendFactory,
            prompts: promptStore,
            repository: repository,
            uiPrefs: uiPrefs,
            recorder: recorder,
            meetingRecorder: meetingRecorder
        )
        // Hotkey monitors and the HUD panel want a running app — defer to
        // the first run-loop turn rather than doing AppKit work inside init.
        dictation.onShowPane = { [weak self] in self?.requestDictatePane() }
        AppContainer.shared = self
        Task { @MainActor [weak self] in
            self?.dictation.bootstrap()
        }

        // Wire auto-titler after construction so we can capture `self`.
        let jobs = jobManager
        MainActor.assumeIsolated {
            jobs.autoTitler = { [weak self] recording, segments, params in
                guard let self else { return }
                await self.generateAutoTitle(for: recording, segments: segments, params: params)
            }
            // Hand the multi-gigabyte LiteRT engine back once the queue has
            // been quiet for a while — it is the only thing holding the
            // process-wide inference gate down.
            jobs.waitForAudio = { [weak self] id in
                await self?.audioPostProcessTracker.waitUntilIdle(id)
            }
            jobs.onIdle = { [weak self] in
                await self?.backendFactory.releaseLiteRTIfIdle() ?? true
            }
        }

        // Anonymous new-release check (see UpdateChecker). Not under the
        // unit-test host.
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil {
            updates.start()
            ModelCatalog.excludeModelsFromBackup()
        }

        // Self-heal transcripts lost to interrupted runs (app updated or
        // quit mid-transcription after the run's initial wipe).
        Task { @MainActor [weak self] in
            guard let self else { return }
            let healed = self.repository.healEmptyTranscripts()
            if healed > 0 { AppLog.info("app", "restored \(healed) transcript(s) from versions") }
            // Before resuming runs: a row left pointing at a WAV the
            // compressor already deleted would be dropped as "audio missing".
            let repointed = self.repository.healMissingAudioPaths()
            if repointed > 0 { AppLog.info("app", "repointed \(repointed) recording(s) at their compressed audio") }
            // Not under the unit-test host: it opens the user's real store.
            if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil {
                self.jobManager.resumePendingTasks()
                // Recordings cut short by a crash: fix their WAV headers and
                // give them a library row. The candidate list is taken here,
                // before anything can record, so a capture started while the
                // repair runs writes a new file that is not on it.
                if !self.recorder.isCapturing, !self.meetingRecorder.isCapturing {
                    let candidates = WavRepair.candidates(in: WavRepair.recordingsDirectory)
                    let repaired = await Task.detached(priority: .utility) { WavRepair.repairAll(candidates) }.value
                    let recovered = WavRepair.importOrphans(repaired, into: self.repository)
                    if recovered > 0 { AppLog.info("app", "recovered \(recovered) interrupted recording(s)") }
                }
            }
        }

        // Pre-warm Parakeet (the default speech-to-text engine). First-ever
        // launch downloads ~1 GB of CoreML models from HuggingFace; after
        // that this is a fast cache load, and every Run/live session starts
        // instantly.
        Task { [weak self] in
            guard let self else { return }
            let backend = self.backendFactory.backend(for: .parakeet)
            if await !backend.isReady {
                try? await backend.load(modelPath: nil)
            }
        }
    }

    // MARK: - Auto-title

    @MainActor
    private func generateAutoTitle(
        for recording: Recording,
        segments: [Segment],
        params: TranscriptionRunner.Params
    ) async {
        // Spawned as its own task after the run: the recording (and its
        // segments, by cascade) can already be gone by the time this starts.
        guard !recording.isDeleted, recording.modelContext != nil else { return }
        let sample = segments
            .sorted { $0.startSeconds < $1.startSeconds }
            .prefix(20)
            .map(\.text)
            .joined(separator: " ")
        guard sample.count > 30 else { return }
        // Captured before the (possibly model-loading) await: a title the
        // user types while Gemma thinks must win over the generated one.
        let titleBefore = recording.title

        // Titles are text generation — run on the configured text engine.
        let kind = uiPrefs.textEngine.supportsTextGeneration ? uiPrefs.textEngine : .gemmaLiteRT
        let backend = backendFactory.backend(for: kind)
        do {
            if !(await backend.isReady) {
                try await backend.load(modelPath: nil)
            }
            let title = try await backend.generateText(
                systemInstruction: "You name audio recordings. Output ONLY a 3–6 word title in title case. No quotes, no period.",
                userMessage: "Title this transcript:\n\n\(String(sample.prefix(2000)))",
                maxTokens: 32
            )
            let trimmed = title
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'.“”"))
            // The recording may have been deleted while the engine loaded
            // and generated — writing into a deleted model is a SwiftData
            // crash (same guard as JobManager's), and so is the backup
            // rewrite below reading one.
            guard !recording.isDeleted, recording.modelContext != nil else { return }
            guard recording.title == titleBefore else {
                AppLog.info("app", "auto-title skipped — the title changed while it was generated")
                return
            }
            if trimmed.count >= 3 && trimmed.count < 90 {
                recording.title = trimmed
                try? recording.modelContext?.save()
                // The run's own backup fired before the title landed —
                // refresh it so recording.json carries the real title.
                BackupService.backupRecording(recording)
            }
        } catch {
            // Auto-title is best-effort; swallow.
        }
    }

    func requestNewRecording() {
        pendingNewRecording = true
        newRecordingRequested &+= 1
    }

    func requestDictatePane() {
        dictatePaneRequested &+= 1
    }

    // MARK: - Updates

    /// Why the app can't quit for an update right now, if anything.
    @MainActor
    func updateBlocker() -> String? {
        switch recorder.state {
        case .recording, .paused: return "A recording is in progress. Stop it, then update."
        default: break
        }
        if meetingRecorder.isRunning { return "A meeting is being recorded. Stop it, then update." }
        switch dictation.phase {
        case .listening, .transcribing, .inserting: return "Dictation is running. Let it finish, then update."
        default: return nil
        }
    }

    /// The Update button, wherever it sits. Recording or dictating blocks
    /// it; a running transcription asks first, since it restarts from the
    /// beginning after the relaunch.
    @MainActor
    func installUpdate(_ release: UpdateChecker.Release) {
        if let why = updateBlocker() {
            let alert = NSAlert()
            alert.messageText = "Not now"
            alert.informativeText = why
            alert.runModal()
            return
        }
        if jobManager.statuses.values.contains(where: { !$0.failed }) {
            let alert = NSAlert()
            alert.messageText = "A transcription is running"
            alert.informativeText = "Transcriberr quits to update, and the transcription starts again after it reopens."
            alert.addButton(withTitle: "Update Now")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        let updates = self.updates
        Task {
            await updates.installer.install(release, currentVersion: updates.currentVersion,
                                            blocker: { [weak self] in self?.updateBlocker() })
        }
    }

}
