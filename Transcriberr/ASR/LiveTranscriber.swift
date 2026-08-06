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
@Observable
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
        status = .loading
        let backend = factory.backend(for: engine)
        do {
            try await backend.load(modelPath: modelDirectory)
        } catch {
            status = .failed(reason: error.localizedDescription)
            return
        }
        status = .running
        guard let source else { return }
        let chunkStream = source.chunks
        consumer = Task { @MainActor [weak self] in
            for await chunk in chunkStream {
                guard let self else { break }
                if Task.isCancelled { break }
                await self.handleChunk(chunk, backend: backend, languages: languages, translateTo: translateTo)
            }
        }
    }

    func stop() async {
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
            let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleaned.isEmpty else { return }
            lines.append(LiveLine(startSeconds: chunk.startTimeSeconds, text: cleaned))
        } catch {
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
