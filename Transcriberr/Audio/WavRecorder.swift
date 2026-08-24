import Foundation
@preconcurrency import AVFoundation
import Observation

/// Records from the default input device, converts to 16 kHz mono Float32 PCM,
/// writes a standards-compliant WAV file, and publishes 5-second chunk events
/// for the live-transcription path.
///
/// All I/O happens on a private serial queue so AVAudioFile writes stay
/// in-order. Only `level` / `elapsedMs` / `state` are mutated on MainActor.
/// `@MainActor` removed for the same reason as `AppContainer` —
/// `_SwiftData_SwiftUI` blows up on actor-isolated @Observable types
/// in macOS 26.5. Mutations happen on MainActor in practice (Tasks hop
/// into MainActor before writing), but the class declaration must stay
/// actor-free.
@Observable
final class WavRecorder: @unchecked Sendable {
    struct Chunk: Sendable {
        let samples: [Float]
        let startTimeSeconds: Double
    }

    enum State: Equatable {
        case idle
        case recording(file: URL)
        case paused(file: URL)
        case failed(reason: String)
        case saved(file: URL, durationSeconds: Double)
    }

    // MARK: - Observable state

    private(set) var state: State = .idle
    private(set) var level: Float = 0           // 0..1 RMS
    private(set) var elapsedMs: Int64 = 0

    /// Rolling per-tap peak history for the live waveform (newest at end).
    /// 64 buckets so the Record screen can draw an Android-style bar history.
    private(set) var peakHistory: [Float] = Array(repeating: 0, count: 64)

    static let sampleRate: Double = 16_000
    static let chunkSeconds: Double = 5

    // MARK: - Internals

    private let engine = AVAudioEngine()

    /// Audio I/O happens off main. `audioFile` and the chunk buffer live here.
    private let ioQueue = DispatchQueue(label: "WavRecorder.io", qos: .userInitiated)

    nonisolated(unsafe) private var converter: AVAudioConverter?
    nonisolated(unsafe) private var audioFile: AVAudioFile?
    nonisolated(unsafe) private var chunkBuffer: [Float] = []
    nonisolated(unsafe) private var totalSamplesWritten: Int = 0
    nonisolated(unsafe) private var inputFormat: AVAudioFormat?

    private let targetFormat: AVAudioFormat = {
        AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: WavRecorder.sampleRate,
            channels: 1,
            interleaved: false
        )!
    }()

    private var sessionStart: Date = .distantPast
    private var pausedAccumulatedMs: Int64 = 0
    private var pauseBeganAt: Date?

    private var chunkContinuation: AsyncStream<Chunk>.Continuation?
    private(set) var chunks: AsyncStream<Chunk>

    init() {
        chunks = AsyncStream<Chunk> { _ in }
        makeChunkStream()
    }

    /// `stop()` permanently finishes the chunk continuation (an `AsyncStream`
    /// can't be un-finished), so every `start()` needs a fresh stream —
    /// otherwise live transcription silently stops working from the second
    /// recording of the app session onward (yields into a finished
    /// continuation are just dropped, no error).
    private func makeChunkStream() {
        var continuation: AsyncStream<Chunk>.Continuation!
        self.chunks = AsyncStream<Chunk> { continuation = $0 }
        self.chunkContinuation = continuation
    }

    // MARK: - Public API

    nonisolated(unsafe) private var isStarting = false

    func start() async throws {
        if case .recording = state { return }
        guard !isStarting else { return }   // double-tap raced past the state check
        isStarting = true
        defer { isStarting = false }

        // ── Permission gate. AVAudioEngine.prepare() throws an NSException
        //    when mic access hasn't been granted yet; that NSException kills
        //    the app with SIGABRT (it's not catchable from Swift `try`).
        //    Resolve TCC up front so the engine call always sees a granted
        //    status (or we bail cleanly).
        //
        //    IMPORTANT: only call `requestAccess` when the status is genuinely
        //    undetermined. Calling it spins up the AVCapture subsystem whose
        //    async continuation can hang on macOS even when permission was
        //    already granted — which left the record button "stuck" (start()
        //    never returned, so uiState stayed .idle). When already authorized
        //    we skip straight to the engine setup, exactly like the original
        //    working path.
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            break
        case .notDetermined:
            let granted = await AVCaptureDevice.requestAccess(for: .audio)
            if !granted {
                state = .failed(reason: "Microphone access denied. Grant it in System Settings → Privacy & Security → Microphone, then try again.")
                AppLog.error("recorder", "microphone permission denied")
                throw RecorderError.noInput
            }
        case .denied, .restricted:
            state = .failed(reason: "Microphone access denied. Grant it in System Settings → Privacy & Security → Microphone, then try again.")
            AppLog.error("recorder", "microphone permission denied/restricted")
            throw RecorderError.noInput
        @unknown default:
            break
        }

        // Reset
        sessionStart = Date()
        pausedAccumulatedMs = 0
        pauseBeganAt = nil
        level = 0
        peakHistory = Array(repeating: 0, count: 64)
        makeChunkStream()
        ioQueue.sync {
            chunkBuffer.removeAll(keepingCapacity: true)
            pendingInputs.removeAll(keepingCapacity: true)
            totalSamplesWritten = 0
        }

        // ── Engine + tap. Every AVAudioEngine touch below is wrapped in
        //    ExceptionTrap so any NSException becomes a Swift Error we can
        //    surface in the UI instead of crashing.
        //
        //    ORDER MATTERS: AVAudioEngine instantiates its input node lazily,
        //    on first access of `engine.inputNode`. Calling `prepare()` (or
        //    `start()`) before that access trips the assertion
        //      "required condition is false: inputNode != nullptr || outputNode != nullptr"
        //    which is the NSException that was killing recording. So we grab
        //    `inputNode` FIRST, install the tap, and only then prepare/start.

        // Some macOS versions throw on `engine.inputNode` itself when no
        // input device is available. Trap that too.
        var grabbedInput: AVAudioInputNode?
        do {
            try ExceptionTrap.run { grabbedInput = self.engine.inputNode }
        } catch {
            state = .failed(reason: "Audio input unavailable: \(error.localizedDescription)")
            AppLog.error("recorder", "engine.inputNode threw: \(error.localizedDescription)")
            throw RecorderError.noInput
        }
        guard let input = grabbedInput else {
            state = .failed(reason: "No audio input device.")
            throw RecorderError.noInput
        }

        // Apple voice processing on the input node = same DSP FaceTime uses:
        // echo cancellation + spectral noise suppression + AGC. Free and
        // dramatically cleaner than raw mic. Must be enabled BEFORE the
        // engine starts; after enabling, the input format may change so we
        // read it again below. Also throws NSException on some configs.
        if RecorderSettings.shared.noiseSuppression {
            do {
                try ExceptionTrap.run {
                    try? input.setVoiceProcessingEnabled(true)
                }
                AppLog.info("recorder", "voice processing enabled")
            } catch {
                AppLog.warn("recorder", "voice processing rejected: \(error.localizedDescription)")
            }
        } else {
            try? ExceptionTrap.run {
                try? input.setVoiceProcessingEnabled(false)
            }
        }

        var nativeFormat: AVAudioFormat?
        do {
            try ExceptionTrap.run {
                nativeFormat = input.outputFormat(forBus: 0)
            }
        } catch {
            state = .failed(reason: "Couldn't read input format: \(error.localizedDescription)")
            AppLog.error("recorder", "outputFormat threw: \(error.localizedDescription)")
            throw RecorderError.noInput
        }
        guard let nativeFormat else {
            state = .failed(reason: "Input format unavailable.")
            throw RecorderError.noInput
        }
        guard nativeFormat.channelCount > 0, nativeFormat.sampleRate > 0 else {
            state = .failed(reason: "No microphone available (check System Settings → Privacy & Security → Microphone).")
            AppLog.error("recorder", "input has no channels: channelCount=\(nativeFormat.channelCount) sampleRate=\(nativeFormat.sampleRate)")
            throw RecorderError.noInput
        }
        AppLog.info("recorder", "input format: \(nativeFormat.sampleRate) Hz, \(nativeFormat.channelCount) ch, common=\(nativeFormat.commonFormat.rawValue)")

        // Build the converter from a MONO version of the native rate, NOT the
        // raw multichannel format. AVAudioConverter's automatic N→1 downmix
        // produces pure silence for many multichannel/aggregate inputs (e.g.
        // the 9-channel "wide-range" device) because it maps no source channel
        // to the mono destination. We downmix to mono ourselves in `ingest`
        // (see downmixToMono) and hand the converter clean mono → 16 kHz.
        guard let nativeMonoFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: nativeFormat.sampleRate,
            channels: 1,
            interleaved: false
        ) else {
            state = .failed(reason: "Cannot build mono input format.")
            throw RecorderError.noInput
        }
        guard let converter = AVAudioConverter(from: nativeMonoFormat, to: targetFormat) else {
            state = .failed(reason: "Cannot build audio converter.")
            throw RecorderError.noInput
        }
        // Normal (not Mastering): Mastering is an offline algorithm with huge
        // priming latency — fed one tap buffer at a time it emits almost
        // nothing. Normal is the streaming-friendly resampler and produces
        // output proportional to each buffer.
        converter.sampleRateConverterAlgorithm = AVSampleRateConverterAlgorithm_Normal
        converter.sampleRateConverterQuality = AVAudioQuality.high.rawValue

        let url = makeOutputURL()
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forWriting: url, settings: targetFormat.settings,
                                   commonFormat: .pcmFormatFloat32, interleaved: false)
        } catch {
            let reason = "Cannot open output file (\(error.localizedDescription)). Try recording again."
            state = .failed(reason: reason)
            AppLog.error("recorder", "AVAudioFile.init failed: \(error.localizedDescription)")
            throw RecorderError.io(reason)
        }

        ioQueue.sync {
            self.converter = converter
            self.audioFile = file
            self.inputFormat = nativeFormat
        }

        // installTap can also throw NSException on a bad format match.
        do {
            try ExceptionTrap.run {
                input.removeTap(onBus: 0)
                input.installTap(onBus: 0, bufferSize: 4096, format: nativeFormat) { [weak self] buf, _ in
                    self?.ingest(buffer: buf)
                }
            }
        } catch {
            state = .failed(reason: "Couldn't install audio tap: \(error.localizedDescription)")
            AppLog.error("recorder", "installTap threw: \(error.localizedDescription)")
            throw RecorderError.noInput
        }

        // Now that the input node exists and the tap is installed, prepare()
        // has a node graph to validate and won't trip the inputNode != nullptr
        // assertion. (Harmless if start() would do it implicitly — it just
        // pre-allocates resources.)
        do {
            try ExceptionTrap.run { self.engine.prepare() }
        } catch {
            try? ExceptionTrap.run { input.removeTap(onBus: 0) }
            ioQueue.sync {
                self.audioFile = nil
                self.converter = nil
            }
            state = .failed(reason: "Audio engine failed to prepare: \(error.localizedDescription)")
            AppLog.error("recorder", "engine.prepare threw: \(error.localizedDescription)")
            throw RecorderError.noInput
        }

        // engine.start() throws Swift errors most of the time, but also has
        // an NSException path on macOS 26.5 when voice processing fails to
        // activate. Trap both.
        var startError: Error?
        do {
            try ExceptionTrap.run {
                do {
                    try self.engine.start()
                } catch {
                    startError = error
                }
            }
        } catch {
            startError = error
        }
        if let startError {
            try? ExceptionTrap.run { input.removeTap(onBus: 0) }
            ioQueue.sync {
                self.audioFile = nil
                self.converter = nil
            }
            state = .failed(reason: "AVAudioEngine.start failed: \(startError.localizedDescription)")
            AppLog.error("recorder", "engine.start failed: \(startError.localizedDescription)")
            throw startError
        }

        AppLog.info("recorder", "started → \(url.path)")
        state = .recording(file: url)
        startTickTask()
    }

    func pause() {
        guard case let .recording(file) = state else { return }
        // Wrapped: engine.pause() can raise an NSException (uncatchable by
        // Swift try) on macOS 26.5 — that would SIGABRT the whole app.
        try? ExceptionTrap.run { self.engine.pause() }
        pauseBeganAt = Date()
        state = .paused(file: file)
    }

    func resume() {
        guard case let .paused(file) = state else { return }
        if let begin = pauseBeganAt {
            pausedAccumulatedMs += Int64(Date().timeIntervalSince(begin) * 1000)
        }
        pauseBeganAt = nil
        var startError: Error?
        do {
            try ExceptionTrap.run {
                do { try self.engine.start() } catch { startError = error }
            }
        } catch {
            startError = error
        }
        if let startError {
            state = .failed(reason: "Resume failed: \(startError.localizedDescription)")
        } else {
            state = .recording(file: file)
        }
    }

    @discardableResult
    func stop() async throws -> URL? {
        let url: URL?
        switch state {
        case .recording(let u), .paused(let u): url = u
        default: return nil
        }

        // Wrapped: engine.stop() and inputNode.removeTap can both raise
        // NSExceptions on macOS 26.5 — SIGABRT risk on every Stop press.
        try? ExceptionTrap.run {
            self.engine.stop()
            self.engine.inputNode.removeTap(onBus: 0)
        }

        // Final flush — drain the converter's internal tail (filter delay),
        // make sure pending I/O has settled, then close the file.
        let written: Int = await withCheckedContinuation { cont in
            ioQueue.async {
                self.flushConverterTail()
                let w = self.totalSamplesWritten
                self.pendingInputs.removeAll()
                self.audioFile = nil
                self.converter = nil
                cont.resume(returning: w)
            }
        }
        let duration = Double(written) / Self.sampleRate
        chunkContinuation?.finish()
        AppLog.info("recorder", "stopped: \(written) samples (\(String(format: "%.2f", duration))s) → \(url?.path ?? "(no url)")")
        if let url { state = .saved(file: url, durationSeconds: duration) }
        return url
    }

    // MARK: - Tap-thread ingestion
    //
    // Runs on AVAudioEngine's internal queue. We hop into our own serial
    // ioQueue immediately to keep AVAudioFile writes ordered.

    /// Pending native-rate input buffers waiting to be resampled. The
    /// converter pulls from here; we return `.noDataNow` when it's empty so
    /// the converter keeps its filter state ALIVE across taps (continuous
    /// streaming resample). Only touched on `ioQueue`.
    nonisolated(unsafe) private var pendingInputs: [AVAudioPCMBuffer] = []

    nonisolated private func ingest(buffer: AVAudioPCMBuffer) {
        guard buffer.frameLength > 0 else { return }
        // Downmix N channels → mono here on the tap thread (also produces a
        // buffer we OWN, so it's safe to hold across the async hop — the tap
        // buffer itself is recycled the instant this callback returns).
        guard let mono = Self.downmixToMono(buffer) else { return }
        ioQueue.async { [weak self] in
            self?.enqueueAndDrain(mono)
        }
    }

    /// Collapse a multichannel capture buffer to a single mono buffer at the
    /// same sample rate. AVAudioConverter can't be trusted to do N→1 (it
    /// silently outputs zeros on many multichannel inputs), so we mix by hand:
    /// average only the channels carrying signal in this buffer, so a lone
    /// live mic on a 9-channel device isn't attenuated by 8 silent channels.
    nonisolated static func downmixToMono(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        let frames = Int(buffer.frameLength)
        let channels = Int(buffer.format.channelCount)
        guard frames > 0, let data = buffer.floatChannelData else { return nil }
        guard let monoFmt = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                          sampleRate: buffer.format.sampleRate,
                                          channels: 1, interleaved: false),
              let mono = AVAudioPCMBuffer(pcmFormat: monoFmt,
                                          frameCapacity: AVAudioFrameCount(frames)) else { return nil }
        mono.frameLength = AVAudioFrameCount(frames)
        let out = mono.floatChannelData![0]

        if channels == 1 {
            memcpy(out, data[0], frames * MemoryLayout<Float>.size)
            return mono
        }

        // Find channels with actual energy (sparse scan for speed).
        var activeChannels: [Int] = []
        for c in 0 ..< channels {
            var energy: Float = 0
            var i = 0
            while i < frames { energy += data[c][i] * data[c][i]; i += 16 }
            if energy > 1e-9 { activeChannels.append(c) }
        }
        let mix = activeChannels.isEmpty ? Array(0 ..< channels) : activeChannels
        let inv = 1.0 / Float(mix.count)
        for i in 0 ..< frames {
            var acc: Float = 0
            for c in mix { acc += data[c][i] }
            out[i] = acc * inv
        }
        return mono
    }

    /// Append the freshly-captured buffer and pull everything the converter
    /// can now produce. ONE long-lived converter, no reset, no per-buffer
    /// endOfStream — that's what keeps the resampler's filter continuous and
    /// the output free of per-buffer priming/flush artifacts.
    nonisolated private func enqueueAndDrain(_ input: AVAudioPCMBuffer) {
        guard let converter = self.converter, let audioFile = self.audioFile else { return }
        pendingInputs.append(input)

        let ratio = targetFormat.sampleRate / input.format.sampleRate
        while true {
            let outCapacity = AVAudioFrameCount(Double(input.frameLength) * ratio + 256)
            guard let outBuf = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: max(1024, outCapacity))
            else { return }

            var error: NSError?
            let status = converter.convert(to: outBuf, error: &error) { [weak self] _, outStatus in
                guard let self, !self.pendingInputs.isEmpty else {
                    // Nothing buffered right now — DON'T end the stream, just
                    // pause. The converter retains its state for the next tap.
                    outStatus.pointee = .noDataNow
                    return nil
                }
                outStatus.pointee = .haveData
                return self.pendingInputs.removeFirst()
            }

            if status == .error {
                AppLog.warn("recorder", "convert error: \(error?.localizedDescription ?? "unknown")")
                return
            }
            let outFrames = Int(outBuf.frameLength)
            guard outFrames > 0, let ptr = outBuf.floatChannelData?[0] else { break }

            do {
                try audioFile.write(from: outBuf)
            } catch {
                AppLog.error("recorder", "audioFile.write failed: \(error.localizedDescription)")
                return
            }

            let samples = Array(UnsafeBufferPointer(start: ptr, count: outFrames))
            self.totalSamplesWritten += outFrames
            self.appendToChunkBuffer(samples)

            let rms = WavRecorder.rms(samples)
            let peak = WavRecorder.peak(of: samples)
            coalescePeak(rms: rms, peak: peak)

            // Stop once the converter has consumed all queued input (it
            // returned fewer frames than capacity AND the queue is empty).
            if pendingInputs.isEmpty && status == .inputRanDry { break }
            if outFrames == 0 { break }
        }
    }

    /// On stop, signal end-of-stream once to flush the resampler's filter
    /// delay (the final ~20 ms it was holding) into the file. Called on ioQueue.
    nonisolated private func flushConverterTail() {
        guard let converter = self.converter, let audioFile = self.audioFile else { return }
        let outBuf = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: 8192)
        guard let outBuf else { return }
        var error: NSError?
        _ = converter.convert(to: outBuf, error: &error) { _, outStatus in
            outStatus.pointee = .endOfStream
            return nil
        }
        let outFrames = Int(outBuf.frameLength)
        guard outFrames > 0, let ptr = outBuf.floatChannelData?[0] else { return }
        try? audioFile.write(from: outBuf)
        self.totalSamplesWritten += outFrames
        self.appendToChunkBuffer(Array(UnsafeBufferPointer(start: ptr, count: outFrames)))
    }

    nonisolated(unsafe) private var pendingRMS: Float = 0
    nonisolated(unsafe) private var pendingPeak: Float = 0
    nonisolated(unsafe) private var lastPublishMs: Int64 = 0
    nonisolated(unsafe) private var publishScheduled: Bool = false

    nonisolated private func coalescePeak(rms: Float, peak: Float) {
        // Combine with anything that hasn't been published yet.
        pendingRMS = max(pendingRMS, rms)
        pendingPeak = max(pendingPeak, peak)

        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        let interval: Int64 = 80          // 12.5 Hz
        if nowMs - lastPublishMs < interval {
            if publishScheduled { return }
            publishScheduled = true
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 80_000_000)
                self?.flushPendingMeter()
            }
            return
        }
        lastPublishMs = nowMs
        let r = pendingRMS, p = pendingPeak
        pendingRMS = 0
        pendingPeak = 0
        Task { @MainActor [weak self] in
            self?.publishMeter(rms: r, peak: p)
        }
    }

    @MainActor
    private func flushPendingMeter() {
        publishScheduled = false
        let r = pendingRMS, p = pendingPeak
        pendingRMS = 0
        pendingPeak = 0
        lastPublishMs = Int64(Date().timeIntervalSince1970 * 1000)
        publishMeter(rms: r, peak: p)
    }

    @MainActor
    private func publishMeter(rms: Float, peak: Float) {
        if rms > 0 || level > 0 {
            level = max(rms, level * 0.85)
        }
        if peak > 0 || peakHistory.last ?? 0 > 0 {
            var hist = peakHistory
            hist.removeFirst()
            hist.append(peak)
            peakHistory = hist
        }
    }

    /// Quick per-tap peak: max(abs) over the just-resampled chunk.
    nonisolated private static func peak(of samples: [Float]) -> Float {
        var peak: Float = 0
        for s in samples {
            let a = s < 0 ? -s : s
            if a > peak { peak = a }
        }
        return peak
    }

    nonisolated private func appendToChunkBuffer(_ samples: [Float]) {
        chunkBuffer.append(contentsOf: samples)
        let chunkSize = Int(Self.chunkSeconds * Self.sampleRate)
        while chunkBuffer.count >= chunkSize {
            let head = Array(chunkBuffer.prefix(chunkSize))
            chunkBuffer.removeFirst(chunkSize)
            let startSec = Double(totalSamplesWritten - chunkBuffer.count - chunkSize) / Self.sampleRate
            DispatchQueue.main.async { [weak self] in
                self?.chunkContinuation?.yield(Chunk(samples: head, startTimeSeconds: max(0, startSec)))
            }
        }
    }

    nonisolated private static func rms(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        var sum: Float = 0
        for s in samples { sum += s * s }
        return (sum / Float(samples.count)).squareRoot()
    }

    private func startTickTask() {
        Task { @MainActor [weak self] in
            while let self, case .recording = self.state {
                let now = Date()
                self.elapsedMs = Int64(now.timeIntervalSince(self.sessionStart) * 1000) - self.pausedAccumulatedMs
                try? await Task.sleep(nanoseconds: 100_000_000) // 100 ms
            }
        }
    }

    private func makeOutputURL() -> URL {
        let dir = FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Transcriberr/Recordings", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let stamp = DateFormatter.fileStamp.string(from: Date())
        // Millisecond + random suffix: two starts in the same second must
        // never collide on one path (that produced CoreAudio -54).
        let ms = Int(Date().timeIntervalSince1970 * 1000) % 1000
        let suffix = String(UUID().uuidString.prefix(4))
        return dir.appendingPathComponent("Recording_\(stamp)-\(String(format: "%03d", ms))\(suffix).wav")
    }

    enum RecorderError: LocalizedError {
        case noInput
        case io(String)
        var errorDescription: String? {
            switch self {
            case .noInput: return "No audio input available."
            case .io(let reason): return reason
            }
        }
    }
}

private extension DateFormatter {
    static let fileStamp: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return f
    }()
}
