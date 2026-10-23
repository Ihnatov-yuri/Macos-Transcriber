import os
import Foundation

/// Anything that emits the recorder's one-second 16 kHz chunk feed. Lets the
/// live worker consume the mic recorder OR the meeting recorder unchanged.
protocol LiveChunkSource: AnyObject {
    /// A new stream of the chunks from now on, for this subscriber alone.
    func subscribeChunks() -> AsyncStream<WavRecorder.Chunk>
}
extension WavRecorder: LiveChunkSource {
    func subscribeChunks() -> AsyncStream<WavRecorder.Chunk> { liveFeed.subscribe() }
}
extension MeetingRecorder: LiveChunkSource {
    func subscribeChunks() -> AsyncStream<WavRecorder.Chunk> { liveFeed.subscribe() }
}

/// Fans a recorder's live chunks out, one `AsyncStream` per subscriber.
///
/// Until v3.16.1 each recorder had ONE stream for the whole recording, and
/// cancelling the task that iterates an `AsyncStream` terminates the stream.
/// So switching Live off mid-recording killed the feed for good: switched
/// back on, live listened to a dead stream and never showed another word.
/// Now stopping live ends only its own subscription.
///
/// Thread-safe: chunks are yielded on the recorder's IO queue, subscriptions
/// come from the main actor, terminations from anywhere.
final class LiveChunkFeed: @unchecked Sendable {
    private let lock = NSLock()
    private var subscribers: [Int: AsyncStream<WavRecorder.Chunk>.Continuation] = [:]
    private var nextId = 0
    private let backlog: Int

    init(backlog: Int) { self.backlog = backlog }

    func subscribe() -> AsyncStream<WavRecorder.Chunk> {
        var continuation: AsyncStream<WavRecorder.Chunk>.Continuation!
        let stream = AsyncStream<WavRecorder.Chunk>(bufferingPolicy: .bufferingNewest(backlog)) { continuation = $0 }
        let id: Int = lock.withLock {
            nextId += 1
            subscribers[nextId] = continuation
            return nextId
        }
        continuation.onTermination = { [weak self] _ in
            guard let self else { return }
            self.lock.withLock { _ = self.subscribers.removeValue(forKey: id) }
        }
        return stream
    }

    func yield(_ chunk: WavRecorder.Chunk) {
        let targets = lock.withLock { Array(subscribers.values) }
        for c in targets { c.yield(chunk) }
    }

    /// The recording ended: every subscriber's stream finishes.
    func finishAll() {
        let targets = lock.withLock { () -> [AsyncStream<WavRecorder.Chunk>.Continuation] in
            defer { subscribers.removeAll() }
            return Array(subscribers.values)
        }
        for c in targets { c.finish() }
    }

    var subscriberCount: Int { lock.withLock { subscribers.count } }
}

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
    /// Audio has arrived in this session (the panel says "waiting for audio"
    /// until it has).
    private(set) var heardAudio = false

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
    /// The session whose read loop is running; new audio for it only has to
    /// be appended. Per session, so a read left hanging by an earlier
    /// session can never keep a new one from reading.
    private var readingSession: Int?

    // Diagnostics: the heartbeat line in the log.
    private var heardSeconds = 0.0
    private var heardPeak: Float = 0
    private var readCount = 0
    private var lastReadMs = 0
    private var nextHeartbeat = 30.0

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
    /// A read taking longer than this is abandoned; the audio is read again.
    nonisolated static let readDeadline: TimeInterval = 10
    /// No audio this long after start: subscribe to the recorder again.
    nonisolated static let audioWatchdogSeconds: TimeInterval = 5

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
        streamsPartials = engine.isParakeet
        status = .running
        AppLog.info("live", "started · \(engine.rawValue) · \(streamsPartials ? "streaming" : "phrase by phrase")")
        subscribe(to: source, session: token)
        // Self-check: a session that hears nothing has lost its feed.
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.audioWatchdogSeconds * 1_000_000_000))
            guard let self, token == self.startToken, !self.heardAudio, let source = self.source else { return }
            AppLog.warn("live", "no audio from the recorder after \(Int(Self.audioWatchdogSeconds)) s — subscribing again")
            self.consumer?.cancel()
            self.subscribe(to: source, session: token)
        }
    }

    private func subscribe(to source: any LiveChunkSource, session token: Int) {
        let chunkStream = source.subscribeChunks()
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
        heardAudio = false
        heardSeconds = 0
        heardPeak = 0
        readCount = 0
        nextHeartbeat = 30
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
        if !heardAudio {
            heardAudio = true
            AppLog.info("live", String(format: "first audio · chunk @%.1fs", chunk.startTimeSeconds))
        }
        noteHeard(chunk.samples)
        if pending.isEmpty { pendingStart = chunk.startTimeSeconds }
        pending.append(contentsOf: chunk.samples)
        guard readingSession != session else { return }
        readingSession = session
        Task { @MainActor [weak self] in
            guard let self else { return }
            while session == self.startToken, await self.step(session: session) {}
            if self.readingSession == session { self.readingSession = nil }
        }
    }

    /// Every 30 s of audio: what live heard and did. When captions go quiet,
    /// this line says whether audio arrived, how loud it was, and whether
    /// the engine was reading.
    private func noteHeard(_ samples: [Float]) {
        heardSeconds += Double(samples.count) / Double(Self.sampleRate)
        for s in samples { heardPeak = max(heardPeak, abs(s)) }
        guard heardSeconds >= nextHeartbeat else { return }
        nextHeartbeat += 30
        AppLog.info("live", String(
            format: "%.0f s heard · peak %.0f dB · %d reads (last %d ms) · %d lines · open phrase %.1f s%@",
            heardSeconds, 20 * log10(max(1e-5, heardPeak)), readCount, lastReadMs, lines.count,
            Double(pending.count) / Double(Self.sampleRate),
            readingSession == nil ? "" : " · reading"))
        heardPeak = 0
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
        let languages = languages
        let translateTo = translateTo
        let started = Date()
        do {
            // Interactive with bounded patience, as dictation does: a Gemma
            // call from a background job must not leave captions minutes
            // behind (see InferenceGate). Bounded in time as well: a read
            // that never returns must not stop live for the rest of the
            // recording.
            let text = try await Self.withDeadline(Self.readDeadline) {
                try await InferenceGate.$interactive.withValue(true) {
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
            }
            readCount += 1
            lastReadMs = Int(Date().timeIntervalSince(started) * 1000)
            // Stopped or restarted while this read was in flight: its text
            // belongs to a session that is gone.
            guard session == startToken else { return .gone }
            let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return cleaned.isEmpty ? .silent : .text(cleaned)
        } catch is InferenceGate.Busy {
            AppLog.info("live", "engines busy — retrying with the next audio")
            return session == startToken ? .busy : .gone
        } catch is ReadTimeout {
            AppLog.warn("live", String(format: "a %.1f s read took over %.0f s — abandoned, reading again",
                                       Double(samples.count) / Double(Self.sampleRate), Self.readDeadline))
            return session == startToken ? .busy : .gone
        } catch {
            // Cancellation is Stop doing its job, not a failed read.
            if error is CancellationError || session != startToken { return .gone }
            // One failed read must not end the session.
            AppLog.warn("live", "read failed: \(error.localizedDescription)")
            return .silent
        }
    }

    struct ReadTimeout: Error {}

    /// Runs `op` and returns its result, or throws `ReadTimeout` after
    /// `seconds` — without waiting for `op`, which may never return. A task
    /// group would wait for it; this races two unstructured tasks instead.
    nonisolated static func withDeadline<T: Sendable>(
        _ seconds: TimeInterval,
        _ op: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let claimed = OSAllocatedUnfairLock(initialState: false)
        @Sendable func claim() -> Bool { claimed.withLock { done in defer { done = true }; return !done } }
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<T, Error>) in
            let work = Task {
                do {
                    let value = try await op()
                    if claim() { cont.resume(returning: value) }
                } catch {
                    if claim() { cont.resume(throwing: error) }
                }
            }
            Task {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                if claim() {
                    work.cancel()
                    cont.resume(throwing: ReadTimeout())
                }
            }
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
