import Foundation
import CoreAudio
import AVFoundation
import Observation

/// Meeting-mode recorder: captures the microphone AND all system audio (the
/// other meeting participants, tapped digitally before it reaches the
/// speakers) into one 16 kHz mono WAV — the exact format WavRecorder
/// produces, so every downstream stage (decode, ASR, diarization) is
/// unchanged.
///
/// Mechanics: a CoreAudio process tap (macOS 14.4+, prompts once for
/// "System Audio Recording") grabs the system mix; an aggregate device pairs
/// the tap with the default input device so both sources share one clock
/// (drift-compensated) and arrive in a single IO callback. All channels are
/// downmixed to mono, streamed through AVAudioConverter to 16 kHz, and
/// written incrementally — same converter discipline as WavRecorder.
@Observable
final class MeetingRecorder: @unchecked Sendable {

    enum MeetingError: LocalizedError {
        case coreAudio(String, OSStatus)
        case denied
        var errorDescription: String? {
            switch self {
            case .coreAudio(let what, let code):
                return "\(what) failed (\(code)). If this is the first meeting recording, grant Transcriberr “System Audio Recording” in System Settings → Privacy & Security → Screen & System Audio Recording, then try again."
            case .denied:
                return "Microphone access is not authorized."
            }
        }
    }

    private let ioQueue = DispatchQueue(label: "meeting.rec.io")

    private(set) var level: Float = 0
    private(set) var elapsedMs: Int64 = 0
    /// Rolling per-callback peak history, same shape as WavRecorder's so the
    /// Record-screen waveform can render either source.
    private(set) var peakHistory: [Float] = Array(repeating: 0, count: 64)
    nonisolated(unsafe) private var lastPublishMs: Int64 = 0

    /// Live-caption chunk feed: same 5-second 16 kHz chunks WavRecorder
    /// emits, cut from the converted output right before it hits the file.
    private var chunkContinuation: AsyncStream<WavRecorder.Chunk>.Continuation?
    private(set) var chunks: AsyncStream<WavRecorder.Chunk>
    nonisolated(unsafe) private var chunkBuffer: [Float] = []
    nonisolated(unsafe) private var chunkTotal16k: Int64 = 0

    /// "Me" timeline: intervals where the MIC was louder than the system tap.
    /// The aggregate delivers mic and tap as separate buffers, so before the
    /// downmix we know exactly which side the energy came from — ground truth
    /// no clustering can give. Saved as <recording>.me.json; after
    /// transcription the best-overlapping speaker gets the user's name.
    nonisolated(unsafe) private var meIntervals: [[Double]] = []
    nonisolated(unsafe) private var meOpenAt: Double? = nil

    init() {
        var continuation: AsyncStream<WavRecorder.Chunk>.Continuation!
        self.chunks = AsyncStream<WavRecorder.Chunk> { continuation = $0 }
        self.chunkContinuation = continuation
    }

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var tapDesc: CATapDescription?
    nonisolated(unsafe) private var converter: AVAudioConverter?
    nonisolated(unsafe) private var audioFile: AVAudioFile?
    nonisolated(unsafe) private var paused = false
    nonisolated(unsafe) private var framesSeen: Int64 = 0
    private var nativeRate: Double = 48_000
    private var fileURL: URL?
    private var isRunning = false
    private var isStarting = false

    // MARK: - Public surface (mirrors WavRecorder)

    func start() async throws {
        guard !isStarting, !isRunning else { return }
        isStarting = true
        defer { isStarting = false }

        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: break
        case .notDetermined:
            guard await AVCaptureDevice.requestAccess(for: .audio) else { throw MeetingError.denied }
        default: throw MeetingError.denied
        }

        do {
            try setupCapture()
        } catch {
            // Full cleanup: a partial setup may have opened the output file
            // already — leaving it set would let a later stray stop() return
            // an orphan header-only WAV.
            teardownCoreAudio()
            ioQueue.sync {
                self.converter = nil
                self.audioFile = nil
            }
            fileURL = nil
            throw error
        }
        isRunning = true
    }

    func stop() async throws -> URL? {
        // A second stop must NOT hand back the old URL — the caller would
        // create a duplicate Recording row for the same WAV.
        guard isRunning else { return nil }
        isRunning = false
        teardownCoreAudio()
        // Drain any in-flight IO callback, then flush the converter tail.
        ioQueue.sync {
            self.flushConverterTail()
            if let open = self.meOpenAt {
                self.meIntervals.append([open, Double(self.framesSeen) / self.nativeRate])
                self.meOpenAt = nil
            }
            if let url = self.fileURL, !self.meIntervals.isEmpty,
               let data = try? JSONEncoder().encode(self.meIntervals) {
                let sidecar = url.deletingPathExtension().appendingPathExtension("me.json")
                try? data.write(to: sidecar)
                AppLog.info("meeting", "me-timeline: \(self.meIntervals.count) intervals → \(sidecar.lastPathComponent)")
            }
            self.audioFile = nil
            self.converter = nil
        }
        AppLog.info("meeting", "stopped after \(elapsedMs / 1000)s → \(fileURL?.lastPathComponent ?? "?")")
        return fileURL
    }

    func pause()  { ioQueue.async { self.paused = true } }
    func resume() { ioQueue.async { self.paused = false } }

    // MARK: - Capture graph

    private func setupCapture() throws {
        // 1. System-audio process tap (all processes, stereo mixdown).
        let desc = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        desc.name = "Transcriberr System Tap"
        desc.isPrivate = true
        desc.muteBehavior = .unmuted
        try check(AudioHardwareCreateProcessTap(desc, &tapID), "System-audio tap")
        tapDesc = desc

        // 2. Aggregate device: default mic + the tap, one clock.
        let micUID = try defaultInputUID()
        let aggDict: [String: Any] = [
            kAudioAggregateDeviceNameKey as String: "Transcriberr Meeting",
            kAudioAggregateDeviceUIDKey as String: "nl.ihnatov.Transcriberr.meeting.\(UUID().uuidString)",
            kAudioAggregateDeviceIsPrivateKey as String: true,
            kAudioAggregateDeviceTapAutoStartKey as String: true,
            kAudioAggregateDeviceSubDeviceListKey as String: [
                [kAudioSubDeviceUIDKey as String: micUID,
                 kAudioSubDeviceDriftCompensationKey as String: true]
            ],
            kAudioAggregateDeviceTapListKey as String: [
                [kAudioSubTapUIDKey as String: desc.uuid.uuidString,
                 kAudioSubTapDriftCompensationKey as String: true]
            ],
        ]
        try check(AudioHardwareCreateAggregateDevice(aggDict as CFDictionary, &aggID), "Aggregate device")

        nativeRate = deviceSampleRate(aggID) ?? 48_000

        // 3. Converter + output file: 16 kHz mono Float32, identical to WavRecorder.
        guard
            let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000,
                                       channels: 1, interleaved: false),
            let nativeMono = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: nativeRate,
                                           channels: 1, interleaved: false),
            let conv = AVAudioConverter(from: nativeMono, to: target)
        else {
            throw MeetingError.coreAudio("Audio converter setup", -1)
        }
        conv.sampleRateConverterAlgorithm = AVSampleRateConverterAlgorithm_Normal
        conv.sampleRateConverterQuality = AVAudioQuality.high.rawValue

        let dir = FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Transcriberr/Recordings", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let name = "meeting_\(Int(Date().timeIntervalSince1970 * 1000))_\(UUID().uuidString.prefix(8)).wav"
        let url = dir.appendingPathComponent(name)
        let file = try AVAudioFile(forWriting: url, settings: target.settings,
                                   commonFormat: .pcmFormatFloat32, interleaved: false)

        ioQueue.sync {
            self.converter = conv
            self.audioFile = file
            self.paused = false
            self.framesSeen = 0
            self.chunkBuffer.removeAll(keepingCapacity: true)
            self.chunkTotal16k = 0
            self.meIntervals.removeAll(keepingCapacity: true)
            self.meOpenAt = nil
        }
        fileURL = url
        elapsedMs = 0

        // 4. IO callback on our serial queue.
        var pid: AudioDeviceIOProcID?
        try check(AudioDeviceCreateIOProcIDWithBlock(&pid, aggID, ioQueue) { [weak self] _, inData, _, _, _ in
            self?.handleIO(inData)
        }, "Audio IO callback")
        procID = pid
        try check(AudioDeviceStart(aggID, procID), "Audio device start")
        AppLog.info("meeting", "recording mic + system audio @\(Int(nativeRate)) Hz → \(name)")
    }

    private func teardownCoreAudio() {
        if let procID, aggID != kAudioObjectUnknown {
            AudioDeviceStop(aggID, procID)
            AudioDeviceDestroyIOProcID(aggID, procID)
        }
        procID = nil
        if aggID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggID)
            aggID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
        tapDesc = nil
    }

    // MARK: - IO path (runs on ioQueue)

    private func handleIO(_ abl: UnsafePointer<AudioBufferList>) {
        guard !paused, audioFile != nil else { return }
        let list = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: abl))

        var frames = 0
        for b in list {
            let ch = max(1, Int(b.mNumberChannels))
            frames = max(frames, Int(b.mDataByteSize) / (4 * ch))
        }
        guard frames > 0 else { return }

        // Downmix every source buffer (mic channels + tap channels) to mono.
        // Buffer order follows the aggregate's composition: the mic subdevice
        // first, the system tap after — measure their energy separately for
        // the "me" timeline before the identities blur into the mix.
        var mono = [Float](repeating: 0, count: frames)
        var micSq: Float = 0
        var tapSq: Float = 0
        for (bi, b) in list.enumerated() {
            guard let raw = b.mData else { continue }
            let ch = max(1, Int(b.mNumberChannels))
            let n = min(frames, Int(b.mDataByteSize) / (4 * ch))
            let p = raw.assumingMemoryBound(to: Float.self)
            var sq: Float = 0
            for f in 0..<n {
                var s: Float = 0
                for c in 0..<ch { s += p[f * ch + c] }
                let m = s / Float(ch)
                mono[f] += m
                sq += m * m
            }
            if bi == 0 { micSq = sq / Float(max(1, frames)) } else { tapSq += sq / Float(max(1, frames)) }
        }
        updateMeTimeline(micRMS: micSq.squareRoot(), tapRMS: tapSq.squareRoot(),
                         t: Double(framesSeen) / nativeRate)

        var sumSq: Float = 0
        var peak: Float = 0
        for i in 0..<frames {
            mono[i] = max(-1, min(1, mono[i]))
            sumSq += mono[i] * mono[i]
            peak = max(peak, abs(mono[i]))
        }
        let rms = min(1, sqrt(sumSq / Float(frames)) * 6)

        convertAndWrite(mono)
        framesSeen += Int64(frames)
        let ms = Int64(Double(framesSeen) / nativeRate * 1000)

        // Publish stats on the main actor (@Observable writes drive SwiftUI),
        // throttled to ~30 Hz so the HAL callback rate doesn't flood renders.
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        if now - lastPublishMs >= 33 {
            lastPublishMs = now
            Task { @MainActor [weak self] in
                self?.publishStats(rms: rms, peak: peak, ms: ms)
            }
        }
    }

    @MainActor
    private func publishStats(rms: Float, peak: Float, ms: Int64) {
        level = max(rms, level * 0.85)
        var hist = peakHistory
        hist.removeFirst()
        hist.append(peak)
        peakHistory = hist
        elapsedMs = ms
    }

    private func convertAndWrite(_ samples: [Float]) {
        guard let converter, let audioFile else { return }
        guard let inBuf = AVAudioPCMBuffer(pcmFormat: converter.inputFormat,
                                           frameCapacity: AVAudioFrameCount(samples.count)) else { return }
        inBuf.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { src in
            inBuf.floatChannelData![0].update(from: src.baseAddress!, count: samples.count)
        }
        let outCap = AVAudioFrameCount(Double(samples.count) * 16_000 / nativeRate) + 64
        guard let outBuf = AVAudioPCMBuffer(pcmFormat: converter.outputFormat,
                                            frameCapacity: outCap) else { return }
        var fed = false
        var err: NSError?
        let status = converter.convert(to: outBuf, error: &err) { _, outStatus in
            if fed { outStatus.pointee = .noDataNow; return nil }
            fed = true
            outStatus.pointee = .haveData
            return inBuf
        }
        if status == .error {
            AppLog.error("meeting", "convert failed: \(err?.localizedDescription ?? "?")")
            return
        }
        if outBuf.frameLength > 0 {
            try? audioFile.write(from: outBuf)
            if let p = outBuf.floatChannelData?[0] {
                appendToChunkBuffer(Array(UnsafeBufferPointer(start: p, count: Int(outBuf.frameLength))))
            }
        }
    }

    /// Open/close "me" intervals from per-callback energy. Mic wins when it
    /// clearly dominates the tap; short blips (<0.3 s) are dropped.
    private func updateMeTimeline(micRMS: Float, tapRMS: Float, t: Double) {
        let micActive = micRMS > 0.004 && micRMS > tapRMS * 1.5
        if micActive {
            if meOpenAt == nil { meOpenAt = t }
        } else if let open = meOpenAt {
            if t - open >= 0.3 {
                if let last = meIntervals.last, open - last[1] < 0.6 {
                    meIntervals[meIntervals.count - 1][1] = t
                } else {
                    meIntervals.append([open, t])
                }
            }
            meOpenAt = nil
        }
    }

    /// Mirror of WavRecorder.appendToChunkBuffer — same size, same timing math.
    private func appendToChunkBuffer(_ samples: [Float]) {
        chunkTotal16k += Int64(samples.count)
        chunkBuffer.append(contentsOf: samples)
        let chunkSize = Int(WavRecorder.chunkSeconds * WavRecorder.sampleRate)
        while chunkBuffer.count >= chunkSize {
            let head = Array(chunkBuffer.prefix(chunkSize))
            chunkBuffer.removeFirst(chunkSize)
            let startSec = Double(chunkTotal16k - Int64(chunkBuffer.count) - Int64(chunkSize)) / WavRecorder.sampleRate
            DispatchQueue.main.async { [weak self] in
                self?.chunkContinuation?.yield(
                    WavRecorder.Chunk(samples: head, startTimeSeconds: max(0, startSec)))
            }
        }
    }

    private func flushConverterTail() {
        guard let converter, let audioFile else { return }
        let outCap: AVAudioFrameCount = 4096
        guard let outBuf = AVAudioPCMBuffer(pcmFormat: converter.outputFormat,
                                            frameCapacity: outCap) else { return }
        var err: NSError?
        let status = converter.convert(to: outBuf, error: &err) { _, outStatus in
            outStatus.pointee = .endOfStream
            return nil
        }
        if status != .error, outBuf.frameLength > 0 {
            try? audioFile.write(from: outBuf)
        }
    }

    // MARK: - CoreAudio helpers

    private func check(_ status: OSStatus, _ what: String) throws {
        guard status == noErr else {
            AppLog.error("meeting", "\(what) failed: OSStatus \(status)")
            throw MeetingError.coreAudio(what, status)
        }
    }

    private func defaultInputUID() throws -> String {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var dev = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        try check(AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                             &addr, 0, nil, &size, &dev), "Default input lookup")
        addr.mSelector = kAudioDevicePropertyDeviceUID
        var uid: CFString? = nil
        size = UInt32(MemoryLayout<CFString?>.size)
        try check(AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &uid), "Input UID lookup")
        guard let uid else { throw MeetingError.coreAudio("Input UID lookup", -1) }
        return uid as String
    }

    private func deviceSampleRate(_ device: AudioObjectID) -> Double? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var rate: Float64 = 0
        var size = UInt32(MemoryLayout<Float64>.size)
        guard AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &rate) == noErr, rate > 0 else {
            return nil
        }
        return rate
    }
}
