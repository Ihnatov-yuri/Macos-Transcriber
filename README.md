# Transcriberr (macOS)

A native SwiftUI macOS app that reproduces [Transcriber-Android](../Claude/Projects/Transcriber-Android/) — same architecture, same UX, same sidecar formats — but tuned for **bigger / more powerful models** on Apple Silicon.

**Status:** Phase 1 — **builds cleanly**, end-to-end pipeline wired through Gemma 4 (audio in) on MLX with FluidAudio diarization (community-1 + WeSpeaker + VBx clustering). Whisper has been dropped as a backend; Gemma 4 is the ASR engine.

---

## Build

```bash
./setup.sh
```

That script installs [XcodeGen](https://github.com/yonaskolb/XcodeGen) via Homebrew if missing, generates `Transcriberr.xcodeproj` from `project.yml`, and opens it in Xcode.

In Xcode, set your signing team (or leave it as "None" for personal builds) and press ⌘R.

Or from the command line:

```bash
xcodegen generate
xcodebuild -project Transcriberr.xcodeproj -scheme Transcriberr \
    -configuration Debug -destination "platform=macOS" \
    -derivedDataPath .build/xcode -skipMacroValidation build
open .build/xcode/Build/Products/Debug/Transcriberr.app
```

**Requirements:** macOS 15+ (Sequoia — mandated by Gemma4Swift), Xcode 16+, Apple Silicon Mac, Metal Toolchain (Xcode prompts to download on first MLX build; or run `xcodebuild -downloadComponent MetalToolchain`).

**First-run model download:** Open the app → ⌘, (Settings) → Models tab → click "Download" next to the model you want. The default is **Gemma 4 E4B (MLX 8-bit)** (~8 GB) — the biggest audio-capable Gemma 4 that fits 16 GB Macs. With 32 GB+ RAM, bump to **Gemma 4 E4B (MLX BF16)** (~19 GB) for max accuracy. With <16 GB, drop to **Gemma 4 E4B (MLX 4-bit)** (~5 GB) or **E2B 4-bit** (~3.6 GB).

> Audio support is only on the **E2B / E4B** families. The 26B-A4B and 31B variants are text + vision only — use them for the post-processing presets if you have the RAM, not for ASR.

Diarization (FluidAudio) auto-downloads its models on first use from `huggingface.co/FluidInference/speaker-diarization-coreml`.

---

## Architecture (mirror of the Android app)

```
Transcriberr/
  App/
    TranscriberrApp.swift      — @main, scenes, commands
    AppContainer.swift         — lazy DI singleton (mirrors data/AppContainer.kt)
  Data/
    Schema.swift               — SwiftData @Models (Recording / Segment / OutputDoc / PendingTask)
    RecordingRepository.swift  — read/write, speaker-name persistence across re-transcribe
  Audio/
    WavRecorder.swift          — AVAudioEngine → 16 kHz mono PCM, 5-sec live chunks
    AudioDecoder.swift         — streaming decode + VAD silence scan + cut-point snap
    AudioPlayerController.swift — AVPlayer + position tracking
  ASR/
    ASRBackend.swift           — protocol every backend implements
    BackendFactory.swift       — local/remote backend resolver
    TranscriptionRunner.swift  — end-to-end pipeline (file → segments)
    LiveTranscriber.swift      — 5-sec rolling chunks during recording
    PostProcessor.swift        — runs preset templates via any backend
    DiarizationRunner.swift    — sherpa-onnx (pyannote + CAM++)
    JobManager.swift           — persisted FIFO queue
    ModelCatalog.swift         — curated download list
    ModelDownloader.swift      — URLSession resumable download
    TranscriptExporter.swift   — .txt / .srt / .json sidecars (round-trip with Android)
    DomainVocabulary.swift     — Medical / IT / Construction / Legal / Finance packs
    Backends/
      Gemma4MLXBackend.swift   — local Gemma 4 via VincentGourbin/gemma-4-swift-mlx (audio + text, CPU or Metal)
      WhisperKitBackend.swift  — local Whisper via WhisperKit (Core ML)
      OpenAIBackend.swift      — Whisper-1 + GPT-4o
      AnthropicBackend.swift   — Claude (text post-processing only)
      GoogleGeminiBackend.swift — Gemini 2.5 (audio + text)
    Stores/
      GemmaSettingsStore.swift — compute backend / context / threads
      PromptStore.swift        — system instructions + vocab + tone
      PresetStore.swift        — four built-in editable presets
      SnippetStore.swift       — {snippet:name} substitution
      UIPrefs.swift            — cross-screen UI state
      APIKeyStore.swift        — Keychain-backed API keys
  UI/
    Nav/AppShell.swift         — NavigationSplitView sidebar (Record / Library)
    Record/                    — record screen + view model
    Library/                   — recordings list with search
    Detail/                    — tabbed detail + player bar
    Settings/                  — Models / Gemma / Prompts / Presets / Style / Snippets / API Keys
    Theme/                     — palette + typography + primitives
  Utility/
    IdleAssertion.swift        — IOPMAssertion to keep the Mac awake during long jobs
  Resources/
    Models/                    — downloaded model files (.gitignored)
```

---

## Model strategy

| Role | Default (local) | Alternatives |
|---|---|---|
| **ASR** | **Gemma 4 E4B (MLX 8-bit)** — biggest audio-capable Gemma 4 (9.6B total / 4.5B active), Conformer encoder, 30 s/chunk, runs on CPU or Metal | E4B BF16 (32 GB+ RAM), E4B 4-bit, E2B 4-bit (lighter), OpenAI Whisper-1 (API), Gemini 2.5 (API) |
| **Post-processing** | Gemma 4 26B-A4B / 31B (MLX 4-bit) when RAM permits, otherwise reuse the audio Gemma | Claude, GPT-4o, Gemini 2.5 |
| **Diarization** | **FluidAudio offline pipeline** — pyannote community-1 powerset segmentation + WeSpeaker embeddings + VBx Bayesian-HMM clustering, all CoreML on the ANE. AMI-SDM DER ~10.6%, 60× real-time on M1, language-agnostic. | Prompt-based via the same Gemma that does ASR (less precise across chunks) |

Gemma 4 weights are pulled from the `mlx-community/*` repos on Hugging Face. CPU-only inference is supported via Settings → Gemma 4 → Compute backend → CPU.

Default backend is set in **Settings → Style**; per-recording override available on the Detail screen's Run sheet.

---

## Cross-app compatibility

Sidecar files (`<stem>.txt`, `<stem>.srt`, `<stem>.json`, `<stem>.speakers.json`) use the **same schema as the Android app**, so files round-trip between devices without re-transcribing.

---

## What's working now

- Record from the default mic (16 kHz mono PCM WAV in `~/Documents/Transcriberr/Recordings/`).
- Import any audio file (Library tab → ⊕) — copied into the same folder.
- Run a recording through Gemma 4 audio with optional diarization and translate-to-English.
- Library list with search across titles AND segment text.
- Detail screen with playback bar (AVPlayer + tap-to-seek), tabbed Transcript / Summary / Clean / Translate / Context-rewrite panes.
- Post-processing presets call Gemma 4 (or any backend) on the transcript text.
- Live transcript on the Record screen via Gemma 4 over 5-second chunks.
- Settings: choose Gemma 4 model, download from HuggingFace, compute backend (Auto / GPU / CPU), context window, custom prompts, snippets, tone, vocabulary, API keys (Keychain).
- Sidecar export: `<stem>.txt` / `.srt` / `.json` / `.speakers.json` — round-trips with the Android app.

## What's still TODO

- OpenAI / Anthropic / Gemini API backends are stubs (key storage works; HTTP calls not implemented).
- Engine-rebuild retry path is wired but the "chunk wedged" detection is only on timeout; LiteRT-LM-style hang heuristics absent (less needed on MLX).
- Domain-vocabulary packs (Medical / IT / etc.) are wired through the UI but the term lists aren't bundled yet.
- Waveform peaks for the player bar (currently just a progress capsule).
- Tests.

---

## License

Apache-2.0 (matches the Android app).
