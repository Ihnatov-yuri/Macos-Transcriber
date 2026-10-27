import Foundation
@preconcurrency import AVFoundation
import CoreAudio

/// Apple's voice processing — the echo canceller FaceTime, and calls in
/// Teams or Meet, run on the microphone — for the meeting recorder's mic.
///
/// Why: on laptop speakers the mic hears the far side as loud as the call
/// audio itself. The offline `EchoCanceller` removes most of it, but its
/// all-or-nothing residual suppressor let ~100 short bursts through on a
/// 29-minute call (22 s of doubled syllables, 60-75 ms late — "echo
/// everywhere" on playback). Measured on the same MacBook, speakers playing
/// that call from ANOTHER process: voice processing took the echo from
/// -20.7 to -64.9 dBFS (the empty-room floor), and with the user talking
/// over it Parakeet got every one of their words and none of the far side's.
///
/// How: a separate AVAudioEngine with voice processing on the same mic runs
/// next to the meeting aggregate (which stays the clock for both tracks).
/// Its cleaned samples go through a small FIFO; the aggregate's IO callback
/// `pull`s one cycle's worth and uses it in place of the raw mic. The two
/// devices tick at the same nominal rate, so the FIFO only absorbs jitter
/// and the occasional drift sample. If the unit stops delivering, `pull`
/// returns nil and the recorder falls back to the raw mic (and with it, the
/// offline canceller) rather than recording silence.
///
/// The unit must only exist while recording: while it exists, coreaudiod
/// turns every other app down (-4 dB at the mildest setting, -15 dB by
/// default) — the v3.2.1 lesson. `stop()` destroys it.
nonisolated final class VoiceProcessedMic: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let lock = NSLock()
    /// Serializes `release` and the route-change restart. Separate from
    /// `lock`: both call `removeTap`, which waits for a tap callback in
    /// flight — and that callback (`push`) takes `lock`.
    private let controlLock = NSLock()
    /// Cleaned mono samples at `targetRate` (under `lock`). Read from
    /// `head` on; the consumed front is dropped in one go now and then
    /// instead of shifting the array on every IO cycle.
    private var fifo: [Float] = []
    private var head = 0
    private var buffered: Int { fifo.count - head }
    private var targetRate: Double = 0
    private var converter: AVAudioConverter?
    private var primed = false
    private var lastPush = Date.distantPast
    private var stalled = false
    private var released = false   // under `controlLock`
    /// Set (under `lock`) once the unit was let go mid-recording because the
    /// output moved to headphones: `pull` then hands back the raw mic at
    /// once, without the "stopped delivering" warning.
    private var retired = false
    private var underruns = 0
    private var dropped = 0
    /// Largest single delivery from the tap, in target-rate samples. The
    /// tap's buffer size is only a request: macOS often hands over ~100 ms
    /// at a time whatever is asked, and a cushion smaller than one delivery
    /// empties between deliveries — every gap a hole in the user's voice.
    private var largestPush = 0
    private var configObserver: NSObjectProtocol?

    /// Jitter cushion kept in the FIFO (at least one tap delivery), and the
    /// most it may hold before the oldest samples are dropped (drift
    /// between the two devices).
    private var cushion: Int { max(Int(targetRate * 0.03), largestPush) }
    private var ceiling: Int { cushion + max(Int(targetRate * 0.12), 2 * largestPush) }

    /// Bring the unit up on the chosen microphone (~1 s). False when macOS
    /// refuses it; the unit is then already gone and the caller records the
    /// raw mic as before.
    func start(inputUID: String?) -> Bool {
        let t0 = Date()
        AudioInputDevices.apply(uid: inputUID, to: engine)
        var input: AVAudioInputNode?
        var failure: String?
        do {
            try ExceptionTrap.run {
                let node = self.engine.inputNode
                do { try node.setVoiceProcessingEnabled(true) } catch { failure = error.localizedDescription }
                input = node
            }
        } catch {
            failure = error.localizedDescription
        }
        guard let input, failure == nil else {
            AppLog.warn("meeting", "echo filter unavailable: \(failure ?? "no input") — recording the raw mic")
            release()
            return false
        }
        input.voiceProcessingOtherAudioDuckingConfiguration = .init(
            enableAdvancedDucking: false, duckingLevel: .min)
        let sourceRate: Double
        do {
            sourceRate = try installTap(on: input)
            var startError: Error?
            try ExceptionTrap.run {
                do { try self.engine.start() } catch { startError = error }
            }
            if let startError { throw startError }
        } catch {
            AppLog.warn("meeting", "echo filter failed to start: \(error.localizedDescription) — recording the raw mic")
            release()
            return false
        }
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { [weak self] _ in self?.restartAfterConfigurationChange() }
        AppLog.info("meeting", String(format: "echo filter on (Apple voice processing, %.0f Hz) in %.2fs",
                                      sourceRate, Date().timeIntervalSince(t0)))
        return true
    }

    /// (Re)install the tap for the node's CURRENT format and return its
    /// rate. After a route change the format can differ (a headset's 16 kHz
    /// input): a tap built for the old one is refused, or would hand over
    /// samples at a rate `push` no longer knows.
    private func installTap(on input: AVAudioInputNode) throws -> Double {
        var format: AVAudioFormat?
        try ExceptionTrap.run { format = input.outputFormat(forBus: 0) }
        guard let format, format.channelCount > 0, format.sampleRate > 0 else {
            throw NSError(domain: "VoiceProcessedMic", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "no input format"])
        }
        // With voice processing on, the node reports several channels; the
        // first one is the processed microphone (the probe that measured
        // the numbers above read exactly that one).
        let sourceRate = format.sampleRate
        try ExceptionTrap.run {
            input.removeTap(onBus: 0)
            input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buf, _ in
                guard let p = buf.floatChannelData?[0] else { return }
                self?.push(UnsafeBufferPointer(start: p, count: Int(buf.frameLength)), sourceRate: sourceRate)
            }
        }
        return sourceRate
    }

    /// The rate the recorder's IO callback runs at. Known only once the
    /// aggregate exists, which is built after this unit so that whatever the
    /// unit does to the mic's format is already in place.
    func setTargetRate(_ rate: Double) {
        lock.lock(); defer { lock.unlock() }
        targetRate = rate
        fifo.removeAll(keepingCapacity: true)
        head = 0
        primed = false
        converter = nil
    }

    /// `frames` cleaned samples for one IO cycle. Nil until the FIFO holds
    /// its cushion, and again if the unit has stopped delivering — the
    /// caller uses the raw mic for that cycle.
    func pull(_ frames: Int) -> [Float]? {
        lock.lock(); defer { lock.unlock() }
        if retired { return nil }
        if !primed {
            guard buffered >= cushion + frames else { return nil }
            primed = true
        }
        if buffered >= frames {
            let out = Array(fifo[head..<(head + frames)])
            head += frames
            compact()
            return out
        }
        if Date().timeIntervalSince(lastPush) > 1 {
            if !stalled {
                stalled = true
                AppLog.warn("meeting", "echo filter stopped delivering — recording the raw mic until it returns")
            }
            primed = false
            return nil
        }
        // Late by a few samples: pad, keep the timeline.
        underruns += 1
        var out = Array(fifo[head...])
        fifo.removeAll(keepingCapacity: true)
        head = 0
        out.append(contentsOf: repeatElement(0, count: frames - out.count))
        return out
    }

    /// Drop the consumed front once it is worth a copy (under `lock`).
    private func compact() {
        if head >= 16_384 || head == fifo.count {
            fifo.removeFirst(head)
            head = 0
        }
    }

    /// Destroy the unit so coreaudiod lifts its duck on other apps. The
    /// engine has to be stopped first: a running engine refuses the toggle
    /// (-10849), and `engine.stop()` alone leaves the duck in place.
    func stop() {
        lock.lock()
        let summary = "underruns \(underruns), dropped \(dropped) samples, largest tap delivery \(largestPush)"
        lock.unlock()
        release()
        AppLog.info("meeting", "echo filter released (\(summary))")
    }

    private func release() {
        // A route-change restart already on its way must not start the
        // engine again after this — the mic would stay open with nothing
        // reading it.
        controlLock.lock(); defer { controlLock.unlock() }
        releaseLocked()
    }

    /// `release` for a caller already holding `controlLock`.
    private func releaseLocked() {
        released = true
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
        configObserver = nil
        var toggleError: Error?
        try? ExceptionTrap.run {
            self.engine.stop()
            let input = self.engine.inputNode
            input.removeTap(onBus: 0)
            guard input.isVoiceProcessingEnabled else { return }
            do { try input.setVoiceProcessingEnabled(false) } catch { toggleError = error }
        }
        if let toggleError {
            AppLog.warn("meeting", "echo filter release failed: \(toggleError.localizedDescription)")
        }
    }

    /// The unit rebuilds itself on a route change (headphones plugged in,
    /// output switched) and stops the engine. Re-tap for the new format and
    /// start it again; until it is back, `pull` falls back to the raw mic.
    /// Serialized with `release`, so it can never revive a unit that was
    /// already let go.
    ///
    /// A switch to headphones (AirPods connected mid-call) lets the unit go
    /// instead: there is no echo left to remove, and a live unit on the mic
    /// is what silenced the Teams mic in v4.6-5.0.6 (macOS could not rebuild
    /// Teams' Voice Isolation chain around it). It used to restart here on
    /// whatever the new route was, so the filter stayed on for the rest of
    /// the call although it never starts on headphones.
    private func restartAfterConfigurationChange() {
        controlLock.lock(); defer { controlLock.unlock() }
        guard !released else { return }
        let route = Self.outputRoute()
        if route.headphones {
            releaseLocked()
            lock.lock(); retired = true; lock.unlock()
            AppLog.info("meeting", "echo filter off — output switched to '\(route.name)' (headphones), recording the raw mic")
            return
        }
        do {
            let rate = try installTap(on: engine.inputNode)
            var startError: Error?
            try ExceptionTrap.run {
                do { try self.engine.start() } catch { startError = error }
            }
            if let startError { throw startError }
            AppLog.info("meeting", String(format: "echo filter restarted after a route change (%.0f Hz)", rate))
        } catch {
            AppLog.warn("meeting", "echo filter restart after a route change failed: \(error.localizedDescription)")
        }
    }

    /// Internal (not private) for the FIFO tests.
    func push(_ samples: UnsafeBufferPointer<Float>, sourceRate: Double) {
        lock.lock(); defer { lock.unlock() }
        guard targetRate > 0 else { return }
        lastPush = Date()
        if stalled {
            stalled = false
            AppLog.info("meeting", "echo filter delivering again")
        }
        let before = fifo.count
        if sourceRate == targetRate {
            fifo.append(contentsOf: samples)
        } else {
            fifo.append(contentsOf: resample(samples, from: sourceRate))
        }
        largestPush = max(largestPush, fifo.count - before)
        if buffered > ceiling {
            let excess = buffered - cushion
            head += excess
            dropped += excess
            compact()
        }
    }

    /// Streaming rate conversion for a unit that runs at a different rate
    /// than the aggregate (called under `lock`).
    private func resample(_ samples: UnsafeBufferPointer<Float>, from sourceRate: Double) -> [Float] {
        if converter == nil || converter?.inputFormat.sampleRate != sourceRate {
            guard let src = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sourceRate,
                                          channels: 1, interleaved: false),
                  let dst = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: targetRate,
                                          channels: 1, interleaved: false)
            else { return [] }
            converter = AVAudioConverter(from: src, to: dst)
        }
        guard let converter,
              let inBuf = AVAudioPCMBuffer(pcmFormat: converter.inputFormat,
                                           frameCapacity: AVAudioFrameCount(samples.count)),
              let outBuf = AVAudioPCMBuffer(
                pcmFormat: converter.outputFormat,
                frameCapacity: AVAudioFrameCount(Double(samples.count) * targetRate / sourceRate) + 64)
        else { return [] }
        inBuf.frameLength = AVAudioFrameCount(samples.count)
        inBuf.floatChannelData![0].update(from: samples.baseAddress!, count: samples.count)
        var fed = false
        var err: NSError?
        let status = converter.convert(to: outBuf, error: &err) { _, outStatus in
            if fed { outStatus.pointee = .noDataNow; return nil }
            fed = true
            outStatus.pointee = .haveData
            return inBuf
        }
        guard status != .error, let p = outBuf.floatChannelData?[0] else { return [] }
        return Array(UnsafeBufferPointer(start: p, count: Int(outBuf.frameLength)))
    }

    // MARK: - When to use it

    /// The default output, and whether it is headphones. With headphones the
    /// mic hears no echo, so the unit would only cost the -4 dB duck.
    /// Built-in: the jack shows up either as its own device ("External
    /// Headphones") or as the 'hdpn' data source of the speakers device —
    /// check both. Bluetooth/USB: by name, since nothing else tells a
    /// headset from a speaker; a miss only means the filter runs where it
    /// was not needed.
    static func outputRoute() -> (name: String, headphones: Bool) {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var dev = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &dev) == noErr,
              dev != kAudioObjectUnknown else { return ("unknown output", false) }
        let name = AudioInputDevices.string(dev, kAudioObjectPropertyName) ?? "?"
        if isHeadphoneName(name) { return (name, true) }
        guard AudioInputDevices.transportType(dev) == kAudioDeviceTransportTypeBuiltIn else { return (name, false) }
        addr.mSelector = kAudioDevicePropertyDataSource
        addr.mScope = kAudioDevicePropertyScopeOutput
        var source: UInt32 = 0
        size = UInt32(MemoryLayout<UInt32>.size)
        let jack = AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &source) == noErr
            && source == 0x6864_706E     // 'hdpn'
        return (name, jack)
    }

    static func isHeadphoneName(_ name: String) -> Bool {
        let n = name.lowercased()
        return ["airpods", "headphone", "headset", "earbud", "buds", "beats", "earpods", "wh-1000", "quietcomfort"]
            .contains { n.contains($0) }
    }
}
