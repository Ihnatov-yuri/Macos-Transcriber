# What I Learned Building a Fully Local Transcriber for macOS

*Transcriberr is a native macOS app that records, transcribes, diarizes, and rewrites conversations — entirely on-device. No audio ever leaves the Mac. Getting there was harder than it looks, and the hard parts were never where I expected.*

## Hardship #1: The model that lied convincingly

The first architecture used one multimodal model (Gemma, via MLX) for everything: audio in, text out. It demoed beautifully — and then transcribed a business meeting as a conversation about music production that never happened. Whole paragraphs, fluent and confident, invented from noise.

The debugging lesson: **isolate the layer before blaming it.** A model that hallucinates looks identical to a broken microphone pipeline from the transcript view. We proved the recorder was healthy with a headless CLI (151 dB SNR on a test tone), proved the decode was healthy, and only then could we say with confidence: the 8-bit quantized audio tower itself was degraded. The same model family, running through Google's own LiteRT-LM runtime — the stack we'd already proven on Android — was word-perfect. Same weights, different runtime, opposite result. *You are not integrating a model; you are integrating a model-runtime pair.*

## Hardship #2: A small model cannot copy

Local post-processing (clean-up, rewrite, translation) runs on a small on-device LLM. The prompts said, clearly: *remove stutters, keep every sentence, copy speaker labels exactly.* The model agreed — for about two thousand characters. Then "Yuri:" became "uri:", stutters sailed through untouched, and by the end of a 27-minute transcript entire phrases were dropping: "Have weekend. Have great. Bye."

No prompt fixes this, because it isn't a comprehension failure — it's attention arithmetic. The fix was architectural, in two moves:

1. **Do mechanical work in code, not in the model.** A deterministic destutter pass collapses "for for for for", phrase echoes, and filler sounds *before* the model sees the text — measured on real recordings: 371 fillers → 0, 29 stutter-triples → 0. Code is free, instant, and doesn't drift.
2. **Never ask a small model for a long output.** Rewrites now run per speaker-turn window (~2,600 chars), each prompted with the tail of the *already-processed* previous window for continuity, then stitched. Short spans are where small models are flawless. A failed window falls back to its source text — content can never be lost, only left unpolished.

The general form of this learning: **prompt for judgment, code for mechanics, and chunk everything.**

## Hardship #3: The platform fights back quietly

Three macOS incidents, none of which threw a useful error at the time of the mistake:

- **~/Library/Caches is not storage.** macOS silently purged a 10 GB model mid-week. Models now live in Application Support.
- **SwiftData contexts don't share news.** Writes on one ModelContext were invisible to reads on another — deletes that didn't delete, restores that didn't restore, all silently. The cure was structural: one main-actor context for everything, which converted a whole class of "silent no-op" bugs into a compile-time discipline.
- **Code signatures must agree.** Google ships its LiteRT dylib signed with Google's Team ID. An ad-hoc-signed app embedding it launches fine from Xcode — and dies instantly for a packaged build, because dyld refuses to pair binaries from different teams. One `codesign --force -s -` per embedded dylib, scripted into packaging.

## The architecture choices that paid off

**Engines are a protocol, quality is a tournament.** Every ASR engine — Parakeet on the Neural Engine, Whisper large-v3, Gemma — implements one small protocol. That made the killer feature almost free: *versioned transcripts.* Every run is snapshotted; engines compete on the same audio and the user restores whichever version won. When we benchmarked against a Samsung S24's built-in transcriber, this is how we proved the app was better — per recording, side by side, not by vibes.

**Merge engines by confidence, arbitrate by context.** "Super mode" runs two engines and merges word-by-word using per-word confidence (a ROVER-style alignment). Where they genuinely disagree, a local LLM arbitrates — given the surrounding transcript as context. The subtle bug worth sharing: our first merge trusted agreement too early and threw away the one word only Whisper caught ("OWASP 10"). Verbatim shortcuts are only safe at near-certainty; everything else deserves a vote.

**A CLI harness that runs the app's real code.** Every pipeline stage — record, decode, transcribe, diarize — is executable headlessly, using the same classes as the GUI. Nearly every hard bug in this project was isolated by that harness, not by clicking through the app. If a pipeline can only be tested through its UI, it can't be debugged at all.

**Vocabulary as data, harvested from life.** Names and product terms ("Blits", "Kaiko", "KimKim") are the difference between a transcript you trust and one you re-check. The app keeps per-language vocabulary lists — injected into ASR prompts and every rewrite — and they were bootstrapped automatically from the user's own files and past transcripts. The user's folder names are a better source of truth than any model's guess.

## The one-line summary

Local-first AI is not "cloud AI, but smaller." It's a different engineering discipline: **prove each layer with evidence, let deterministic code do everything it can, give models only the short, judgment-shaped work they're actually good at — and never trust a demo.**

---

*Transcriberr runs Parakeet, Whisper, and Gemma fully on-device on Apple Silicon.*
*Yuri Ihnatov — [ihnatov.nl](https://ihnatov.nl) · [github.com/Ihnatov-yuri](https://github.com/Ihnatov-yuri)*
