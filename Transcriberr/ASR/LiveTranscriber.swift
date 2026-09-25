import Foundation

/// Anything that emits the recorder's 5-second 16 kHz chunk feed. Lets the
/// live worker consume the mic recorder OR the meeting recorder unchanged.
protocol LiveChunkSource: AnyObject {
    var chunks: AsyncStream<WavRecorder.Chunk> { get }
}
extension WavRecorder: LiveChunkSource {}
extension MeetingRecorder: LiveChunkSource {}
import Observation

/// Streaming Gemma 4 over the recorder's 5-second chunk feed.
/// Mirror of `asr/LiveTranscriber.kt`. Mutex (`actor`) serializes calls so
/// a parallel file-transcribe job and the live worker can share one engine.
/// `@MainActor`: `status` and `lines` are `@Observable` state SwiftUI reads
/// on the main thread, and `start`/`stop` are nonisolated `async` methods —
/// which, per SE-0338, run on the cooperative pool even when a view calls
/// them. So `status` was being written off-main while `lines` was written
/// on it. Every heavy step in here is an `await` into an actor or a task,
/// so the isolation costs nothing.
@Observable
@MainActor
final class LiveTranscriber: @unchecked Sendable {
    struct LiveLine: Sendable, Identifiable {
        let id = UUID()
        let startSeconds: Double
        let text: String
    }

    enum Status: Sendable, Equatable {
        case idle
        case loading
        case running
        case modelMissing(backend: String)
        case failed(reason: String)
    }

    private(set) var status: Status = .idle
    private(set) var lines: [LiveLine] = []

    private let factory: BackendFactory
    private weak var source: (any LiveChunkSource)?
    private var consumer: Task<Void, Never>?
    /// Bumped by every start/stop, so a `start()` that was suspended in a
    /// model load — or a chunk still in flight — can tell its session has
    /// been superseded.
    private var startToken = 0

    /// Read per chunk, not captured at start: switching the language on the
    /// Record screen mid-recording has to reach the very next live chunk.
    var languages: Set<String> = []
    var translateTo: String?

    init(factory: BackendFactory, recorder: any LiveChunkSource) {
        self.factory = factory
        self.source = recorder
    }

    func start(
        engine: BackendFactory.Kind,
        languages: Set<String>,
        translateTo: String?,
        modelDirectory: URL?
    ) async {
        await stop()
        // A new session starts with an empty caption list.
        lines.removeAll()
        self.languages = languages
        self.translateTo = translateTo
        let token = startToken
        status = .loading
        let backend = factory.backend(for: engine)
        do {
            try await backend.load(modelPath: modelDirectory)
        } catch {
            if token == startToken { status = .failed(reason: error.localizedDescription) }
            return
        }
        // Stopped (or restarted) while the model was loading.
        guard token == startToken else { return }
        // No recorder attached (or it went away): `.running` with no
        // consumer would claim captions that can never arrive.
        guard let source else {
            status = .failed(reason: "no audio source")
            return
        }
        status = .running
        let chunkStream = source.chunks
        consumer = Task { @MainActor [weak self] in
            for await chunk in chunkStream {
                guard let self else { break }
                if Task.isCancelled { break }
                await self.handleChunk(chunk, backend: backend, session: token,
                                       languages: self.languages, translateTo: self.translateTo)
            }
        }
    }

    func stop() async {
        startToken &+= 1
        consumer?.cancel()
        consumer = nil
        if status == .running || status == .loading {
            status = .idle
        }
    }

    func clear() {
        lines.removeAll()
    }

    /// Energy stats for a chunk: RMS and peak, both as linear amplitude (0…1)
    /// and dB. Used by the voice-activity gate below.
    private static func energy(_ samples: [Float]) -> (rms: Float, peak: Float) {
        guard !samples.isEmpty else { return (0, 0) }
        var sumSq: Float = 0
        var peak: Float = 0
        for s in samples {
            let a = s < 0 ? -s : s
            sumSq += s * s
            if a > peak { peak = a }
        }
        return ((sumSq / Float(samples.count)).squareRoot(), peak)
    }

    /// Voice-activity gate. Gemma's audio tower hallucinates confident,
    /// plausible speech ("안녕하세요. 저는 김원아입니다." etc.) when handed silence or
    /// room tone. We refuse to transcribe a chunk that doesn't clear a basic
    /// energy floor, so quiet gaps between sentences don't spawn invented text.
    ///
    /// Deliberately CONSERVATIVE: it gates on peak, which for real speech sits
    /// far above the RMS level meter (transients hit -20…-6 dB even when the
    /// smoothed RMS reads -50 dB). True silence/room tone rarely peaks above
    /// -34 dB. Tune from the per-chunk log lines below if needed.
    private static func hasSpeech(rms: Float, peak: Float) -> Bool {
        // peak > ~-34 dB and rms > ~-52 dB.
        return peak > 0.02 && rms > 0.0025
    }

    private func handleChunk(
        _ chunk: WavRecorder.Chunk,
        backend: ASRBackend,
        session: Int,
        languages: Set<String>,
        translateTo: String?
    ) async {
        // Skip silence/near-silence outright — see hasSpeech().
        let (rms, peak) = Self.energy(chunk.samples)
        let rmsDb = 20 * log10(max(1e-5, rms))
        let peakDb = 20 * log10(max(1e-5, peak))
        let voiced = Self.hasSpeech(rms: rms, peak: peak)
        AppLog.info("live", String(format: "chunk @%.1fs rms=%.1fdB peak=%.1fdB → %@",
                                    chunk.startTimeSeconds, rmsDb, peakDb,
                                    voiced ? "transcribe" : "skip(silence)"))
        guard voiced else { return }
        do {
            let text = try await backend.transcribeChunk(
                samples: chunk.samples,
                languages: languages,
                translateTo: translateTo,
                diarize: false,
                previousContext: nil,
                speakerHints: []
            )
            // Stopped or restarted while this chunk was in flight: its text
            // belongs to a session that is gone.
            guard session == startToken else { return }
            let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleaned.isEmpty else { return }
            lines.append(LiveLine(startSeconds: chunk.startTimeSeconds, text: cleaned))
        } catch {
            // Cancellation is Stop doing its job, not a failed chunk.
            if error is CancellationError || Task.isCancelled || session != startToken { return }
            // Keep the worker alive across single-chunk failures so a transient
            // hiccup doesn't kill the live session.
            lines.append(LiveLine(
                startSeconds: chunk.startTimeSeconds,
                text: "[chunk failed: \(error.localizedDescription)]"
            ))
        }
    }
}


extension LiveTranscriber {
    /// Point the live worker at the recorder that is about to start.
    func attach(_ newSource: any LiveChunkSource) { source = newSource }
}
