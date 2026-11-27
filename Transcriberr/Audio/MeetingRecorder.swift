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
/// No actor isolation on the type (see `WavRecorder`): explicitly
/// `nonisolated`, since the module default is the main actor. The IO
/// callback's state lives in `io` and is only touched on `ioQueue`.
@Observable
nonisolated final class MeetingRecorder: @unchecked Sendable {

    enum MeetingError: LocalizedError {
        case coreAudio(String, OSStatus)
        case denied
        var errorDescription: String? {
            switch self {
            case .coreAudio(let what, let code):
                return String(localized: "\(what) failed (\(code)). If this is the first meeting recording, grant Transcriberr “System Audio Recording” in System Settings → Privacy & Security → Screen & System Audio Recording, then try again.", comment: "First value is a Core Audio step name in English, second an error code")
            case .denied:
                return String(localized: "Microphone access is not authorized.")
            }
        }
    }

    private let ioQueue = DispatchQueue(label: "meeting.rec.io")

    /// The IO path's state. Only touched on `ioQueue` — the IO proc runs
    /// there, and every other access sits in an `ioQueue.sync`/`async`
    /// block — which is what makes the unchecked Sendable true.
    private nonisolated final class IOState: @unchecked Sendable {
        var converter: AVAudioConverter?
        var audioFile: AVAudioFile?
        /// Raw per-source tracks saved alongside the mix: <base>.mic.wav (you)
        /// and <base>.sys.wav (everyone else). The mix stays the primary
        /// recording; the tracks preserve ground truth for split-track
        /// (re-)transcription.
        var micConverter: AVAudioConverter?
        var micFile: AVAudioFile?
        var sysConverter: AVAudioConverter?
        var sysFile: AVAudioFile?
        var paused = false
        var framesSeen: Int64 = 0
        var lastPublishMs: Int64 = 0
        /// Channel count the system tap was created with — chosen per
        /// session so it never equals the microphone's (see
        /// `tapChannelCount`). The IO callback tells the two sources apart
        /// by it.
        var tapChannels = 2
        var warnedPositionalFallback = false
        var nativeRate: Double = 48_000
        /// Live-caption chunking (see `appendToChunkBuffer`).
        var chunkBuffer: [Float] = []
        var chunkTotal16k: Int64 = 0
        /// "Me" timeline: intervals where the MIC was louder than the system
        /// tap. The aggregate delivers mic and tap as separate buffers, so
        /// before the downmix we know exactly which side the energy came
        /// from — ground truth no clustering can give. Saved as
        /// <recording>.me.json; after transcription the best-overlapping
        /// speaker gets the user's name.
        var meIntervals: [[Double]] = []
        var meOpenAt: Double? = nil
        /// The meeting app is muted (see `MeetingMuteMonitor`): the mic
        /// leaves the live mix and captions. The `.mic` track keeps it, and
        /// these stretches go to <recording>.mute.json, so what becomes of
        /// them can still be decided after the meeting (see `MicMute`).
        var micMuted = false
        /// What the meeting app says, and what the Record screen's switch
        /// says; `micMuted` is the two combined (see `MicSwitch.leavesOut`).
        var appMuted = false
        var micSwitch: MicSwitch = .auto
        var muteIntervals: [[Double]] = []
        var muteOpenAt: Double? = nil
        /// The stretches the switch stood at Mic off: also in
        /// `muteIntervals`, and marked so that nothing is kept from them.
        var offIntervals: [[Double]] = []
        var offOpenAt: Double? = nil
        /// Echo duck: while the system tap is loud and the mic is NOT
        /// dominant, the mic is mostly hearing the speakers — its
        /// contribution to the mix (and the mic track) is attenuated.
        /// Smoothed so it never pumps.
        var micGain: Float = 1
        /// Apple's echo filter on the mic while on speakers. When it
        /// delivers, its cleaned samples replace the raw mic everywhere in
        /// `handleIO` — gate, me-timeline, mix and the `.mic` track.
        var voiceMic: VoiceProcessedMic?
        /// `voiceMic` belongs to the Transcriberr Microphone (a call may
        /// still be using it): hand it back instead of stopping it.
        var voiceMicBorrowed = false
    }
    @ObservationIgnored private let io = IOState()

    private(set) var level: Float = 0
    /// The meeting app that has the user muted right now, if any.
    private(set) var mutedIn: String?
    /// The Record screen's switch for this meeting. Back to `.auto` with
    /// every new recording.
    private(set) var micSwitch: MicSwitch = .auto
    @ObservationIgnored private let muteMonitor = MeetingMuteMonitor()
    private(set) var elapsedMs: Int64 = 0
    /// Rolling per-callback peak history, same shape as WavRecorder's so the
    /// Record-screen waveform can render either source.
    private(set) var peakHistory: [Float] = Array(repeating: 0, count: 64)

    /// Live-caption chunk feed: same one-second 16 kHz chunks WavRecorder
    /// emits, cut from the converted output right before it hits the file.
    let liveFeed = LiveChunkFeed(backlog: MeetingRecorder.liveChunkBacklog)

    init() {}

    /// For `MeetingMoveCheck` only: record the plain mic and the call audio
    /// into `recordingsDirectory` — no Transcriberr Microphone, no echo
    /// filter, no mute following. A check run beside the user's own app
    /// must not open a second unit on a mic a call is using (that breaks
    /// the call's mic), duck other apps, or leave files where the library's
    /// crash repair would import them.
    @ObservationIgnored var plainCapture = false
    @ObservationIgnored var recordingsDirectory: URL?

    /// Live captions consume these one-second chunks in real time; if the
    /// consumer falls behind (a stalled main thread), an unbounded stream
    /// grows for the whole session and the captions fall further and further
    /// behind the audio. Dropping the oldest backlog keeps captions near the
    /// live edge — the transcript of record comes from the file, not from
    /// this feed. The live worker only appends on arrival, so 40 s of slack
    /// is never reached in normal use.
    static let liveChunkBacklog = 40

    // The capture graph's handles. Written by `startCapture` /
    // `teardownCoreAudio` on the pool, never shown: kept out of observation
    // so those writes don't run SwiftUI's registrar off the main actor.
    @ObservationIgnored private var tapID = AudioObjectID(kAudioObjectUnknown)
    @ObservationIgnored private var aggID = AudioObjectID(kAudioObjectUnknown)
    @ObservationIgnored private var procID: AudioDeviceIOProcID?
    @ObservationIgnored private var tapDesc: CATapDescription?
    @ObservationIgnored private var fileURL: URL?
    /// Exposed read-only so dictation can refuse to open a second input
    /// chain while a meeting is being captured.
    private(set) var isRunning = false
    private var isStarting = false

    /// A capture is starting or running. Launch-time crash repair
    /// (`WavRepair`) must not run while this is true.
    var isCapturing: Bool { isStarting || isRunning }

    /// Set when capture ended on its own mid-meeting: the microphone was
    /// unplugged (or the aggregate built on it died), after which the
    /// aggregate stops calling the IO proc and the file silently stops
    /// growing. The graph is torn down and the files closed at that moment,
    /// but `isRunning` stays true so the next `stop()` still returns the
    /// file with everything captured up to then. Cleared by `start()`.
    private(set) var interruption: String?
    /// Called on the main actor once `interruption` is set, so the owner can
    /// react (say, run its normal Stop) without polling.
    @ObservationIgnored var onInterrupted: (@MainActor (String) -> Void)?

    /// Called on the main actor when the recording moved to another
    /// microphone (or to the call audio alone) and carries on, with a line
    /// to show the user.
    @ObservationIgnored var onMicMoved: (@MainActor (String) -> Void)?
    /// The microphone this meeting started on (it is moved back to it when
    /// it returns) and the one it records from now; nil: the call audio
    /// alone. Main actor.
    @ObservationIgnored private var sessionMicUID: String?
    @ObservationIgnored private var currentMicUID: String?
    /// A move is under way: device events wait for it to finish.
    @ObservationIgnored private var isMoving = false
    /// Watches that audio keeps arriving (see `watchForStalls`).
    @ObservationIgnored private var stallWatch: Task<Void, Never>?
    /// Counts recording sessions, so a move still finishing from the last
    /// one never touches the next. Main actor.
    @ObservationIgnored private var session = 0
    /// Microphones that would not open (or were just lost), and until when
    /// they are left alone: a headset reconnecting is listed before it can
    /// record, and moving onto it again and again would cut a gap into the
    /// files each time. Main actor.
    @ObservationIgnored private var coolingDown: [String: Date] = [:]
    static let coolDownSeconds: TimeInterval = 20

    /// The microphone the aggregate was built on, watched for removal.
    @ObservationIgnored private var micDeviceID = AudioObjectID(kAudioObjectUnknown)
    /// Main-actor copies of the devices being watched (the pool-side IDs
    /// are reset by teardown while a listener callback may be queued).
    @ObservationIgnored private var watchedMic = AudioObjectID(kAudioObjectUnknown)
    @ObservationIgnored private var watchedAggregate = AudioObjectID(kAudioObjectUnknown)
    /// The output kept running for the tap (main-actor copy).
    @ObservationIgnored private var watchedClock = AudioObjectID(kAudioObjectUnknown)
    /// The rate the converters were built for (main-actor copy).
    @ObservationIgnored private var watchedRate: Double = 0
    @ObservationIgnored private var deviceListeners: [(object: AudioObjectID, address: AudioObjectPropertyAddress,
                                   block: AudioObjectPropertyListenerBlock)] = []
    /// Serializes `finishCapture` — an interruption and a Stop can both
    /// arrive — and the listener list it empties.
    private let captureLock = NSLock()

    // MARK: - Public surface (mirrors WavRecorder)

    /// Nonisolated on purpose — tap and aggregate creation block — so the
    /// observable flags (`isStarting`, `isRunning`, `elapsedMs`, the chunk
    /// stream) are claimed and released on the main actor rather than
    /// written from the pool underneath SwiftUI and `publishStats`.
    /// `@concurrent` keeps it on the pool: a plain nonisolated async function
    /// runs on its caller's actor, which for the Record button is main.
    @concurrent
    func start() async throws {
        // A move from the last session (Stop landed during it) finishes
        // first: it must not rebuild the graph this start is building.
        while await MainActor.run(body: { self.isMoving }) {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        let claimed = await MainActor.run { () -> Bool in
            guard !isStarting, !isRunning else { return false }
            isStarting = true
            interruption = nil
            session += 1
            coolingDown.removeAll()
            return true
        }
        guard claimed else { return }
        do {
            try await startCapture()
            await MainActor.run {
                watchDevices()
                isRunning = true
                isStarting = false
                if !plainCapture { startFollowingMute() }
                watchForStalls()
                // A device lost while starting was ignored (not running yet).
                handleDeviceChange()
            }
        } catch {
            await MainActor.run { isStarting = false }
            throw error
        }
    }

    private func startCapture() async throws {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: break
        case .notDetermined:
            guard await AVCaptureDevice.requestAccess(for: .audio) else { throw MeetingError.denied }
        default: throw MeetingError.denied
        }

        do {
            try await setupCapture()
        } catch {
            // Full cleanup: a partial setup may have opened the output file
            // already — leaving it set would let a later stray stop() return
            // an orphan header-only WAV.
            teardownCoreAudio()
            ioQueue.sync {
                let io = self.io
                io.converter = nil
                io.audioFile = nil
                io.micConverter = nil; io.micFile = nil
                io.sysConverter = nil; io.sysFile = nil
            }
            // Delete the header-only files this attempt already created.
            // They are real files in ~/Documents/Transcriberr/Recordings —
            // three per failed start, invisible to the library (no row ever
            // referenced them) and never cleaned up by anything.
            if let partial = fileURL {
                let base = partial.deletingPathExtension()
                for suffix in ["wav", "mic.wav", "sys.wav"] {
                    try? FileManager.default.removeItem(
                        at: base.appendingPathExtension(suffix))
                }
            }
            fileURL = nil
            throw error
        }
    }

    /// `@concurrent` for the same reason as `start()`: `finishCapture` waits
    /// for the IO proc to return.
    @concurrent
    func stop() async throws -> URL? {
        // A stop that lands while start() is still setting up must wait for
        // it: returning nil here would let start() finish afterwards and leave a
        // capture running — mic open, files growing — that nothing could stop.
        while await MainActor.run(body: { self.isStarting }) {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        // A second stop must NOT hand back the old URL — the caller would
        // create a duplicate Recording row for the same WAV.
        let wasRunning = await MainActor.run { () -> Bool in
            guard isRunning else { return false }
            isRunning = false
            stallWatch?.cancel()
            stallWatch = nil
            return true
        }
        guard wasRunning else { return nil }
        let finalMs = finishCapture()
        let elapsed = await MainActor.run { () -> Int64 in
            if finalMs > 0 { elapsedMs = finalMs }
            liveFeed.finishAll()
            return elapsedMs
        }
        AppLog.info("meeting", "stopped after \(elapsed / 1000)s → \(fileURL?.lastPathComponent ?? "?")")
        return fileURL
    }

    /// Stop's capture work without the state flip: remove the device
    /// listeners, tear the CoreAudio graph down, flush and close the three
    /// files, write the me-timeline. Idempotent — a second call finds
    /// nothing open and returns the same elapsed time. Returns milliseconds
    /// actually captured.
    private func finishCapture() -> Int64 {
        captureLock.lock()
        defer { captureLock.unlock() }
        muteMonitor.stop()
        Task { @MainActor in self.mutedIn = nil; self.micSwitch = .auto }
        removeDeviceListeners()
        teardownCoreAudio()
        // Drain any in-flight IO callback, then flush the converter tail.
        var finalMs: Int64 = 0
        ioQueue.sync {
            let io = self.io
            // Exact elapsed time from the frames actually captured — the
            // published value is throttled (~30 Hz) and can lag the last
            // callback, and the caller saves the recording's duration from it.
            finalMs = Int64(Double(io.framesSeen) / io.nativeRate * 1000)
            self.flushConverterTail()
            self.flushTrackTail(converter: io.micConverter, file: io.micFile)
            self.flushTrackTail(converter: io.sysConverter, file: io.sysFile)
            io.micConverter = nil; io.micFile = nil
            io.sysConverter = nil; io.sysFile = nil
            if let open = io.meOpenAt {
                io.meIntervals.append([open, Double(io.framesSeen) / io.nativeRate])
                io.meOpenAt = nil
            }
            if let url = self.fileURL, !io.meIntervals.isEmpty,
               let data = try? JSONEncoder().encode(io.meIntervals) {
                let sidecar = url.deletingPathExtension().appendingPathExtension("me.json")
                AppLog.attempt("meeting", "writing \(sidecar.lastPathComponent)") { try data.write(to: sidecar) }
                AppLog.info("meeting", "me-timeline: \(io.meIntervals.count) intervals → \(sidecar.lastPathComponent)")
                io.meIntervals.removeAll()   // written once, even if finish runs twice
            }
            if let open = io.muteOpenAt {
                io.muteIntervals.append([open, Double(io.framesSeen) / io.nativeRate])
                io.muteOpenAt = nil
            }
            if let open = io.offOpenAt {
                io.offIntervals.append([open, Double(io.framesSeen) / io.nativeRate])
                io.offOpenAt = nil
            }
            if let url = self.fileURL, !io.muteIntervals.isEmpty {
                MicMute.save(MicMuteLog(mode: .follow, muted: io.muteIntervals, off: io.offIntervals), forMain: url)
                AppLog.info("meeting", "mic left out: \(io.muteIntervals.count) stretches, \(io.offIntervals.count) by the Mic off switch")
                io.muteIntervals.removeAll()
                io.offIntervals.removeAll()
            }
            io.micMuted = false
            io.micSwitch = .auto
            io.audioFile = nil
            io.converter = nil
        }
        return finalMs
    }

    // MARK: - Device loss

    /// Watch the microphone and the aggregate for removal, and the device
    /// list as a backstop (a USB mic yanked out is reported there even when
    /// its own is-alive notification never comes). CoreAudio calls these on
    /// the main queue; `handleDeviceChange` decides.
    @MainActor
    private func watchDevices() {
        captureLock.lock()
        defer { captureLock.unlock() }
        watchedMic = micDeviceID
        watchedAggregate = aggID
        watchedRate = ioQueue.sync { io.nativeRate }
        watchedClock = clockDevice
        func listen(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) {
            guard object != kAudioObjectUnknown else { return }
            var address = AudioObjectPropertyAddress(
                mSelector: selector,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain)
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                Task { @MainActor [weak self] in self?.handleDeviceChange() }
            }
            if AudioObjectAddPropertyListenerBlock(object, &address, DispatchQueue.main, block) == noErr {
                deviceListeners.append((object: object, address: address, block: block))
            }
        }
        listen(watchedMic, kAudioDevicePropertyDeviceIsAlive)
        listen(watchedAggregate, kAudioDevicePropertyDeviceIsAlive)
        // A rate change (Audio MIDI Setup, another app, a Bluetooth profile
        // switch) would leave the converters resampling from the old rate,
        // and the file would speed up or slow down with no sign of it, so
        // the converters are rebuilt for the new rate (`rebuildConverters`).
        listen(watchedMic, kAudioDevicePropertyNominalSampleRate)
        listen(watchedAggregate, kAudioDevicePropertyNominalSampleRate)
        listen(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDevices)
        // The tap follows the default output; the output clock must too.
        listen(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice)
    }

    /// Called with `captureLock` held.
    private func removeDeviceListeners() {
        for var l in deviceListeners {
            AudioObjectRemovePropertyListenerBlock(l.object, &l.address, DispatchQueue.main, l.block)
        }
        deviceListeners.removeAll()
    }

    /// A watched device died mid-meeting: end capture now — the aggregate
    /// has stopped (or is about to stop) delivering audio, and the screen
    /// would otherwise keep saying RECORDING over a file that no longer
    /// grows. Everything captured so far is flushed and closed; `stop()`
    /// hands it back as usual. A sample-rate change is not an ending: the
    /// converters are rebuilt and the recording continues, unless that
    /// rebuild fails.
    @MainActor
    private func handleDeviceChange() {
        guard isRunning, interruption == nil, !isMoving else { return }
        let micGone = !Self.isAlive(watchedMic)
        if micGone || !Self.isAlive(watchedAggregate) {
            // The meeting goes on without that microphone, so the recording
            // does too: before v5.9.2 this ended the recording, and the rest
            // of a meeting whose headset dropped was never captured.
            AppLog.warn("meeting", "\(micGone ? "the microphone was disconnected" : "the meeting audio device stopped") mid-meeting — moving the recording to another microphone")
            moveMicrophone(micLost: micGone)
            return
        }
        if Self.outputMoved(clock: watchedClock, now: Self.defaultOutputDevice()) {
            // Headphones in or out, a headset gone: the tap follows the new
            // default output by itself, but only the old one is kept
            // running. Move just the output clock: no gap in the files, the
            // mic and the echo filter untouched.
            moveOutputClock()
            return
        }
        if let newRate = deviceSampleRate(watchedAggregate),
           Self.rateChanged(capture: watchedRate, now: newRate) {
            // A rate change is survivable: rebuild the converters for the
            // new rate and keep writing the same files. Only a rebuild that
            // cannot be done ends the recording.
            AppLog.warn("meeting", "aggregate rate moved from \(Int(watchedRate)) Hz to \(Int(newRate)) Hz — rebuilding converters")
            if rebuildConverters(forRate: newRate) { return }
            endOnDeviceLoss(reason: "The audio device changed its sample rate",
                            message: String(localized: "The audio device changed its sample rate, so the meeting recording stopped. Press Stop to keep what was recorded."))
            return
        }
        // The device list moved (a headset back, a mic plugged in): back to
        // the microphone the meeting started on, or onto any microphone
        // while only the call audio is recording.
        let devices = AudioInputDevices.available()
        let pick = Self.pickMic(startedOn: sessionMicUID, avoiding: coolingSet(),
                                chosen: RecorderSettings.inputDeviceUIDNow,
                                systemDefault: AudioInputDevices.systemDefault()?.uid,
                                available: devices.map(\.uid))
        guard Self.shouldMoveBack(current: currentMicUID, pick: pick, startedOn: sessionMicUID),
              let id = devices.first(where: { $0.uid == pick })?.id, Self.isAlive(id) else { return }
        moveMicrophone(micLost: false)
    }

    /// The microphones still cooling down (see `coolingDown`).
    @MainActor
    private func coolingSet() -> Set<String> {
        let now = Date()
        coolingDown = coolingDown.filter { $0.value > now }
        return Set(coolingDown.keys)
    }

    @MainActor
    private func coolDown(_ uid: String?) {
        guard let uid else { return }
        coolingDown[uid] = Date().addingTimeInterval(Self.coolDownSeconds)
    }

    /// An aggregate can stay "alive" and still stop calling the IO proc,
    /// or never start calling it after a rebuild (seen in the move checks:
    /// a rebuilt graph delivered under a second, then nothing): the file
    /// stops growing with no notification at all. Once a second, check that
    /// frames still arrive; after two seconds without any (not paused, no
    /// move under way) rebuild the graph the way a lost device is.
    @MainActor
    private func watchForStalls() {
        stallWatch?.cancel()
        stallWatch = Task { @MainActor [weak self] in
            var last: Int64 = -1
            var state = StallState()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self, !Task.isCancelled, self.isRunning, self.interruption == nil else { return }
                let (frames, paused) = self.ioQueue.sync { (self.io.framesSeen, self.io.paused) }
                if self.isMoving {
                    // A rebuild is under way: wait for audio from the new
                    // graph before judging it.
                    last = frames
                    state.still = 0
                    state.armed = false
                    continue
                }
                let rebuild = Self.stallStep(frames: frames, last: last, paused: paused, state: &state)
                last = frames
                if rebuild {
                    AppLog.warn("meeting", "no audio for \(Self.stallSeconds) s with the device still there — rebuilding the capture (\(state.rebuilds) of \(Self.maxStallRebuilds))")
                    self.moveMicrophone(micLost: false)
                }
            }
        }
    }

    static let stallSeconds = 2
    /// Stall rebuilds per recording. A graph that never delivers (no
    /// System Audio Recording permission, say) is not rebuilt at all — the
    /// watchdog arms only once audio has flowed — and one that keeps dying
    /// is not torn down forever, each time toggling the echo filter's duck
    /// and the Transcriberr Microphone's unit.
    static let maxStallRebuilds = 3

    struct StallState: Equatable {
        /// Audio has arrived since the last (re)build.
        var armed = false
        var still = 0
        var rebuilds = 0
    }

    /// One watchdog tick (once a second): true when the capture should be
    /// rebuilt now. Paused counts as moving.
    nonisolated static func stallStep(frames: Int64, last: Int64, paused: Bool,
                                      state: inout StallState) -> Bool {
        if paused { state.still = 0; return false }
        if frames > max(last, 0) { state.armed = true; state.still = 0; return false }
        guard state.armed else { return false }
        state.still += 1
        guard state.still >= stallSeconds, state.rebuilds < maxStallRebuilds else { return false }
        state.rebuilds += 1
        state.still = 0
        state.armed = false
        return true
    }

    /// For `transcriberrcli meetingmove`: act as if the current microphone
    /// had just been unplugged, through the same move a real removal takes.
    @MainActor
    func simulateMicLoss() {
        guard isRunning, interruption == nil else { return }
        AppLog.warn("meeting", "simulated microphone loss — moving the recording to another microphone")
        // It is still plugged in: without the cool-down the recording
        // would move straight back to it.
        coolDown(currentMicUID)
        moveMicrophone(micLost: true)
    }

    /// The microphone being recorded now (nil: the call audio alone).
    @MainActor var currentMicrophoneUID: String? { currentMicUID }

    /// The default output is no longer the one the output clock runs. With
    /// no output to follow, or no clock running (it could not be started:
    /// rebuilding would only fail again, in a loop), nothing moved.
    nonisolated static func outputMoved(clock: AudioObjectID, now: AudioObjectID?) -> Bool {
        guard let now, clock != kAudioObjectUnknown else { return false }
        return now != clock
    }

    /// The microphone to record from: the one the meeting started on while
    /// it is connected, else the one picked in Settings, else the system
    /// default; never one in `avoiding` — the one that just went away (the
    /// system default can still name it for a moment) or one cooling down
    /// after it would not open. Nil: no microphone left — the call audio
    /// records alone.
    nonisolated static func pickMic(startedOn: String?, avoiding: Set<String>, chosen: String?,
                                    systemDefault: String?, available: [String]) -> String? {
        for uid in [startedOn, chosen, systemDefault] {
            if let uid, !uid.isEmpty, !avoiding.contains(uid), available.contains(uid) { return uid }
        }
        return nil
    }

    /// What a move tries, in order: the picked mic twice (a device still
    /// coming up refuses for a moment), then the mic it was on if that one
    /// still works, then the call audio alone. Never the same one twice
    /// in a row beyond the first retry.
    nonisolated static func moveAttempts(target: String?, previous: String?, previousUsable: Bool) -> [String?] {
        var out: [String?] = [target, target]
        if previousUsable, let previous, previous != target { out.append(previous) }
        if target != nil { out.append(nil) }
        return out
    }

    /// With the current microphone still working, move only back to the one
    /// the meeting started on, or onto any microphone while there is none.
    /// A mic plugged in mid-meeting does not take over a working one.
    nonisolated static func shouldMoveBack(current: String?, pick: String?, startedOn: String?) -> Bool {
        guard let pick, pick != current else { return false }
        return current == nil || pick == startedOn
    }

    /// Rebuild the capture graph on another microphone (or on the call
    /// audio alone) and keep writing the same three files. Off the main
    /// actor: tearing the graph down waits for the IO proc. `micLost`: the
    /// current microphone went away (otherwise the aggregate died under a
    /// working mic, or a mic came back).
    /// Only when even the call audio cannot be captured does the recording
    /// end, the way it did before.
    @MainActor
    private func moveMicrophone(micLost: Bool) {
        guard !isMoving else { return }
        isMoving = true
        let previous = currentMicUID
        if micLost { coolDown(previous) }
        let avoiding = coolingSet()
        let previousUsable = !micLost && previous.flatMap { AudioInputDevices.resolve(uid: $0) }.map { Self.isAlive($0.id) } == true
        let started = sessionMicUID
        let mySession = session
        Task.detached(priority: .userInitiated) { [self] in
            // Right after a removal the system default can still name the
            // lost device, or nothing: give it a second to settle before
            // falling back to the call audio alone.
            var target: String?
            for attempt in 0..<10 {
                target = Self.pickMic(startedOn: started, avoiding: avoiding,
                                      chosen: RecorderSettings.inputDeviceUIDNow,
                                      systemDefault: AudioInputDevices.systemDefault()?.uid,
                                      available: AudioInputDevices.available().map(\.uid))
                if target != nil || !micLost || attempt == 9 { break }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            var moved = false
            var onto: AudioInputDevices.Device?
            var failed: Set<String> = []
            let attempts = Self.moveAttempts(target: target, previous: previous, previousUsable: previousUsable)
            for (i, uid) in attempts.enumerated() {
                let current = await MainActor.run { self.isRunning && self.session == mySession }
                guard current else { break }
                let mic = uid.flatMap { AudioInputDevices.resolve(uid: $0) }
                if uid != nil, mic == nil { if let uid { failed.insert(uid) }; continue }
                if self.rebuildGraph(on: mic) { moved = true; onto = mic; break }
                if let uid { failed.insert(uid) }
                if i < attempts.count - 1 { try? await Task.sleep(nanoseconds: 250_000_000) }
            }
            let movedOnto = onto
            await MainActor.run {
                // Always cleared: Start waits on it.
                self.isMoving = false
                guard self.session == mySession else { return }
                for uid in failed where uid != movedOnto?.uid { self.coolDown(uid) }
                guard self.isRunning else { return }
                guard moved else {
                    self.endOnDeviceLoss(
                        reason: "The microphone was disconnected",
                        message: String(localized: "The microphone was disconnected, so the meeting recording stopped. Press Stop to keep what was recorded."))
                    return
                }
                self.currentMicUID = movedOnto?.uid
                self.watchDevices()
                if movedOnto?.uid == previous {
                    // Same source, rebuilt (a dead aggregate, a stall):
                    // nothing the user needs to hear about.
                    AppLog.info("meeting", "recording continues on \(movedOnto.map { "'\($0.name)'" } ?? "the call audio alone")")
                } else {
                    let message: String
                    if let mic = movedOnto {
                        AppLog.info("meeting", "recording continues on '\(mic.name)' into the same files")
                        message = micLost
                            ? String(localized: "The microphone was disconnected. The recording carries on with “\(mic.name)”.")
                            : String(localized: "The recording now uses “\(mic.name)”.")
                    } else {
                        AppLog.warn("meeting", "no microphone left — recording continues with the call audio only")
                        message = String(localized: "The microphone was disconnected. The recording carries on with the call audio and takes a microphone as soon as one is connected.")
                    }
                    self.onMicMoved?(message)
                }
                // Anything that changed while the graph was rebuilt.
                self.handleDeviceChange()
            }
        }
    }

    /// One attempt at the move, holding `captureLock` so a Stop waits for
    /// it (and finds a graph it can tear down). False when the graph could
    /// not be built, or the files are already closed (a Stop got there
    /// first). The gap is what the rebuild takes: well under a second.
    private nonisolated func rebuildGraph(on mic: AudioInputDevices.Device?) -> Bool {
        captureLock.lock()
        defer { captureLock.unlock() }
        removeDeviceListeners()
        teardownCoreAudio()
        let open = ioQueue.sync { () -> Bool in
            let io = self.io
            guard io.audioFile != nil else { return false }
            // What the old converters still hold goes into the files first.
            self.flushConverterTail(feedLive: true)
            self.flushTrackTail(converter: io.micConverter, file: io.micFile)
            self.flushTrackTail(converter: io.sysConverter, file: io.sysFile)
            return true
        }
        guard open else { return false }
        do {
            let graph = try buildGraph(micUID: mic?.uid, micID: mic?.id ?? AudioObjectID(kAudioObjectUnknown),
                                       echoFilterInput: mic?.uid)
            guard let mix = Self.makeConverter(nativeRate: graph.rate),
                  let micConv = Self.makeConverter(nativeRate: graph.rate),
                  let sysConv = Self.makeConverter(nativeRate: graph.rate) else {
                throw MeetingError.coreAudio("Audio converter setup", -1)
            }
            ioQueue.sync {
                let io = self.io
                io.converter = mix
                io.micConverter = io.micFile == nil ? nil : micConv
                io.sysConverter = io.sysFile == nil ? nil : sysConv
                io.framesSeen = Self.convertFrameCount(io.framesSeen, from: io.nativeRate, to: graph.rate)
                io.nativeRate = graph.rate
                io.tapChannels = graph.tapChannels
                io.warnedPositionalFallback = false
                io.micGain = 1
                io.voiceMic?.setTargetRate(graph.rate)
            }
            try startIO()
            AppLog.info("meeting", "capture rebuilt on \(mic.map { "'\($0.name)'" } ?? "the call audio alone") @\(Int(graph.rate)) Hz")
            return true
        } catch {
            AppLog.warn("meeting", "moving the recording to \(mic?.name ?? "the call audio") failed: \(error.localizedDescription)")
            teardownCoreAudio()
            return false
        }
    }

    /// End the recording because its audio device is gone for good: the
    /// files are closed with everything captured, and the owner is told.
    @MainActor
    private func endOnDeviceLoss(reason: String, message: String) {
        AppLog.warn("meeting", "\(reason.lowercased()) mid-meeting — closing capture, audio so far is kept")
        interruption = message
        stallWatch?.cancel()
        stallWatch = nil
        // Off the main actor: AudioDeviceStop waits for the IO proc to return.
        Task.detached(priority: .userInitiated) { [self] in
            let ms = self.finishCapture()
            // Still this session (no Stop + new start in between).
            await MainActor.run { if ms > 0, self.interruption != nil { self.elapsedMs = ms } }
        }
        onInterrupted?(message)
    }

    /// The device now runs at a rate other than the one capture was set up
    /// for. An unreadable rate is not a change (the is-alive check covers a
    /// device that went away).
    nonisolated static func rateChanged(capture: Double, now: Double?) -> Bool {
        guard capture > 0, let now, now > 0 else { return false }
        return abs(now - capture) >= 1
    }

    /// A frame count captured at `oldRate`, expressed at `newRate` — the
    /// same span of time. `framesSeen` is counted at the capture rate and
    /// every timestamp (elapsed time, the me-timeline) divides it by that
    /// rate, so on a rate change it is re-expressed at the new one and the
    /// timeline continues instead of jumping. A non-positive rate leaves
    /// the count as it is.
    nonisolated static func convertFrameCount(_ frames: Int64, from oldRate: Double, to newRate: Double) -> Int64 {
        guard oldRate > 0, newRate > 0, frames > 0 else { return frames }
        return Int64((Double(frames) * newRate / oldRate).rounded())
    }

    /// Native-rate mono → 16 kHz mono converter, the one every output
    /// (mix and both tracks) is written through. Nil when AVFoundation
    /// cannot build it for this rate.
    nonisolated static func makeConverter(nativeRate: Double) -> AVAudioConverter? {
        guard nativeRate > 0,
              let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000,
                                         channels: 1, interleaved: false),
              let nativeMono = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: nativeRate,
                                             channels: 1, interleaved: false),
              let conv = AVAudioConverter(from: nativeMono, to: target)
        else { return nil }
        conv.sampleRateConverterAlgorithm = AVSampleRateConverterAlgorithm_Normal
        conv.sampleRateConverterQuality = AVAudioQuality.high.rawValue
        return conv
    }

    /// The aggregate now delivers `newRate`: swap in converters built for
    /// it, the way WavRecorder's configuration-change handling does. The
    /// converters are built here (not on the IO thread); the swap runs on
    /// `ioQueue` between two IO callbacks — the old converters' tails are
    /// flushed into the files first, `framesSeen` is re-expressed at the
    /// new rate, and the same files keep growing at their fixed 16 kHz.
    /// False when a converter cannot be built (the caller then stops the
    /// recording cleanly).
    @MainActor
    private func rebuildConverters(forRate newRate: Double) -> Bool {
        guard let mix = Self.makeConverter(nativeRate: newRate),
              let mic = Self.makeConverter(nativeRate: newRate),
              let sys = Self.makeConverter(nativeRate: newRate) else {
            AppLog.error("meeting", "cannot build converters for \(Int(newRate)) Hz — stopping the recording")
            return false
        }
        let oldRate = ioQueue.sync { () -> Double in
            let io = self.io
            // Capture already finished (an interruption or Stop got there
            // first): nothing to rebuild, nothing to stop.
            guard io.audioFile != nil else { return 0 }
            let old = io.nativeRate
            self.flushConverterTail(feedLive: true)
            self.flushTrackTail(converter: io.micConverter, file: io.micFile)
            self.flushTrackTail(converter: io.sysConverter, file: io.sysFile)
            io.converter = mix
            io.micConverter = io.micFile == nil ? nil : mic
            io.sysConverter = io.sysFile == nil ? nil : sys
            io.framesSeen = Self.convertFrameCount(io.framesSeen, from: old, to: newRate)
            io.nativeRate = newRate
            io.voiceMic?.setTargetRate(newRate)
            return old
        }
        guard oldRate > 0 else { return true }
        watchedRate = newRate
        AppLog.info("meeting", "converters rebuilt \(Int(oldRate)) Hz → \(Int(newRate)) Hz — recording continues into the same files")
        return true
    }

    /// Whether a device still exists and runs. An unknown ID (nothing to
    /// watch) counts as alive; a lookup that fails means the object is gone.
    private static func isAlive(_ id: AudioObjectID) -> Bool {
        guard id != kAudioObjectUnknown else { return true }
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsAlive,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var alive: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &alive) == noErr else { return false }
        return alive != 0
    }

    func pause()  { ioQueue.async { self.io.paused = true } }
    func resume() { ioQueue.async { self.io.paused = false } }

    // MARK: - Capture graph

    private func setupCapture() async throws {
        // Still the last meeting's file until the new one is named below: a
        // start that fails before then would delete that meeting's audio in the
        // cleanup (its tracks may not be compressed or rebuilt yet).
        fileURL = nil
        let mic = selectedInputDevice()
        let micUID = try mic?.uid ?? defaultInputUID()
        let graph = try buildGraph(micUID: micUID,
                                   micID: mic?.id ?? AudioInputDevices.systemDefault()?.id ?? AudioObjectID(kAudioObjectUnknown),
                                   echoFilterInput: RecorderSettings.inputDeviceUIDNow)
        let nativeRate = graph.rate
        let tapChannels = graph.tapChannels
        await MainActor.run { sessionMicUID = micUID; currentMicUID = micUID }

        // 3. Converter + output file: 16 kHz mono Float32, identical to WavRecorder.
        guard
            let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000,
                                       channels: 1, interleaved: false),
            let conv = Self.makeConverter(nativeRate: nativeRate)
        else {
            throw MeetingError.coreAudio("Audio converter setup", -1)
        }

        let dir = recordingsDirectory ?? FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Transcriberr/Recordings", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let base = "meeting_\(Int(Date().timeIntervalSince1970 * 1000))_\(UUID().uuidString.prefix(8))"
        let url = dir.appendingPathComponent(base + ".wav")
        // Recorded BEFORE the files are opened, so a throw part-way through
        // this sequence still tells `start()`'s catch which files to remove.
        fileURL = url
        let file = try AVAudioFile(forWriting: url, settings: target.settings,
                                   commonFormat: .pcmFormatFloat32, interleaved: false)
        guard let mConv = Self.makeConverter(nativeRate: nativeRate),
              let sConv = Self.makeConverter(nativeRate: nativeRate) else {
            throw MeetingError.coreAudio("Track converter setup", -1)
        }
        let mFile = try AVAudioFile(
            forWriting: dir.appendingPathComponent(base + ".mic.wav"),
            settings: target.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let sFile = try AVAudioFile(
            forWriting: dir.appendingPathComponent(base + ".sys.wav"),
            settings: target.settings, commonFormat: .pcmFormatFloat32, interleaved: false)

        ioQueue.sync {
            let io = self.io
            io.converter = conv
            io.audioFile = file
            io.micConverter = mConv
            io.micFile = mFile
            io.sysConverter = sConv
            io.sysFile = sFile
            io.paused = false
            io.framesSeen = 0
            io.lastPublishMs = 0
            io.tapChannels = tapChannels
            io.warnedPositionalFallback = false
            io.nativeRate = nativeRate
            io.chunkBuffer.removeAll(keepingCapacity: true)
            io.chunkTotal16k = 0
            io.meIntervals.removeAll(keepingCapacity: true)
            io.muteIntervals.removeAll(keepingCapacity: true)
            io.muteOpenAt = nil
            io.offIntervals.removeAll(keepingCapacity: true)
            io.offOpenAt = nil
            // The switch may have been set before the recording began.
            io.micMuted = io.micSwitch.leavesOut(appMuted: false)
            io.appMuted = false
            io.meOpenAt = nil
            io.micGain = 1
            io.voiceMic?.setTargetRate(nativeRate)
        }
        await MainActor.run { elapsedMs = 0 }

        try startIO()
        AppLog.info("meeting", "recording mic + system audio @\(Int(nativeRate)) Hz → \(base).wav (+ .mic/.sys tracks)")
    }

    /// What `buildGraph` made: the aggregate's rate and the tap's width.
    private struct Graph {
        let rate: Double
        let tapChannels: Int
    }

    /// Steps 0–2 of a capture graph: the echo filter, the system tap and
    /// the aggregate pairing the tap with the microphone `micUID`. A nil
    /// `micUID` builds the aggregate on the tap alone — the call audio
    /// keeps recording while no microphone is connected. Shared by Start
    /// and by moving a running meeting onto another microphone.
    private func buildGraph(micUID: String?, micID: AudioObjectID,
                            echoFilterInput: String?) throws -> Graph {
        // 0. Apple's echo filter, before the aggregate reads the mic's
        //    format (bringing it up can change that format). Skipped on
        //    headphones: no echo to remove, and it would still turn every
        //    other app down 4 dB. Assigned at once so a throw further down
        //    still releases it through `teardownCoreAudio`.
        //    With the Transcriberr Microphone on, the call and the recording
        //    share its one unit (a second one on the same mic breaks the
        //    call's mic), whatever the output.
        if micUID != nil, !plainCapture {
            let shared = VirtualMicrophone.shared.acquireForRecording()
            if shared.held {
                ioQueue.sync { io.voiceMic = shared.unit; io.voiceMicBorrowed = true }
                AppLog.info("meeting", "mic shared with the Transcriberr Microphone")
            } else if RecorderSettings.meetingEchoFilterNow {
                let route = VoiceProcessedMic.outputRoute()
                if route.headphones {
                    AppLog.info("meeting", "echo filter off — output '\(route.name)' is headphones")
                } else {
                    AppLog.info("meeting", "output '\(route.name)' — starting the echo filter")
                    // Told first: a call opening the Transcriberr Microphone
                    // from here on gets the raw mic, never a second unit.
                    VirtualMicrophone.shared.recorderVoiceProcessing(true)
                    let vp = VoiceProcessedMic()
                    if vp.start(inputUID: echoFilterInput) {
                        ioQueue.sync { io.voiceMic = vp }
                    } else {
                        VirtualMicrophone.shared.recorderVoiceProcessing(false)
                    }
                }
            }
        }

        // 1. System-audio process tap (all processes, mixed down). Its
        //    channel count is picked so it can never equal the microphone's:
        //    `handleIO` tells the two apart by channel count, and with an
        //    always-stereo tap a stereo microphone would leave it guessing by
        //    position. A wrong guess reverses the split: the mic gate mutes
        //    everyone else in the meeting instead of the room. Next to a
        //    stereo mic the tap is mono; the downmix
        //    treats both the same.
        let micStreams = micUID != nil && micID != kAudioObjectUnknown
            ? AudioInputDevices.inputStreamChannelCounts(micID) : []
        let tapChannels = Self.tapChannelCount(forMicStreams: micStreams)
        // With the Transcriberr Microphone on, our own process is never the
        // far side: its feed is the user's mic played into a hidden device,
        // and it can start at any point of the recording (a call opens the
        // device), after this tap is built. Left in, the user would be
        // recorded as the far side too. With it off, nothing of ours feeds
        // anything, and sound played from Transcriberr during a call (a clip
        // shared with the others) stays in the call track.
        let excludeOwn = RecorderSettings.virtualMicrophoneNow || VirtualMicrophone.shared.isActive
        let excluded = excludeOwn ? VirtualMicrophone.ownProcessObject().map { [$0] } ?? [] : []
        let desc = tapChannels == 1
            ? CATapDescription(monoGlobalTapButExcludeProcesses: excluded)
            : CATapDescription(stereoGlobalTapButExcludeProcesses: excluded)
        desc.name = "Transcriberr System Tap"
        desc.isPrivate = true
        desc.muteBehavior = .unmuted
        try check(AudioHardwareCreateProcessTap(desc, &tapID), "System-audio tap")
        tapDesc = desc

        // 2. Aggregate device: the chosen mic + the tap, one clock. With no
        //    mic, the tap alone.
        micDeviceID = micUID == nil ? AudioObjectID(kAudioObjectUnknown) : micID
        let subDevices: [[String: Any]] = micUID.map {
            [[kAudioSubDeviceUIDKey as String: $0,
              kAudioSubDeviceDriftCompensationKey as String: true]]
        } ?? []
        let aggDict: [String: Any] = [
            kAudioAggregateDeviceNameKey as String: "Transcriberr Meeting",
            kAudioAggregateDeviceUIDKey as String: "nl.ihnatov.Transcriberr.meeting.\(UUID().uuidString)",
            kAudioAggregateDeviceIsPrivateKey as String: true,
            kAudioAggregateDeviceTapAutoStartKey as String: true,
            kAudioAggregateDeviceSubDeviceListKey as String: subDevices,
            kAudioAggregateDeviceTapListKey as String: [
                [kAudioSubTapUIDKey as String: desc.uuid.uuidString,
                 kAudioSubTapDriftCompensationKey as String: true]
            ],
        ]
        try check(AudioHardwareCreateAggregateDevice(aggDict as CFDictionary, &aggID), "Aggregate device")

        let nativeRate = deviceSampleRate(aggID) ?? 48_000
        let layout = AudioInputDevices.inputStreamChannelCounts(aggID)
        let tapIndex = Self.tapBufferIndex(channelCounts: layout, tapChannels: tapChannels)
        AppLog.info("meeting", "aggregate input streams \(layout) (mic \(micStreams), tap \(tapChannels)ch) → tap buffer \(tapIndex.map(String.init) ?? "by position")")
        return Graph(rate: nativeRate, tapChannels: tapChannels)
    }

    /// Step 4: the IO callback on our serial queue, and the device started.
    private func startIO() throws {
        var pid: AudioDeviceIOProcID?
        try check(AudioDeviceCreateIOProcIDWithBlock(&pid, aggID, ioQueue) { [weak self] _, inData, _, _, _ in
            self?.handleIO(inData)
        }, "Audio IO callback")
        procID = pid
        try check(AudioDeviceStart(aggID, procID), "Audio device start")
        startOutputClock()
    }

    // MARK: - Output clock

    @ObservationIgnored private var clockDevice = AudioObjectID(kAudioObjectUnknown)
    @ObservationIgnored private var clockProcID: AudioDeviceIOProcID?
    private let clockQueue = DispatchQueue(label: "meeting.rec.clock")

    /// The system tap is fed by the output device's IO cycle: while
    /// nothing plays, the output device stops, and the aggregate built on
    /// the tap delivers nothing at all — the call side, and the microphone
    /// with it (measured 2026-11-27: mic + tap 0 callbacks in 2 s with
    /// nothing playing, 183 with the output running; making the mic the
    /// aggregate's clock changed nothing). A meeting recording in silence
    /// — before the call starts, an in-person meeting with Meeting on, a
    /// lull in which the call app stops its output — captured nothing. So
    /// while capture runs, the default output runs too, playing silence.
    /// Our own zeros add nothing to the tap. Followed to a new default
    /// output (`handleDeviceChange`) by rebuilding the graph.
    private func startOutputClock() {
        stopOutputClock()
        guard let out = Self.defaultOutputDevice() else { return }
        var pid: AudioDeviceIOProcID?
        let made = AudioDeviceCreateIOProcIDWithBlock(&pid, out, clockQueue) { _, _, _, outData, _ in
            for b in UnsafeMutableAudioBufferListPointer(outData) {
                if let d = b.mData { memset(d, 0, Int(b.mDataByteSize)) }
            }
        }
        guard made == noErr, let pid else {
            AppLog.warn("meeting", "cannot keep the output running (\(made)) — the recording depends on something playing")
            return
        }
        guard AudioDeviceStart(out, pid) == noErr else {
            AudioDeviceDestroyIOProcID(out, pid)
            AppLog.warn("meeting", "cannot start the output clock — the recording depends on something playing")
            return
        }
        clockDevice = out
        clockProcID = pid
    }

    /// The default output changed mid-meeting: restart the silent output
    /// on the new one. Off the main actor (stopping the old device waits for
    /// its IO proc), under `captureLock` like every graph handle.
    @MainActor
    private func moveOutputClock() {
        guard !isMoving else { return }
        isMoving = true
        let mySession = session
        Task.detached(priority: .userInitiated) { [self] in
            let (running, now) = self.restartOutputClock()
            await MainActor.run {
                self.isMoving = false
                guard self.session == mySession, self.isRunning, running else { return }
                AppLog.info("meeting", "default output changed — the silent output moved with it")
                self.watchedClock = now
                // Anything that changed meanwhile.
                self.handleDeviceChange()
            }
        }
    }

    /// Under `captureLock`: restart the output clock on the current default
    /// output while capture runs. Returns whether it was running, and the
    /// device the clock now runs on.
    private nonisolated func restartOutputClock() -> (Bool, AudioObjectID) {
        captureLock.lock()
        defer { captureLock.unlock() }
        guard procID != nil else { return (false, clockDevice) }
        startOutputClock()
        return (true, clockDevice)
    }

    private func stopOutputClock() {
        if let clockProcID, clockDevice != kAudioObjectUnknown {
            AudioDeviceStop(clockDevice, clockProcID)
            AudioDeviceDestroyIOProcID(clockDevice, clockProcID)
        }
        clockProcID = nil
        clockDevice = AudioObjectID(kAudioObjectUnknown)
    }

    nonisolated static func defaultOutputDevice() -> AudioObjectID? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var id = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id) == noErr,
              id != kAudioObjectUnknown else { return nil }
        return id
    }

    private func teardownCoreAudio() {
        stopOutputClock()
        if let procID, aggID != kAudioObjectUnknown {
            AudioDeviceStop(aggID, procID)
            AudioDeviceDestroyIOProcID(aggID, procID)
        }
        procID = nil
        // After the IO proc is gone, so no cycle is still pulling from it.
        // Every way capture ends comes through here — Stop, a failed start,
        // a mic unplugged mid-meeting — so the unit (and the duck it puts
        // on every other app) never outlives the recording.
        let (vp, borrowed) = ioQueue.sync { () -> (VoiceProcessedMic?, Bool) in
            let v = (self.io.voiceMic, self.io.voiceMicBorrowed)
            self.io.voiceMic = nil
            self.io.voiceMicBorrowed = false
            return v
        }
        if borrowed {
            VirtualMicrophone.shared.releaseFromRecording()
        } else if let vp {
            vp.stop()
            VirtualMicrophone.shared.recorderVoiceProcessing(false)
        }
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
        guard !io.paused, io.audioFile != nil else { return }
        let list = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: abl))

        var frames = 0
        for b in list {
            let ch = max(1, Int(b.mNumberChannels))
            frames = max(frames, Int(b.mDataByteSize) / (4 * ch))
        }
        guard frames > 0 else { return }

        // Downmix every source buffer (mic channels + tap channels) to mono.
        // The tap was built with a channel count the mic doesn't use (see
        // `setupCapture`), so the one buffer carrying `tapChannels` is the
        // tap. Trust that over assuming the aggregate always orders
        // sub-devices before taps: get the split backwards and the mic-only
        // gate below mutes the far side — everyone else in the meeting —
        // instead of the user, which is what silences the waveform (and the
        // saved mix) whenever someone other than the user is talking.
        // Position (tap last, after the sub-devices) is the fallback only
        // when the count is ambiguous — a mic exposing both a mono and a
        // stereo stream — and it is logged once so a bad split is traceable.
        var micMono = [Float](repeating: 0, count: frames)
        var sysMono = [Float](repeating: 0, count: frames)
        let tapIndex = Self.tapBufferIndex(channelCounts: list.map { Int($0.mNumberChannels) },
                                           tapChannels: io.tapChannels)
        if tapIndex == nil, !io.warnedPositionalFallback {
            io.warnedPositionalFallback = true
            AppLog.warn("meeting", "cannot tell tap from mic by channel count \(list.map(\.mNumberChannels)) — assuming the tap is the last buffer")
        }
        for (bi, b) in list.enumerated() {
            guard let raw = b.mData else { continue }
            let ch = max(1, Int(b.mNumberChannels))
            let n = min(frames, Int(b.mDataByteSize) / (4 * ch))
            let p = raw.assumingMemoryBound(to: Float.self)
            let isTap = tapIndex.map { bi == $0 } ?? (bi == list.count - 1)
            // Average only the channels carrying signal in this buffer — the
            // WavRecorder.downmixToMono rule. A plain average lets the silent
            // input 2 of a two-input interface halve a mic on input 1 (-6 dB),
            // which also skews the gate and the me-timeline against the user.
            // A bitmask, not an array: this runs once per HAL cycle. Past 64
            // channels (or all silent) it falls back to averaging everything.
            var activeMask: UInt64 = 0
            if ch > 1, ch <= 64 {
                for c in 0..<ch {
                    var energy: Float = 0
                    var f = 0
                    while f < n { let v = p[f * ch + c]; energy += v * v; f += 16 }
                    if energy > 1e-9 { activeMask |= 1 << UInt64(c) }
                }
            }
            let active = activeMask.nonzeroBitCount
            let inv = 1 / Float(active == 0 ? ch : active)
            for f in 0..<n {
                var s: Float = 0
                for c in 0..<ch where active == 0 || activeMask & (1 << UInt64(c)) != 0 {
                    s += p[f * ch + c]
                }
                let m = s * inv
                if isTap { sysMono[f] += m } else { micMono[f] += m }
            }
        }
        // Apple's echo filter, when on: the same mic with the far side's
        // echo already removed. A nil cycle (still priming, or the unit
        // stalled after a route change) keeps the raw mic.
        var filtered = false
        if let cleaned = io.voiceMic?.pull(frames) { micMono = cleaned; filtered = true }

        var micSq: Float = 0
        var sysSq: Float = 0
        for f in 0..<frames {
            micSq += micMono[f] * micMono[f]
            sysSq += sysMono[f] * sysMono[f]
        }
        let micRMS = (micSq / Float(frames)).squareRoot()
        let tapRMS = (sysSq / Float(frames)).squareRoot()
        // Me-timeline sees RAW energies — the duck must not blind it.
        updateMeTimeline(micRMS: micRMS, tapRMS: tapRMS,
                         t: Double(io.framesSeen) / io.nativeRate)
        updateMuteLog(t: Double(io.framesSeen) / io.nativeRate)

        // Duck the mic while the far side is talking and the mic is just
        // hearing the speakers. Fully open when the user speaks or the far
        // side is quiet; ~40 ms smoothing (0.25/cycle at ~10 ms callbacks).
        // FULL gate, not a soft duck: the far side's voice already arrives
        // pristine from the system tap — any mic contribution while only
        // they speak is pure room echo (a 12% floor was audible).
        // Asymmetric ramps: open near-instantly when the user speaks so no
        // syllable is clipped; close gently so it never pumps.
        // Open on relative dominance OR clear absolute speech energy — a
        // loud far side must not be able to gate out the user's interjection.
        // With the echo filter delivering there is no echo left to gate, and
        // the gate would only cut the user's quieter words over the far side
        // out of the live mix (and the live captions read from it).
        io.micGain = io.micMuted ? 0 : filtered ? 1 : Self.gateStep(micRMS: micRMS, tapRMS: tapRMS, currentGain: io.micGain)
        // The ungated mic goes to the .mic.wav track — the offline echo
        // canceller needs unmodified ground truth (it subtracts the echo
        // mathematically). The gate shapes only the playback mix. With the
        // echo filter on this is the filtered mic; the canceller then finds
        // no echo path (peak correlation 0.01-0.04 against its 0.1 bar,
        // measured) and leaves it as it is.
        let rawMic = micMono
        if io.micGain < 0.999 {
            for f in 0..<frames { micMono[f] *= io.micGain }
        }

        var mono = [Float](repeating: 0, count: frames)
        for f in 0..<frames { mono[f] = micMono[f] + sysMono[f] }
        writeTrack(rawMic, converter: io.micConverter, file: io.micFile)
        writeTrack(sysMono, converter: io.sysConverter, file: io.sysFile)

        var sumSq: Float = 0
        var peak: Float = 0
        for i in 0..<frames {
            mono[i] = max(-1, min(1, mono[i]))
            sumSq += mono[i] * mono[i]
            peak = max(peak, abs(mono[i]))
        }
        let rms = min(1, sqrt(sumSq / Float(frames)) * 6)

        convertAndWrite(mono)
        io.framesSeen += Int64(frames)
        let ms = Int64(Double(io.framesSeen) / io.nativeRate * 1000)

        // Publish stats on the main actor (@Observable writes drive SwiftUI),
        // throttled to ~30 Hz so the HAL callback rate doesn't flood renders.
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        if now - io.lastPublishMs >= 33 {
            io.lastPublishMs = now
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
        guard let converter = io.converter, let audioFile = io.audioFile else { return }
        guard let inBuf = AVAudioPCMBuffer(pcmFormat: converter.inputFormat,
                                           frameCapacity: AVAudioFrameCount(samples.count)) else { return }
        inBuf.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { src in
            inBuf.floatChannelData![0].update(from: src.baseAddress!, count: samples.count)
        }
        let outCap = AVAudioFrameCount(Double(samples.count) * 16_000 / io.nativeRate) + 64
        guard let outBuf = AVAudioPCMBuffer(pcmFormat: converter.outputFormat,
                                            frameCapacity: outCap) else { return }
        let feed = ConverterInput(once: inBuf, whenDone: .noDataNow)
        var err: NSError?
        let status = converter.convert(to: outBuf, error: &err) { _, outStatus in feed.next(outStatus) }
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
    private func updateMuteLog(t: Double) {
        if io.micMuted {
            if io.muteOpenAt == nil { io.muteOpenAt = t }
        } else if let open = io.muteOpenAt {
            io.muteIntervals.append([open, t])
            io.muteOpenAt = nil
        }
        if io.micSwitch == .off {
            if io.offOpenAt == nil { io.offOpenAt = t }
        } else if let open = io.offOpenAt {
            io.offIntervals.append([open, t])
            io.offOpenAt = nil
        }
    }

    @MainActor
    private func startFollowingMute() {
        guard MeetingMuteMonitor.isEnabled else { return }
        muteMonitor.start { [weak self] reading in
            guard let self else { return }
            let muted = reading?.muted ?? false
            self.ioQueue.async {
                self.io.appMuted = muted
                self.io.micMuted = self.io.micSwitch.leavesOut(appMuted: muted)
            }
            Task { @MainActor in self.mutedIn = muted ? reading?.app : nil }
        }
    }

    /// The user's own say over the mic while the meeting records. Works with
    /// or without a meeting app to follow. Like the app's mute it only
    /// shapes the live mix and captions and writes stretches to
    /// `.mute.json`: the `.mic` track keeps everything.
    @MainActor
    func setMicSwitch(_ choice: MicSwitch) {
        guard choice != micSwitch else { return }
        micSwitch = choice
        AppLog.info("mute", "mic switch: \(choice.rawValue)")
        ioQueue.async {
            self.io.micSwitch = choice
            self.io.micMuted = choice.leavesOut(appMuted: self.io.appMuted)
        }
    }

    private func updateMeTimeline(micRMS: Float, tapRMS: Float, t: Double) {
        let micActive = micRMS > 0.004 && micRMS > tapRMS * 1.5
        if micActive {
            if io.meOpenAt == nil { io.meOpenAt = t }
        } else if let open = io.meOpenAt {
            if t - open >= 0.3 {
                if let last = io.meIntervals.last, open - last[1] < 0.6 {
                    io.meIntervals[io.meIntervals.count - 1][1] = t
                } else {
                    io.meIntervals.append([open, t])
                }
            }
            io.meOpenAt = nil
        }
    }

    /// Mirror of WavRecorder.appendToChunkBuffer — same size, same timing math.
    private func appendToChunkBuffer(_ samples: [Float]) {
        io.chunkTotal16k += Int64(samples.count)
        io.chunkBuffer.append(contentsOf: samples)
        let chunkSize = Int(WavRecorder.chunkSeconds * WavRecorder.sampleRate)
        while io.chunkBuffer.count >= chunkSize {
            let head = Array(io.chunkBuffer.prefix(chunkSize))
            io.chunkBuffer.removeFirst(chunkSize)
            let startSec = Double(io.chunkTotal16k - Int64(io.chunkBuffer.count) - Int64(chunkSize)) / WavRecorder.sampleRate
            liveFeed.yield(WavRecorder.Chunk(samples: head, startTimeSeconds: max(0, startSec)))
        }
    }

    /// Convert one source's samples to 16 kHz and append to its track file.
    /// Same streaming discipline as the mix path, no chunk feed.
    private func writeTrack(_ samples: [Float], converter: AVAudioConverter?, file: AVAudioFile?) {
        guard let converter, let file,
              let inBuf = AVAudioPCMBuffer(pcmFormat: converter.inputFormat,
                                           frameCapacity: AVAudioFrameCount(samples.count)) else { return }
        inBuf.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { src in
            inBuf.floatChannelData![0].update(from: src.baseAddress!, count: samples.count)
        }
        let outCap = AVAudioFrameCount(Double(samples.count) * 16_000 / io.nativeRate) + 64
        guard let outBuf = AVAudioPCMBuffer(pcmFormat: converter.outputFormat,
                                            frameCapacity: outCap) else { return }
        let feed = ConverterInput(once: inBuf, whenDone: .noDataNow)
        var err: NSError?
        let status = converter.convert(to: outBuf, error: &err) { _, outStatus in feed.next(outStatus) }
        if status != .error, outBuf.frameLength > 0 { try? file.write(from: outBuf) }
    }

    private func flushTrackTail(converter: AVAudioConverter?, file: AVAudioFile?) {
        guard let converter, let file,
              let outBuf = AVAudioPCMBuffer(pcmFormat: converter.outputFormat,
                                            frameCapacity: 4096) else { return }
        var err: NSError?
        let status = converter.convert(to: outBuf, error: &err) { _, outStatus in
            outStatus.pointee = .endOfStream
            return nil
        }
        if status != .error, outBuf.frameLength > 0 { try? file.write(from: outBuf) }
    }

    /// Drain the mix converter's filter delay into the file. `feedLive`
    /// also hands those samples to the live-caption chunker — for a
    /// mid-meeting converter swap, where the chunk timeline must keep
    /// matching the file; at Stop the feed is being closed anyway.
    private func flushConverterTail(feedLive: Bool = false) {
        guard let converter = io.converter, let audioFile = io.audioFile else { return }
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
            if feedLive, let p = outBuf.floatChannelData?[0] {
                appendToChunkBuffer(Array(UnsafeBufferPointer(start: p, count: Int(outBuf.frameLength))))
            }
        }
    }

    /// Channel count for the system tap: whichever of mono/stereo the
    /// microphone's streams don't use, so `tapBufferIndex` can always tell
    /// the two apart. Stereo by default (a mono mic is the common case),
    /// mono next to a stereo mic. A mic exposing both a mono and a stereo
    /// stream can't be separated by count at all — position then decides.
    static func tapChannelCount(forMicStreams micStreams: [Int]) -> Int {
        if micStreams.contains(2) && !micStreams.contains(1) { return 1 }
        return 2
    }

    /// Index of the tap's buffer in the aggregate's buffer list when exactly
    /// one buffer carries the tap's channel count; nil when that is
    /// ambiguous (the caller falls back to position).
    static func tapBufferIndex(channelCounts: [Int], tapChannels: Int) -> Int? {
        let matches = channelCounts.indices.filter { channelCounts[$0] == tapChannels }
        return matches.count == 1 ? matches[0] : nil
    }

    /// Pure gate math, extracted for unit tests: full-open on user speech
    /// (relative dominance OR clear absolute energy), full-close while only
    /// the far side plays, asymmetric smoothing (fast open, gentle close).
    static func gateStep(micRMS: Float, tapRMS: Float, currentGain: Float) -> Float {
        let micActive = micRMS > 0.02 || (micRMS > 0.004 && micRMS > tapRMS * 1.5)
        let target: Float = (micActive || tapRMS < 0.004) ? 1.0 : 0.0
        return currentGain + (target - currentGain) * (target > currentGain ? 0.6 : 0.15)
    }

    // MARK: - CoreAudio helpers

    private func check(_ status: OSStatus, _ what: String) throws {
        guard status == noErr else {
            AppLog.error("meeting", "\(what) failed: OSStatus \(status)")
            throw MeetingError.coreAudio(what, status)
        }
    }

    /// The microphone to record: the one picked in Settings → Audio Input
    /// when it is still connected, otherwise the system default. Nil only
    /// when CoreAudio reports no default input; `defaultInputUID` then
    /// produces the error.
    private func selectedInputDevice() -> AudioInputDevices.Device? {
        AudioInputDevices.effective(uid: RecorderSettings.inputDeviceUIDNow)
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
        // +1 CFString (Create rule) — take ownership so it is released.
        var uid: Unmanaged<CFString>?
        size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        try check(AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &uid), "Input UID lookup")
        guard let uid else { throw MeetingError.coreAudio("Input UID lookup", -1) }
        return uid.takeRetainedValue() as String
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
