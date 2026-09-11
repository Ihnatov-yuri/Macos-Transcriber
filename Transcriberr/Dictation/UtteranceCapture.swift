import Foundation
@preconcurrency import AVFoundation
import Observation

/// Microphone capture for dictation: the same input chain as `WavRecorder`
/// (hand-rolled mono downmix, one continuous 16 kHz resampler, optional
/// Apple voice processing) but everything stays in memory — an utterance is
/// seconds, not hours, and it is transcribed the instant the key is released.
///
/// Voice processing is created at `start()` and torn down at `stop()`, never
/// kept warm: the moment the voice-processing unit exists in the process,
/// coreaudiod ducks every other app's output by 15 dB (measured:
/// `_DuckClientVolumeScalar … to 0.177828`), and only disabling it lifts the
/// duck — `engine.stop()` alone does not. Keeping it prewarmed made the Mac
/// quieter for as long as the app was running.
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

    /// `var`, not `let`: an AVAudioEngine cannot let go of an input device
    /// once its input node has been used — Apple's own answer to that is to
    /// throw the engine away and build another. Which is the only way to hand
    /// a Bluetooth headset back its stereo profile after a dictated sentence.
    private var engine = AVAudioEngine()
    private let ioQueue = DispatchQueue(label: "UtteranceCapture.io", qos: .userInitiated)
    private var converter: AVAudioConverter?
    private var pendingInputs: [AVAudioPCMBuffer] = []
    private var samples: [Float] = []
    private var voicedSinceDrain = false
    private var lastVoicedSample: Int = 0     // index into samples
    private var totalSamples: Int = 0
    private var startedAt: Date = .distantPast
    private var tick: Task<Void, Never>?
    /// Use Apple's voice-processing unit (echo cancellation, noise
    /// suppression, AGC) for the next session. Set by the controller from the
    /// dictation settings before `start()`. Costs ~1 s to bring up, so the
    /// raw path stays the default for an instant start.
    var voiceProcessing = false
    /// Whether the voice-processing unit currently exists on the engine.
    private var voiceProcessingActive = false
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
        // Never hold a Bluetooth microphone open just to be ready. Opening
        // it drops the link to the hands-free profile — mono, 16 kHz, for
        // that device's PLAYBACK too — and it stays there as long as the
        // input is open, which for a prewarm means the whole session. The
        // user hears their soundbar go wrong and has no way to connect it to
        // an app they only left running. Same mistake as keeping the
        // voice-processing unit warm (v3.2.1), in a different costume.
        guard Self.captureDisturbsBluetooth() == false else {
            AppLog.info("dictation", "prewarm skipped — opening capture would drop a Bluetooth link to hands-free")
            return
        }
        let t0 = Date()
        do {
            try configureInput()
            try ExceptionTrap.run { self.engine.prepare() }
            AppLog.info("dictation", String(format: "capture prewarmed in %.2fs", Date().timeIntervalSince(t0)))
        } catch {
            AppLog.warn("dictation", "capture prewarm failed: \(error.localizedDescription)")
        }
    }

    /// Whether starting capture would put a Bluetooth link into hands-free
    /// mode — see `AudioInputDevices.captureWouldDisturbBluetooth`.
    static func captureDisturbsBluetooth() -> Bool {
        AudioInputDevices.captureWouldDisturbBluetooth(uid: RecorderSettings.shared.inputDeviceUID)
    }

    /// Grab the input node (raw — voice processing is handled by
    /// `setVoiceProcessing(_:)` at session boundaries only).
    @MainActor
    @discardableResult
    private func configureInput() throws -> AVAudioInputNode {
        // Chosen microphone FIRST — see `AudioInputDevices.apply`. Touching
        // `inputNode` before this opens whatever macOS calls the default
        // input, which is exactly what we are trying not to do.
        AudioInputDevices.apply(uid: RecorderSettings.shared.inputDeviceUID, to: engine)
        var grabbedInput: AVAudioInputNode?
        do {
            try ExceptionTrap.run { grabbedInput = self.engine.inputNode }
        } catch {
            throw CaptureError.noInput("Audio input unavailable: \(error.localizedDescription)")
        }
        guard let input = grabbedInput else { throw CaptureError.noInput("No audio input device.") }
        if configObserver == nil {
            configObserver = NotificationCenter.default.addObserver(
                forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in self?.handleConfigurationChange() }
            }
        }
        return input
    }

    /// Create or destroy the voice-processing unit. The engine must be
    /// uninitialized for the toggle to be accepted (a prepared engine answers
    /// -10849), so the caller stops it first. Failures are logged, not
    /// swallowed — a silent failure here is exactly how an unwanted unit
    /// survives into idle time.
    @MainActor
    private func setVoiceProcessing(_ on: Bool, input: AVAudioInputNode) {
        guard voiceProcessingActive != on else { return }
        let t0 = Date()
        var toggleError: Error?
        try? ExceptionTrap.run {
            do { try input.setVoiceProcessingEnabled(on) } catch { toggleError = error }
        }
        if let toggleError {
            AppLog.warn("dictation", "voice processing \(on ? "enable" : "disable") failed: \(toggleError.localizedDescription)")
            voiceProcessingActive = input.isVoiceProcessingEnabled
            return
        }
        if on {
            // Duck other apps as little as macOS allows while we capture
            // (-4 dB instead of the default -15 dB).
            input.voiceProcessingOtherAudioDuckingConfiguration = .init(
                enableAdvancedDucking: false, duckingLevel: .min
            )
        }
        voiceProcessingActive = on
        AppLog.info("dictation", String(format: "voice processing %@ in %.2fs",
                                        on ? "enabled" : "disabled", Date().timeIntervalSince(t0)))
    }

    /// The engine stops itself when the audio route changes (device
    /// switch, voice-processing graph rebuild). Mid-session, restart it so the
    /// tap keeps delivering instead of silently starving.
    @MainActor
    private func handleConfigurationChange() {
        guard isRunning else { return }
        AppLog.warn("dictation", "audio configuration changed mid-session — rebuilding tap and restarting")
        // Restarting alone was not enough. The tap and the converter were
        // both built from the PREVIOUS native format; after a device switch
        // (headphones plugged in, mic changed, the voice-processing graph
        // rebuilding itself) the restart either threw on the format mismatch
        // — leaving the HUD saying LISTENING while nothing was captured, and
        // the whole utterance lost to "Nothing heard" — or resampled at the
        // wrong ratio and produced garbage. Re-read the format and rebuild
        // both before starting.
        let input = engine.inputNode
        var nativeFormat: AVAudioFormat?
        do {
            try ExceptionTrap.run { nativeFormat = input.outputFormat(forBus: 0) }
        } catch {
            AppLog.error("dictation", "post-change format read failed: \(error.localizedDescription)")
            return
        }
        guard let nativeFormat, nativeFormat.channelCount > 0, nativeFormat.sampleRate > 0,
              let monoFormat = AVAudioFormat(
                  commonFormat: .pcmFormatFloat32, sampleRate: nativeFormat.sampleRate,
                  channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: monoFormat, to: targetFormat)
        else {
            AppLog.error("dictation", "no usable input format after configuration change")
            return
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
            AppLog.error("dictation", "tap reinstall failed: \(error.localizedDescription)")
            return
        }
        var startError: Error?
        try? ExceptionTrap.run {
            do { try self.engine.start() } catch { startError = error }
        }
        if let startError {
            AppLog.error("dictation", "engine restart failed: \(startError.localizedDescription)")
        } else {
            AppLog.info("dictation", "capture resumed at \(Int(nativeFormat.sampleRate)) Hz, \(nativeFormat.channelCount) ch")
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
        if voiceProcessing {
            // Uninitialize the prewarmed graph so the toggle is accepted.
            try? ExceptionTrap.run { self.engine.stop() }
            setVoiceProcessing(true, input: input)
        }
        // Every throw below used to leave the voice-processing unit alive.
        // `stop()` is the only other place that takes it down and it
        // early-returns on `guard isRunning` — which is set at the very end
        // of this function — so a failed start (device yanked, input held by
        // another app, unreadable format) left coreaudiod ducking every
        // other app by 15 dB for the rest of the app's life, with the
        // controller only showing a message. That is the v3.2.1 landmine.
        var startedCleanly = false
        defer {
            if !startedCleanly {
                try? ExceptionTrap.run { self.engine.stop() }
                try? ExceptionTrap.run { input.removeTap(onBus: 0) }
                setVoiceProcessing(false, input: input)
            }
        }

        // Read the format AFTER the voice-processing decision: it changes.
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
        startedCleanly = true
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
        // Tear the voice-processing unit down so other apps get their
        // volume back, then keep the raw graph warm for the next passage —
        // except on Bluetooth, where staying warm means the link never climbs
        // back out of hands-free mode after a single dictated sentence.
        if voiceProcessingActive, let input = try? configureInput() {
            setVoiceProcessing(false, input: input)
        }
        if Self.captureDisturbsBluetooth() {
            AppLog.info("dictation", "releasing the Bluetooth input — rebuilding the engine instead of keeping it warm")
            releaseEngine()
        } else {
            try? ExceptionTrap.run { self.engine.prepare() }
        }
        return out
    }

    /// Drop the engine and build a fresh one, which is the only way to make
    /// the input device close: `stop()` leaves it open, `reset()` leaves it
    /// open, and there is no API to disable an input node that has been used.
    /// Costs the next session a cold start (~0.15 s for the raw graph), which
    /// is the right trade against holding someone's headphones in hands-free
    /// mode indefinitely.
    @MainActor
    private func releaseEngine() {
        if let configObserver {
            NotificationCenter.default.removeObserver(configObserver)
            self.configObserver = nil
        }
        try? ExceptionTrap.run { self.engine.stop() }
        engine = AVAudioEngine()
        // The flag describes the OLD input node. A fresh engine's node has no
        // voice-processing unit, so leaving it true made the `guard` in
        // `setVoiceProcessing` swallow every later enable — "MIC · FILTERED"
        // silently off for the rest of the session, with nothing in the log.
        voiceProcessingActive = false
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
