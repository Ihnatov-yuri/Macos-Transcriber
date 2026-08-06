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

            if liveEnabled, !activeMeeting {
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
            let recording = Recording(title: title, audioPath: url.path, durationSeconds: duration)
            try container.repository.save(recording)
            uiState = .finished(url)

            if autoTranscribe {
                let modelDir: URL? = nil
                let params = TranscriptionRunner.Params(
                    file: url,
                    backend: container.uiPrefs.defaultBackend,
                    modelDirectory: modelDir,
                    languages: liveLanguages,
                    translateTo: nil
                )
                container.jobManager.enqueue(recording, params: params)
            }
        } catch {
            lastError = error.localizedDescription
            uiState = .idle
        }
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
