import Foundation

// transcriberrcli voice enroll <audio> [--me <meeting.m4a>] [--out <print.json>]
// transcriberrcli voice score <meeting.m4a> [--print <print.json>] [--csv <out.csv>]
// transcriberrcli voice show
//
// Enroll from any audio file (or, with --me, from a meeting's mic track
// where its me.json says the user spoke — calibration without a new
// recording). Score a split-track meeting's echo-cancelled mic and its
// system track against the print, and compare with me.json.

@MainActor
func cmdVoice(_ args: [String]) async -> Int32 {
    func opt(_ name: String) -> String? {
        guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
        return args[i + 1]
    }
    let decoder = AudioDecoder()
    switch args.first {
    case "show":
        guard let p = VoiceprintStore.load() else { print("[voice] no voice print enrolled"); return 1 }
        print("[voice] \(p.model), \(p.embeddings.count) windows, \(Int(p.seconds)) s voiced, self-similarity \(String(format: "%.2f", p.selfSimilarity)), made \(p.created)")
        return 0

    case "enroll":
        guard args.count > 1 else { print("usage: voice enroll <audio> [--me <meeting.m4a>] [--out <print.json>]"); return 64 }
        do {
            var samples: [Float]
            if let meeting = opt("--me") {
                let url = URL(fileURLWithPath: meeting)
                guard let mic = AudioCompressor.sidecarURL(for: url, kind: "mic"),
                      let me = TranscriptionRunner.micSpeech(for: url) else {
                    print("[voice] \(meeting) has no mic track or me.json"); return 1
                }
                let raw = try await decoder.decodeAll(file: mic)
                // The longest me.json stretches until ~45 s: the clearest solo speech.
                var picked: [Float] = []
                for r in me.sorted(by: { $0.upperBound - $0.lowerBound > $1.upperBound - $1.lowerBound }) {
                    let a = Int(r.lowerBound * 16_000), b = min(raw.count, Int(r.upperBound * 16_000))
                    guard b - a > 16_000 else { continue }
                    picked += raw[a..<b]
                    if picked.count > 45 * 16_000 { break }
                }
                samples = picked
            } else {
                samples = try await decoder.decodeAll(file: URL(fileURLWithPath: args[1]))
            }
            print("[voice] enrolling from \(String(format: "%.1f", Double(samples.count) / 16_000)) s…")
            let t0 = Date()
            let p = try await VoiceEmbedder.shared.enroll(samples)
            print("[voice] \(p.embeddings.count) windows in \(String(format: "%.1f", Date().timeIntervalSince(t0))) s, self-similarity \(String(format: "%.2f", p.selfSimilarity))")
            if let out = opt("--out") {
                try JSONEncoder().encode(p).write(to: URL(fileURLWithPath: out))
                print("[voice] print → \(out)")
            } else {
                try VoiceprintStore.save(p, audio: samples)
                print("[voice] print → \(VoiceprintStore.printURL.path)")
            }
            return 0
        } catch {
            print("[voice] ❌ \(error.localizedDescription)"); return 1
        }

    case "score":
        guard args.count > 1 else { print("usage: voice score <meeting.m4a> [--print <print.json>] [--csv <out.csv>]"); return 64 }
        let url = URL(fileURLWithPath: args[1])
        let vp: Voiceprint?
        if let path = opt("--print") {
            vp = (try? Data(contentsOf: URL(fileURLWithPath: path))).flatMap { try? JSONDecoder().decode(Voiceprint.self, from: $0) }
        } else {
            vp = VoiceprintStore.load()
        }
        guard let vp else { print("[voice] no voice print"); return 1 }
        guard let micURL = AudioCompressor.sidecarURL(for: url, kind: "mic"),
              let sysURL = AudioCompressor.sidecarURL(for: url, kind: "sys") else {
            // One track: the whole file's scores, for comparing with a transcript.
            do {
                let samples = try await decoder.decodeAll(file: url)
                let s = try await VoiceEmbedder.shared.scores(samples, against: vp)
                let csv = opt("--csv") ?? "/dev/stdout"
                let lines = ["t,score"] + s.enumerated().map { i, v in
                    "\(Double(i) * VoiceActivity.hop),\(v.map { String(format: "%.3f", $0) } ?? "")"
                }
                try lines.joined(separator: "\n").write(toFile: csv, atomically: false, encoding: .utf8)
                return 0
            } catch {
                print("[voice] ❌ \(error.localizedDescription)"); return 1
            }
        }
        do {
            let raw = try await decoder.decodeAll(file: micURL)
            let sys = try await decoder.decodeAll(file: sysURL)
            let aec = EchoCanceller.cancelDetailed(mic: raw, ref: sys)
            print("[voice] AEC \(aec.outcome), mic echo \(String(format: "%.1f", aec.micEchoDB)) dB")
            let t0 = Date()
            let micScores = try await VoiceEmbedder.shared.scores(aec.samples, against: vp)
            let t1 = Date()
            let sysScores = try await VoiceEmbedder.shared.scores(sys, against: vp)
            print("[voice] scored \(Int(Double(raw.count) / 16_000)) s: mic \(String(format: "%.1f", t1.timeIntervalSince(t0))) s, sys \(String(format: "%.1f", Date().timeIntervalSince(t1))) s")
            let me = TranscriptionRunner.micSpeech(for: url) ?? []
            func summary(_ name: String, _ s: [Float?]) {
                let v = s.compactMap { $0 }.sorted()
                guard !v.isEmpty else { print("  \(name): silent"); return }
                func p(_ q: Double) -> String { String(format: "%.2f", v[min(v.count - 1, Int(Double(v.count) * q))]) }
                let ivs = VoiceActivity.intervals(s)
                let secs = ivs.reduce(0) { $0 + $1.upperBound - $1.lowerBound }
                print("  \(name): voiced \(v.count / 2) s, score p10 \(p(0.1)) p50 \(p(0.5)) p90 \(p(0.9)); user \(Int(secs)) s in \(ivs.count) stretches")
                if !me.isEmpty {
                    var inMe: [Float] = [], outMe: [Float] = []
                    for (i, x) in s.enumerated() {
                        guard let x else { continue }
                        let t = (Double(i) + 0.5) * VoiceActivity.hop
                        if me.contains(where: { $0.contains(t) }) { inMe.append(x) } else { outMe.append(x) }
                    }
                    func med(_ a: [Float]) -> String { a.isEmpty ? "—" : String(format: "%.2f", a.sorted()[a.count / 2]) }
                    print("    inside me.json: \(inMe.count / 2) s, median \(med(inMe)); outside: \(outMe.count / 2) s, median \(med(outMe))")
                }
            }
            summary("mic", micScores)
            summary("sys", sysScores)
            if let csv = opt("--csv") {
                var lines = ["t,mic,sys,me"]
                for i in 0..<max(micScores.count, sysScores.count) {
                    let t = Double(i) * VoiceActivity.hop
                    let m = i < micScores.count ? micScores[i].map { String(format: "%.3f", $0) } ?? "" : ""
                    let s = i < sysScores.count ? sysScores[i].map { String(format: "%.3f", $0) } ?? "" : ""
                    let inMe = me.contains { $0.contains(t + 0.25) } ? "1" : "0"
                    lines.append("\(t),\(m),\(s),\(inMe)")
                }
                try lines.joined(separator: "\n").write(toFile: csv, atomically: true, encoding: .utf8)
                print("[voice] scores → \(csv)")
            }
            return 0
        } catch {
            print("[voice] ❌ \(error.localizedDescription)"); return 1
        }

    case "bench":
        return await cmdVoiceBench(args[1])
    default:
        print("usage: voice enroll|score|show …")
        return 64
    }
}

// Batched slots must embed exactly as FluidAudio's single-slot helper does
// (the thresholds were calibrated on it), and how fast.
import FluidAudio
func cmdVoiceBench(_ path: String) async -> Int32 {
    guard let samples = try? await AudioDecoder().decodeAll(file: URL(fileURLWithPath: path)),
          samples.count > 30 * 16_000,
          let models = try? await DiarizerModels.downloadIfNeeded() else { print("[voice] bench: no audio/models"); return 1 }
    let ref = DiarizerManager()
    ref.initialize(models: models)
    let clips = (0..<7).map { samples[($0 * 32_000)..<($0 * 32_000 + 24_000)] }
    do {
        let mine = try await VoiceEmbedder.shared.embed(clips)
        var worst: Float = 1
        for (c, e) in zip(clips, mine) {
            worst = min(worst, VoiceActivity.cosine(try ref.extractSpeakerEmbedding(from: Array(c)), e))
        }
        for c in clips.prefix(3) {
            let solo = try await VoiceEmbedder.shared.embed([c])[0]
            print("  solo vs helper \(VoiceActivity.cosine(try ref.extractSpeakerEmbedding(from: Array(c)), solo))")
        }
        for (k, (c, e)) in zip(clips, mine).enumerated() {
            print("  slot \(k % 3) vs helper \(VoiceActivity.cosine(try ref.extractSpeakerEmbedding(from: Array(c)), e))")
        }
        print("[voice] batched vs helper: lowest cosine \(String(format: "%.4f", worst)) over \(clips.count) clips")
        let many = (0..<600).map { i -> ArraySlice<Float> in let a = (i * 8000) % (samples.count - 24_000); return samples[a..<(a + 24_000)] }
        let t0 = Date()
        _ = try await VoiceEmbedder.shared.embed(many)
        print("[voice] \(String(format: "%.1f", Date().timeIntervalSince(t0) / 600 * 1000)) ms/window")
        return 0
    } catch {
        print("[voice] ❌ \(error)"); return 1
    }
}

// whisperloop <meeting.m4a> <seconds> <model-id> [fallbacks]
// Diagnostic: decode the system-track chunk containing <seconds>, cut as
// the app cuts it, with the app's Whisper options; print per-segment
// repetition (compression ratio), confidence and the temperature used.
import WhisperKit
@MainActor
func cmdWhisperLoop(_ args: [String]) async -> Int32 {
    guard args.count >= 3, let at = Double(args[1]) else { print("usage: whisperloop <meeting.m4a> <seconds> <model-id> [fallbacks]"); return 64 }
    let url = URL(fileURLWithPath: args[0])
    guard let sys = AudioCompressor.sidecarURL(for: url, kind: "sys") else { print("no sys track"); return 1 }
    let decoder = AudioDecoder()
    do {
        let samples = try await decoder.decodeAll(file: sys)
        let pipe = try await WhisperKit(WhisperKitConfig(model: args[2], verbose: false, prewarm: true))
        if at < 0 {
            // Every chunk of both tracks: how often does the first, greedy
            // attempt fail, and how confident is what is kept?
            var tracks = [("sys", samples)]
            if let mic = AudioCompressor.sidecarURL(for: url, kind: "mic") { tracks.append(("mic", try await decoder.decodeAll(file: mic))) }
            for (name, track) in tracks {
                for c in decoder.chunk(samples: track).chunks {
                    var o = DecodingOptions()
                    o.task = .transcribe; o.temperature = 0; o.temperatureFallbackCount = 2
                    o.wordTimestamps = true; o.language = "en"
                    o.withoutTimestamps = ProcessInfo.processInfo.environment["WL_NOTS"] != nil
                    let r = try await pipe.transcribe(audioArray: c.samples, decodeOptions: o)
                    let segs = r.flatMap(\.segments)
                    let text = r.map(\.text).joined(separator: " ")
                    let fb = r.map(\.timings.totalDecodingFallbacks).reduce(0, +)
                    let lp = segs.isEmpty ? 0 : segs.map(\.avgLogprob).reduce(0, +) / Float(segs.count)
                    let rms = VoiceActivity.rms(c.samples[...])
                    print(String(format: "%@ %6.1f fb %.0f temp %.1f logp %5.2f rms %.3f chars %4d", name, c.startSeconds, fb, segs.last?.temperature ?? 0, lp, rms, text.count))
                }
            }
            return 0
        }
        guard let chunk = decoder.chunk(samples: samples).chunks.first(where: { $0.startSeconds <= at && at < $0.endSeconds }) else { print("no chunk"); return 1 }
        print(String(format: "chunk %.1f-%.1f s, model %@", chunk.startSeconds, chunk.endSeconds, args[2]))
        for fallbacks in [args.count > 3 ? Int(args[3]) ?? 2 : 2] {
            var o = DecodingOptions()
            o.task = .transcribe
            o.temperature = 0
            o.temperatureFallbackCount = fallbacks
            o.wordTimestamps = ProcessInfo.processInfo.environment["WL_NOWORDTS"] == nil
            o.withoutTimestamps = ProcessInfo.processInfo.environment["WL_NOTS"] != nil
            o.language = ProcessInfo.processInfo.environment["WL_AUTOLANG"] == nil ? "en" : nil
            let results = try await pipe.transcribe(audioArray: chunk.samples, decodeOptions: o)
            for r in results {
                print("fallbacks allowed \(fallbacks): \(r.timings.totalDecodingFallbacks) used")
                for s in r.segments {
                    print(String(format: "  [%.1f-%.1f] temp %.1f cr %.2f logp %.2f nosp %.2f | %@", s.start, s.end, s.temperature, s.compressionRatio, s.avgLogprob, s.noSpeechProb, String(s.text.prefix(120))))
                }
            }
        }
        return 0
    } catch {
        print("❌ \(error)"); return 1
    }
}
