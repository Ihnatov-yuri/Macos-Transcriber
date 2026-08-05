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
    }

    var elapsedMs: Int64 { container.recorder.elapsedMs }
    var level: Float { container.recorder.level }

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
        container.recorder.pause()
        uiState = .paused
    }

    func resume() {
        guard uiState == .paused else { return }
        container.recorder.resume()
        uiState = .recording
    }

    private func beginRecording() async {
        lastError = nil
        do {
            try await container.recorder.start()
            uiState = .recording

            if liveEnabled {
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
        }
    }

    private func endRecording() async {
        lastError = nil
        await liveWorker.stop()
        do {
            guard let url = try await container.recorder.stop() else {
                uiState = .idle
                return
            }
            let duration = Double(container.recorder.elapsedMs) / 1000
            let title = "Recording \(DateFormatter.short.string(from: Date()))"
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
