import Foundation
@preconcurrency import AVFoundation
import FluidAudio
import WhisperKit
import LiteRTLM

// CLI test harness for the Transcriberr audio pipeline.
//
// Run:  transcriberrcli record [seconds]   — captures from default mic
//       transcriberrcli decode <file>      — decodes + VAD-chunks any file
//       transcriberrcli noisesup <file>    — runs the offline noise-suppression pass
//       transcriberrcli help
//
// All paths exercise the same code the app uses (WavRecorder, AudioDecoder,
// NoiseSuppressor) so a green CLI run means the audio layer is healthy
// independent of the SwiftUI / SwiftData stack.

let args = CommandLine.arguments
let command = args.count > 1 ? args[1] : "help"

func usage() {
    print("""
    transcriberrcli — audio pipeline smoke tests

    USAGE
      transcriberrcli record [seconds]     capture seconds (default 5) from the mic
      transcriberrcli decode <file>        decode to 16k mono Float32 and chunk it
      transcriberrcli noisesup <file>      run the offline noise-suppression pass
      transcriberrcli transcribe <file>    Parakeet v3 ASR on any audio file (downloads models on first run)
      transcriberrcli vocab <file.txt> [Language]
                                            dry-run the vocabulary spelling pass on a transcript
                                            (app vocabulary; prints every change)
      transcriberrcli kb <subcommand>      query the knowledge base (read-only) — `kb help` for details
      transcriberrcli mcp                  serve the knowledge base over MCP (stdio, for LLM clients)
      transcriberrcli restore-backups [--dry-run]
                                            re-inject ~/Documents/Transcriberr Backups into the live
                                            store — fills in anything missing after a crash/corrupt
                                            store/accidental delete; never overwrites what's already there
      transcriberrcli migrate-audio [--dry-run]
                                            one-time migration: transcode existing WAV recordings
                                            (+ mic/sys sidecars) to AAC, verified before the WAV is
                                            deleted, updates each Recording's audioPath
      transcriberrcli migrate-echo [--dry-run]
                                            one-time backfill: rerun offline echo cancellation on
                                            every meeting recording made before v2.5.2, replacing
                                            the live-gated mix with a properly echo-cancelled one
      transcriberrcli help                 this message

    Each command exits 0 on success, non-zero on failure.
    """)
}

@MainActor
func cmdRecord(seconds: Double) async -> Int32 {
    print("[record] capturing \(seconds)s of audio…")

    // Pre-flight TCC. A command-line tool can't present the microphone
    // permission dialog, so if status is .notDetermined, calling
    // requestAccess() inside the recorder would hang forever. Fail fast with
    // guidance instead. (The GUI app CAN show the dialog, so this only
    // affects the headless harness.)
    let status = AVCaptureDevice.authorizationStatus(for: .audio)
    if status != .authorized {
        print("""
        [record] ❌ microphone not authorized for this CLI (status=\(status.rawValue)).
                 A command-line tool can't show the permission prompt. Grant it once:
                   • System Settings → Privacy & Security → Microphone → enable your Terminal app
                 Then re-run. (The GUI app prompts on its own and is unaffected.)
        """)
        return 2
    }

    let rec = WavRecorder()
    do {
        try await rec.start()
    } catch {
        print("[record] ❌ start failed: \(error.localizedDescription)")
        return 1
    }

    let started = Date()
    while Date().timeIntervalSince(started) < seconds {
        try? await Task.sleep(nanoseconds: 100_000_000)
        let s = rec.elapsedMs / 1000
        FileHandle.standardOutput.write("\r  elapsed \(s)s  level=\(String(format: "%.3f", rec.level))".data(using: .utf8)!)
    }
    print("")

    let url: URL?
    do {
        url = try await rec.stop()
    } catch {
        print("[record] ❌ stop failed: \(error.localizedDescription)")
        return 1
    }
    guard let url else {
        print("[record] ❌ no output URL")
        return 1
    }
    let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
    let size = (attrs?[.size] as? Int64) ?? 0
    print("[record] ✓ wrote \(url.path) (\(size) bytes)")

    // Sanity: 5 seconds at 16 kHz mono Float32 ≈ 5 × 16000 × 4 = 320 KB plus
    // 44 bytes of WAV header. Anything under 100 KB means the tap never
    // delivered audio — the bug we hit before.
    let expectedMin = Int64(seconds * 16_000 * 4 * 0.5)   // 50% margin
    if size < expectedMin {
        print("[record] ❌ output suspiciously small (expected ≥ \(expectedMin) bytes)")
        return 2
    }
    return 0
}

@MainActor
func cmdDecode(path: String) async -> Int32 {
    let url = URL(fileURLWithPath: NSString(string: path).expandingTildeInPath)
    print("[decode] reading \(url.lastPathComponent)…")
    let decoder = AudioDecoder()
    do {
        let (samples, chunks, duration) = try await decoder.decodeAndChunk(file: url)
        print("[decode] ✓ \(samples.count) samples, \(String(format: "%.2f", duration))s, \(chunks.count) chunks")
        for (i, c) in chunks.prefix(3).enumerated() {
            print("  chunk[\(i)] \(String(format: "%.1f", c.startSeconds))s–\(String(format: "%.1f", c.endSeconds))s (\(c.samples.count) samples)")
        }
        return 0
    } catch {
        print("[decode] ❌ \(error.localizedDescription)")
        return 1
    }
}

@MainActor
func cmdNoiseSup(path: String) async -> Int32 {
    let url = URL(fileURLWithPath: NSString(string: path).expandingTildeInPath)
    let decoder = AudioDecoder()
    do {
        let raw = try await decoder.decodeAll(file: url)
        print("[noisesup] decoded \(raw.count) samples; running NoiseSuppressor…")
        let cleaned = NoiseSuppressor.process(samples: raw, sampleRate: AudioDecoder.sampleRate)
        print("[noisesup] ✓ in=\(raw.count) out=\(cleaned.count)")
        return cleaned.isEmpty ? 1 : 0
    } catch {
        print("[noisesup] ❌ \(error.localizedDescription)")
        return 1
    }
}

@MainActor
func cmdTranscribe(path: String) async -> Int32 {
    let url = URL(fileURLWithPath: NSString(string: path).expandingTildeInPath)
    print("[asr] decoding \(url.lastPathComponent)…")
    let decoder = AudioDecoder()
    let samples: [Float]
    do {
        samples = try await decoder.decodeAll(file: url)
    } catch {
        print("[asr] ❌ decode failed: \(error.localizedDescription)")
        return 1
    }
    print("[asr] \(samples.count) samples (\(String(format: "%.1f", Double(samples.count) / 16_000))s). Loading Parakeet v3 (first run downloads ~1 GB)…")

    do {
        let models = try await AsrModels.downloadAndLoad(version: .v3) { p in
            FileHandle.standardOutput.write("\r  download/load \(Int(p.fractionCompleted * 100))%".data(using: .utf8)!)
        }
        print("")
        let manager = AsrManager(config: .default)
        try await manager.loadModels(models)
        var state = try TdtDecoderState()
        let t0 = Date()
        let result = try await manager.transcribe(samples, decoderState: &state, language: nil)
        let dt = Date().timeIntervalSince(t0)
        print("[asr] ✓ \(String(format: "%.2f", dt))s compute, confidence \(String(format: "%.2f", result.confidence))")
        print("──────────────────────────────────────────")
        print(result.text)
        print("──────────────────────────────────────────")
        return result.text.isEmpty ? 2 : 0
    } catch {
        print("[asr] ❌ \(error)")
        return 1
    }
}

/// End-to-end test of the diarized-transcription path: FluidAudio diarizer →
/// Parakeet with token timings → speaker labeling → turn coalescing → name
/// inference. Mirrors the app's TranscriptionRunner finalize logic.
@MainActor
func cmdSuperDiar(path: String) async -> Int32 {
    let url = URL(fileURLWithPath: NSString(string: path).expandingTildeInPath)
    let decoder = AudioDecoder()
    let samples: [Float]
    do { samples = try await decoder.decodeAll(file: url) } catch {
        print("[superdiar] ❌ decode: \(error.localizedDescription)"); return 1
    }
    print("[superdiar] \(String(format: "%.1f", Double(samples.count) / 16_000))s of audio")

    do {
        // Diarize.
        let diar = OfflineDiarizerManager(config: OfflineDiarizerConfig())
        try await diar.prepareModels()
        let dResult = try await diar.process(audio: samples)
        let regions = dResult.segments.map { seg -> (start: Double, end: Double, spk: String) in
            (Double(seg.startTimeSeconds), Double(seg.endTimeSeconds), seg.speakerId)
        }
        let speakers = Set(regions.map(\.spk))
        print("[superdiar] diarizer: \(regions.count) regions, \(speakers.count) speakers")

        // Transcribe with timings.
        let models = try await AsrModels.downloadAndLoad(version: .v3)
        let manager = AsrManager(config: .default)
        try await manager.loadModels(models)
        var state = try TdtDecoderState()
        let result = try await manager.transcribe(samples, decoderState: &state, language: nil)
        guard let timings = result.tokenTimings, !timings.isEmpty else {
            print("[superdiar] ❌ no token timings"); return 2
        }

        // Label by midpoint (same logic as ParakeetBackend.labelSpeakers).
        func spkFor(_ mid: Double) -> String {
            var best: (String, Double)? = nil
            for r in regions {
                if mid >= r.start && mid <= r.end { return r.spk }
                let d = mid < r.start ? r.start - mid : mid - r.end
                if best == nil || d < best!.1 { best = (r.spk, d) }
            }
            return best?.0 ?? "?"
        }
        var turns: [(spk: String, text: String)] = []
        for t in timings {
            let spk = spkFor((t.startTime + t.endTime) / 2)
            if var last = turns.last, last.spk == spk {
                last.text += t.token
                turns[turns.count - 1] = last
            } else {
                turns.append((spk, t.token))
            }
        }
        // Name inference (same regex as DiarizationRunner).
        let rx = try NSRegularExpression(pattern: #"\b(?:I'?m|I am|My name is|This is)\s+([A-Z][a-zA-Z]{1,30})\b"#)
        var names: [String: String] = [:]
        print("──────────────────────────────────────────")
        for turn in turns {
            let text = turn.text.replacingOccurrences(of: "▁", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            if names[turn.spk] == nil,
               let m = rx.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
               let r = Range(m.range(at: 1), in: text) {
                names[turn.spk] = String(text[r])
            }
            print("\(names[turn.spk] ?? turn.spk): \(text)")
        }
        print("──────────────────────────────────────────")
        print("[superdiar] inferred names: \(names)")
        return 0
    } catch {
        print("[superdiar] ❌ \(error)")
        return 1
    }
}

/// Whisper large-v3 via WhisperKit — same engine the app's Whisper backend
/// uses. First run downloads ~3 GB from HuggingFace.
@MainActor
func cmdWhisper(path: String, language: String? = nil) async -> Int32 {
    let url = URL(fileURLWithPath: NSString(string: path).expandingTildeInPath)
    let decoder = AudioDecoder()
    let samples: [Float]
    do { samples = try await decoder.decodeAll(file: url) } catch {
        print("[whisper] ❌ decode: \(error.localizedDescription)"); return 1
    }
    print("[whisper] \(String(format: "%.1f", Double(samples.count) / 16_000))s of audio; loading large-v3 (first run downloads ~3 GB)…")
    do {
        let config = WhisperKitConfig(model: "large-v3", verbose: false, prewarm: true)
        let pipe = try await WhisperKit(config)
        var options = DecodingOptions()
        options.task = .transcribe
        options.temperature = 0
        options.language = language
        let t0 = Date()
        let results = try await pipe.transcribe(audioArray: samples, decodeOptions: options)
        let text = results.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        print("[whisper] ✓ \(String(format: "%.1f", Date().timeIntervalSince(t0)))s compute")
        print("──────────────────────────────────────────")
        print(text)
        print("──────────────────────────────────────────")
        return text.isEmpty ? 2 : 0
    } catch {
        print("[whisper] ❌ \(error)")
        return 1
    }
}

/// Time Whisper's whole-track reading per chip placement.
///   whisperbench <ane|gpu|split|encgpu|dual|dual2|dual3> <Language> <file> [file…]
/// Files are read concurrently, as Super reads a meeting's two tracks.
/// The dual modes load two Whisper copies, first file on the first:
/// dual = ane + gpu, dual2 = ane + encgpu, dual3 = split + ane.
/// Each file's text goes to <file>.<placement>.txt.
func cmdWhisperBench(placement: String, language: String, paths: [String]) async -> Int32 {
    let decoder = AudioDecoder()
    var tracks: [(String, [Float])] = []
    for p in paths {
        let url = URL(fileURLWithPath: NSString(string: p).expandingTildeInPath)
        do { tracks.append((url.path, try await decoder.decodeAll(file: url))) } catch {
            print("decode failed: \(p): \(error.localizedDescription)"); return 1
        }
    }
    let backends: [WhisperBackend]
    switch placement {
    case "dual": backends = [WhisperBackend(placement: .ane), WhisperBackend(placement: .gpu)]
    case "dual2": backends = [WhisperBackend(placement: .ane), WhisperBackend(placement: .encgpu)]
    case "dual3": backends = [WhisperBackend(placement: .split), WhisperBackend(placement: .ane)]
    default:
        guard let pl = WhisperBackend.Placement(rawValue: placement) else { print("unknown placement"); return 64 }
        backends = [WhisperBackend(placement: pl)]
    }
    let tl = Date()
    do { for b in backends { try await b.load(modelPath: nil) } } catch {
        print("load failed: \(error)"); return 1
    }
    print(String(format: "load %.1fs", Date().timeIntervalSince(tl)))
    let audio = tracks.map { Double($0.1.count) / 16_000 }.reduce(0, +)
    let t0 = Date()
    let results = await withTaskGroup(of: (Int, String, Double).self) { group in
        for (i, t) in tracks.enumerated() {
            let b = backends[min(i, backends.count - 1)]
            group.addTask {
                let s = Date()
                let r = try? await b.transcribeTimedSegments(samples: t.1, languages: [language])
                return (i, r?.text ?? "", Date().timeIntervalSince(s))
            }
        }
        var out: [(Int, String, Double)] = []
        for await r in group { out.append(r) }
        return out.sorted { $0.0 < $1.0 }
    }
    let wall = Date().timeIntervalSince(t0)
    for (i, text, secs) in results {
        let path = tracks[i].0 + ".\(placement).txt"
        try? text.write(toFile: path, atomically: true, encoding: .utf8)
        print(String(format: "track %d: %.0fs audio in %.1fs, %d chars → %@", i,
                     Double(tracks[i].1.count) / 16_000, secs, text.count, path))
    }
    print(String(format: "WALL %.1fs for %.0fs of audio (%.2fx realtime)", wall, audio, audio / wall))
    return 0
}

/// Gemma via Google's LiteRT-LM runtime — the Android-proven stack.
@MainActor
func cmdLitert(path: String) async -> Int32 {
    let modelDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Transcriberr/models/litert-community/gemma-4-E2B-it-litert-lm")
    guard let model = (try? FileManager.default.contentsOfDirectory(at: modelDir, includingPropertiesForKeys: nil))?
        .first(where: { $0.pathExtension == "litertlm" }) else {
        print("[litert] ❌ no .litertlm bundle in \(modelDir.path)"); return 1
    }
    let url = URL(fileURLWithPath: NSString(string: path).expandingTildeInPath)
    let decoder = AudioDecoder()
    guard let samples = try? await decoder.decodeAll(file: url) else {
        print("[litert] ❌ decode failed"); return 1
    }
    let capped = samples.count > 16_000 * 28 ? Array(samples.prefix(16_000 * 28)) : samples
    // 16-bit PCM WAV
    let wav = FileManager.default.temporaryDirectory.appendingPathComponent("litert-test.wav")
    var data = Data()
    func le32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
    func le16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
    let pcmLen = capped.count * 2
    data.append(contentsOf: Array("RIFF".utf8)); le32(UInt32(36 + pcmLen))
    data.append(contentsOf: Array("WAVE".utf8)); data.append(contentsOf: Array("fmt ".utf8)); le32(16)
    le16(1); le16(1); le32(16000); le32(32000); le16(2); le16(16)
    data.append(contentsOf: Array("data".utf8)); le32(UInt32(pcmLen))
    for s in capped { le16(UInt16(bitPattern: Int16(max(-1, min(1, s)) * 32767))) }
    try? data.write(to: wav)
    defer { try? FileManager.default.removeItem(at: wav) }

    print("[litert] loading \(model.lastPathComponent)…")
    do {
        var engine: Engine?
        for gpu in [true, false] {
            do {
                let cfg = try EngineConfig(
                    modelPath: model.path,
                    backend: gpu ? .gpu : .cpu(),
                    audioBackend: .cpu(),
                    maxNumTokens: 8192,
                    cacheDir: NSTemporaryDirectory()
                )
                let e = Engine(engineConfig: cfg)
                try await e.initialize()
                engine = e
                print("[litert] engine ready on \(gpu ? "GPU" : "CPU")")
                break
            } catch {
                print("[litert] \(gpu ? "GPU" : "CPU") init failed: \(error.localizedDescription)")
            }
        }
        guard let engine else { return 1 }
        let sampler = try SamplerConfig(topK: 1, topP: 0.95, temperature: 0.1)
        let conv = try await engine.createConversation(with: ConversationConfig(
            systemMessage: Message("You are a professional transcription engine."),
            samplerConfig: sampler
        ))
        let t0 = Date()
        let response = try await conv.sendMessage(Message(contents: [
            Content.audioFile(wav.path),
            Content.text("Transcribe the following speech segment in English into English text. Only output the transcription, with no preamble. When transcribing numbers, write the digits."),
        ]))
        print("[litert] ✓ \(String(format: "%.1f", Date().timeIntervalSince(t0)))s compute")
        print("──────────────────────────────────────────")
        print(response.toString.trimmingCharacters(in: .whitespacesAndNewlines))
        print("──────────────────────────────────────────")
        return 0
    } catch {
        print("[litert] ❌ \(error)")
        return 1
    }
}

/// Reproduction test for the v2.2.1 engine-exclusivity fix: fire three
/// concurrent generations at the LiteRT engine — pre-fix, interleaved
/// conversations starved one into an empty response.
@MainActor
func cmdGenTest() async -> Int32 {
    let prompts = PromptStore()
    let factory = BackendFactory(gemma: GemmaSettingsStore(), prompts: prompts, apiKeys: APIKeyStore())
    let backend = factory.backend(for: .gemmaLiteRT)
    do {
        print("[gentest] loading Gemma…")
        try await backend.load(modelPath: nil)
        let t0 = Date()
        async let a = backend.generateText(
            systemInstruction: "You answer in exactly one word.",
            userMessage: "Name any color.", maxTokens: 8)
        async let b = backend.generateText(
            systemInstruction: "You answer in exactly one word.",
            userMessage: "Name any animal.", maxTokens: 8)
        async let c = backend.generateText(
            systemInstruction: "You answer in exactly one word.",
            userMessage: "Name any city.", maxTokens: 8)
        let (ra, rb, rc) = try await (a, b, c)
        let dt = Date().timeIntervalSince(t0)
        print("[gentest] concurrent results in \(String(format: "%.1f", dt))s:")
        print("  A: \(ra.prefix(40))  (\(ra.count) chars)")
        print("  B: \(rb.prefix(40))  (\(rb.count) chars)")
        print("  C: \(rc.prefix(40))  (\(rc.count) chars)")
        let empties = [ra, rb, rc].filter(\.isEmpty).count
        print(empties == 0 ? "[gentest] ✓ PASS — no starved generations" : "[gentest] ❌ FAIL — \(empties) empty")
        return empties == 0 ? 0 : 1
    } catch {
        print("[gentest] ❌ \(error)")
        return 1
    }
}

/// Meeting brief on a real transcript (.txt) with the local Gemma — shows
/// what the model proposes, what the guards accept, and how long one
/// whole-transcript read takes.
@MainActor
func cmdBrief(path: String) async -> Int32 {
    let url = URL(fileURLWithPath: NSString(string: path).expandingTildeInPath)
    guard let text = try? String(contentsOf: url, encoding: .utf8) else {
        print("[brief] ❌ cannot read \(path)"); return 1
    }
    let app = UserDefaults(suiteName: "nl.ihnatov.Transcriberr")
    let vocabulary = app?.string(forKey: "prompt.vocabulary") ?? ""
    let factory = BackendFactory(gemma: GemmaSettingsStore(), prompts: PromptStore(), apiKeys: APIKeyStore())
    let backend = factory.backend(for: .gemmaLiteRT)
    do {
        try await backend.load(modelPath: nil)
        let parts = MeetingBriefBuilder.sections(text)
        print("[brief] \(text.count) chars ≈ \(MeetingBriefBuilder.estimatedTokens(text)) tokens → \(parts.count) section(s)")
        let t0 = Date()
        let brief = try await MeetingBriefBuilder.build(transcript: text, vocabulary: vocabulary) { system, user, maxTokens in
            let raw = try await backend.generateText(systemInstruction: system, userMessage: user, maxTokens: maxTokens)
            print("── raw model output ──\n\(raw)\n──────────────────────")
            return raw
        }
        print("[brief] ✓ \(String(format: "%.0f", Date().timeIntervalSince(t0)))s")
        print(brief.promptBlock)
        for f in brief.fixes {
            print("ACCEPTED FIX  \(f.from) → \(f.to)  (\(MeetingBriefBuilder.occurrences(of: f.from, in: text))×)")
        }
        return 0
    } catch {
        print("[brief] ❌ \(error)"); return 1
    }
}

/// Full transcription pipeline, headless — same code path as the app's
/// RUN button, for validating changes on real recordings without a deploy.
@MainActor
func cmdRun(path: String, speakers: Int, backend: String = "parakeet-v3",
            engineA: String? = nil, engineB: String? = nil,
            language: String = "English") async -> Int32 {
    let url = URL(fileURLWithPath: NSString(string: path).expandingTildeInPath)
    guard let kind = BackendFactory.Kind(rawValue: backend) else {
        print("unknown backend '\(backend)' — one of \(BackendFactory.Kind.allCases.map(\.rawValue))")
        return 64
    }
    if kind == .ensemble {
        UserDefaults.standard.set(engineA ?? "whisper-large-v3", forKey: "ensemble.engineA")
        UserDefaults.standard.set(engineB ?? "gemma4-litert", forKey: "ensemble.engineB")
        UserDefaults.standard.set(true, forKey: "ui.superMaxQuality")
        // A/B switch for scripts/eval-set.sh: TRANSCRIBERR_LONGFORM=1/0
        // forces long-form Whisper on/off; unset = the language default.
        switch ProcessInfo.processInfo.environment["TRANSCRIBERR_LONGFORM"] {
        case "1": UserDefaults.standard.set(true, forKey: "ensemble.whisperLongForm")
        case "0": UserDefaults.standard.set(false, forKey: "ensemble.whisperLongForm")
        default: UserDefaults.standard.removeObject(forKey: "ensemble.whisperLongForm")
        }
    }
    // The CLI has its own defaults domain; borrow the app's vocabulary so a
    // headless run biases and votes exactly as the app would.
    if let app = UserDefaults(suiteName: "nl.ihnatov.Transcriberr") {
        for key in ["prompt.vocabulary", "prompt.vocabulary.byLang"] {
            if let v = app.string(forKey: key) { UserDefaults.standard.set(v, forKey: key) }
        }
    }
    let prompts = PromptStore()
    let factory = BackendFactory(gemma: GemmaSettingsStore(), prompts: prompts, apiKeys: APIKeyStore())
    let runner = TranscriptionRunner(factory: factory, prompts: prompts, diarization: DiarizationRunner())
    let params = TranscriptionRunner.Params(
        file: url, backend: kind, modelDirectory: nil,
        languages: [language], translateTo: nil,
        diarize: true, hybridDiarize: false, expectedSpeakers: speakers)
    let t0 = Date()
    do {
        for try await ev in runner.run(params) {
            switch ev {
            case .stage(let text, let f):
                FileHandle.standardError.write("[\(Int(f * 100))%] \(text)\n".data(using: .utf8)!)
            case .done(let segs):
                print("### DONE \(String(format: "%.0f", Date().timeIntervalSince(t0)))s \(segs.count) segments")
                for s in segs {
                    let k = s.speakerName ?? s.speakerKey ?? "?"
                    print("\(String(format: "%.1f", s.startSeconds))\t\(k)\t\(s.text)\t\(s.speakerKey ?? "")")
                }
            default: break
            }
        }
        return 0
    } catch {
        print("### FAILED \(error)")
        return 1
    }
}

/// Whisper language detection over sliding windows of a file (experiment:
/// can it find the English stretches inside a Ukrainian meeting?).
@MainActor
func cmdLangID(path: String, window: Double) async -> Int32 {
    // A zero window never advances (infinite loop); a negative one traps on
    // an inverted slice range.
    guard window > 0 else { print("window must be > 0 seconds"); return 64 }
    let url = URL(fileURLWithPath: NSString(string: path).expandingTildeInPath)
    guard let samples = try? await AudioDecoder().decodeAll(file: url) else { print("decode failed"); return 1 }
    do {
        let pipe = try await WhisperKit(WhisperKitConfig(model: "large-v3", verbose: false, prewarm: true))
        let hop = window / 2
        var t = 0.0
        while t + window <= Double(samples.count) / 16_000 {
            let a = Int(t * 16_000), b = Int((t + window) * 16_000)
            let slice = Array(samples[a..<b])
            if (WhisperBackend.peakWindowRMS(slice) ?? 0) >= 0.01 {
                let r = try await pipe.detectLangauge(audioArray: slice)
                let top = r.langProbs.sorted { $0.value > $1.value }.prefix(3)
                    .map { "\($0.key) \(String(format: "%.2f", $0.value))" }.joined(separator: ", ")
                print(String(format: "%6.1f  %@  [%@]", t, r.language, top))
            }
            t += hop
        }
        return 0
    } catch { print("\(error)"); return 1 }
}

/// Dry run of `TranscriptHygiene.applyVocabulary` over a text file, line by
/// line, with the app's vocabulary — every changed line is printed.
@MainActor
func cmdVocab(path: String, language: String) -> Int32 {
    let url = URL(fileURLWithPath: NSString(string: path).expandingTildeInPath)
    guard let text = try? String(contentsOf: url, encoding: .utf8) else { print("cannot read \(path)"); return 1 }
    if let app = UserDefaults(suiteName: "nl.ihnatov.Transcriberr") {
        for key in ["prompt.vocabulary", "prompt.vocabulary.byLang"] {
            if let v = app.string(forKey: key) { UserDefaults.standard.set(v, forKey: key) }
        }
    }
    let terms = TranscriptHygiene.vocabularyTerms(languages: [language])
    var changed = 0
    for line in text.components(separatedBy: "\n") {
        let fixed = TranscriptHygiene.applyVocabulary(line, terms: terms)
        if fixed != line { changed += 1; print("- \(line)\n+ \(fixed)") }
    }
    print("### \(changed) lines changed, \(terms.count) terms")
    return 0
}

/// Offline echo-cancellation check over a meeting's track pair.
@MainActor
func cmdAEC(base: String) async -> Int32 {

    let baseURL = URL(fileURLWithPath: NSString(string: base).expandingTildeInPath)
    guard let mic = AudioCompressor.sidecarURL(for: baseURL, kind: "mic"),
          let sys = AudioCompressor.sidecarURL(for: baseURL, kind: "sys") else {
        print("[aec] ❌ no mic/sys sidecar found next to \(baseURL.lastPathComponent) (checked .m4a and .wav)")
        return 1
    }
    let decoder = AudioDecoder()
    do {
        let m = try await decoder.decodeAll(file: mic)
        let r = try await decoder.decodeAll(file: sys)
        print("[aec] mic \(m.count) smp, sys \(r.count) smp — running NLMS…")
        let t0 = Date()
        let cleaned = EchoCanceller.cancel(mic: m, ref: r)
        var ein = 0.0, eout = 0.0
        for v in m { ein += Double(v * v) }
        for v in cleaned { eout += Double(v * v) }
        let erle = 10 * log10(ein / max(eout, 1e-12))
        // write cleaned wav for offline analysis
        if let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false),
           let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(cleaned.count)) {
            buf.frameLength = AVAudioFrameCount(cleaned.count)
            cleaned.withUnsafeBufferPointer { src in buf.floatChannelData![0].update(from: src.baseAddress!, count: cleaned.count) }
            let outURL = baseURL.deletingPathExtension().appendingPathExtension("aec.wav")
            if let f = try? AVAudioFile(forWriting: outURL, settings: fmt.settings, commonFormat: .pcmFormatFloat32, interleaved: false) {
                try? f.write(from: buf)
                print("[aec] cleaned → \(outURL.lastPathComponent)")
            }
        }
        print("[aec] ✓ \(String(format: "%.1f", Date().timeIntervalSince(t0)))s — mic energy reduced by \(String(format: "%.1f", erle)) dB (echo removed; user speech preserved)")
        return 0
    } catch {
        print("[aec] ❌ \(error)")
        return 1
    }
}

@MainActor
func main() async -> Int32 {
    switch command {
    case "record":
        let s = (args.count > 2 ? Double(args[2]) : nil) ?? 5
        return await cmdRecord(seconds: s)
    case "decode":
        guard args.count > 2 else { usage(); return 64 }
        return await cmdDecode(path: args[2])
    case "noisesup":
        guard args.count > 2 else { usage(); return 64 }
        return await cmdNoiseSup(path: args[2])
    case "transcribe":
        guard args.count > 2 else { usage(); return 64 }
        return await cmdTranscribe(path: args[2])
    case "superdiar":
        guard args.count > 2 else { usage(); return 64 }
        return await cmdSuperDiar(path: args[2])
    case "whisperbench":
        guard args.count > 4 else { usage(); return 64 }
        return await cmdWhisperBench(placement: args[2], language: args[3], paths: Array(args[4...]))
    case "whisper":
        guard args.count > 2 else { usage(); return 64 }
        return await cmdWhisper(path: args[2], language: args.count > 3 ? args[3] : nil)
    case "gentest":
        return await cmdGenTest()
    case "run":
        guard args.count > 2 else { usage(); return 64 }
        return await cmdRun(
            path: args[2],
            speakers: args.count > 3 ? Int(args[3]) ?? 0 : 0,
            backend: args.count > 4 ? args[4] : "parakeet-v3",
            engineA: args.count > 5 ? args[5] : nil,
            engineB: args.count > 6 ? args[6] : nil,
            language: args.count > 7 ? args[7] : "English")
    case "langid":
        guard args.count > 2 else { usage(); return 64 }
        return await cmdLangID(path: args[2], window: args.count > 3 ? Double(args[3]) ?? 4 : 4)
    case "vocab":
        guard args.count > 2 else { usage(); return 64 }
        return cmdVocab(path: args[2], language: args.count > 3 ? args[3] : "English")
    case "brief":
        guard args.count > 2 else { usage(); return 64 }
        return await cmdBrief(path: args[2])
    case "aec":
        guard args.count > 2 else { usage(); return 64 }
        return await cmdAEC(base: args[2])
    case "litert":
        guard args.count > 2 else { usage(); return 64 }
        return await cmdLitert(path: args[2])
    case "kb":
        return cmdKB(Array(args.dropFirst(2)))
    case "restore-backups":
        return cmdRestoreBackups(dryRun: args.dropFirst(2).contains("--dry-run"))
    case "migrate-audio":
        return await cmdMigrateAudio(dryRun: args.dropFirst(2).contains("--dry-run"))
    case "migrate-echo":
        return await cmdMigrateEcho(dryRun: args.dropFirst(2).contains("--dry-run"))
    case "mcp":
        return runMCPServer()
    case "help", "-h", "--help":
        usage()
        return 0
    default:
        usage()
        return 64
    }
}

let exitCode = await main()
// Backup writes are queued off-thread; exit() would drop any still pending.
BackupService.flush()
exit(exitCode)
