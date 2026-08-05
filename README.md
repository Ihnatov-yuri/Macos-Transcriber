# <img src="docs/icon.png" width="42" align="center" alt=""> Transcriberr

A native macOS transcription studio. Everything runs **on-device** on Apple Silicon: speech recognition, speaker diarization, and LLM post-processing — no audio or text ever leaves the Mac unless you explicitly configure a cloud engine.

Companion to [Transcriber-Android](https://github.com/Ihnatov-yuri) — same sidecar formats, bigger models.

<!-- Screenshots: drop PNGs into docs/screenshots/ as app-main.png / app-detail.png and uncomment:
![Library and transcript](docs/screenshots/app-main.png)
![Detail with presets](docs/screenshots/app-detail.png)
-->

## Engines

| Engine | Model | Runs on | Best for |
|---|---|---|---|
| **Parakeet v3** (default) | nvidia/parakeet-tdt-0.6b-v3 (CoreML) | ANE, ~100× realtime | English + major EU languages, long files |
| **Parakeet v2** | English-only variant | ANE | Fast English-only runs |
| **Whisper** | openai/whisper-large-v3 (WhisperKit CoreML) | GPU | Multilingual gold standard — best for Ukrainian, Arabic |
| **Gemma (LiteRT-LM)** | google/gemma E2B / E4B `.litertlm` | GPU + CPU | Prompt-steerable ASR with vocabulary, all text post-processing |
| **Super** | Any two of the above + Gemma arbitration | mixed | Maximum quality: word-confidence ROVER merge, disagreements arbitrated by Gemma with transcript context |
| Cloud (optional) | OpenAI / Anthropic / Gemini | API | Off by default; requires keys |

**Diarization** is always available on every engine: FluidAudio pyannote (community-1) CoreML pre-pass, word-level speaker attribution via token timings, speaker-turn coalescing (gap tunable in Settings), and automatic speaker-name inference from the conversation itself ("Hi, I'm Nicole…"). Names you assign persist across re-runs and versions.

## Features

- **Versioned transcripts** — every engine run is snapshotted; compare engines side-by-side and restore any version. Transcripts are never lost on re-runs (rescue snapshots + lazy wipe + launch healing).
- **Post-processing presets** — Summary, Clean, Translate & Polish, Context-aware Rewrite; all editable, all running locally through Gemma. A deterministic destutter pass collapses stutters ("for for for"), phrase echoes, and hesitation fillers before the model sees the text.
- **Per-language vocabulary** — authoritative spellings for names/products (global + per-language lists) injected into ASR prompts and every preset.
- **Live transcription** while recording, with waveform.
- **Per-recording run settings** — engine, languages, diarization, expected speakers, translate; independent per recording.
- **Durable model storage** in `~/Library/Application Support/Transcriberr/models` (survives macOS cache purges).
- **Sidecar export** — `.txt` / `.srt` / `.json` / `.speakers.json`, round-trips with the Android app.

## Build

```bash
./setup.sh
```

Or manually:

```bash
xcodegen generate
xcodebuild -project Transcriberr.xcodeproj -scheme Transcriberr \
    -configuration Release -destination "platform=macOS" \
    -derivedDataPath .build/xcode build
open .build/xcode/Build/Products/Release/Transcriberr.app
```

**Requirements:** Apple Silicon Mac, macOS 15+, Xcode 16+.

**First run:** models download on demand — Parakeet/Whisper/diarization fetch themselves on first use; Gemma `.litertlm` bundles are downloaded from Settings → Models.

## CLI harness

`transcriberrcli` exercises the same audio + ASR code headlessly (`record`, `decode`, `transcribe`, `whisper <file> [lang]`, `litert`, `qwen <file> [lang]`, `superdiar`). Run with `DYLD_LIBRARY_PATH=.build/xcode/Build/Products/Debug` for the LiteRT dylib.

## Credits

Created by **Yuri Ihnatov** — [ihnatov.nl](https://ihnatov.nl) · [github.com/Ihnatov-yuri](https://github.com/Ihnatov-yuri)

Built on [FluidAudio](https://github.com/FluidInference/FluidAudio) (Parakeet + diarization CoreML), [WhisperKit](https://github.com/argmaxinc/WhisperKit), and Google's [LiteRT-LM](https://github.com/google-ai-edge/LiteRT-LM).

## License

Apache-2.0
