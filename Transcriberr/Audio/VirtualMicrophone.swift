import Foundation
@preconcurrency import AVFoundation
import CoreAudio
import Synchronization

/// The Transcriberr Microphone: Apple's echo filter on the real mic, passed
/// to the call app (Teams, Meet, Zoom) through our own virtual input device.
///
/// Why: voice processing on the built-in mic next to a call app's own
/// processing broke the call — coreaudiod could not rebuild Teams' Voice
/// Isolation chain around our unit, and Teams' mic fell to room noise for
/// the rest of the call (v4.6-5.0.6). With this on, only Transcriberr opens
/// the real mic; the call takes the cleaned mic from the device, and the
/// meeting recording takes it from the same unit. See
/// docs/virtual-microphone.md.
///
/// How: the HAL plug-in in MicDriver/ has a visible input device
/// ("Transcriberr Microphone") and a hidden output device ("Transcriberr Mic
/// Feed") that loop into each other. While the setting is on and the driver
/// is installed this class keeps the feed's IO running — silence when there
/// is nothing to send — which is also what keeps the microphone device
/// published: when Transcriberr quits or crashes the feed stops, and the
/// plug-in withdraws the microphone, so the call app falls back to another
/// mic as if a USB mic had been unplugged. While a call has the microphone
/// open, one `VoiceProcessedMic` runs on the real mic, and its sink hands
/// every render cycle to `ring`, which the feed's IO reads. A meeting that
/// records during such a call borrows that unit; a meeting with no call on
/// the device records the way it would with this off. Starting the unit
/// for a recording alone would put voice processing on the mic a call app
/// may still be using directly, the v4.6-5.0.6 failure.
nonisolated final class VirtualMicrophone: @unchecked Sendable {
    static let shared = VirtualMicrophone()

    static let micUID = "nl.ihnatov.Transcriberr.Microphone"
    static let feedUID = "nl.ihnatov.Transcriberr.MicFeed"
    static let micName = "Transcriberr Microphone"
    static let driverBundleName = "TranscriberrMic.driver"
    static let installedURL = URL(fileURLWithPath: "/Library/Audio/Plug-Ins/HAL/TranscriberrMic.driver")
    /// The plug-in's one format: 48 kHz mono Float32.
    static let feedRate: Double = 48_000

    /// Serializes every state change below.
    private let queue = DispatchQueue(label: "nl.ihnatov.Transcriberr.virtual-mic")
    private var feedDevice = AudioObjectID(kAudioObjectUnknown)
    private var feedProc: AudioDeviceIOProcID?
    private var unit: VoiceProcessedMic?
    private var recordingHolds = 0
    private var micDevice = AudioObjectID(kAudioObjectUnknown)
    private var micListener: AudioObjectPropertyListenerBlock?
    private var devicesListener: AudioObjectPropertyListenerBlock?
    /// A call (any app but us) has the microphone open. Under `queue` for
    /// changes; held in a `Mutex` so quitting can read it without waiting
    /// for the queue (it may be bringing the unit up, about a second).
    private let callFlag = Mutex(false)
    private var callInUse: Bool {
        get { callFlag.withLock { $0 } }
        set { callFlag.withLock { $0 = newValue } }
    }

    /// Cleaned mic on its way to the feed device.
    let ring = FeedRing()
    /// Only touched on the engine's render thread.
    private var resampler = LinearResampler()
    private var resampled: [Float] = []

    private init() {
        resampled.reserveCapacity(Self.resampleCapacity)
        // coreaudiod restarted (Install restarts it on purpose; it can also
        // crash): every device ID and IO proc we hold died with it.
        var addr = Self.address(kAudioHardwarePropertyServiceRestarted)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, queue) { [weak self] _, _ in
            self?.serviceRestarted()
        }
    }

    private func serviceRestarted() {
        AppLog.info("virtual-mic", "coreaudiod restarted — starting over")
        let hadFeed = feedProc != nil
        stopUnit()
        feedProc = nil
        feedDevice = AudioObjectID(kAudioObjectUnknown)
        micListener = nil
        micDevice = AudioObjectID(kAudioObjectUnknown)
        callInUse = false
        ring.reset()
        if hadFeed || RecorderSettings.shared.virtualMicrophone {
            // The plug-in may take a moment to come back after the restart.
            queue.asyncAfter(deadline: .now() + 1) { self.reconcile() }
        }
    }

    // MARK: - State

    /// The feed is running: the device exists and calls can use it.
    var isActive: Bool { queue.sync { feedProc != nil } }
    /// A call (any app but us) has the Transcriberr Microphone open.
    var isInUseByCall: Bool { callInUse }

    static var isInstalled: Bool { FileManager.default.fileExists(atPath: installedURL.path) }

    /// The plug-in bundle shipped inside the app, for Install.
    static var bundledDriverURL: URL? {
        Bundle.main.url(forResource: "TranscriberrMic", withExtension: "driver")
    }

    /// Bring everything in line with the setting: call at launch and
    /// whenever the setting changes.
    func refresh() {
        queue.async { self.reconcile() }
    }

    /// The meeting recorder's way in: the unit a call on the Transcriberr
    /// Microphone already uses. Not `held` when the virtual microphone is
    /// off or no call uses it (the recorder then does what it would with
    /// this off); `held` with no unit when it would not start. Every `held`
    /// pairs with `releaseFromRecording`.
    func acquireForRecording() -> (held: Bool, unit: VoiceProcessedMic?) {
        queue.sync {
            guard feedProc != nil, callInUse || unit != nil else { return (false, nil) }
            recordingHolds += 1
            reconcile()
            return (true, unit)
        }
    }

    func releaseFromRecording() {
        queue.sync {
            recordingHolds = max(0, recordingHolds - 1)
            unit?.detachRecorder()
            reconcile()
        }
    }

    /// Quit: stop the unit (lifts its duck on other apps) and the feed.
    /// The plug-in withdraws the microphone a few seconds later.
    func shutdown() {
        queue.sync {
            stopUnit()
            stopFeed()
        }
    }

    // MARK: - Reconcile (on `queue`)

    private func reconcile() {
        let wanted = RecorderSettings.shared.virtualMicrophone && Self.isInstalled
        if !wanted {
            stopUnit()
            stopFeed()
            return
        }
        if feedProc == nil { startFeed() }
        guard feedProc != nil else { return }
        watchMicrophone()
        let needUnit = callInUse || recordingHolds > 0
        if needUnit && unit == nil { startUnit() }
        if !needUnit && unit != nil { stopUnit() }
    }

    private func startFeed() {
        let device = Self.deviceID(forUID: Self.feedUID)
        guard device != kAudioObjectUnknown else {
            AppLog.warn("virtual-mic", "driver installed but its feed device is missing — coreaudiod has not loaded it (restart the Mac, or reinstall)")
            return
        }
        // A small buffer: the call hears the mic one feed buffer later.
        var frames: UInt32 = 256
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyBufferFrameSize,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        AudioObjectSetPropertyData(device, &addr, 0, nil, UInt32(MemoryLayout<UInt32>.size), &frames)

        let ring = self.ring
        ring.reset()
        var proc: AudioDeviceIOProcID?
        let status = AudioDeviceCreateIOProcIDWithBlock(&proc, device, nil) { _, _, _, outData, _ in
            let list = UnsafeMutableAudioBufferListPointer(outData)
            for (i, b) in list.enumerated() {
                guard let data = b.mData else { continue }
                let n = Int(b.mDataByteSize) / MemoryLayout<Float>.size
                let p = data.assumingMemoryBound(to: Float.self)
                if i == 0 { ring.read(into: p, count: n) } else { p.update(repeating: 0, count: n) }
            }
        }
        guard status == noErr, let proc else {
            AppLog.warn("virtual-mic", "feed IO proc failed (\(status))")
            return
        }
        let started = AudioDeviceStart(device, proc)
        guard started == noErr else {
            AudioDeviceDestroyIOProcID(device, proc)
            AppLog.warn("virtual-mic", "feed start failed (\(started))")
            return
        }
        feedDevice = device
        feedProc = proc
        AppLog.info("virtual-mic", "feed running — '\(Self.micName)' is available to calls")
    }

    private func stopFeed() {
        unwatchMicrophone()
        if let feedProc, feedDevice != kAudioObjectUnknown {
            AudioDeviceStop(feedDevice, feedProc)
            AudioDeviceDestroyIOProcID(feedDevice, feedProc)
            AppLog.info("virtual-mic", "feed stopped — '\(Self.micName)' goes away in a few seconds")
        }
        feedProc = nil
        feedDevice = AudioObjectID(kAudioObjectUnknown)
        callInUse = false
        ring.reset()
    }

    private func startUnit() {
        let route = VoiceProcessedMic.outputRoute()
        let vp = VoiceProcessedMic()
        vp.keepsMicOnHeadphones = true
        vp.feed = { [weak self] samples, rate in self?.deliver(samples, rate: rate) }
        // Only the user's own choice is selected explicitly. Following the
        // system default goes through `AudioInputDevices.apply(uid: nil)`,
        // which binds to the real mic behind the Transcriberr Microphone
        // when the user made that the default (the device must never feed
        // itself). Naming the default device explicitly instead failed on a
        // USB webcam mic with voice processing (-10851, 2026-10-27) and fell
        // back to the default anyway.
        let chosen = RecorderSettings.shared.inputDeviceUID
        let mic = AudioInputDevices.effective(uid: chosen)
        let why = recordingHolds > 0 ? "a meeting records" : "a call uses '\(Self.micName)'"
        AppLog.info("virtual-mic", "\(why) — starting the mic on '\(mic?.name ?? "default")', output '\(route.name)'")
        if vp.start(inputUID: chosen, voiceProcessing: !route.headphones) {
            unit = vp
        } else {
            AppLog.warn("virtual-mic", "mic engine would not start — '\(Self.micName)' carries silence")
        }
    }

    private func stopUnit() {
        guard let vp = unit else { return }
        unit = nil
        vp.stop()
        ring.reset()
        AppLog.info("virtual-mic", "mic engine stopped — no call and no recording")
    }

    /// Render thread: one cycle of the mic, at the engine's rate. Resampled
    /// in pieces small enough that `resampled` never outgrows the capacity
    /// reserved at init, so nothing is allocated on this thread.
    private func deliver(_ samples: UnsafeBufferPointer<Float>, rate: Double) {
        if rate == Self.feedRate {
            ring.write(samples)
            return
        }
        guard let base = samples.baseAddress, rate > 0 else { return }
        let piece = max(1, Int(Double(Self.resampleCapacity) * rate / Self.feedRate) - 2)
        var done = 0
        while done < samples.count {
            let n = min(piece, samples.count - done)
            resampled.removeAll(keepingCapacity: true)
            resampler.process(UnsafeBufferPointer(start: base + done, count: n), from: rate, to: Self.feedRate, into: &resampled)
            resampled.withUnsafeBufferPointer { ring.write($0) }
            done += n
        }
    }

    static let resampleCapacity = 16_384

    // MARK: - Is a call using it

    /// Follow `DeviceIsRunningSomewhere` on the microphone device. The
    /// device comes and goes with the feed, so the device list is watched
    /// too and the listener moved to whatever ID it has now.
    private func watchMicrophone() {
        if devicesListener == nil {
            var addr = Self.address(kAudioHardwarePropertyDevices)
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.reconcile() }
            if AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, queue, block) == noErr {
                devicesListener = block
            }
        }
        let device = Self.deviceID(forUID: Self.micUID)
        if device != micDevice {
            removeMicListener()
            micDevice = device
            if device != kAudioObjectUnknown {
                var addr = Self.address(kAudioDevicePropertyDeviceIsRunningSomewhere)
                let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.micUsageChanged() }
                if AudioObjectAddPropertyListenerBlock(device, &addr, queue, block) == noErr {
                    micListener = block
                }
            }
        }
        callInUse = micDevice != kAudioObjectUnknown && Self.isRunningSomewhere(micDevice)
    }

    private func micUsageChanged() {
        let inUse = micDevice != kAudioObjectUnknown && Self.isRunningSomewhere(micDevice)
        if inUse != callInUse {
            AppLog.info("virtual-mic", inUse ? "a call opened '\(Self.micName)'" : "'\(Self.micName)' no longer in use")
        }
        reconcile()
    }

    private func removeMicListener() {
        if let micListener, micDevice != kAudioObjectUnknown {
            var addr = Self.address(kAudioDevicePropertyDeviceIsRunningSomewhere)
            AudioObjectRemovePropertyListenerBlock(micDevice, &addr, queue, micListener)
        }
        micListener = nil
        micDevice = AudioObjectID(kAudioObjectUnknown)
    }

    private func unwatchMicrophone() {
        removeMicListener()
        if let devicesListener {
            var addr = Self.address(kAudioHardwarePropertyDevices)
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, queue, devicesListener)
        }
        devicesListener = nil
    }

    // MARK: - Core Audio helpers

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector,
                                   mScope: kAudioObjectPropertyScopeGlobal,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    /// Hidden devices (the feed) are only reachable this way.
    static func deviceID(forUID uid: String) -> AudioObjectID {
        var addr = address(kAudioHardwarePropertyTranslateUIDToDevice)
        var cfUID = uid as CFString
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = withUnsafeMutablePointer(to: &cfUID) { q in
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr,
                                       UInt32(MemoryLayout<CFString>.size), q, &size, &device)
        }
        return status == noErr ? device : AudioObjectID(kAudioObjectUnknown)
    }

    private static func isRunningSomewhere(_ device: AudioObjectID) -> Bool {
        var addr = address(kAudioDevicePropertyDeviceIsRunningSomewhere)
        var running: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &running) == noErr && running != 0
    }

    /// Our own process as a Core Audio object, so the meeting recorder's
    /// system tap can leave it out: the feed is our own mic, and it must
    /// never land in the `.sys` track.
    static func ownProcessObject() -> AudioObjectID? {
        var addr = address(kAudioHardwarePropertyTranslatePIDToProcessObject)
        var pid = getpid()
        var object = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr,
                                                UInt32(MemoryLayout<pid_t>.size), &pid, &size, &object)
        return status == noErr && object != kAudioObjectUnknown ? object : nil
    }

    // MARK: - Install

    /// Copy the bundled plug-in into /Library/Audio/Plug-Ins/HAL and restart
    /// coreaudiod (macOS asks for an administrator password; all sound stops
    /// for a second). `remove: true` takes it out again. Returns an error
    /// message, or nil on success.
    static func install(remove: Bool = false) async -> String? {
        let dest = installedURL.path
        var script = "/bin/rm -rf \(shellQuoted(dest))"
        if !remove {
            guard let source = bundledDriverURL?.path else { return "The plug-in is missing from this copy of Transcriberr." }
            script += " && /usr/bin/ditto \(shellQuoted(source)) \(shellQuoted(dest))"
                + " && /usr/sbin/chown -R root:wheel \(shellQuoted(dest))"
        }
        script += " && /usr/bin/killall coreaudiod"
        let apple = "do shell script \"\(appleScriptEscaped(script))\" with administrator privileges"
        return await Task.detached {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            p.arguments = ["-e", apple]
            let err = Pipe()
            p.standardError = err
            p.standardOutput = Pipe()
            do { try p.run() } catch { return error.localizedDescription }
            p.waitUntilExit()
            guard p.terminationStatus == 0 else {
                let text = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                // -128: the user pressed Cancel at the password prompt.
                return text.contains("-128") ? "Cancelled." : (text.isEmpty ? "osascript failed" : text)
            }
            AppLog.info("virtual-mic", remove ? "driver removed" : "driver installed")
            return nil
        }.value
    }

    static func shellQuoted(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func appleScriptEscaped(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }
}

/// Mic samples between the engine's render thread and the feed device's IO
/// thread. They run on different clocks (the mic's crystal, the plug-in's
/// host-time timeline), so it absorbs jitter and trims drift: it waits for
/// a cushion of at least one delivery (and the read) before playing, pads an empty read
/// with silence (and waits for the cushion again), and drops the oldest
/// samples once the backlog passes its ceiling, so the call never hears the
/// user later than that.
nonisolated final class FeedRing: @unchecked Sendable {
    private let capacity: Int
    private let storage: UnsafeMutablePointer<Float>
    /// Heap-allocated: an `os_unfair_lock` must keep one address, which a
    /// stored property passed as `&lock` does not guarantee.
    private let lock: os_unfair_lock_t = {
        let p = os_unfair_lock_t.allocate(capacity: 1)
        p.initialize(to: os_unfair_lock())
        return p
    }()
    private var readIndex = 0
    private var count = 0
    private var primed = false
    private var largestWrite = 0
    private(set) var underruns = 0
    private(set) var dropped = 0

    /// Minimum cushion: 10 ms.
    private let minimumCushion: Int

    init(capacity: Int = 48_000, minimumCushion: Int = 480) {
        self.capacity = capacity
        self.minimumCushion = minimumCushion
        storage = .allocate(capacity: capacity)
        storage.initialize(repeating: 0, count: capacity)
    }

    deinit {
        storage.deallocate()
        lock.deinitialize(count: 1)
        lock.deallocate()
    }

    private var cushion: Int { max(minimumCushion, largestWrite) }
    private var ceiling: Int { min(capacity, cushion + max(4 * minimumCushion, 2 * largestWrite)) }

    var buffered: Int {
        os_unfair_lock_lock(lock); defer { os_unfair_lock_unlock(lock) }
        return count
    }

    func reset() {
        os_unfair_lock_lock(lock); defer { os_unfair_lock_unlock(lock) }
        readIndex = 0
        count = 0
        primed = false
    }

    func write(_ samples: UnsafeBufferPointer<Float>) {
        os_unfair_lock_lock(lock); defer { os_unfair_lock_unlock(lock) }
        let n = min(samples.count, capacity)
        largestWrite = max(largestWrite, n)
        let src = samples.baseAddress!.advanced(by: samples.count - n)
        var writeIndex = (readIndex + count) % capacity
        for i in 0..<n {
            storage[writeIndex] = src[i]
            writeIndex += 1
            if writeIndex == capacity { writeIndex = 0 }
        }
        count += n
        if count > capacity {
            // Wrapped over the oldest samples.
            readIndex = (readIndex + count - capacity) % capacity
            count = capacity
        }
        if count > ceiling {
            let excess = count - cushion
            readIndex = (readIndex + excess) % capacity
            count -= excess
            dropped += excess
        }
    }

    /// Exactly `n` samples into `out`: audio when primed, silence otherwise.
    func read(into out: UnsafeMutablePointer<Float>, count n: Int) {
        os_unfair_lock_lock(lock); defer { os_unfair_lock_unlock(lock) }
        if !primed {
            // A cushion of one delivery left AFTER this read: between two
            // deliveries the reads take up to one delivery's worth.
            guard count >= cushion + n else {
                out.update(repeating: 0, count: n)
                return
            }
            primed = true
        }
        let take = min(n, count)
        for i in 0..<take {
            out[i] = storage[readIndex]
            readIndex += 1
            if readIndex == capacity { readIndex = 0 }
        }
        count -= take
        if take < n {
            out.advanced(by: take).update(repeating: 0, count: n - take)
            underruns += 1
            primed = false
        }
    }
}

/// Streaming linear-interpolation rate converter for the feed (the voice
/// unit runs at the mic's rate, the device at 48 kHz). Allocation-free once
/// `out` has capacity, so it can run on the render thread.
nonisolated struct LinearResampler: Sendable {
    /// Position of the next output sample, in input samples relative to the
    /// current block (from -1: the previous block's last sample).
    private var position: Double = 0
    private var last: Float = 0

    mutating func process(_ input: UnsafeBufferPointer<Float>, from sourceRate: Double, to targetRate: Double,
                          into out: inout [Float]) {
        let n = input.count
        guard n > 0, sourceRate > 0, targetRate > 0 else { return }
        let step = sourceRate / targetRate
        while position < Double(n - 1) {
            let i = Int(position.rounded(.down))
            let frac = Float(position - Double(i))
            let a = i < 0 ? last : input[i]
            let b = input[i + 1]
            out.append(a + (b - a) * frac)
            position += step
        }
        position -= Double(n)
        last = input[n - 1]
    }
}
