import Foundation

/// Curated downloadable models.
/// Mac counterpart to `asr/ModelCatalog.kt` — biases toward bigger / better
/// since Mac isn't phone-RAM constrained.
struct ModelEntry: Sendable, Identifiable {
    let id: String
    let name: String
    let backend: BackendFactory.Kind
    let huggingFaceID: String?     // for Gemma4Swift's downloader
    let directURL: URL?            // reserved for non-HF direct .zip downloads
    let sizeBytes: Int64
    let supportsAudio: Bool
    let purpose: String
}

enum ModelCatalog {
    static let entries: [ModelEntry] = [
        // ---------- Gemma 4 (LiteRT-LM — Google's own runtime + bundles) ----------
        // The same .litertlm bundles the Android app uses, where Gemma audio
        // works well. Audio tower validated by Google, unlike the community
        // MLX quants.
        ModelEntry(
            id: "gemma-4-e4b-it-litert",
            name: "Gemma 4 E4B (Google LiteRT) — audio + text",
            backend: .gemmaLiteRT,
            huggingFaceID: "litert-community/gemma-4-E4B-it-litert-lm",
            directURL: URL(string: "https://huggingface.co/litert-community/gemma-4-E4B-it-litert-lm/resolve/main/gemma-4-E4B-it.litertlm"),
            sizeBytes: 4_900_000_000,
            supportsAudio: true,
            purpose: "Google-made bundle; biggest LiteRT Gemma with audio."
        ),
        ModelEntry(
            id: "gemma-4-e2b-it-litert",
            name: "Gemma 4 E2B (Google LiteRT) — audio + text · proven on Android",
            backend: .gemmaLiteRT,
            huggingFaceID: "litert-community/gemma-4-E2B-it-litert-lm",
            directURL: URL(string: "https://huggingface.co/litert-community/gemma-4-E2B-it-litert-lm/resolve/main/gemma-4-E2B-it.litertlm"),
            sizeBytes: 3_100_000_000,
            supportsAudio: true,
            purpose: "The exact model the Android Transcriber runs."
        ),
    ]

    static func defaultLocalDirectory() -> URL {
        let fm = FileManager.default
        let app = try? fm.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let dir = (app ?? fm.temporaryDirectory)
            .appendingPathComponent("Transcriberr/Models", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Where Gemma4Swift caches downloaded weights — surfaced so the Settings
    /// page can show "Open in Finder".
    static func gemmaCacheDirectory() -> URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("models", isDirectory: true)
    }
}

extension ModelCatalog {
    /// Purge-proof model storage. ~/Library/Caches is evicted by macOS under
    /// disk pressure (it silently deleted the 10 GB MLX Gemma) — single-file
    /// bundles we manage ourselves live in Application Support instead.
    static func durableModelsDirectory() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Transcriberr/models", isDirectory: true)
    }

    /// Local snapshot dir for a HF repo id, if downloaded (mirrors
    /// ModelDownloader.localPath without needing an entry instance).
    static func cachedRepoDirectory(huggingFaceID: String?) -> URL? {
        guard let hfID = huggingFaceID else { return nil }
        var dir = durableModelsDirectory()
        for part in hfID.split(separator: "/") { dir = dir.appendingPathComponent(String(part)) }
        return FileManager.default.fileExists(atPath: dir.path) ? dir : nil
    }
}
