import Foundation

/// Ihnatov Whisper UK: Whisper large-v3 turbo with its decoder fine-tuned for
/// Ukrainian, as a Core ML build in WhisperKit's layout on Hugging Face
/// (`ihnatov-yuri/whisper-large-v3-turbo-uk`, `coreml/whisper-large-v3-turbo-uk/`).
/// WhisperKit only downloads from argmaxinc's repo, so the app fetches and
/// updates it itself (`HFModelRelease`) and hands WhisperKit the folder.
/// The folder holds the tokenizer too, so loading needs no network.
nonisolated enum WhisperUKModel {
    /// Its id among the Whisper models (`WhisperModel.all`).
    static let id = "ihnatov-yuri_whisper-large-v3-turbo-uk"

    static let release: HFModelRelease = {
        var parts = ["config.json", "generation_config.json", "tokenizer.json", "tokenizer_config.json"]
        for part in ["MelSpectrogram", "AudioEncoder", "TextDecoder"] {
            parts += ["weights/weight.bin", "model.mil", "coremldata.bin"].map { "\(part).mlmodelc/\($0)" }
        }
        return HFModelRelease(
            repo: "ihnatov-yuri/whisper-large-v3-turbo-uk", remoteFolder: "coreml/whisper-large-v3-turbo-uk",
            displayName: "Whisper UK", logTag: "whisper-uk",
            maxTotalBytes: 3_000_000_000,  // version 1 is about 1.6 GB
            requiredFiles: parts,
            parentDirectory: ModelCatalog.durableModelsDirectory()
                .appendingPathComponent("ihnatov-yuri/whisper-large-v3-turbo-uk", isDirectory: true),
            folderName: "whisper-large-v3-turbo-uk")
    }()

    /// Once a day while the app runs, when the user allowed update checks.
    static func startUpdateLoop(allowed: @escaping @Sendable () async -> Bool) {
        release.startUpdateLoop(lastCheckKey: "whisperUK.lastUpdateCheck", allowed: allowed)
    }
}
