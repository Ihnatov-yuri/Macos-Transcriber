import EventKit
import AppKit
import Foundation
import Observation
import SwiftUI

/// Block-based notification observers, removed from their centre when the
/// bag is released. `NotificationCenter.removeObserver` is thread-safe, so
/// the nonisolated deinit may run anywhere.
nonisolated final class NotificationObserverBag: @unchecked Sendable {
    private let center: NotificationCenter
    private let lock = NSLock()
    private var tokens: [NSObjectProtocol] = []

    init(center: NotificationCenter) { self.center = center }

    func add(_ token: NSObjectProtocol) {
        lock.lock(); defer { lock.unlock() }
        tokens.append(token)
    }

    /// Removes every observer now (also done on release).
    func removeAll() {
        lock.lock()
        let gone = tokens
        tokens = []
        lock.unlock()
        for t in gone { center.removeObserver(t) }
    }

    var count: Int {
        lock.lock(); defer { lock.unlock() }
        return tokens.count
    }

    deinit { for t in tokens { center.removeObserver(t) } }
}

/// Mirror of `ui/record/RecordViewModel.kt`.
@Observable
@MainActor
final class RecordModel {
    enum UIState: Equatable {
        case idle
        case recording
        case paused
        case finished(URL)
    }

    let container: AppContainer
    private(set) var liveWorker: LiveTranscriber

    var uiState: UIState = .idle
    var autoTranscribe: Bool { didSet { container.uiPrefs.autoTranscribe = autoTranscribe } }
    /// Both reach a recording already running: otherwise Live switched on
    /// mid-meeting does nothing until the next recording (if only
    /// `beginRecording` looks at it), which reads as "live does not work".
    var liveEnabled: Bool {
        didSet {
            container.uiPrefs.liveEnabled = liveEnabled
            guard liveEnabled != oldValue else { return }
            Task { @MainActor in await self.applyLiveToRunningSession(restart: false) }
        }
    }
    var liveEngine: BackendFactory.Kind {
        didSet {
            container.uiPrefs.liveEngine = liveEngine
            guard liveEngine != oldValue else { return }
            Task { @MainActor in await self.applyLiveToRunningSession(restart: true) }
        }
    }
    var liveLanguages: Set<String> {
        didSet {
            container.uiPrefs.lastLanguages = liveLanguages
            // Reaches a live session already running.
            liveWorker.languages = liveLanguages
        }
    }
    /// Meeting mode: capture system audio (the other participants, tapped
    /// digitally) alongside the mic. Live captions read the meeting mix.
    var meetingMode: Bool {
        didSet {
            UserDefaults.standard.set(meetingMode, forKey: "ui.meetingMode")
            // A choice made for a meeting does not wait for the next one.
            // Not `activeMeeting`: that stays set after a meeting has ended.
            if !meetingMode, Self.micChoiceEnds(activeMeeting: activeMeeting, sessionRunning: sessionRunning) { container.meetingRecorder.setMicSwitch(.auto) }
        }
    }
    /// Which recorder the CURRENT session started with (the toggle may move
    /// mid-recording; stop must go to the recorder that started).
    private var activeMeeting = false
    /// Exposed so the record screen can pick the right waveform source.
    var meetingActive: Bool { activeMeeting }
    private var isStopping = false
    /// The crashed recording this session carries on: Stop joins the two.
    private(set) var continuing: InterruptedRecording?
    var lastError: String?
    /// A plain message for the record screen (not an error).
    var notice: String?
    /// When the Mac went to sleep mid-recording; nil otherwise. Only a pause
    /// the app made for sleep is resumed on wake — never the user's own.
    private var sleptAt: Date?
    /// Removes the sleep/wake observers when this model goes away (one
    /// model per window: otherwise they pile up in the workspace centre).
    /// A box with its own deinit, so no main-actor deinit is needed here.
    private let powerObservers = NotificationObserverBag(center: NSWorkspace.shared.notificationCenter)

    init(container: AppContainer) {
        self.container = container
        self.liveWorker = LiveTranscriber(
            factory: container.backendFactory,
            recorder: container.recorder
        )
        self.autoTranscribe = container.uiPrefs.autoTranscribe
        self.liveEnabled = container.uiPrefs.liveEnabled
        self.liveEngine = container.uiPrefs.liveEngine
        self.liveLanguages = container.uiPrefs.lastLanguages
        self.meetingMode = UserDefaults.standard.bool(forKey: "ui.meetingMode")
        watchSleep()
    }

    /// Closing the lid sleeps the Mac and the audio stops arriving; without
    /// this the session stays on RECORDING with nothing said about it (a
    /// meeting ran 50 min on the clock, 30 min on disk). The recording
    /// pauses for the sleep and carries on after wake.
    private func watchSleep() {
        let center = NSWorkspace.shared.notificationCenter
        powerObservers.add(center.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleWillSleep() }
        })
        powerObservers.add(center.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleDidWake() }
        })
    }

    private func handleWillSleep() {
        guard uiState == .recording else { return }
        AppLog.info("recorder", "Mac going to sleep — pausing the \(activeMeeting ? "meeting" : "recording")")
        pause()
        sleptAt = Date()
    }

    private func handleDidWake() {
        guard let since = sleptAt else { return }
        sleptAt = nil
        guard uiState == .paused else { return }
        let slept = Self.sleepNotice(from: since, to: Date())
        Task { @MainActor [weak self] in
            // Audio devices come back a moment after the wake notification.
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard let self, self.uiState == .paused else { return }
            self.resume()
            if !self.activeMeeting, case .failed(let reason) = self.container.recorder.state {
                AppLog.warn("recorder", "resume after sleep failed: \(reason)")
                self.lastError = reason
                return
            }
            AppLog.info("recorder", "Mac woke — recording resumed (\(slept))")
            self.notice = slept
        }
    }

    /// "Paused while your Mac slept · 13:59–14:18".
    static func sleepNotice(from: Date, to: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return String(localized: "Paused while your Mac slept · \(f.string(from: from))–\(f.string(from: to))")
    }

    var elapsedMs: Int64 { activeMeeting ? container.meetingRecorder.elapsedMs : container.recorder.elapsedMs }
    var level: Float { activeMeeting ? container.meetingRecorder.level : container.recorder.level }
    var micMutedIn: String? { activeMeeting ? container.meetingRecorder.mutedIn : nil }
    /// The mic switch is there for a meeting: while one records, and
    /// before, so that a call can start with the mic already left out.
    var showsMicSwitch: Bool {
        Self.showsMicSwitch(meetingMode: meetingMode, activeMeeting: activeMeeting,
                            recording: uiState == .recording || uiState == .paused)
    }
    /// Meeting switched off: the mic choice made for a meeting goes back to
    /// Auto, unless that meeting is still recording. `activeMeeting` alone
    /// stays set after a meeting has ended, so once one had been recorded
    /// a "Mic off" outlived the switch and left the mic out of the next.
    nonisolated static func micChoiceEnds(activeMeeting: Bool, sessionRunning: Bool) -> Bool {
        !(activeMeeting && sessionRunning)
    }

    nonisolated static func showsMicSwitch(meetingMode: Bool, activeMeeting: Bool, recording: Bool) -> Bool {
        recording ? activeMeeting : meetingMode
    }
    var micSwitch: MicSwitch { showsMicSwitch ? container.meetingRecorder.micSwitch : .auto }
    func setMicSwitch(_ choice: MicSwitch) {
        guard showsMicSwitch else { return }
        container.meetingRecorder.setMicSwitch(choice)
    }

    func toggleRecord() async {
        switch uiState {
        case .idle, .finished:
            await beginRecording()
        case .recording, .paused:
            // The stop control must STOP — also from pause. Resuming is the
            // pause button's job.
            await endRecording()
        }
    }

    func pause() {
        guard uiState == .recording else { return }
        if activeMeeting { container.meetingRecorder.pause() } else { container.recorder.pause() }
        uiState = .paused
    }

    func resume() {
        guard uiState == .paused else { return }
        if activeMeeting { container.meetingRecorder.resume() } else { container.recorder.resume() }
        uiState = .recording
    }

    /// Set for the whole of `beginRecording`, including across its awaits.
    /// `uiState` alone can't guard a double press: the first tap hops off
    /// the main actor inside `recorder.start()`, so the second tap would see
    /// `.idle`, call start again, hit the recorder's own "already
    /// starting" guard (which returns SUCCESSFULLY) and set `.recording`
    /// with no engine behind it. Pressing Stop would then find the recorder
    /// still idle and return nil, leaving the first start to open the mic with
    /// nothing on screen able to stop it.
    private var isStarting = false

    /// "Continue recording" after a crash: the same kind of recording as
    /// the one cut short, whatever the Meeting switch says now.
    func continueRecording(_ r: InterruptedRecording) async {
        switch uiState {
        case .idle, .finished: break
        case .recording, .paused: return
        }
        await beginRecording(meeting: r.isMeeting, continuing: r)
    }

    private func beginRecording(meeting: Bool? = nil, continuing next: InterruptedRecording? = nil) async {
        guard !isStarting else { return }
        isStarting = true
        defer { isStarting = false }
        lastError = nil
        notice = nil
        // Dictation already refuses to start while a recording is running;
        // without the mirror image, ⌘N (or the Record button) during a
        // dictation session would open a second engine — and a second
        // voice-processing unit — on the same input device.
        if container.dictation.phase == .listening {
            lastError = String(localized: "Dictation is listening · finish it first").uppercased()
            return
        }
        do {
            activeMeeting = meeting ?? meetingMode
            continuing = nil
            if activeMeeting {
                // The mic went away mid-meeting: the recorder has already
                // closed its files, so stop the session and save what was
                // captured instead of showing RECORDING over a dead device.
                container.meetingRecorder.onInterrupted = { [weak self] message in
                    guard let self, self.activeMeeting, self.uiState == .recording || self.uiState == .paused else { return }
                    Task { @MainActor in
                        await self.endRecording()
                        self.lastError = message
                    }
                }
                // The mic changed and the recording carried on: say so on
                // the Record screen and in a pop-out note, since the user
                // is usually in the call, not here.
                container.meetingRecorder.onMicMoved = { [weak self] message in
                    guard let self, self.activeMeeting, self.sessionRunning else { return }
                    self.notice = message
                    RecordingNoticeHUD.shared.show(
                        title: String(localized: "Meeting recording", comment: "Pop-out note title: something happened to the meeting being recorded"),
                        text: message)
                }
                try await container.meetingRecorder.start()
                // The calendar question, asked now while the user is here
                // (see MeetingContext.requestAccess); the run never asks.
                if MeetingContext.isEnabled {
                    Task { _ = await MeetingContext.requestAccess(EKEventStore(), ask: true) }
                }
            } else {
                try await container.recorder.start()
            }
            uiState = .recording
            RecordingActivity.shared.begin()
            if let next {
                continuing = next
                let cutAt = DateFormatter.time.string(from: next.endedAt)
                notice = next.isMeeting
                    ? String(localized: "Continuing the meeting cut short at \(cutAt). Stop joins the two parts.")
                    : String(localized: "Continuing the recording cut short at \(cutAt). Stop joins the two parts.")
            }

            liveWorker.clear()
            if liveEnabled { await startLive(resetCaptions: true) }
        } catch {
            lastError = error.localizedDescription
            uiState = .idle
            activeMeeting = false
        }
    }

    private var sessionRunning: Bool { uiState == .recording || uiState == .paused }

    private func startLive(resetCaptions: Bool) async {
        liveWorker.attach(activeMeeting ? container.meetingRecorder : container.recorder)
        await liveWorker.start(
            engine: liveEngine,
            languages: liveLanguages,
            translateTo: nil,
            modelDirectory: nil,
            resetCaptions: resetCaptions
        )
        // Stop can land while the live model is still loading: the
        // session is gone (or going) by the time start returns, and
        // the worker must not stay attached to a stopped recorder.
        if isStopping || !sessionRunning || !liveEnabled {
            await liveWorker.stop()
        }
    }

    /// Live toggled, or its engine changed, while a recording runs. Earlier
    /// captions stay on screen. `beginRecording` and `endRecording` own the
    /// worker while they run.
    private func applyLiveToRunningSession(restart: Bool) async {
        guard sessionRunning, !isStarting, !isStopping else { return }
        if liveEnabled {
            if restart || liveWorker.status != .running { await startLive(resetCaptions: false) }
        } else {
            await liveWorker.stop()
        }
    }

    private func endRecording() async {
        // Stop suspends at several awaits with uiState still .recording — a
        // double-press must not run a second stop and save a duplicate row.
        guard !isStopping else { return }
        isStopping = true
        defer {
            isStopping = false
            // Held Super runs carry on (see RecordingActivity) — on every
            // exit, failed stops included.
            RecordingActivity.shared.end()
        }
        lastError = nil
        await liveWorker.stop()
        let joining = continuing
        continuing = nil
        do {
            let wasMeeting = activeMeeting
            let url: URL?
            if wasMeeting {
                url = try await container.meetingRecorder.stop()
            } else {
                url = try await container.recorder.stop()
            }
            guard let url else {
                // Say something. A nil URL here means the recorder had
                // already failed (or never started) and the session is gone —
                // silently dropping back to idle would look like the Stop button
                // simply discarding the recording.
                // Only the mic recorder keeps a failure state; for a meeting
                // it would be a stale reason from some other session.
                if !wasMeeting, case .failed(let reason) = container.recorder.state {
                    lastError = reason
                } else if lastError == nil {
                    lastError = String(localized: "Recording could not be saved.")
                }
                activeMeeting = false
                uiState = .idle
                return
            }
            // Prefer what actually landed on disk over the wall-clock
            // ticker: the ticker is a display convenience (100 ms
            // granularity, pause bookkeeping) — the sample count is the
            // truth the player and the library will show.
            let duration: Double
            if !wasMeeting, case .saved(_, let written) = container.recorder.state, written > 0 {
                duration = written
            } else {
                duration = Double(wasMeeting ? container.meetingRecorder.elapsedMs
                                             : container.recorder.elapsedMs) / 1000
            }
            let title = "\(wasMeeting ? "Meeting" : "Recording") \(DateFormatter.short.string(from: Date()))"
            // Save with the WAV path FIRST — compressing before the row
            // exists would widen the crash/quit window between "audio
            // written to disk" and "the DB knows about it" from a few
            // synchronous statements to a real, multi-second async
            // transcode. The recording is fully safe and visible before
            // any compression happens at all.
            let recording = Recording(title: title, audioPath: url.path, durationSeconds: duration)
            // Pending BEFORE the row becomes visible: with auto-transcribe on,
            // compression starts only after the job has decoded the WAV, and
            // a merge/split started in that gap must still wait it out (see
            // AudioPostProcessTracker). Cleared when post-processing ends.
            let tracker = container.audioPostProcessTracker
            await tracker.markPending(recording.id)
            do {
                try container.repository.save(recording)
            } catch {
                await tracker.clearPending(recording.id)
                throw error
            }
            uiState = .finished(url)

            // Echo-cancel rebuild + AAC compression run in the BACKGROUND,
            // never awaited here: awaiting them would block this function
            // (and, when autoTranscribe is on, block transcription from even
            // starting), so pressing Stop would look hung for however long
            // that takes. TranscriptionRunner decodes the whole file into memory
            // up front regardless of format, so it doesn't need the
            // compressed/rebuilt version — it can start on the raw WAV
            // immediately. Post-processing only has to wait until that
            // decode is done (signaled via onSourceConsumed), not until
            // transcription finishes, so it never races the job's reads.
            //
            // The work itself is anchored to `container` (app-lifetime), NOT
            // to `self` — RecordModel is view-scoped `@State` and would
            // otherwise silently drop this work (never compressing/rebuilding,
            // no error, nothing) the moment the user leaves the Record screen
            // while it's still running. `self` is only used afterward, best-
            // effort, to refresh the on-screen state if the view is still around.
            let container = container
            let languages = liveLanguages
            if let joining {
                // Carrying on after a crash: no run on this part alone. Both
                // parts are made ready, joined into one recording, and that
                // one is transcribed.
                let transcribe = autoTranscribe
                notice = nil
                Task { @MainActor [weak self] in
                    let partURL = await Self.finishPostProcessing(
                        container: container, recording: recording, mainURL: url, wasMeeting: wasMeeting)
                    do {
                        let joined = try await Self.join(container: container, earlier: joining, later: recording)
                        if transcribe { Self.transcribe(joined, container: container, languages: languages, isMeeting: wasMeeting) }
                        if let self, self.uiState == .finished(url) {
                            self.uiState = .finished(URL(fileURLWithPath: joined.audioPath))
                            self.notice = String(localized: "Joined into “\(joined.title)”.")
                        }
                    } catch {
                        AppLog.error("record", "could not join the part to the recording cut short: \(error.localizedDescription)")
                        if transcribe, !recording.isDeleted, recording.modelContext != nil {
                            Self.transcribe(recording, container: container, languages: languages, isMeeting: wasMeeting)
                        }
                        if let self, self.uiState == .finished(url) {
                            self.uiState = .finished(partURL)
                            self.lastError = String(localized: "The new part could not be joined to the one cut short, so it is in the Library on its own. \(error.localizedDescription)")
                        }
                    }
                }
            } else if autoTranscribe {
                let jobManager = container.jobManager
                let (params, followUp) = Self.params(file: url, container: container, languages: languages, isMeeting: wasMeeting)
                Task { @MainActor [weak self] in
                    await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                        jobManager.enqueue(recording, params: params, followUp: followUp) { cont.resume() }
                    }
                    let finalURL = await Self.finishPostProcessing(
                        container: container, recording: recording, mainURL: url, wasMeeting: wasMeeting)
                    if let self, finalURL != url, self.uiState == .finished(url) {
                        self.uiState = .finished(finalURL)
                    }
                }
            } else {
                Task { @MainActor [weak self] in
                    let finalURL = await Self.finishPostProcessing(
                        container: container, recording: recording, mainURL: url, wasMeeting: wasMeeting)
                    if let self, finalURL != url, self.uiState == .finished(url) {
                        self.uiState = .finished(finalURL)
                    }
                }
            }
        } catch {
            lastError = error.localizedDescription
            activeMeeting = false
            uiState = .idle
        }
    }

    /// Rebuilds the meeting mix with offline echo cancellation (no-op for a
    /// plain recording) and reclaims disk space via AAC compression, then
    /// repoints the saved `Recording` at whatever file survived, then clears
    /// the tracker's pending mark set in `endRecording`. Only ever
    /// called after it's safe to mutate the recording's files — either
    /// nothing is reading them (auto-transcribe off) or the transcription
    /// job has finished decoding them (auto-transcribe on). Static, and
    /// takes `container` explicitly, so it runs to completion independent of
    /// whether the `RecordModel` that started it is still alive.
    static func finishPostProcessing(
        container: AppContainer, recording: Recording, mainURL: URL, wasMeeting: Bool
    ) async -> URL {
        let tracker = container.audioPostProcessTracker
        await tracker.markBusy(recording.id)
        let rebuiltURL = wasMeeting
            ? (await MeetingMixRebuilder.rebuildMix(mainURL: mainURL) ?? mainURL)
            : mainURL
        let finalURL = await AudioCompressor.compressRecordingFiles(mainURL: rebuiltURL, includeSidecars: wasMeeting)
        if finalURL != mainURL {
            try? container.repository.updateAudioPath(finalURL, for: recording)
        }
        await tracker.markIdle(recording.id)
        return finalURL
    }
}

// MARK: - Runs and carrying on after a crash

extension RecordModel {
    /// The run a stopped recording gets: the default engine, and for a
    /// meeting Super in the background after the quick draft.
    static func params(file url: URL, container: AppContainer, languages: Set<String>, isMeeting: Bool)
        -> (TranscriptionRunner.Params, TranscriptionRunner.Params?) {
        let params = TranscriptionRunner.Params(
            file: url,
            backend: container.uiPrefs.defaultBackend,
            modelDirectory: nil,
            languages: languages,
            translateTo: nil
        )
        let followUp: TranscriptionRunner.Params? =
            isMeeting && params.backend != .ensemble && container.uiPrefs.meetingSuperFollowUp
            ? TranscriptionRunner.Params(
                file: url, backend: .ensemble, modelDirectory: nil,
                languages: languages, translateTo: nil,
                diarize: true, keepVisibleUntilDone: true)
            : nil
        return (params, followUp)
    }

    /// Queue the run a stopped recording would have had.
    static func transcribe(_ recording: Recording, container: AppContainer, languages: Set<String>, isMeeting: Bool) {
        let (params, followUp) = params(file: URL(fileURLWithPath: recording.audioPath),
                                        container: container, languages: languages, isMeeting: isMeeting)
        container.jobManager.enqueue(recording, params: params, followUp: followUp) {}
    }

    /// "Transcribe it" on the launch question: the recovered recording gets
    /// the echo rebuild and compression its Stop never ran, then its run.
    static func transcribeRecovered(_ r: InterruptedRecording, container: AppContainer) {
        guard let recording = try? container.repository.get(id: r.id) else { return }
        let languages = container.uiPrefs.lastLanguages
        Task { @MainActor in
            await container.audioPostProcessTracker.markPending(recording.id)
            _ = await finishPostProcessing(container: container, recording: recording,
                                           mainURL: URL(fileURLWithPath: recording.audioPath), wasMeeting: r.isMeeting)
            guard !recording.isDeleted, recording.modelContext != nil else { return }
            transcribe(recording, container: container, languages: languages, isMeeting: r.isMeeting)
        }
    }

    /// Join the part recorded after a crash to the recording the crash cut
    /// short. The recovered part first gets the echo rebuild and compression
    /// its Stop never ran; the merge then writes one recording with both
    /// parts (tracks included), and the two parts leave the Library only
    /// once the joined one is saved.
    static func join(container: AppContainer, earlier r: InterruptedRecording, later: Recording) async throws -> Recording {
        let repository = container.repository
        container.joiningIDs.formUnion([r.id, later.id])
        defer { container.joiningIDs.subtract([r.id, later.id]) }
        guard let earlier = try repository.get(id: r.id) else {
            throw NSError(domain: "Resume", code: 1, userInfo: [NSLocalizedDescriptionKey:
                String(localized: "The recording cut short is no longer in the Library.")])
        }
        if URL(fileURLWithPath: earlier.audioPath).pathExtension.lowercased() == "wav" {
            await container.audioPostProcessTracker.markPending(earlier.id)
            _ = await finishPostProcessing(container: container, recording: earlier,
                                           mainURL: URL(fileURLWithPath: earlier.audioPath), wasMeeting: r.isMeeting)
        }
        let joined = try await repository.merge(earlier, later)
        for part in [earlier, later] { container.jobManager.cancel(part.id) }
        if let open = container.librarySelection, open == earlier.id || open == later.id {
            container.librarySelection = joined.id
        }
        try repository.adoptJoin(joined, title: RecordingResume.joinedTitle(r), replacing: [earlier, later])
        AppLog.info("record", "joined the part recorded after a crash → '\(joined.title)'")
        return joined
    }
}

private extension DateFormatter {
    static let short: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .short
        return f
    }()
    static let time: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .short
        return f
    }()
}
