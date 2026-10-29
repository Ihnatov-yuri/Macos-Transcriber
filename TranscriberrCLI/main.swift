import AppKit
import Foundation
@preconcurrency import AVFoundation
import FluidAudio
import WhisperKit
@preconcurrency import LiteRTLM

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
      transcriberrcli transcribe <file> [--json] [--language Dutch]
                                           Parakeet v3 ASR on any audio file (downloads models on first run);
                                           --json prints only JSON with word-level start/end times
      transcriberrcli diarize <list.tsv> <outdir> [speakers]
                                            the app's diarizer (diar.engine, fallback, foldScraps) on
                                            "<id>\t<audio>" lines; writes <id>.rttm + timing.tsv
      transcriberrcli context <when|file> [minutes]  the calendar invite a recording at that time would use
      transcriberrcli bench [score <backend> [engA engB]] [--dir <dir>]  the user's checked references; score an engine on them
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
      transcriberrcli voice enroll|score|show
                                            voice print: enroll from audio (or a meeting's mic via
                                            --me), score a meeting's tracks against it
      transcriberrcli uk-model [status|update]
                                            Parakeet UK: installed release vs Hugging Face; update
                                            fetches the newest and switches to it
      transcriberrcli virtualmic [seconds]  Transcriberr Microphone driver check: a tone through the
                                            hidden feed device, recorded back from the microphone
                                            (silent; quit Transcriberr first)
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
func cmdTranscribe(path: String, json: Bool = false, language: String? = nil) async -> Int32 {
    // With --json, stdout carries only the JSON document; progress goes to stderr.
    func say(_ line: String) {
        if json { FileHandle.standardError.write((line + "\n").data(using: .utf8)!) } else { print(line) }
    }
    let url = URL(fileURLWithPath: NSString(string: path).expandingTildeInPath)
    say("[asr] decoding \(url.lastPathComponent)…")
    let decoder = AudioDecoder()
    let samples: [Float]
    do {
        samples = try await decoder.decodeAll(file: url)
    } catch {
        say("[asr] ❌ decode failed: \(error.localizedDescription)")
        return 1
    }
    let seconds = Double(samples.count) / 16_000
    say("[asr] \(samples.count) samples (\(String(format: "%.1f", seconds))s). Loading Parakeet v3 (first run downloads ~1 GB)…")
    let hint = language.flatMap { ParakeetBackend.languageHint(from: [$0]) }
    if let language, hint == nil { say("[asr] unknown --language '\(language)', using auto-detect") }

    do {
        let models = try await AsrModels.downloadAndLoad(version: .v3) { p in
            if !json {
                FileHandle.standardOutput.write("\r  download/load \(Int(p.fractionCompleted * 100))%".data(using: .utf8)!)
            }
        }
        if !json { print("") }
        let manager = AsrManager(config: .default)
        try await manager.loadModels(models)
        var state = try TdtDecoderState()
        let t0 = Date()
        let result = try await manager.transcribe(samples, decoderState: &state, language: hint)
        let dt = Date().timeIntervalSince(t0)
        say("[asr] ✓ \(String(format: "%.2f", dt))s compute, confidence \(String(format: "%.2f", result.confidence))")
        if json {
            let doc = TranscriptJSON(text: result.text, confidence: result.confidence, durationS: seconds,
                                     language: hint?.rawValue, timings: result.tokenTimings ?? [])
            print(try doc.encoded())
        } else {
            print("──────────────────────────────────────────")
            print(result.text)
            print("──────────────────────────────────────────")
        }
        return result.text.isEmpty ? 2 : 0
    } catch {
        say("[asr] ❌ \(error)")
        return 1
    }
}

/// Benchmark entry: DiarizationRunner exactly as the runner's pre-pass calls
/// it (no voice print, so foldScraps without scores), one RTTM per line.
@MainActor
func cmdDiarize(list: String, outDir: String, speakers: Int) async -> Int32 {
    let out = URL(fileURLWithPath: NSString(string: outDir).expandingTildeInPath)
    let runner = DiarizationRunner()
    let decoder = AudioDecoder()
    do {
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        var timing = ""
        for line in try String(contentsOfFile: list, encoding: .utf8).split(separator: "\n") {
            let parts = line.split(separator: "\t", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            let samples = try await decoder.decodeAll(file: URL(fileURLWithPath: parts[1]))
            let seconds = Double(samples.count) / 16_000
            let t0 = Date()
            let diar = DiarizationRunner.foldScraps(try await runner.run(samples: samples, numClusters: speakers))
            let elapsed = Date().timeIntervalSince(t0)
            let rttm = diar.map {
                String(format: "SPEAKER %@ 1 %.3f %.3f <NA> <NA> %@ <NA> <NA>\n",
                       parts[0], $0.startSeconds, $0.endSeconds - $0.startSeconds, $0.speakerId)
            }.joined()
            try rttm.write(to: out.appendingPathComponent("\(parts[0]).rttm"), atomically: true, encoding: .utf8)
            timing += "\(parts[0])\t\(DiarizationRunner.engine.rawValue)\t\(String(format: "%.1f", seconds))\t\(String(format: "%.2f", elapsed))\n"
            print("[diarize] \(parts[0]) \(Int(seconds)) s → \(String(format: "%.1f", elapsed)) s, \(Set(diar.map(\.speakerId)).count) speakers")
        }
        try timing.write(to: out.appendingPathComponent("timing.tsv"), atomically: true, encoding: .utf8)
        return 0
    } catch {
        print("[diarize] ❌ \(error)")
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
    // At most `parallel` files at once: the bench once read 20 short clips
    // together, every one ran past Whisper's decode budget, and each came
    // back empty with no error. Override with TRANSCRIBERR_BENCH_PARALLEL.
    let parallel = max(1, Int(ProcessInfo.processInfo.environment["TRANSCRIBERR_BENCH_PARALLEL"] ?? "") ?? 2)
    print("reading \(tracks.count) file(s), \(min(parallel, tracks.count)) at a time")
    let results = await withTaskGroup(of: (Int, Result<String, Error>, Double).self) { group in
        var next = 0
        func submit() {
            let i = next
            let t = tracks[i]
            let b = backends[min(i, backends.count - 1)]
            next += 1
            group.addTask {
                let s = Date()
                do {
                    let r = try await b.transcribeTimedSegments(samples: t.1, languages: [language])
                    return (i, .success(r.text), Date().timeIntervalSince(s))
                } catch {
                    return (i, .failure(error), Date().timeIntervalSince(s))
                }
            }
        }
        while next < min(parallel, tracks.count) { submit() }
        var out: [(Int, Result<String, Error>, Double)] = []
        for await r in group {
            out.append(r)
            if next < tracks.count { submit() }
        }
        return out.sorted { $0.0 < $1.0 }
    }
    let wall = Date().timeIntervalSince(t0)
    var failed = 0
    for (i, result, secs) in results {
        let path = tracks[i].0 + ".\(placement).txt"
        switch result {
        case .success(let text):
            try? text.write(toFile: path, atomically: true, encoding: .utf8)
            print(String(format: "track %d: %.0fs audio in %.1fs, %d chars → %@", i,
                         Double(tracks[i].1.count) / 16_000, secs, text.count, path))
        case .failure(let error):
            // No .txt: an empty file would read as "Whisper heard nothing".
            failed += 1
            try? FileManager.default.removeItem(atPath: path)
            print(String(format: "track %d: FAILED after %.1fs: %@ (%@)", i, secs,
                         error.localizedDescription, tracks[i].0))
        }
    }
    print(String(format: "WALL %.1fs for %.0fs of audio (%.2fx realtime)", wall, audio, audio / wall))
    if failed > 0 { print("\(failed) of \(tracks.count) file(s) FAILED"); return 1 }
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
    // TRANSCRIBERR_NO_VOCAB=1: run as a user with no vocabulary at all (to
    // measure what a meeting context alone brings).
    if ProcessInfo.processInfo.environment["TRANSCRIBERR_NO_VOCAB"] == "1" {
        for key in ["prompt.vocabulary", "prompt.vocabulary.byLang", DisputeLearning.key] {
            UserDefaults.standard.removeObject(forKey: key)
        }
    } else if let app = UserDefaults(suiteName: "nl.ihnatov.Transcriberr") {
        for key in ["prompt.vocabulary", "prompt.vocabulary.byLang"] {
            if let v = app.string(forKey: key) { UserDefaults.standard.set(v, forKey: key) }
        }
        if let learned = app.stringArray(forKey: DisputeLearning.key) {
            UserDefaults.standard.set(learned, forKey: DisputeLearning.key)
        }
    }
    let prompts = PromptStore()
    let factory = BackendFactory(gemma: GemmaSettingsStore(), prompts: prompts, apiKeys: APIKeyStore())
    // The whole process is one job: as in the app while a job runs, Gemma's
    // idle release must not fire. It did after 3 quiet minutes and took
    // Super's engines with it ("Ensemble backend not loaded").
    factory.liteRTReleaseAllowed = { false }
    let runner = TranscriptionRunner(factory: factory, prompts: prompts, diarization: DiarizationRunner())
    var params = TranscriptionRunner.Params(
        file: url, backend: kind, modelDirectory: nil,
        languages: language == "auto" ? [] : [language], translateTo: nil,
        diarize: true, hybridDiarize: false, expectedSpeakers: speakers)
    // A/B for meeting context: TRANSCRIBERR_CONTEXT=<MeetingContext.json>
    // (as `transcriberrcli context` prints it) runs with that invite.
    if let path = ProcessInfo.processInfo.environment["TRANSCRIBERR_CONTEXT"],
       let json = try? String(contentsOfFile: path, encoding: .utf8) {
        params.meetingContext = MeetingContext.decode(json)
        if let mc = params.meetingContext, mc.voteTerms == nil {
            params.meetingContext?.voteTerms = MeetingContext.voteTerms(from: mc.calendarTerms)
        }
        FileHandle.standardError.write("meeting context: \(params.meetingContext?.allTerms ?? [])\n".data(using: .utf8)!)
    }
    let t0 = Date()
    var disputes: [WordDispute] = []
    do {
        for try await ev in runner.run(params) {
            switch ev {
            case .stage(let text, let f):
                FileHandle.standardError.write("[\(Int(f * 100))%] \(text)\n".data(using: .utf8)!)
            case .segments(_, let segs) where ProcessInfo.processInfo.environment["TRANSCRIBERR_SHOW_LIVE"] == "1":
                for s in segs {
                    FileHandle.standardError.write("LIVE \(String(format: "%.1f", s.startSeconds))\t\(s.speakerKey ?? "?")\t\(s.text)\n".data(using: .utf8)!)
                }
            case .disputes(let d):
                disputes = d
            case .done(let segs):
                print("### DONE \(String(format: "%.0f", Date().timeIntervalSince(t0)))s \(segs.count) segments")
                // On stderr: stdout is the transcript eval-set.sh scores.
                let shown = DisputeIndex.locate(d: disputes, in: segs.map { ($0.startSeconds, $0.endSeconds, $0.text) })
                var report = "### DISPUTES \(disputes.count) found, \(shown.count) shown in the final text\n"
                for (seg, hit) in shown {
                    report += "DISPUTE \(String(format: "%.1f", segs[seg].startSeconds))\t\(hit.dispute.chosen) | \(hit.dispute.alternative)\n"
                }
                FileHandle.standardError.write(report.data(using: .utf8)!)
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

/// Prints the meeting context a recording made at `start` (ISO 8601, local
/// "yyyy-MM-dd HH:mm", or a recording file whose creation date is used)
/// would get: the invite, its terms, and the past events with its people.
@MainActor
func cmdContext(start: String, minutes: Double) async -> Int32 {
    var date: Date?
    let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm"
    date = ISO8601DateFormatter().date(from: start) ?? f.date(from: start)
    // A meeting file: its name says when it started.
    if date == nil, let iv = MeetingContext.recordedInterval(audioPath: start, createdAtMillis: 0, duration: minutes * 60) {
        date = iv.start
    }
    guard let date else { print("cannot read a date from '\(start)'"); return 64 }
    guard let mc = await MeetingContext.lookup(start: date, end: date.addingTimeInterval(minutes * 60), ask: true) else {
        print("no invite covers \(date) (+\(Int(minutes)) min) — or calendar access was refused")
        return 1
    }
    let past = MeetingContext.pastEvents(sharing: mc)
    FileHandle.standardError.write("""
        title: \(mc.title)
        attendees: \(mc.attendees)
        invite terms: \(mc.inviteTerms)
        calendar terms: \(mc.calendarTerms)
        past events with these people: \(past.count)\n
        """.data(using: .utf8)!)
    print(MeetingContext.encode(mc) ?? "")
    return 0
}

/// `bench`: per language, how much checked speech the user's corrections
/// built and the engine-vs-user WER of the text they corrected.
/// `bench score <backend> [engA engB]`: runs that engine on every clip and
/// scores it against the references, per language.
@MainActor
func cmdBench(_ argv: [String]) async -> Int32 {
    var argv = argv
    var dir = Benchmark.root
    if let i = argv.firstIndex(of: "--dir"), i + 1 < argv.count {
        dir = URL(fileURLWithPath: NSString(string: argv[i + 1]).expandingTildeInPath)
        argv.removeSubrange(i...(i + 1))
    }
    let items = Benchmark.items(in: dir)
    print("\(items.count) checked lines in \(dir.path)")
    for s in Benchmark.summary(items) {
        print(String(format: "  %-10@ %3d lines %6.1f min %5d words  first engine text vs you: %5.1f%% WER",
                     s.language as NSString, s.items, s.seconds / 60, s.words, s.wer * 100))
    }
    guard argv.first == "score", argv.count >= 2, let kind = BackendFactory.Kind(rawValue: argv[1]) else { return 0 }
    // Score as the app runs: with the user's vocabulary and word choices.
    if let app = UserDefaults(suiteName: "nl.ihnatov.Transcriberr") {
        for key in ["prompt.vocabulary", "prompt.vocabulary.byLang"] {
            if let v = app.string(forKey: key) { UserDefaults.standard.set(v, forKey: key) }
        }
        if let learned = app.stringArray(forKey: DisputeLearning.key) {
            UserDefaults.standard.set(learned, forKey: DisputeLearning.key)
        }
    }
    if kind == .ensemble {
        UserDefaults.standard.set(argv.count > 2 ? argv[2] : "whisper-large-v3", forKey: "ensemble.engineA")
        UserDefaults.standard.set(argv.count > 3 ? argv[3] : "parakeet-v3", forKey: "ensemble.engineB")
        UserDefaults.standard.set(true, forKey: "ui.superMaxQuality")
    }
    let prompts = PromptStore()
    let factory = BackendFactory(gemma: GemmaSettingsStore(), prompts: prompts, apiKeys: APIKeyStore())
    let runner = TranscriptionRunner(factory: factory, prompts: prompts, diarization: DiarizationRunner())
    var totals: [String: (errors: Int, words: Int)] = [:]
    for (k, it) in items.enumerated() {
        let params = TranscriptionRunner.Params(
            file: dir.appendingPathComponent(it.clip), backend: kind,
            languages: it.language.map { [$0] } ?? [])
        var hyp = ""
        do {
            for try await ev in runner.run(params) {
                if case .done(let segs) = ev {
                    hyp = segs.filter { Benchmark.onSide(speakerKey: $0.speakerKey, track: it.track) }
                        .map(\.text).joined(separator: " ")
                }
            }
        } catch {
            FileHandle.standardError.write("item \(k + 1) failed: \(error)\n".data(using: .utf8)!)
        }
        let e = Benchmark.wordErrors(ref: it.reference, hyp: hyp)
        let lang = it.language ?? "Unknown"
        totals[lang] = ((totals[lang]?.errors ?? 0) + e.errors, (totals[lang]?.words ?? 0) + e.words)
        print("ITEM \(k + 1)/\(items.count)\t\(lang)\t\(e.errors)/\(e.words)\t\(hyp.prefix(80))")
    }
    for (lang, t) in totals.sorted(by: { $0.key < $1.key }) {
        print(String(format: "### %@ %@: %.1f%% WER (%d words)", kind.rawValue, lang,
                     t.words == 0 ? 0 : Double(t.errors) / Double(t.words) * 100, t.words))
    }
    return 0
}

/// Replays finalize on inputs a run saved with TRANSCRIBERR_DUMP_FINALIZE.
@MainActor
func cmdRefinalize(path: String) -> Int32 {
    let url = URL(fileURLWithPath: NSString(string: path).expandingTildeInPath)
    guard let data = try? Data(contentsOf: url),
          let dump = try? JSONDecoder().decode(FinalizeDump.self, from: data) else {
        print("cannot read finalize dump at \(url.path)"); return 1
    }
    let prompts = PromptStore()
    let runner = TranscriptionRunner(
        factory: BackendFactory(gemma: GemmaSettingsStore(), prompts: prompts, apiKeys: APIKeyStore()),
        prompts: prompts, diarization: DiarizationRunner())
    let voice = ProcessInfo.processInfo.environment["TRANSCRIBERR_NO_VOICE"] == "1" ? nil : dump.voice
    let out = runner.finalizeSegments(
        dump.rawSegments, diarize: dump.diarize, splitTracks: dump.splitTracks,
        expectedSpeakers: dump.expectedSpeakers, diarSegments: dump.diarSegments,
        myName: dump.myName,
        timelines: ProcessInfo.processInfo.environment["TRANSCRIBERR_NO_TIMING"] == "1" ? [:] : dump.timedTimelines,
        // A/B: TRANSCRIBERR_NO_VOICE=1 replays with the loudness timeline instead.
        micSpeech: voice == nil ? dump.micSpeechRanges : nil,
        voice: voice,
        micEcho: dump.micEcho ?? false,
        clusterVoice: ProcessInfo.processInfo.environment["TRANSCRIBERR_NO_VOICE"] == "1" ? nil : dump.clusterVoice,
        sysSound: dump.sysSoundRanges)
    for s in out {
        print(String(format: "%.1f\t%.1f\t", s.startSeconds, s.endSeconds) + "\(s.speakerKey ?? "?")\t\(s.text)")
    }
    return 0
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
        if pipe.modelState != .loaded { try await pipe.loadModels() }
        let hop = window / 2
        var t = 0.0
        while t + window <= Double(samples.count) / 16_000 {
            let a = Int(t * 16_000), b = Int((t + window) * 16_000)
            let slice = Array(samples[a..<b])
            if (WhisperBackend.peakWindowRMS(slice) ?? 0) >= 0.01 {
                guard let tokenizer = pipe.tokenizer else { print("no tokenizer"); return 1 }
                let r = try await WhisperLanguageProbe.detect(pipe: pipe, tokenizer: tokenizer, samples: slice)
                let top = r.probs.sorted { $0.value > $1.value }.prefix(3)
                    .map { "\($0.key) \(String(format: "%.2f", $0.value))" }.joined(separator: ", ")
                let pair = WhisperBackend.pickAllowed(["ar", "en"], probs: r.probs)
                print(String(format: "%6.1f  %@  [%@]  en+ar → %@", t, r.top, top, pair))
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
        let (cleaned, outcome, echoDelay, _) = try await EchoCanceller.cancelGuided(mic: m, ref: r, print: VoiceprintStore.load())
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
        // The file the app would play back, written beside the cleaned
        // track; the recording itself is not touched.
        let mix = MeetingMixRebuilder.playbackMix(cleanedMic: cleaned, outcome: outcome, echoDelay: echoDelay, sys: r)
        if let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false),
           let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(mix.count)) {
            buf.frameLength = AVAudioFrameCount(mix.count)
            mix.withUnsafeBufferPointer { src in buf.floatChannelData![0].update(from: src.baseAddress!, count: mix.count) }
            let outURL = baseURL.deletingPathExtension().appendingPathExtension("mix.wav")
            if let f = try? AVAudioFile(forWriting: outURL, settings: fmt.settings, commonFormat: .pcmFormatFloat32, interleaved: false) {
                try? f.write(from: buf)
                print("[aec] playback mix → \(outURL.lastPathComponent)")
            }
        }
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
        let rest = Array(args.dropFirst(2))
        var path: String?, json = false, language: String?
        var i = 0
        while i < rest.count {
            switch rest[i] {
            case "--json": json = true
            case "--language" where i + 1 < rest.count: i += 1; language = rest[i]
            default: if path == nil { path = rest[i] } else { usage(); return 64 }
            }
            i += 1
        }
        guard let path else { usage(); return 64 }
        return await cmdTranscribe(path: path, json: json, language: language)
    case "diarize":
        guard args.count > 3 else { usage(); return 64 }
        return await cmdDiarize(list: args[2], outDir: args[3], speakers: args.count > 4 ? Int(args[4]) ?? 0 : 0)
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
    case "thinkab":
        guard args.count > 2 else { usage(); return 64 }
        return await cmdThinkAB(out: args[2],
                                titleCount: args.count > 3 ? Int(args[3]) ?? 8 : 8,
                                peopleCount: args.count > 4 ? Int(args[4]) ?? 3 : 3,
                                maxLines: args.count > 5 ? Int(args[5]) ?? 60 : 60)
    case "refinalize":
        guard args.count > 2 else { usage(); return 64 }
        return cmdRefinalize(path: args[2])
    case "run":
        guard args.count > 2 else { usage(); return 64 }
        return await cmdRun(
            path: args[2],
            speakers: args.count > 3 ? Int(args[3]) ?? 0 : 0,
            backend: args.count > 4 ? args[4] : "parakeet-v3",
            engineA: args.count > 5 ? args[5] : nil,
            engineB: args.count > 6 ? args[6] : nil,
            language: args.count > 7 ? args[7] : "English")
    case "bench":
        return await cmdBench(Array(args.dropFirst(2)))
    case "context":
        guard args.count > 2 else { usage(); return 64 }
        return await cmdContext(start: args[2], minutes: args.count > 3 ? Double(args[3]) ?? 30 : 30)
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
    case "voice":
        return await cmdVoice(Array(args.dropFirst(2)))
    case "virtualmic":
        return await cmdVirtualMic(Array(args.dropFirst(2)))
    case "whisperloop":
        return await cmdWhisperLoop(Array(args.dropFirst(2)))
    case "uk-model":
        return await cmdUKModel(args.count > 2 ? args[2] : "status")
    case "help", "-h", "--help":
        usage()
        return 0
    default:
        usage()
        return 64
    }
}

/// Parakeet UK release on this Mac and on Hugging Face. `update` fetches a
/// newer release and switches to it at once, unless the app is running.
func cmdUKModel(_ sub: String) async -> Int32 {
    let installed = ParakeetUKModel.manifest(at: ParakeetUKModel.modelDirectory)
    print("installed: \(ParakeetUKModel.isInstalled() ? ParakeetUKModel.versionName() : "none")"
          + " @ \(installed.map { String($0.revision.prefix(8)) } ?? "no manifest (4.7.0 install)")")
    if let pending = ParakeetUKModel.manifest(at: ParakeetUKModel.pendingDirectory) {
        print("waiting for the next launch: \(ParakeetUKModel.versionName(at: ParakeetUKModel.pendingDirectory)) @ \(pending.revision.prefix(8))")
    }
    do {
        let latest = try await ParakeetUKModel.fetchLatest()
        print("on Hugging Face: \(latest.revision.prefix(8)), \(latest.files.count) files, \(latest.totalBytes / 1_000_000) MB")
    } catch {
        print("Hugging Face: \(error.localizedDescription)"); return 1
    }
    guard sub == "update" else { return 0 }
    let result = await ParakeetUKModel.checkForUpdate()
    print("update check: \(result)")
    // The running app may have the current files open: it switches at its
    // next launch instead.
    if NSRunningApplication.runningApplications(withBundleIdentifier: "nl.ihnatov.Transcriberr").isEmpty {
        ParakeetUKModel.applyPendingUpdate()
    } else {
        print("Transcriberr is running: the new release takes over at its next launch")
    }
    let now = ParakeetUKModel.manifest(at: ParakeetUKModel.modelDirectory)
    print("now: \(ParakeetUKModel.versionName()) @ \(now.map { String($0.revision.prefix(8)) } ?? "no manifest")")
    if case .failed = result { return 1 }
    return 0
}

let exitCode = await main()
// Backup writes are queued off-thread; exit() would drop any still pending.
BackupService.flush()
exit(exitCode)
