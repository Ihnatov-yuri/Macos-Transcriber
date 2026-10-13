import Foundation

/// Anything that emits the recorder's one-second 16 kHz chunk feed. Lets the
/// live worker consume the mic recorder OR the meeting recorder unchanged.
protocol LiveChunkSource: AnyObject {
    var chunks: AsyncStream<WavRecorder.Chunk> { get }
}
extension WavRecorder: LiveChunkSource {}
extension MeetingRecorder: LiveChunkSource {}
import Observation

/// Live captions over the recorder's one-second chunk feed, phrase by phrase.
///
/// Audio collects into the open phrase. A pause in speech (or 15 s without
/// one) closes it: the phrase is read once more and becomes a line. With a
/// fast engine (Parakeet on the Neural Engine, ~100× real time) the open
/// phrase is also re-read about once a second and shown as `partial`, so
/// words appear while they are being said.
///
/// Until v3.15.10 every hard-cut 5-second chunk was read on its own and only
/// the newest was shown: words split at every cut, and the screen held one
/// fragment at a time.
///
/// `@MainActor`: `status`, `lines` and `partial` are `@Observable` state
/// SwiftUI reads on the main thread. Every heavy step is an `await` into the
/// engine's actor, so the isolation costs nothing.
@Observable
@MainActor
final class LiveTranscriber: @unchecked Sendable {
    struct LiveLine: Sendable, Identifiable {
        let id = UUID()
        let startSeconds: Double
        let endSeconds: Double
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
    /// Finished phrases, oldest first.
    private(set) var lines: [LiveLine] = []
    /// The phrase still being spoken, as last read; nil between phrases.
    private(set) var partial: LiveLine?

    private let factory: BackendFactory
    private weak var source: (any LiveChunkSource)?
    private var consumer: Task<Void, Never>?
    /// Bumped by every start/stop, so a `start()` that was suspended in a
    /// model load — or a read still in flight — can tell its session has
    /// been superseded.
    private var startToken = 0

    /// Read per phrase, not captured at start: switching the language on the
    /// Record screen mid-recording has to reach the very next read.
    var languages: Set<String> = []
    var translateTo: String?

    // MARK: - Phrase state

    private var backend: ASRBackend?
    /// Re-read the open phrase as it grows (fast local engines only).
    private var streamsPartials = false
    /// Audio of the open phrase, 16 kHz mono.
    private var pending: [Float] = []
    private var pendingStart: Double = 0
    /// `pending.count` at the last partial read.
    private var lastPartialRead = 0
    /// A read loop is running; new audio only has to be appended.
    private var reading = false

    nonisolated static let sampleRate = 16_000
    /// 20 ms analysis frames for the pause finder.
    nonisolated static let frameSamples = 320
    /// A pause at least this long closes a phrase…
    nonisolated static let minPauseSeconds = 0.45
    /// …once the phrase holds at least this much audio.
    nonisolated static let minPhraseSeconds = 1.5
    /// No pause by now: close at the quietest moment of the last few seconds.
    nonisolated static let maxPhraseSeconds = 15.0
    /// New audio needed before the open phrase is re-read.
    nonisolated static let partialStepSeconds = 0.9
    /// How long a read may wait for the inference gate (Gemma running for a
    /// background job) before this pass is skipped and retried later.
    nonisolated static let gatePatience: TimeInterval = 3

    init(factory: BackendFactory, recorder: any LiveChunkSource) {
        self.factory = factory
        self.source = recorder
    }

    /// `resetCaptions: false` keeps what is on screen — an engine switch or
    /// Live turned back on mid-recording carries on below the earlier text.
    func start(
        engine: BackendFactory.Kind,
        languages: Set<String>,
        translateTo: String?,
        modelDirectory: URL?,
        resetCaptions: Bool = true
    ) async {
        await stop()
        if resetCaptions { clear() }
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
        self.backend = backend
        streamsPartials = engine == .parakeet || engine == .parakeetV2
        status = .running
        AppLog.info("live", "started · \(engine.rawValue) · \(streamsPartials ? "streaming" : "phrase by phrase")")
        let chunkStream = source.chunks
        consumer = Task { @MainActor [weak self] in
            for await chunk in chunkStream {
                guard let self else { break }
                if Task.isCancelled { break }
                self.append(chunk, session: token)
            }
        }
    }

    func stop() async {
        startToken &+= 1
        consumer?.cancel()
        consumer = nil
        backend = nil
        // The open phrase is dropped with its audio; its last reading stays
        // on screen until the next session clears it.
        pending.removeAll()
        lastPartialRead = 0
        if status == .running || status == .loading {
            status = .idle
        }
    }

    func clear() {
        lines.removeAll()
        partial = nil
    }

    // MARK: - Audio in

    private func append(_ chunk: WavRecorder.Chunk, session: Int) {
        guard session == startToken else { return }
        if pending.isEmpty { pendingStart = chunk.startTimeSeconds }
        pending.append(contentsOf: chunk.samples)
        guard !reading else { return }
        reading = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            while session == self.startToken, await self.step(session: session) {}
            self.reading = false
        }
    }

    /// One unit of work on the open phrase. Returns false when there is
    /// nothing more to do until new audio arrives.
    private func step(session: Int) async -> Bool {
        guard let backend, !pending.isEmpty else { return false }
        let sr = Double(Self.sampleRate)
        let frames = Self.frameRMS(pending)

        // Room tone only: let it go rather than reading it.
        if !Self.hasSpeech(frames) {
            if Double(pending.count) / sr >= 2 {
                pendingStart += Double(pending.count) / sr
                pending.removeAll()
                lastPartialRead = 0
                partial = nil
            }
            return false
        }

        if let cut = Self.phraseEnd(frames: frames, sampleCount: pending.count) {
            let phrase = Array(pending.prefix(cut))
            let start = pendingStart
            pending.removeFirst(cut)
            pendingStart += Double(cut) / sr
            lastPartialRead = 0
            let end = start + Double(cut) / sr
            switch await read(phrase, backend: backend, session: session) {
            case .text(let text):
                lines.append(LiveLine(startSeconds: start, endSeconds: end, text: text))
                partial = nil
                AppLog.info("live", String(format: "line @%.1fs %.1fs → %d chars", start, end - start, text.count))
            case .silent:
                partial = nil
            case .busy:
                // Put it back: the next chunk retries with the gate free.
                pending.insert(contentsOf: phrase, at: 0)
                pendingStart = start
                return false
            case .gone:
                return false
            }
            return true
        }

        guard streamsPartials,
              Double(pending.count - lastPartialRead) / sr >= Self.partialStepSeconds
        else { return false }
        lastPartialRead = pending.count
        let snapshot = pending
        let start = pendingStart
        let result = await read(snapshot, backend: backend, session: session)
        // A phrase closed while this read was out: it is a line by now.
        guard start == pendingStart else { return true }
        if case .text(let text) = result {
            partial = LiveLine(startSeconds: start, endSeconds: start + Double(snapshot.count) / sr, text: text)
        }
        return true
    }

    private enum ReadResult { case text(String), silent, busy, gone }

    private func read(_ samples: [Float], backend: ASRBackend, session: Int) async -> ReadResult {
        do {
            // Interactive with bounded patience, as dictation does: a Gemma
            // call from a background job must not leave captions minutes
            // behind (see InferenceGate).
            let text = try await InferenceGate.$interactive.withValue(true) {
                try await InferenceGate.$patience.withValue(Self.gatePatience) {
                    try await ParakeetBackend.$logsChunks.withValue(false) {
                        try await backend.transcribeChunk(
                            samples: samples,
                            languages: languages,
                            translateTo: translateTo,
                            diarize: false,
                            previousContext: nil,
                            speakerHints: []
                        )
                    }
                }
            }
            // Stopped or restarted while this read was in flight: its text
            // belongs to a session that is gone.
            guard session == startToken else { return .gone }
            let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return cleaned.isEmpty ? .silent : .text(cleaned)
        } catch is InferenceGate.Busy {
            AppLog.info("live", "engines busy — retrying with the next audio")
            return session == startToken ? .busy : .gone
        } catch {
            // Cancellation is Stop doing its job, not a failed read.
            if error is CancellationError || session != startToken { return .gone }
            // One failed read must not end the session.
            AppLog.warn("live", "read failed: \(error.localizedDescription)")
            return .silent
        }
    }

    // MARK: - Phrase finding (pure, tested)

    /// RMS of each 20 ms frame.
    nonisolated static func frameRMS(_ samples: [Float]) -> [Float] {
        let n = samples.count / frameSamples
        var out = [Float](repeating: 0, count: n)
        samples.withUnsafeBufferPointer { p in
            for f in 0..<n {
                var sum: Float = 0
                let base = f * frameSamples
                for i in base..<(base + frameSamples) { sum += p[i] * p[i] }
                out[f] = (sum / Float(frameSamples)).squareRoot()
            }
        }
        return out
    }

    /// Below this a frame counts as a pause: three times the quietest tenth
    /// of the phrase (its room tone), kept inside -50…-34 dB.
    nonisolated static func pauseThreshold(_ frames: [Float]) -> Float {
        guard !frames.isEmpty else { return 0.003 }
        let floor = frames.sorted()[frames.count / 10]
        return min(0.02, max(0.003, floor * 3))
    }

    /// Voice-activity floor. Silence and room tone must not reach an engine:
    /// Gemma's audio tower invents confident speech from them, and Parakeet
    /// returns stray words.
    nonisolated static func hasSpeech(_ frames: [Float]) -> Bool {
        // ~-34 dB peak frame and ~-52 dB overall.
        guard let peak = frames.max(), peak > 0.02 else { return false }
        var sumSq: Float = 0
        for f in frames { sumSq += f * f }
        return (sumSq / Float(frames.count)).squareRoot() > 0.0025
    }

    /// Where the open phrase ends, in samples, or nil while it is still
    /// going. The first pause of `minPauseSeconds` that follows at least
    /// `minPhraseSeconds` of audio closes it, cut in the middle of the
    /// pause. Past `maxPhraseSeconds` the quietest frame of the last few
    /// seconds closes it instead.
    nonisolated static func phraseEnd(frames: [Float], sampleCount: Int) -> Int? {
        let frameSeconds = Double(frameSamples) / Double(sampleRate)
        let minPause = Int((minPauseSeconds / frameSeconds).rounded(.up))
        let minPhrase = Int(minPhraseSeconds / frameSeconds)
        let threshold = pauseThreshold(frames)
        var runStart: Int?
        for (i, rms) in frames.enumerated() {
            if rms < threshold {
                if runStart == nil { runStart = i }
                if let s = runStart, i - s + 1 >= minPause, s >= minPhrase {
                    return (s + minPause / 2) * frameSamples
                }
            } else {
                runStart = nil
            }
        }
        let maxPhrase = Int(maxPhraseSeconds / frameSeconds)
        guard frames.count >= maxPhrase else { return nil }
        // Quietest frame between 10 s in and the last 0.3 s.
        let lo = Int(10 / frameSeconds)
        let hi = frames.count - Int(0.3 / frameSeconds)
        guard hi > lo else { return min(sampleCount, maxPhrase * frameSamples) }
        var best = lo
        for i in lo..<hi where frames[i] < frames[best] { best = i }
        return (best + 1) * frameSamples
    }
}


extension LiveTranscriber {
    /// Point the live worker at the recorder that is about to start.
    func attach(_ newSource: any LiveChunkSource) { source = newSource }
}
