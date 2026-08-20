import Foundation
import Observation
import SwiftUI

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
    var liveEnabled: Bool { didSet { container.uiPrefs.liveEnabled = liveEnabled } }
    var liveEngine: BackendFactory.Kind { didSet { container.uiPrefs.liveEngine = liveEngine } }
    var liveLanguages: Set<String> { didSet { container.uiPrefs.lastLanguages = liveLanguages } }
    /// Meeting mode: capture system audio (the other participants, tapped
    /// digitally) alongside the mic. Live transcription is unavailable in
    /// this mode — the live worker feeds off WavRecorder's chunk stream.
    var meetingMode: Bool { didSet { UserDefaults.standard.set(meetingMode, forKey: "ui.meetingMode") } }
    /// Which recorder the CURRENT session started with (the toggle may move
    /// mid-recording; stop must go to the recorder that started).
    private var activeMeeting = false
    /// Exposed so the record screen can pick the right waveform source.
    var meetingActive: Bool { activeMeeting }
    private var isStopping = false
    var lastError: String?

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
    }

    var elapsedMs: Int64 { activeMeeting ? container.meetingRecorder.elapsedMs : container.recorder.elapsedMs }
    var level: Float { activeMeeting ? container.meetingRecorder.level : container.recorder.level }

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

    private func beginRecording() async {
        lastError = nil
        do {
            activeMeeting = meetingMode
            if activeMeeting {
                try await container.meetingRecorder.start()
            } else {
                try await container.recorder.start()
            }
            uiState = .recording

            if liveEnabled {
                liveWorker.attach(activeMeeting ? container.meetingRecorder : container.recorder)
                liveWorker.clear()
                await liveWorker.start(
                    engine: liveEngine,
                    languages: liveLanguages,
                    translateTo: nil,
                    modelDirectory: nil
                )
            }
        } catch {
            lastError = error.localizedDescription
            uiState = .idle
            activeMeeting = false
        }
    }

    private func endRecording() async {
        // Stop suspends at several awaits with uiState still .recording — a
        // double-press must not run a second stop and save a duplicate row.
        guard !isStopping else { return }
        isStopping = true
        defer { isStopping = false }
        lastError = nil
        await liveWorker.stop()
        do {
            let wasMeeting = activeMeeting
            let url: URL?
            if wasMeeting {
                url = try await container.meetingRecorder.stop()
            } else {
                url = try await container.recorder.stop()
            }
            guard let url else {
                uiState = .idle
                return
            }
            let duration = Double(wasMeeting ? container.meetingRecorder.elapsedMs
                                             : container.recorder.elapsedMs) / 1000
            let title = "\(wasMeeting ? "Meeting" : "Recording") \(DateFormatter.short.string(from: Date()))"
            // Save with the WAV path FIRST — compressing before the row
            // exists would widen the crash/quit window between "audio
            // written to disk" and "the DB knows about it" from a few
            // synchronous statements to a real, multi-second async
            // transcode. The recording is fully safe and visible before
            // any compression happens at all.
            let recording = Recording(title: title, audioPath: url.path, durationSeconds: duration)
            try container.repository.save(recording)
            uiState = .finished(url)

            // Echo-cancel rebuild + AAC compression run in the BACKGROUND,
            // never awaited here — they used to block this function (and,
            // when autoTranscribe was on, block transcription from even
            // starting), so pressing Stop looked hung for however long that
            // took. TranscriptionRunner decodes the whole file into memory
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
            if autoTranscribe {
                let params = TranscriptionRunner.Params(
                    file: url,
                    backend: container.uiPrefs.defaultBackend,
                    modelDirectory: nil,
                    languages: liveLanguages,
                    translateTo: nil
                )
                let jobManager = container.jobManager
                Task { @MainActor [weak self] in
                    await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                        jobManager.enqueue(recording, params: params) { cont.resume() }
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
            uiState = .idle
        }
    }

    /// Rebuilds the meeting mix with offline echo cancellation (no-op for a
    /// plain recording) and reclaims disk space via AAC compression, then
    /// repoints the saved `Recording` at whatever file survived. Only ever
    /// called after it's safe to mutate the recording's files — either
    /// nothing is reading them (auto-transcribe off) or the transcription
    /// job has finished decoding them (auto-transcribe on). Static, and
    /// takes `container` explicitly, so it runs to completion independent of
    /// whether the `RecordModel` that started it is still alive.
    private static func finishPostProcessing(
        container: AppContainer, recording: Recording, mainURL: URL, wasMeeting: Bool
    ) async -> URL {
        let tracker = container.audioPostProcessTracker
        await tracker.markBusy(recording.id)
        let rebuiltURL = wasMeeting
            ? await MeetingMixRebuilder.rebuildMix(mainURL: mainURL)
            : mainURL
        let finalURL = await AudioCompressor.compressRecordingFiles(mainURL: rebuiltURL, includeSidecars: wasMeeting)
        if finalURL != mainURL {
            try? container.repository.updateAudioPath(finalURL, for: recording)
        }
        await tracker.markIdle(recording.id)
        return finalURL
    }
}

private extension DateFormatter {
    static let short: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .short
        return f
    }()
}
