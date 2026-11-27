import Foundation
import AVFoundation

/// The live check behind `transcriberrcli meetingmove` and the app's
/// `TRANSCRIBERR_SELFTEST=meetingmove` launch: a real meeting capture (mic +
/// call audio, nothing played) whose microphone is lost halfway, through the
/// same move a real removal takes. It passes when the recording carried on
/// into the same files. The files are deleted afterwards: they are not in
/// the library. The app run exists because a shell may not hold the System
/// Audio Recording permission, and without it no audio arrives at all.
@MainActor
enum MeetingMoveCheck {

    struct Outcome {
        var ok: Bool
        var lines: [String]
    }

    static func run(seconds: Double, onNote: @escaping @MainActor (String) -> Void = { _ in }) async -> Outcome {
        var lines: [String] = []
        func say(_ s: String) { lines.append(s); AppLog.info("meetingmove", s) }
        let rec = MeetingRecorder()
        rec.plainCapture = true
        // Never the Recordings folder: a file left by a killed run would be
        // imported into the library by the next launch's crash repair.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("transcriberr-meetingmove-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        rec.recordingsDirectory = dir
        defer { try? FileManager.default.removeItem(at: dir) }
        var notes: [String] = []
        var simulated = false
        var interrupted: String?
        // Only notes after the loss count: a move at start is not the one
        // being checked.
        rec.onMicMoved = { note in
            if simulated { notes.append(note) }
            onNote(note)
        }
        rec.onInterrupted = { interrupted = $0 }
        do { try await rec.start() } catch {
            say("start failed: \(error.localizedDescription)")
            return Outcome(ok: false, lines: lines)
        }
        let startedOn = rec.currentMicrophoneUID
        say("recording on \(startedOn ?? "?") for \(Int(seconds)) s, mic lost at \(Int(seconds / 2)) s")
        let t0 = Date()
        var noAudio = false
        while Date().timeIntervalSince(t0) < seconds {
            if !simulated, Date().timeIntervalSince(t0) >= seconds / 2 {
                simulated = true
                say("\(rec.elapsedMs) ms captured before the loss")
                if rec.elapsedMs == 0 { noAudio = true; break }
                rec.simulateMicLoss()
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        let endedOn = rec.currentMicrophoneUID
        guard let url = try? await rec.stop() else {
            say("stop returned no file")
            return Outcome(ok: false, lines: lines)
        }
        let base = url.deletingPathExtension()
        if noAudio {
            say("FAIL: no audio reached the recorder at all, before any move: this process lacks System Audio Recording permission (Privacy & Security → Screen & System Audio Recording)")
            return Outcome(ok: false, lines: lines)
        }
        let lengths = ["wav", "mic.wav", "sys.wav"].map { duration(base.appendingPathExtension($0)) }
        say("mix \(String(format: "%.2f", lengths[0])) s · mic \(String(format: "%.2f", lengths[1])) s · call \(String(format: "%.2f", lengths[2])) s")
        say("started on \(startedOn ?? "nothing") · ended on \(endedOn ?? "the call audio alone")")
        for n in notes { say("note: \(n)") }
        var ok = true
        if let interrupted { say("FAIL: the recording ended: \(interrupted)"); ok = false }
        if notes.isEmpty { say("FAIL: no move was announced after the loss"); ok = false }
        // The lost mic is left alone (cooling down), so the recording must
        // end on another mic, or on the call audio alone.
        if endedOn == startedOn { say("FAIL: the recording is still on the mic it lost"); ok = false }
        // Everything but the rebuild gap: a recording that stopped at the
        // loss would hold about half.
        if lengths[0] < seconds * 0.85 {
            say("FAIL: the mix holds \(String(format: "%.1f", lengths[0])) of \(Int(seconds)) s"); ok = false
        }
        if abs(lengths[1] - lengths[2]) > 0.1 || abs(lengths[0] - lengths[1]) > 0.1 {
            say("FAIL: the tracks are out of step"); ok = false
        }
        say(ok ? "PASS: the recording carried on into the same files" : "FAILED")
        return Outcome(ok: ok, lines: lines)
    }

    private static func duration(_ url: URL) -> Double {
        guard let f = try? AVAudioFile(forReading: url) else { return 0 }
        return Double(f.length) / f.processingFormat.sampleRate
    }
}
