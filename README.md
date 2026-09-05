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
| **Super** | Any two of the above + Gemma arbitration | mixed | Maximum quality: word-confidence ROVER merge; disputed chunks arbitrated in a second pass with two-sided transcript context + vocabulary |
| Cloud (optional) | OpenAI / Anthropic / Gemini | API | Off by default; requires keys |

**Diarization** is always available on every engine: FluidAudio pyannote (community-1) CoreML pre-pass, word-level speaker attribution via token timings, speaker-turn coalescing (gap tunable in Settings), and automatic speaker-name inference from the conversation itself ("Hi, I'm Nicole…"). Names you assign persist across re-runs and versions.

## Meeting mode

Records your **microphone and system audio** (Zoom/Teams/Meet participants, tapped digitally via a CoreAudio process tap) on one drift-compensated clock. Saves the mix plus raw per-source tracks; transcription runs **split-track**: your voice is ground-truth "you" (named from Settings → Engines → My name), diarization only untangles the others, and an **offline NLMS echo canceller** subtracts the far side's room echo from your mic (measured: −11.8 dB on echo, −0.2 dB on speech). A capture gate keeps playback echo-free; sentence-level scrubs catch the rest.

## Dictation

Hold a modifier key in **any app**, talk, release — the text lands at the cursor. Parakeet decodes the whole passage in a fraction of a second on the Neural Engine, so there is no streaming lag and full-context accuracy. Everything the transcription path learned is reused:

- **Hotkey** — Right ⌥ by default (Right ⌘ / ⌃ / ⇧ or fn selectable); hold-to-talk or tap-to-toggle. Toggle mode flushes a passage at every pause, so hands-free dictation appears paragraph by paragraph. Needs Accessibility access once (System Settings → Privacy & Security → Accessibility) for the global key and for the paste.
- **Cleanup** — the same deterministic destutter pass as the presets (fillers, "the the", phrase echoes), spoken commands ("new paragraph", "comma", "question mark", "open quote"…), and your vocabulary's canonical spellings (exact, never fuzzy).
- **Polish** (optional) — a short Gemma pass per passage, guarded: a result that isn't clearly the same passage cleaned up is discarded.
- **Menu bar + floating status strip**; an in-app **Dictate** scratch pad; optional **history** — every passage saved with its audio as a normal recording in a "Dictation" folder (playable, re-transcribable, searchable via the KB CLI / MCP).
- Insertion is pasteboard + ⌘V with the previous clipboard restored; without Accessibility access the text is copied instead.
- Automation hook: `transcriberr://dictate/start`, `/stop`, `/toggle`, `/cancel`, `/pane` (Shortcuts, Raycast, Stream Deck). Use `open -g` to keep the current app in front so the text is pasted there; a plain `open` activates Transcriberr and the text lands in its scratch pad.

## Features

- **Versioned transcripts** — every engine run is snapshotted; compare engines side-by-side and restore any version. Transcripts are never lost on re-runs (rescue snapshots + lazy wipe + launch healing).
- **Post-processing presets** — Summary, **Minutes** (decisions + action items by owner), Clean, Translate & Polish, Context-aware Rewrite; all editable, all running locally through Gemma. A deterministic destutter pass collapses stutters ("for for for"), phrase echoes, and hesitation fillers before the model sees the text.
- **Per-language vocabulary** — authoritative spellings for names/products (global + per-language lists) injected into ASR prompts and every preset.
- **Live transcription** while recording, with waveform.
- **Per-recording run settings** — engine, languages, diarization, expected speakers, translate; independent per recording.
- **Durable model storage** in `~/Library/Application Support/Transcriberr/models` (survives macOS cache purges).
- **Sidecar export** — `.txt` / `.srt` / `.json` / `.speakers.json`, round-trips with the Android app.

## Tests

```bash
xcodebuild test -project Transcriberr.xcodeproj -scheme Transcriberr -destination "platform=macOS" \
    -derivedDataPath ~/Library/Caches/transcriberr-test-dd -clonedSourcePackagesDirPath .build/xcode/SourcePackages
```

Unit tests over the pure-logic core (destutter, echo scrub/trim, ROVER merge, chunk windowing, NLMS canceller with synthetic ground truth, dictation text stages), the repository (merge/split/versions/folders/tags), the compressor, the KB layer and the player. **Every release must pass the suite first.**

Keep the test derived-data path *outside* `~/Documents`: the test host is launched by launchd and would block in the dynamic loader on the "access your Documents folder" permission prompt (`The test runner hung before establishing connection`), which nobody is there to answer in a headless run.

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
./scripts/package.sh   # re-sign embedded dylibs (required — see script)
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

**PolyForm Noncommercial 1.0.0** — free for personal, hobby, research, and other noncommercial use. Business/commercial use requires a separate license: [atoman@gmail.com](mailto:atoman@gmail.com).

(The [Android app](https://github.com/Ihnatov-yuri) remains Apache-2.0.)
