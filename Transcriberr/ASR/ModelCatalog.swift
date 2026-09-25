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
    /// SHA-256 of the file at `directURL` (Hugging Face's LFS object id).
    /// Verified before a download is moved into place: the bundle is parsed
    /// by native code in a process holding mic + Accessibility grants.
    var sha256: String? = nil
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
            directURL: URL(string: "https://huggingface.co/litert-community/gemma-4-E4B-it-litert-lm/resolve/2eee7ac325f20eb8c9ac1d0e972f7c84663062da/gemma-4-E4B-it.litertlm"),
            sizeBytes: 3_659_530_240,
            sha256: "0b2a8980ce155fd97673d8e820b4d29d9c7d99b8fa6806f425d969b145bd52e0",
            supportsAudio: true,
            purpose: "Google-made bundle; biggest LiteRT Gemma with audio."
        ),
        ModelEntry(
            id: "gemma-4-e2b-it-litert",
            name: "Gemma 4 E2B (Google LiteRT) — audio + text · proven on Android",
            backend: .gemmaLiteRT,
            huggingFaceID: "litert-community/gemma-4-E2B-it-litert-lm",
            directURL: URL(string: "https://huggingface.co/litert-community/gemma-4-E2B-it-litert-lm/resolve/b3ca0d2f076785a8f4b2219ddbd2bdb99954eae1/gemma-4-E2B-it.litertlm"),
            sizeBytes: 2_588_147_712,
            sha256: "181938105e0eefd105961417e8da75903eacda102c4fce9ce90f50b97139a63c",
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

    /// Keep the multi-GB model bundles out of Time Machine: they are
    /// downloaded again on demand, and backing them up cost every backup
    /// several GB. The flag is set on the folder, so it covers everything
    /// downloaded into it later.
    static func excludeModelsFromBackup() {
        var dir = durableModelsDirectory()
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            if (try? dir.resourceValues(forKeys: [.isExcludedFromBackupKey]))?.isExcludedFromBackup == true { return }
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try dir.setResourceValues(values)
        } catch {
            AppLog.warn("models", "could not exclude models from backup: \(error.localizedDescription)")
        }
    }

    /// Local snapshot dir for a HF repo id, if downloaded (mirrors
    /// ModelDownloader.localPath without needing an entry instance).
    static func cachedRepoDirectory(huggingFaceID: String?) -> URL? {
        guard let hfID = huggingFaceID else { return nil }
        var dir = durableModelsDirectory()
        for part in hfID.split(separator: "/") { dir = dir.appendingPathComponent(String(part)) }
        // NON-EMPTY, not merely present. A cancelled or failed download
        // leaves the directory behind, and an existence check then reported
        // the model as cached: the run passed the "download it first" gate
        // in Detail and failed minutes later with a bare modelMissing
        // instead of the actionable "SETTINGS → MODELS" message.
        // …and a `.partial` (download in progress, or cut short by a quit)
        // is not a model either.
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return contents.contains { !$0.hasPrefix(".") && !$0.hasSuffix(".partial") } ? dir : nil
    }
}
