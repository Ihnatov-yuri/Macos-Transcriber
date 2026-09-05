import Foundation
@preconcurrency import AVFoundation
import Observation

/// Microphone capture for dictation: the same input chain as `WavRecorder`
/// (voice processing, hand-rolled mono downmix, one continuous 16 kHz
/// resampler) but everything stays in memory — an utterance is seconds, not
/// hours, and it is transcribed the instant the key is released.
///
/// Also tracks voice activity so toggle mode can flush a passage at every
/// pause. No actor isolation on the type (see `WavRecorder`).
@Observable
final class UtteranceCapture: @unchecked Sendable {
    static let sampleRate: Double = 16_000

    private(set) var isRunning = false
    private(set) var level: Float = 0
    private(set) var peakHistory: [Float] = Array(repeating: 0, count: 48)
    private(set) var elapsedSeconds: Double = 0

    private let engine = AVAudioEngine()
    private let ioQueue = DispatchQueue(label: "UtteranceCapture.io", qos: .userInitiated)
    private var converter: AVAudioConverter?
    private var pendingInputs: [AVAudioPCMBuffer] = []
    private var samples: [Float] = []
    private var voicedSinceDrain = false
    private var lastVoicedSample: Int = 0     // index into samples
    private var totalSamples: Int = 0
    private var startedAt: Date = .distantPast
    private var tick: Task<Void, Never>?
    /// Voice-processing state the engine was last configured with; toggling
    /// it costs seconds, so `start()` only touches it when the setting changed.
    private var configuredVoiceProcessing: Bool?
    private var configObserver: NSObjectProtocol?
    // Diagnostics (ioQueue): how much the tap actually delivered.
    private var tapCalls = 0
    private var tapFrames = 0

    private let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: UtteranceCapture.sampleRate,
        channels: 1, interleaved: false
    )!

    // MARK: - Voice activity

    /// Same conservative gate as the live captioner: real speech peaks far
    /// above room tone even when the smoothed RMS is quiet. `noiseFloor`
    /// (RMS of the quietest recent frames) raises the bar in a noisy room so
    /// steady fan/traffic noise never counts as speech.
    nonisolated static func isVoiced(rms: Float, peak: Float, noiseFloor: Float = 0) -> Bool {
        peak > max(0.02, noiseFloor * 6) && rms > max(0.0025, noiseFloor * 3)
    }

    /// Rolling per-frame RMS history (ioQueue) for the adaptive noise floor.
    private var frameRMS: [Float] = []
    private var noiseFloor: Float = 0

    /// Seconds of silence since the last voiced frame (0 while talking).
    var silenceSeconds: Double {
        ioQueue.sync {
            guard voicedSinceDrain else { return 0 }
            return Double(totalSamples - lastVoicedSample) / Self.sampleRate
        }
    }
    /// Whether anything voiced arrived since the last drain.
    var hasVoiceSinceDrain: Bool { ioQueue.sync { voicedSinceDrain } }
    var bufferedSeconds: Double { ioQueue.sync { Double(samples.count) / Self.sampleRate } }

    // MARK: - Lifecycle

    enum CaptureError: LocalizedError {
        case permission, noInput(String)
        var errorDescription: String? {
            switch self {
            case .permission:
                return "Microphone access denied. Grant it in System Settings → Privacy & Security → Microphone."
            case .noInput(let r):
                return r
            }
        }
    }

    /// Configure the input chain ahead of time. Enabling voice processing on
    /// a fresh engine takes seconds — measured 4 s on first use — which is
    /// exactly the moment the user starts talking. Called at launch and after
    /// every stop (when the mic is already authorized, so it never prompts).
    @MainActor
    func prewarm() {
        guard !isRunning, AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else { return }
        let t0 = Date()
        do {
            try configureInput()
            try ExceptionTrap.run { self.engine.prepare() }
            AppLog.info("dictation", String(format: "capture prewarmed in %.2fs", Date().timeIntervalSince(t0)))
        } catch {
            AppLog.warn("dictation", "capture prewarm failed: \(error.localizedDescription)")
        }
    }

    /// Grab the input node and apply the voice-processing preference (only
    /// when it differs from what the engine already has).
    @MainActor
    @discardableResult
    private func configureInput() throws -> AVAudioInputNode {
        var grabbedInput: AVAudioInputNode?
        do {
            try ExceptionTrap.run { grabbedInput = self.engine.inputNode }
        } catch {
            throw CaptureError.noInput("Audio input unavailable: \(error.localizedDescription)")
        }
        guard let input = grabbedInput else { throw CaptureError.noInput("No audio input device.") }
        let wantVP = RecorderSettings.shared.noiseSuppression
        if configuredVoiceProcessing != wantVP {
            let t0 = Date()
            try? ExceptionTrap.run { try? input.setVoiceProcessingEnabled(wantVP) }
            configuredVoiceProcessing = wantVP
            AppLog.info("dictation", String(format: "voice processing %@ in %.2fs",
                                            wantVP ? "enabled" : "disabled", Date().timeIntervalSince(t0)))
        }
        if configObserver == nil {
            configObserver = NotificationCenter.default.addObserver(
                forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in self?.handleConfigurationChange() }
            }
        }
        return input
    }

    /// The engine stops itself when the audio route changes (device
    /// switch, voice-processing graph rebuild). Mid-session, restart it so the
    /// tap keeps delivering instead of silently starving.
    @MainActor
    private func handleConfigurationChange() {
        guard isRunning else { return }
        AppLog.warn("dictation", "audio configuration changed mid-session — restarting engine")
        var startError: Error?
        try? ExceptionTrap.run {
            do { try self.engine.start() } catch { startError = error }
        }
        if let startError {
            AppLog.error("dictation", "engine restart failed: \(startError.localizedDescription)")
        }
    }

    @MainActor
    func start() async throws {
        guard !isRunning else { return }
        let t0 = Date()
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: break
        case .notDetermined:
            guard await AVCaptureDevice.requestAccess(for: .audio) else { throw CaptureError.permission }
        default:
            throw CaptureError.permission
        }

        ioQueue.sync {
            samples.removeAll(keepingCapacity: true)
            pendingInputs.removeAll(keepingCapacity: true)
            voicedSinceDrain = false
            lastVoicedSample = 0
            totalSamples = 0
            tapCalls = 0
            tapFrames = 0
            frameRMS.removeAll(keepingCapacity: true)
            noiseFloor = 0
        }
        level = 0
        peakHistory = Array(repeating: 0, count: 48)
        elapsedSeconds = 0

        let input = try configureInput()

        var nativeFormat: AVAudioFormat?
        do {
            try ExceptionTrap.run { nativeFormat = input.outputFormat(forBus: 0) }
        } catch {
            throw CaptureError.noInput("Couldn't read input format: \(error.localizedDescription)")
        }
        guard let nativeFormat, nativeFormat.channelCount > 0, nativeFormat.sampleRate > 0 else {
            throw CaptureError.noInput("No microphone available (check System Settings → Privacy & Security → Microphone).")
        }
        guard let monoFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: nativeFormat.sampleRate,
            channels: 1, interleaved: false
        ), let converter = AVAudioConverter(from: monoFormat, to: targetFormat) else {
            throw CaptureError.noInput("Cannot build audio converter.")
        }
        converter.sampleRateConverterAlgorithm = AVSampleRateConverterAlgorithm_Normal
        converter.sampleRateConverterQuality = AVAudioQuality.high.rawValue
        ioQueue.sync { self.converter = converter }

        do {
            try ExceptionTrap.run {
                input.removeTap(onBus: 0)
                input.installTap(onBus: 0, bufferSize: 4096, format: nativeFormat) { [weak self] buf, _ in
                    self?.ingest(buffer: buf)
                }
            }
        } catch {
            throw CaptureError.noInput("Couldn't install audio tap: \(error.localizedDescription)")
        }
        do {
            try ExceptionTrap.run { self.engine.prepare() }
            var startError: Error?
            try ExceptionTrap.run {
                do { try self.engine.start() } catch { startError = error }
            }
            if let startError { throw startError }
        } catch {
            try? ExceptionTrap.run { input.removeTap(onBus: 0) }
            ioQueue.sync { self.converter = nil }
            throw CaptureError.noInput("Audio engine failed to start: \(error.localizedDescription)")
        }

        startedAt = Date()
        isRunning = true
        tick = Task { @MainActor [weak self] in
            while let self, self.isRunning {
                self.elapsedSeconds = Date().timeIntervalSince(self.startedAt)
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
        AppLog.info("dictation", String(format: "capture started in %.2fs (%d Hz, %d ch)",
                                        Date().timeIntervalSince(t0), Int(nativeFormat.sampleRate),
                                        Int(nativeFormat.channelCount)))
    }

    /// Stop the engine and return everything captured since the last drain.
    @MainActor
    @discardableResult
    func stop() -> [Float] {
        guard isRunning else { return [] }
        isRunning = false
        tick?.cancel()
        tick = nil
        let wasRunning = engine.isRunning
        try? ExceptionTrap.run {
            self.engine.stop()
            self.engine.inputNode.removeTap(onBus: 0)
        }
        let (out, calls, frames): ([Float], Int, Int) = ioQueue.sync {
            flushConverterTail()
            let s = samples
            samples.removeAll()
            pendingInputs.removeAll()
            converter = nil
            voicedSinceDrain = false
            return (s, tapCalls, tapFrames)
        }
        level = 0
        AppLog.info("dictation", String(format: "capture stopped: %.2fs (tap %d calls, %d frames, engine %@)",
                                        Double(out.count) / Self.sampleRate, calls, frames,
                                        wasRunning ? "running" : "stopped"))
        // Keep the configured graph warm for the next passage.
        try? ExceptionTrap.run { self.engine.prepare() }
        return out
    }

    /// Copy of the audio buffered so far (live preview) — nothing is consumed.
    func snapshot() -> [Float] {
        ioQueue.sync { samples }
    }

    /// Take the buffered audio (for a pause flush) and keep capturing.
    func drain() -> [Float] {
        ioQueue.sync {
            let s = samples
            samples.removeAll(keepingCapacity: true)
            voicedSinceDrain = false
            return s
        }
    }

    // MARK: - Ingest (tap thread → ioQueue)

    nonisolated private func ingest(buffer: AVAudioPCMBuffer) {
        guard buffer.frameLength > 0, let mono = WavRecorder.downmixToMono(buffer) else { return }
        ioQueue.async { [weak self] in self?.enqueueAndDrain(mono) }
    }

    nonisolated private func enqueueAndDrain(_ input: AVAudioPCMBuffer) {
        tapCalls += 1
        tapFrames += Int(input.frameLength)
        guard let converter else { return }
        pendingInputs.append(input)
        let ratio = targetFormat.sampleRate / input.format.sampleRate
        while true {
            let cap = AVAudioFrameCount(Double(input.frameLength) * ratio + 256)
            guard let outBuf = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: max(1024, cap)) else { return }
            var error: NSError?
            let status = converter.convert(to: outBuf, error: &error) { [weak self] _, outStatus in
                guard let self, !self.pendingInputs.isEmpty else {
                    outStatus.pointee = .noDataNow
                    return nil
                }
                outStatus.pointee = .haveData
                return self.pendingInputs.removeFirst()
            }
            if status == .error { return }
            let n = Int(outBuf.frameLength)
            guard n > 0, let ptr = outBuf.floatChannelData?[0] else { break }
            append(Array(UnsafeBufferPointer(start: ptr, count: n)))
            if pendingInputs.isEmpty && status == .inputRanDry { break }
        }
    }

    nonisolated private func flushConverterTail() {
        guard let converter, let outBuf = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: 8192) else { return }
        var error: NSError?
        _ = converter.convert(to: outBuf, error: &error) { _, outStatus in
            outStatus.pointee = .endOfStream
            return nil
        }
        let n = Int(outBuf.frameLength)
        guard n > 0, let ptr = outBuf.floatChannelData?[0] else { return }
        append(Array(UnsafeBufferPointer(start: ptr, count: n)))
    }

    /// Runs on ioQueue. Appends, updates the voice-activity clock, and
    /// publishes the meter at ~12 Hz.
    nonisolated private func append(_ chunk: [Float]) {
        samples.append(contentsOf: chunk)
        totalSamples += chunk.count
        var sumSq: Float = 0
        var peak: Float = 0
        for s in chunk {
            sumSq += s * s
            let a = s < 0 ? -s : s
            if a > peak { peak = a }
        }
        let rms = (sumSq / Float(max(1, chunk.count))).squareRoot()
        // Adaptive floor: the 20th percentile of the last ~4 s of frames.
        frameRMS.append(rms)
        if frameRMS.count > 200 { frameRMS.removeFirst(frameRMS.count - 200) }
        if frameRMS.count >= 20 {
            let sorted = frameRMS.sorted()
            noiseFloor = sorted[sorted.count / 5]
        }
        if Self.isVoiced(rms: rms, peak: peak, noiseFloor: noiseFloor) {
            voicedSinceDrain = true
            lastVoicedSample = totalSamples
        }
        meterRMS = max(meterRMS, rms)
        meterPeak = max(meterPeak, peak)
        let now = Date().timeIntervalSince1970
        if now - lastMeterPublish >= 0.08 {
            lastMeterPublish = now
            let r = meterRMS, p = meterPeak
            meterRMS = 0; meterPeak = 0
            Task { @MainActor [weak self] in
                guard let self, self.isRunning else { return }
                self.level = max(r, self.level * 0.85)
                var hist = self.peakHistory
                hist.removeFirst()
                hist.append(p)
                self.peakHistory = hist
            }
        }
    }
    private var meterRMS: Float = 0
    private var meterPeak: Float = 0
    private var lastMeterPublish: TimeInterval = 0

    // MARK: - Gain

    /// Mic sensitivity from Settings → Audio Input, applied to the utterance
    /// before recognition. AUTO peak-normalizes a quiet take to −3 dBFS;
    /// fixed steps multiply and clip.
    nonisolated static func applyGain(_ samples: [Float], sensitivity: RecorderSettings.MicSensitivity) -> [Float] {
        guard !samples.isEmpty else { return samples }
        var peak: Float = 0
        for s in samples { let a = s < 0 ? -s : s; if a > peak { peak = a } }
        guard peak > 0 else { return samples }
        let gain: Float
        if let fixed = sensitivity.fixedGain {
            gain = fixed
        } else {
            // Only boost quiet audio; never attenuate a healthy signal.
            // Cap at +24 dB so a near-silent take doesn't become noise.
            guard peak < 0.25 else { return samples }
            gain = min(16, 0.7 / peak)
        }
        return samples.map { max(-1, min(1, $0 * gain)) }
    }
}
