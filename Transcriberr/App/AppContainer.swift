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
    // MARK: - Persistence
    let modelContainer: ModelContainer
    let repository: RecordingRepository

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

    // MARK: - Cross-screen signals
    private(set) var newRecordingRequested = 0

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
        repository = RecordingRepository(context: MainActor.assumeIsolated { mc.mainContext })

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
        jobManager = TranscriptionJobManager(
            runner: transcriptionRunner,
            repository: repository
        )

        // Wire auto-titler after construction so we can capture `self`.
        jobManager.autoTitler = { [weak self] recording, segments, params in
            guard let self else { return }
            await self.generateAutoTitle(for: recording, segments: segments, params: params)
        }

        // Self-heal transcripts lost to interrupted runs (app updated or
        // quit mid-transcription after the run's initial wipe).
        Task { @MainActor [weak self] in
            guard let self else { return }
            let healed = self.repository.healEmptyTranscripts()
            if healed > 0 { AppLog.info("app", "restored \(healed) transcript(s) from versions") }
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
        let sample = segments
            .sorted { $0.startSeconds < $1.startSeconds }
            .prefix(20)
            .map(\.text)
            .joined(separator: " ")
        guard sample.count > 30 else { return }

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
            if trimmed.count >= 3 && trimmed.count < 90 {
                recording.title = trimmed
                try? recording.modelContext?.save()
            }
        } catch {
            // Auto-title is best-effort; swallow.
        }
    }

    func requestNewRecording() {
        newRecordingRequested &+= 1
    }

}
