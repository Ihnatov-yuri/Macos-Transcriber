# Transcriberr (macOS) — Port Plan

A native SwiftUI macOS reproduction of the [Transcriber-Android](../../Documents/Claude/Projects/Transcriber-Android/) app, designed to use **bigger / more powerful models** (Gemma 4 via MLX as the local default, plus pluggable cloud API backends) while preserving the Android app's proven architecture, UX, and feature set.

---

## Why "the same approach"?

The Android app is feature-complete v1 and the architecture is already battle-tested:

- Lazy DI via a single `AppContainer`.
- Engine-level singletons protected by a mutex (one Gemma engine, many callers).
- Per-chunk fresh inference contexts (Conversation in Android = per-chunk `MLXContext` here).
- VAD-aligned chunk boundaries with ±2 s flex, 1 s recap overlap.
- Persisted prompt / preset / snippet / vocab stores, all editable in Settings.
- Speaker-name persistence via in-DB snapshot + JSON sidecar.
- Hybrid diarization: prompt-based labels + standalone diarizer pre-pass.

We are **not** rewriting any of this. We are translating it idiom-for-idiom into Swift.

---

## Target platform

| | |
|---|---|
| **Min macOS** | **15 (Sequoia)** — required by Gemma4Swift's `Package.swift` (`.macOS(.v15)`) |
| **Languages** | Swift 6 |
| **UI** | SwiftUI + a few NSViewRepresentable bridges where needed |
| **Persistence** | SwiftData (Android's Room equivalent) |
| **Audio** | AVFoundation (AVAudioEngine record, AVAudioPlayer / AVPlayer playback) |
| **ML — Gemma 4 (audio + text)** | [VincentGourbin/gemma-4-swift-mlx](https://github.com/VincentGourbin/gemma-4-swift-mlx) — native Swift port over MLX, runs E2B / E4B (audio Conformer encoder, 30 s/chunk) on CPU or GPU |
| **ML — Whisper** | [WhisperKit](https://github.com/argmaxinc/WhisperKit) (Core ML) |
| **ML — remote** | OpenAI / Anthropic / Google Gemini APIs via plain `URLSession` |
| **Diarization** | [sherpa-onnx Swift package](https://github.com/k2-fsa/sherpa-onnx) (matches Android exactly) |
| **Bundling** | XcodeGen → `Transcriberr.xcodeproj` (kept out of git; `project.yml` is source of truth) |

---

## Module mapping (Android → macOS)

### UI

| Android | macOS | Notes |
|---|---|---|
| `ui/nav/AppNav.kt` (bottom nav) | `UI/Nav/AppShell.swift` | `NavigationSplitView` with sidebar (Record / Library / Settings) — feels native on macOS instead of forcing a phone-style bottom bar. |
| `ui/record/RecordScreen.kt` | `UI/Record/RecordView.swift` | Same layout: waveform, level meter, elapsed counter, live-transcript card, options sheet. |
| `ui/record/RecordViewModel.kt` | `UI/Record/RecordModel.swift` | `@Observable` class, owns recorder + live worker. |
| `ui/recordings/RecordingsListScreen.kt` | `UI/Library/LibraryView.swift` | Three-pane: list, detail, inspector. |
| `ui/recordings/RecordingDetailScreen.kt` | `UI/Detail/DetailView.swift` | Tabbed: Transcript / Summary / Clean / Translate / Context-rewrite. |
| `ui/recordings/RecordingDetailViewModel.kt` | `UI/Detail/DetailModel.swift` | Job orchestration, speaker renaming. |
| `ui/recordings/PlayerBar.kt` | `UI/Detail/PlayerBar.swift` | AVPlayer + 200-bucket waveform scrubber. |
| `ui/settings/SettingsScreen.kt` | `UI/Settings/SettingsView.swift` | Standard SwiftUI `Settings { ... }` scene, sectioned. |
| `ui/theme/*` | `UI/Theme/*` | Custom palette, IBM Plex Mono + Fraunces (TrueType files in Resources). |
| `ui/MarkdownText.kt` | Built-in SwiftUI `Markdown` (iOS 15+/macOS 12+) | No custom renderer needed. |
| `ui/KeepScreenOn.kt` | `Utility/IdleAssertion.swift` | `IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep…)` |

### Data

| Android | macOS | Notes |
|---|---|---|
| `data/AppContainer.kt` | `Data/AppContainer.swift` | Same lazy-init pattern, exposed as `@Environment(AppContainer.self)`. |
| `data/AppDatabase.kt` (Room v3) | `Data/Schema.swift` (SwiftData `@Model` types) | Migrations via `VersionedSchema`. |
| Entity `Recording` | `@Model class Recording` | identical fields. |
| Entity `Segment` | `@Model class Segment` | identical fields. |
| Entity `OutputDoc` | `@Model class OutputDoc` | identical fields. |
| Entity `PendingTask` | `@Model class PendingTask` | identical fields. |
| `RecordingRepository.kt` | `Data/RecordingRepository.swift` | Same surface. SwiftData `ModelContext` underneath. |

### Audio

| Android | macOS | Notes |
|---|---|---|
| `WavRecorder` | `Audio/WavRecorder.swift` | `AVAudioEngine` → 16 kHz mono 16-bit PCM, emits 5-sec `Chunk`s via `AsyncStream`. |
| `AudioDecoder` | `Audio/AudioDecoder.swift` | `AVAssetReader` for streaming decode + VAD silence scan + cut-point snap. |
| `RecordingService` (foreground service) | `Audio/RecordingSession.swift` | macOS doesn't need foreground services. Just an idle assertion + window-keep-alive. |
| `WakeLockHelper` | `Utility/IdleAssertion.swift` | Same trick. |
| `BatteryOptimization` | — | Not applicable on Mac. |
| `AudioPlayerController` | `Audio/AudioPlayerController.swift` | `AVPlayer` + AsyncStream of `currentTime`. |

### ASR

| Android | macOS | Notes |
|---|---|---|
| `AsrBackend` (interface) | `protocol ASRBackend` | `id`, `isReady`, `load()`, `transcribe(...) async throws`, `release()`. |
| `Gemma4Backend` (LiteRT-LM) | `ASR/Backends/Gemma4MLXBackend.swift` | **Real audio path**: routes through `Gemma4Pipeline` for text and through the lower-level multimodal path (`Gemma4AudioProcessor` + `Gemma4MultimodalLLMModel`) for audio chunks. 30 s/chunk Conformer matches our 28 s VAD-aligned cuts. Default model: `mlx-community/gemma-4-e2b-it-4bit` (5.6 GB peak RAM); upgradeable to E4B/E4B-8bit. Compute backend (CPU / GPU / Auto) maps to `MLX.Device`. |
| `WhisperCppBackend` (JNI) | `ASR/Backends/WhisperMLXBackend.swift` | Use `WhisperKit` from Argmax (Swift-native, Core ML + MLX) or `whisper.cpp` Swift package. Default to WhisperKit for ergonomics. |
| *(new)* | `ASR/Backends/OpenAIBackend.swift` | Whisper-1 + GPT-4-class for post-processing. |
| *(new)* | `ASR/Backends/AnthropicBackend.swift` | Claude for post-processing. Audio not yet supported by Anthropic API → text-only. |
| *(new)* | `ASR/Backends/GoogleGeminiBackend.swift` | Gemini 2.5 audio + text (matches Android's Gemma 4 surface most closely). |
| `AsrFactory` | `ASR/BackendFactory.swift` | Resolve installed model → backend instance. |
| `GemmaSettingsStore` | `ASR/Settings/GemmaSettings.swift` | UserDefaults. Compute backend (Metal / CPU), context window, threads. |
| `TranscriptionRunner` | `ASR/TranscriptionRunner.swift` | `AsyncThrowingStream<ASREvent, Error>` instead of `channelFlow`. Same VAD + chunk + retry logic. |
| `DiarizationRunner` | `ASR/DiarizationRunner.swift` | sherpa-onnx Swift bindings. |
| `LiveTranscriber` | `ASR/LiveTranscriber.swift` | 5-sec rolling chunks during recording. |
| `PostProcessor` | `ASR/PostProcessor.swift` | Pluggable backend, presets, snippet substitution. |
| `PromptStore` | `ASR/Stores/PromptStore.swift` | UserDefaults + JSON. |
| `PresetStore` | `ASR/Stores/PresetStore.swift` | UserDefaults + JSON. |
| `SnippetStore` | `ASR/Stores/SnippetStore.swift` | UserDefaults + JSON. |
| `UiPrefs` | `ASR/Stores/UIPrefs.swift` | UserDefaults. |
| `ModelCatalog` | `ASR/ModelCatalog.swift` | Curated remote model list with checksums. Plus catalog of API-backed pseudo-models. |
| `ModelDownloader` | `ASR/ModelDownloader.swift` | `URLSessionDownloadTask` with resume + atomic `.partial` swap. |
| `TranscriptionJobManager` | `ASR/JobManager.swift` | FIFO `Actor`-backed queue with SwiftData-persisted `PendingTask`. |
| `TranscriptExporter` | `ASR/TranscriptExporter.swift` | `.txt` / `.srt` / `.json` sidecars (identical schema to Android — files round-trip). |
| `DomainVocabulary` | `ASR/DomainVocabulary.swift` | Same packs (Medical / IT / Construction / Legal / Finance × EN/AR/UK/NL). |

### Cross-cutting

- **Threading**: Swift Concurrency. `actor` for the engine singleton; `@MainActor` for view models; `Task.detached(priority: .userInitiated)` for heavy inference; `AsyncStream` / `AsyncThrowingStream` everywhere `Flow` / `channelFlow` was used.
- **Streaming partial text**: The Android trick (`AtomicReference` + poll) becomes much simpler with `AsyncStream.Continuation` — MLX's token callback writes directly into the continuation.
- **Sandbox & entitlements**: Microphone, file read/write (user-selected), network client. No App Sandbox bypass needed for the default cases.
- **Background reliability**: `IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep)` while a job runs; restore on completion.

---

## Phases

### Phase 0 — Scaffold (this commit)
- Project structure, `project.yml`, README, PLAN, stubs for every module.
- Builds and runs as an empty SwiftUI app that lists the planned features.

### Phase 1 — Audio & persistence
- `WavRecorder`, `AudioPlayerController`, `AudioDecoder` (without VAD yet).
- SwiftData schema + repository.
- Library list + Detail screen wired to disk + ExoPlayer-equivalent playback.

### Phase 2 — Whisper backend (easy mode)
- WhisperKit integration. End-to-end file transcribe → segment rows → sidecar export.
- Live transcription on the Record screen.
- Verifies the whole pipeline before tackling Gemma.

### Phase 3 — Gemma 4 via MLX
- `Gemma4MLXBackend` actor with engine load/release + per-chunk inference.
- VAD scan + cut-point snap in `AudioDecoder`.
- Mutex pattern → Swift `actor` (free serialization).
- Prompt scrubbing port from Android `Gemma4Backend.stripPreamble / stripLeakedContext / trimRepetitionTail / scrubBareVocabEcho`.

### Phase 4 — Post-processing & presets
- `PostProcessor` with the four built-in presets.
- Settings → preset editor + snippet editor.
- Tabbed Detail screen.

### Phase 5 — Diarization
- sherpa-onnx Swift bindings.
- Hybrid mode (prompt + diarizer pre-pass).
- Auto-name inference from "Hi, I'm X" patterns.

### Phase 6 — API backends
- Pluggable cloud backends via `ASRBackend` protocol.
- Settings → API keys (Keychain-stored).
- Default to local Gemma 4; surface API alternatives in the Run sheet.

### Phase 7 — Polish
- Library search, fullscreen reader, prose / per-segment toggle, vocabulary quick-fill packs, tone styles, custom prompts, model downloader UI, job queue UI.

---

## Open questions / decisions deferred

1. **Gemma 4 audio in MLX** — **Resolved.** We adopted [VincentGourbin/gemma-4-swift-mlx](https://github.com/VincentGourbin/gemma-4-swift-mlx), a native Swift/MLX port with a working audio Conformer (E2B / E4B, 30 s max per chunk, 750 audio tokens). Model files are downloaded from `mlx-community/*` on HF — **not** `.litertlm` (so no round-trip with Android's model files, but sidecar `.json` / `.srt` / `.txt` still round-trip). CPU and GPU both supported via `MLX.Device.cpu` / `Device.gpu`.

   Side effect: minimum macOS is now **15 (Sequoia)** because Gemma4Swift's `Package.swift` mandates it.

   Caveat: Gemma4Swift's top-level `Gemma4Pipeline` only exposes a text `chat(...)` API; for audio we go through the lower-level `Gemma4AudioProcessor` + `Gemma4MultimodalLLMModel` flow (the same path the project's own CLI uses for `gemma4-cli describe --audio …`). A small follow-up upstream PR adding an `audioChat(...)` convenience would let us delete ~80 lines of bridging code.

2. **WhisperKit vs whisper.cpp Swift** — WhisperKit has nicer streaming + Core ML acceleration; whisper.cpp has more model format support. We default to WhisperKit and keep whisper.cpp as a fallback.

3. **Sandbox** — App Store distribution would need App Sandbox. Direct-download distribution is easier; we ship unsandboxed first, gate on user request.
