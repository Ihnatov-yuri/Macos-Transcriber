import Foundation
import CoreAudio

/// `transcriberrcli virtualmic [seconds]`: checks the installed Transcriberr
/// Microphone driver end to end without a sound on the speakers. Plays a
/// gated 440 Hz tone into the hidden feed device, records the Transcriberr
/// Microphone at the same time, and reports whether the microphone
/// appeared, the level and delay of what came back, and whether it went
/// away again once the feed stopped. Quit Transcriberr first: its own feed
/// would mix into the probe's.
func cmdVirtualMic(_ args: [String]) async -> Int32 {
    if args.contains("--live") { return await virtualMicLive(args.first.flatMap(Double.init) ?? 5) }
    let seconds = args.first.flatMap(Double.init) ?? 3
    let rate = VirtualMicrophone.feedRate
    // `--loopback <UID>`: the same check through another loopback device
    // (BlackHole) as a control — all-silent results there too point at the
    // microphone permission, not at our plug-in.
    let control = args.firstIndex(of: "--loopback").flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }
    let feedUID = control ?? VirtualMicrophone.feedUID
    let micUID = control ?? VirtualMicrophone.micUID
    print("driver installed: \(VirtualMicrophone.isInstalled)")
    let feed = VirtualMicrophone.deviceID(forUID: feedUID)
    guard feed != kAudioObjectUnknown else {
        print("FAIL: no feed device — coreaudiod has not loaded the plug-in")
        return 1
    }
    let micBefore = VirtualMicrophone.deviceID(forUID: micUID)
    print("feed device \(feed); microphone before the feed starts: \(micBefore == kAudioObjectUnknown ? "absent" : "present (\(micBefore)) — is Transcriberr running?")")

    // The tone, indexed by the plug-in's sample time (both devices share
    // one timeline): 100 ms on, 100 ms off, -20 dBFS peak.
    final class Box: @unchecked Sendable {
        let lock = NSLock()
        var recorded: [(time: Int, samples: [Float], host: UInt64)] = []
        var written: [(time: Int, count: Int, host: UInt64)] = []
    }
    let box = Box()
    let tone = probeTone

    var feedProc: AudioDeviceIOProcID?
    var status = AudioDeviceCreateIOProcIDWithBlock(&feedProc, feed, nil) { now, _, _, out, outTime in
        let list = UnsafeMutableAudioBufferListPointer(out)
        guard let b = list.first, let data = b.mData else { return }
        let n = Int(b.mDataByteSize) / 4
        let t0 = Int(outTime.pointee.mSampleTime)
        let p = data.assumingMemoryBound(to: Float.self)
        for i in 0..<n { p[i] = tone(t0 + i) }
        box.lock.lock()
        box.written.append((t0, n, now.pointee.mHostTime))
        box.lock.unlock()
    }
    guard status == noErr, let feedProc else { print("FAIL: feed IO proc \(status)"); return 1 }
    status = AudioDeviceStart(feed, feedProc)
    guard status == noErr else { print("FAIL: feed start \(status)"); return 1 }

    // The microphone is published once the feed runs.
    var mic = AudioObjectID(kAudioObjectUnknown)
    let t0 = Date()
    while mic == kAudioObjectUnknown && Date().timeIntervalSince(t0) < 3 {
        mic = VirtualMicrophone.deviceID(forUID: micUID)
        if mic == kAudioObjectUnknown { try? await Task.sleep(for: .milliseconds(50)) }
    }
    guard mic != kAudioObjectUnknown else {
        AudioDeviceStop(feed, feedProc); AudioDeviceDestroyIOProcID(feed, feedProc)
        print("FAIL: the microphone did not appear within 3 s of the feed starting")
        return 1
    }
    print(String(format: "microphone appeared after %.2f s (device %u, '%@')", Date().timeIntervalSince(t0), mic,
                 AudioInputDevices.string(mic, kAudioObjectPropertyName) ?? "?"))
    let listed = AudioInputDevices.available().contains { $0.uid == VirtualMicrophone.micUID }
    print("left out of Transcriberr's own input list: \(!listed)")

    var micProc: AudioDeviceIOProcID?
    status = AudioDeviceCreateIOProcIDWithBlock(&micProc, mic, nil) { now, input, inTime, _, _ in
        let list = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        guard let b = list.first, let data = b.mData else { return }
        let n = Int(b.mDataByteSize) / 4
        let p = data.assumingMemoryBound(to: Float.self)
        let chunk = Array(UnsafeBufferPointer(start: p, count: n))
        box.lock.lock()
        box.recorded.append((Int(inTime.pointee.mSampleTime), chunk, now.pointee.mHostTime))
        box.lock.unlock()
    }
    guard status == noErr, let micProc else { print("FAIL: mic IO proc \(status)"); return 1 }
    status = AudioDeviceStart(mic, micProc)
    guard status == noErr else { print("FAIL: mic start \(status) (microphone permission?)"); return 1 }
    try? await Task.sleep(for: .seconds(seconds))
    AudioDeviceStop(mic, micProc)
    AudioDeviceDestroyIOProcID(mic, micProc)
    AudioDeviceStop(feed, feedProc)
    AudioDeviceDestroyIOProcID(feed, feedProc)

    let (recorded, written) = box.lock.withLock { (box.recorded, box.written) }
    let total = recorded.reduce(0) { $0 + $1.samples.count }
    guard total > Int(rate) / 2 else { print("FAIL: only \(total) samples recorded"); return 1 }
    var sq: Float = 0, errSq: Float = 0, silent = 0
    for chunk in recorded {
        for (i, v) in chunk.samples.enumerated() {
            sq += v * v
            let d = v - tone(chunk.time + i)
            errSq += d * d
            if v == 0 && tone(chunk.time + i) != 0 { silent += 1 }
        }
    }
    let rms = (sq / Float(total)).squareRoot()
    let errRMS = (errSq / Float(total)).squareRoot()
    print(String(format: "recorded %.2f s in %d cycles, level %.1f dBFS (the tone alone: -26.0)",
                 Double(total) / rate, recorded.count, 20 * log10(max(rms, 1e-9))))
    print(String(format: "difference from the tone at the same sample time: %.1f dBFS; %d samples silent where the tone played",
                 20 * log10(max(errRMS, 1e-9)), silent))
    // Delay through the device: host time the mic delivered sample t, minus
    // host time the feed was handed it.
    var tb = mach_timebase_info_data_t(); mach_timebase_info(&tb)
    var delays: [Double] = []
    for r in recorded {
        guard let w = written.last(where: { $0.time <= r.time && r.time < $0.time + $0.count }) else { continue }
        delays.append(Double(r.host &- w.host) * Double(tb.numer) / Double(tb.denom) / 1e6)
    }
    delays.sort()
    if !delays.isEmpty {
        print(String(format: "feed-to-microphone delay: median %.1f ms, max %.1f ms (mic IO buffer %d frames)",
                     delays[delays.count / 2], delays.last!, recorded.first?.samples.count ?? 0))
    }
    let match = errRMS < 1e-4 && silent < Int(rate) / 100

    // Feed stopped: the microphone should go away after its grace period.
    try? await Task.sleep(for: .seconds(4.5))
    let after = VirtualMicrophone.deviceID(forUID: micUID)
    print("microphone 4.5 s after the feed stopped: \(after == kAudioObjectUnknown ? "gone" : "still there (another feed running?)")")
    print(match ? "PASS: the tone came through unchanged" : "FAIL: what came through is not the tone")
    return match ? 0 : 1
}

/// The probe's tone at plug-in sample time `t` (48 kHz): 440 Hz, -20 dBFS
/// peak, 100 ms on and 100 ms off.
nonisolated private func probeTone(_ t: Int) -> Float {
    (t / 4800) % 2 == 0 ? 0.1 * sinf(2 * .pi * 440 * Float(t % 48_000) / 48_000) : 0
}

/// `transcriberrcli virtualmic [seconds] --live`: the app's own path. Turns
/// the setting on for this process, takes the unit the way a meeting
/// recording does (Apple's voice processing on the real mic, its sink into
/// the feed), and records the Transcriberr Microphone: level and gaps only,
/// so the room is enough. Nothing plays on the speakers.
private func virtualMicLive(_ seconds: Double) async -> Int32 {
    let settings = RecorderSettings.shared
    let was = settings.virtualMicrophone
    settings.virtualMicrophone = true
    defer { settings.virtualMicrophone = was }
    let vm = VirtualMicrophone.shared
    vm.refresh()
    let t0 = Date()
    while !vm.isActive && Date().timeIntervalSince(t0) < 3 { try? await Task.sleep(for: .milliseconds(50)) }
    guard vm.isActive else { print("FAIL: feed did not start"); return 1 }
    let held = vm.acquireForRecording()
    print("unit: \(held.unit == nil ? "none" : "running"), output '\(VoiceProcessedMic.outputRoute().name)'")
    let mic = VirtualMicrophone.deviceID(forUID: VirtualMicrophone.micUID)
    guard mic != kAudioObjectUnknown else { print("FAIL: no microphone device"); return 1 }

    final class Box: @unchecked Sendable { let lock = NSLock(); var samples: [Float] = [] }
    let box = Box()
    var proc: AudioDeviceIOProcID?
    AudioDeviceCreateIOProcIDWithBlock(&proc, mic, nil) { _, input, _, _, _ in
        let list = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        guard let b = list.first, let data = b.mData else { return }
        let p = data.assumingMemoryBound(to: Float.self)
        let chunk = UnsafeBufferPointer(start: p, count: Int(b.mDataByteSize) / 4)
        box.lock.withLock { box.samples.append(contentsOf: chunk) }
    }
    guard let proc else { print("FAIL: mic IO proc"); return 1 }
    AudioDeviceStart(mic, proc)
    try? await Task.sleep(for: .seconds(seconds))
    AudioDeviceStop(mic, proc)
    AudioDeviceDestroyIOProcID(mic, proc)
    if held.held { vm.releaseFromRecording() }
    vm.shutdown()

    let rec = box.lock.withLock { box.samples }
    let skip = min(rec.count, 48_000)   // the unit's first second (it starts with the probe)
    let body = rec[skip...]
    guard !body.isEmpty else { print("FAIL: nothing recorded"); return 1 }
    let rms = (body.reduce(0) { $0 + $1 * $1 } / Float(body.count)).squareRoot()
    // Gaps: runs of exact zeros of 2 ms or more (the feed padding an
    // underrun). A live mic is never exactly zero for that long.
    var gaps = 0, run = 0
    for v in body {
        if v == 0 { run += 1 } else { if run >= 96 { gaps += 1 }; run = 0 }
    }
    if run >= 96 { gaps += 1 }
    print(String(format: "recorded %.1f s after the first second: level %.1f dBFS, %d gaps of exact silence",
                 Double(body.count) / 48_000, 20 * log10(max(rms, 1e-9)), gaps))
    print("feed ring: \(vm.ring.underruns) underruns, \(vm.ring.dropped) samples dropped")
    let ok = rms > 1e-5 && gaps <= 1
    print(ok ? "PASS: the cleaned mic reaches the Transcriberr Microphone" : "FAIL")
    return ok ? 0 : 1
}
