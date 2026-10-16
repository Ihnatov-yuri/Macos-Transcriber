import Foundation
import Observation
import WhisperKit

/// The Whisper builds the app offers, all from argmaxinc/whisperkit-coreml.
/// One is in use at a time (`whisper.model`); large-v3 stays the default
/// because every Whisper measurement in the app (Super's reference set, the
/// Ukrainian and Arabic findings) was made with it.
///
/// `id` is the repo folder name, passed to WhisperKit whole: its download
/// matches `*<variant>/*`, and a bare "large-v3" also matches the turbo,
/// compressed and distil folders.
struct WhisperModel: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let sizeBytes: Int64
    let note: String
    var englishOnly = false

    static let defaultID = "openai_whisper-large-v3"
    static let settingsKey = "whisper.model"

    /// Sizes from the repo listing, 2026-10-15.
    static let all: [WhisperModel] = [
        WhisperModel(id: "openai_whisper-large-v3", name: "large-v3", sizeBytes: 3_090_000_000,
                     note: "Most accurate. Every measurement in the app was made with it."),
        WhisperModel(id: "openai_whisper-large-v3-v20240930_turbo", name: "large-v3 turbo", sizeBytes: 1_640_000_000,
                     note: "OpenAI's turbo build: a much smaller decoder, so faster; slightly less accurate by OpenAI's figures."),
        WhisperModel(id: "openai_whisper-large-v3_947MB", name: "large-v3 compressed", sizeBytes: 950_000_000,
                     note: "large-v3 compressed to under a third of the size."),
        WhisperModel(id: "openai_whisper-large-v3-v20240930_626MB", name: "large-v3 turbo compressed", sizeBytes: 630_000_000,
                     note: "The turbo build compressed: the smallest of the large models."),
        WhisperModel(id: "distil-whisper_distil-large-v3", name: "distil-large-v3", sizeBytes: 1_510_000_000,
                     note: "Distilled for speed. English only.", englishOnly: true),
        WhisperModel(id: "openai_whisper-medium", name: "medium", sizeBytes: 1_530_000_000,
                     note: "The previous generation's middle size, all languages."),
        WhisperModel(id: "openai_whisper-small", name: "small", sizeBytes: 490_000_000,
                     note: "Small and quick; clearly less accurate than the large models."),
    ]

    static func model(_ id: String) -> WhisperModel {
        all.first { $0.id == id } ?? all[0]
    }

    /// The model in use: the running job's pin, else the setting (the
    /// default for an unknown id).
    static var selected: WhisperModel {
        pinLock.lock(); defer { pinLock.unlock() }
        return model(pinnedID ?? UserDefaults.standard.string(forKey: settingsKey) ?? defaultID)
    }

    /// The model a run uses, fixed when it starts. A pick in Settings or in a
    /// recording's engine menu during a run used to make the next load
    /// (a wedge recovery, the next chunk's check) rebuild Whisper with the
    /// new model, so one transcript came from two models. Jobs run one at a
    /// time; the pin is released when the run ends.
    private static let pinLock = NSLock()
    nonisolated(unsafe) private static var pinnedID: String?

    /// Pins the setting for this run. An English-only model on a run that
    /// is not English (distil-large-v3 reading Ukrainian) is replaced by the
    /// default; a model that is not on disk is still pinned (it downloads on
    /// load, and falls back there if it cannot).
    @discardableResult
    static func pin(for languages: Set<String>, setting: String? = nil) -> WhisperModel {
        var m = model(setting ?? UserDefaults.standard.string(forKey: settingsKey) ?? defaultID)
        let english = !languages.isEmpty && languages.allSatisfy { $0.lowercased() == "english" }
        if m.englishOnly && !english {
            AppLog.warn("whisper", "\(m.name) is English only — this run uses \(model(defaultID).name)")
            m = model(defaultID)
        }
        pinLock.lock(); pinnedID = m.id; pinLock.unlock()
        return m
    }

    static func unpin() {
        pinLock.lock(); pinnedID = nil; pinLock.unlock()
    }

    /// The pinned model's id while a run is in flight.
    static var inUse: String? {
        pinLock.lock(); defer { pinLock.unlock() }
        return pinnedID
    }

    /// A downloaded model to fall back on when the chosen one cannot be
    /// fetched (offline): the default first.
    static var fallback: WhisperModel? {
        ([model(defaultID)] + all).first { $0.isDownloaded }
    }

    /// Where WhisperKit keeps its downloads: ~/Documents/huggingface (its
    /// default download base, which the existing large-v3 already uses).
    static var repoDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("huggingface/models/argmaxinc/whisperkit-coreml", isDirectory: true)
    }

    var folder: URL { Self.repoDirectory.appendingPathComponent(id, isDirectory: true) }

    /// All three compiled parts on disk. A cancelled download leaves some.
    var isDownloaded: Bool {
        ["MelSpectrogram.mlmodelc", "AudioEncoder.mlmodelc", "TextDecoder.mlmodelc"].allSatisfy {
            FileManager.default.fileExists(atPath: folder.appendingPathComponent($0).path)
        }
    }
}

/// Downloads and deletes Whisper models from the Models tab. Loading a model
/// that is not on disk still downloads it, as before; this is for fetching
/// one ahead of time and for freeing the space.
@MainActor
@Observable
final class WhisperDownloads {
    static let shared = WhisperDownloads()

    private(set) var progress: [String: Double] = [:]
    private(set) var failures: [String: String] = [:]
    /// Bumped on every download or delete, so views re-read `isDownloaded`.
    private(set) var revision = 0
    private var tasks: [String: Task<Void, Never>] = [:]

    func isDownloading(_ id: String) -> Bool { tasks[id] != nil }

    func download(_ model: WhisperModel) {
        guard tasks[model.id] == nil else { return }
        failures[model.id] = nil
        progress[model.id] = 0
        AppLog.info("whisper", "downloading \(model.id)…")
        tasks[model.id] = Task {
            do {
                _ = try await WhisperKit.download(variant: model.id) { p in
                    let f = p.fractionCompleted
                    Task { @MainActor in self.progress[model.id] = f }
                }
                AppLog.info("whisper", "downloaded \(model.id)")
            } catch {
                if !Task.isCancelled {
                    failures[model.id] = error.localizedDescription
                    AppLog.warn("whisper", "download of \(model.id) failed: \(error.localizedDescription)")
                }
            }
            progress[model.id] = nil
            tasks[model.id] = nil
            revision += 1
        }
    }

    func cancel(_ id: String) {
        tasks[id]?.cancel()
    }

    func delete(_ model: WhisperModel) {
        // The running job's model: its next wedge recovery would download it
        // again in the middle of the run.
        guard WhisperModel.inUse != model.id else {
            failures[model.id] = "In use by the running transcription. Delete it when the run has finished."
            return
        }
        try? FileManager.default.removeItem(at: model.folder)
        AppLog.info("whisper", "deleted \(model.id)")
        revision += 1
    }
}
