import Foundation
import Observation
import WhisperKit

/// The Whisper builds the app offers, from argmaxinc/whisperkit-coreml plus
/// our own Ukrainian turbo (`WhisperUKModel`). Three are picked: one for
/// English runs (`whisper.model.english`, default large-v3 turbo
/// compressed), one for Ukrainian runs (`whisper.model.ukrainian`, default
/// Whisper UK) and one for every other language (`whisper.model`, default
/// large-v3). The 2026-10-16 sweep of the reference set found every smaller
/// model ties or beats large-v3 inside Super in English at 2-4x the speed,
/// and loses 5-15 points in Ukrainian; the 2026-10-28 run of the Ukrainian
/// meetings put Super with Whisper UK at 14.8% WER against 17.4% with
/// large-v3, at a fifth of the time.
///
/// `id` is the repo folder name, passed to WhisperKit whole: its download
/// matches `*<variant>/*`, and a bare "large-v3" also matches the turbo,
/// compressed and distil folders.
nonisolated struct WhisperModel: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let sizeBytes: Int64
    let note: String
    var englishOnly = false
    /// Fine-tuned on Ukrainian: used for Ukrainian runs only, as
    /// `englishOnly` models are for English ones. Our own build, fetched by
    /// `WhisperUKModel` rather than WhisperKit.
    var ukrainianOnly = false

    static let defaultID = "openai_whisper-large-v3"
    /// The model for every run that is not English only (auto-detect too).
    static let settingsKey = "whisper.model"
    static let englishDefaultID = "openai_whisper-large-v3-v20240930_626MB"
    static let englishSettingsKey = "whisper.model.english"
    static let ukrainianDefaultID = WhisperUKModel.id
    static let ukrainianSettingsKey = "whisper.model.ukrainian"

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
        WhisperModel(id: WhisperUKModel.id, name: "UK (large-v3 turbo)", sizeBytes: 1_620_000_000,
                     note: "The turbo build fine-tuned on Ukrainian speech (ihnatov-yuri/whisper-large-v3-turbo-uk): 8.2% WER on the Ukrainian test sets against large-v3's 9.8%.",
                     ukrainianOnly: true),
    ]

    static func model(_ id: String) -> WhisperModel {
        all.first { $0.id == id } ?? all[0]
    }

    /// The model in use: the running job's pin, else the other-languages
    /// setting (the default for an unknown id).
    static var selected: WhisperModel {
        pinLock.lock(); defer { pinLock.unlock() }
        return model(pinnedID ?? UserDefaults.standard.string(forKey: settingsKey) ?? defaultID)
    }

    static func isEnglish(_ languages: Set<String>) -> Bool {
        !languages.isEmpty && languages.allSatisfy { $0.lowercased() == "english" }
    }

    /// Ukrainian alone, or Ukrainian with English: Whisper UK reads English
    /// better than large-v3 does (AMI 13.2% against 22.3%) and code-switched
    /// speech too (39.0% against 43.2%), so a mixed meeting keeps it.
    static func isUkrainian(_ languages: Set<String>) -> Bool {
        let l = Set(languages.map { $0.lowercased() })
        return l.contains("ukrainian") && l.isSubset(of: ["ukrainian", "english"])
    }

    /// An auto-language run (no languages picked) whose Ukrainian model is
    /// not the other-languages one: the runner reads the audio's language
    /// first (`TranscriptionRunner.repinIfUkrainian`).
    static func needsLanguageProbe(_ languages: Set<String>) -> Bool {
        languages.isEmpty && forRun(["Ukrainian"]).id != forRun([]).id
    }

    /// The model a run in these languages would use, without pinning it.
    static func forRun(_ languages: Set<String>, setting: String? = nil, englishSetting: String? = nil,
                       ukrainianSetting: String? = nil) -> WhisperModel {
        let d = UserDefaults.standard
        let english = isEnglish(languages), ukrainian = isUkrainian(languages)
        let m = english
            ? model(englishSetting ?? d.string(forKey: englishSettingsKey) ?? englishDefaultID)
            : ukrainian
            ? model(ukrainianSetting ?? d.string(forKey: ukrainianSettingsKey) ?? ukrainianDefaultID)
            : model(setting ?? d.string(forKey: settingsKey) ?? defaultID)
        return (m.englishOnly && !english) || (m.ukrainianOnly && !ukrainian) ? model(defaultID) : m
    }

    /// One-time move to the two settings (v4.4.0). Before, one model served
    /// every language; a smaller pick was made for speed, which the sweep
    /// shows is free in English and costly elsewhere. So a non-default pick
    /// becomes the English model and other languages go back to large-v3.
    /// Writing the English key marks the move done.
    static func migrateSettings(_ d: UserDefaults = .standard) {
        guard d.object(forKey: englishSettingsKey) == nil else { return }
        let old = d.string(forKey: settingsKey).map(model)
        if let old, old.id != defaultID {
            d.set(old.id, forKey: englishSettingsKey)
            d.set(defaultID, forKey: settingsKey)
            AppLog.info("whisper", "settings moved: \(old.name) for English, \(model(defaultID).name) for other languages")
        } else {
            d.set(englishDefaultID, forKey: englishSettingsKey)
        }
    }

    /// The model a run uses, fixed when it starts. A pick in Settings or in a
    /// recording's engine menu during a run used to make the next load
    /// (a wedge recovery, the next chunk's check) rebuild Whisper with the
    /// new model, so one transcript came from two models. Jobs run one at a
    /// time; the pin is released when the run ends.
    private static let pinLock = NSLock()
    nonisolated(unsafe) private static var pinnedID: String?

    /// Pins this run's model: the English setting when the run is English
    /// only, the Ukrainian one when it is Ukrainian (alone or with English), else the
    /// other-languages one. An English-only model on a run that is not
    /// English (distil-large-v3 reading Ukrainian), or Whisper UK on one that
    /// is not Ukrainian, is replaced by the default; a model that is not on
    /// disk is still pinned (it downloads on load, and falls back there if it
    /// cannot).
    @discardableResult
    static func pin(for languages: Set<String>, setting: String? = nil, englishSetting: String? = nil,
                    ukrainianSetting: String? = nil) -> WhisperModel {
        let m = forRun(languages, setting: setting, englishSetting: englishSetting, ukrainianSetting: ukrainianSetting)
        pinLock.lock(); pinnedID = m.id; pinLock.unlock()
        return m
    }

    static func unpin() {
        pinLock.lock(); lastRun = pinnedID; pinnedID = nil; pinLock.unlock()
    }

    /// The model the last finished run used, for the version it is saved
    /// under: an auto-language run may have switched to Whisper UK after
    /// the job took its label.
    static var lastRunID: String? {
        pinLock.lock(); defer { pinLock.unlock() }
        return lastRun
    }
    nonisolated(unsafe) private static var lastRun: String?

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

    var folder: URL {
        id == WhisperUKModel.id ? WhisperUKModel.release.modelDirectory : Self.repoDirectory.appendingPathComponent(id, isDirectory: true)
    }

    /// All three compiled parts on disk. A cancelled download leaves some.
    var isDownloaded: Bool {
        if id == WhisperUKModel.id { return WhisperUKModel.release.isInstalled() }
        return ["MelSpectrogram.mlmodelc", "AudioEncoder.mlmodelc", "TextDecoder.mlmodelc"].allSatisfy {
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
                if model.id == WhisperUKModel.id {
                    try await WhisperUKModel.release.ensureDownloaded { @Sendable f in
                        Task { @MainActor in self.progress[model.id] = f }
                    }
                } else {
                    _ = try await WhisperKit.download(variant: model.id) { @Sendable p in
                        let f = p.fractionCompleted
                        Task { @MainActor in self.progress[model.id] = f }
                    }
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
