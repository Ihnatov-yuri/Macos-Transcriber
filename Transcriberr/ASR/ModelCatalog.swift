import Foundation

/// The on-device text models (summaries, CLEAN, titles, briefs, the coach,
/// dictation polish, Super's arbiter). Downloaded explicitly from Settings →
/// Models: they are several GB each.
///
/// Two runtimes: MLX (Apple's array framework, Metal) for Gemma, uzu
/// (Mirai) for Qwen3.5 9B, which it decodes about twice as fast as MLX.
/// Both load a plain Hugging Face repo folder; every model is pinned to a
/// commit and every file to its checksum. uzu
/// loads its folder by path, so the app never asks Mirai's catalog server.
nonisolated struct ModelEntry: Sendable, Identifiable, Hashable {
    enum Runtime: String, Sendable, Hashable {
        case mlx, uzu
    }

    /// One file of a pinned Hugging Face commit, with Hugging Face's own
    /// checksum: SHA-256 for LFS files, the git blob SHA-1 for small ones.
    struct File: Sendable, Hashable {
        let path: String
        let size: Int64
        var sha256: String? = nil
        var gitBlob: String? = nil
    }

    let id: String
    let name: String
    let runtime: Runtime
    /// The Hugging Face repo, at `revision`.
    let huggingFaceID: String
    let revision: String
    let files: [File]
    /// Small files the app writes beside the download: what a runtime needs
    /// that the repo does not carry.
    var generatedFiles: [String: String] = [:]
    let sizeBytes: Int64
    /// Peak memory measured on a bench (M3 Pro, 13k-token prompt).
    let peakMemoryGB: Int
    /// Smallest Mac it is offered as a default on.
    let minRAMGB: Int
    let purpose: String
    let measured: Measured

    /// What Settings → Models shows as bars: a bench through
    /// the app's own backends (M3 Pro 36 GB, decode tokens per second) and
    /// the round-two blind test (1-5, mean over the Ukrainian tasks: CLEAN,
    /// Summary, brief, dictation, hour-long meetings, people briefs; and the
    /// English ones: dictation, hour-long meetings).
    struct Measured: Sendable, Hashable {
        let cleanupTokensPerSecond: Double
        let summaryTokensPerSecond: Double
        let ukrainianScore: Double
        let englishScore: Double
    }
}

nonisolated enum ModelCatalog {
    static let gemmaE4B = ModelEntry(
        id: "gemma-4-e4b-mlx",
        name: "Gemma 4 E4B",
        runtime: .mlx,
        huggingFaceID: "mlx-community/gemma-4-e4b-it-4bit",
        revision: "475b9088d29754a3379866cf5aeb6b41acd313c2",
        files: [
            .init(path: "chat_template.jinja", size: 17336, gitBlob: "c19999a347da729cf62806a8ddb7eb8e315223b5"),
            .init(path: "config.json", size: 6628, gitBlob: "4ee08502c4f98810dd43800ec849bd69f94adc98"),
            .init(path: "generation_config.json", size: 208, gitBlob: "e605bb4523b1462ea9d9a3810b9e3ecf7ab7b1f6"),
            .init(path: "model.safetensors", size: 5_146_800_534, sha256: "932b8271fc3fe65adcc78b96c10c6268bbfb13e8f67d1358727c0d6ee97e1eff"),
            .init(path: "model.safetensors.index.json", size: 240961, gitBlob: "c03ce5f7086b735345038501f731634de064493b"),
            .init(path: "tokenizer.json", size: 32_169_626, sha256: "cc8d3a0ce36466ccc1278bf987df5f71db1719b9ca6b4118264f45cb627bfe0f"),
            .init(path: "tokenizer_config.json", size: 2740, gitBlob: "cf6235aee46a24bf71f251c0a4e7a0379948f7d2"),
        ],
        sizeBytes: 5_179_238_033,
        peakMemoryGB: 6,
        minRAMGB: 8,
        purpose: "The small one. Best at English dictation, weakest in Ukrainian: it often answers a Ukrainian meeting in English.",
        measured: .init(cleanupTokensPerSecond: 38, summaryTokensPerSecond: 34, ukrainianScore: 1.8, englishScore: 3.1)
    )

    static let gemma26B = ModelEntry(
        id: "gemma-4-26b-a4b-mlx",
        name: "Gemma 4 26B-A4B",
        runtime: .mlx,
        huggingFaceID: "lmstudio-community/gemma-4-26B-A4B-it-QAT-MLX-4bit",
        revision: "aa5e2e50376f54254d503276ca2222ea8569b95e",
        files: [
            .init(path: "chat_template.jinja", size: 18245, gitBlob: "333cfbf67adb71d9d9dbbcac2113bae2e047d15c"),
            .init(path: "config.json", size: 33376, gitBlob: "b0d4f6e5dae9c2a93ff05e8849ba43dfd4911c71"),
            .init(path: "generation_config.json", size: 203, gitBlob: "5a376e9fca28bfac73fe81b623bd6e4d00bb0817"),
            .init(path: "model-00001-of-00003.safetensors", size: 5_275_612_587, sha256: "898863f0d5eba7153a9c9b9443aac1969809f2149e88481c725b6da40783f129"),
            .init(path: "model-00002-of-00003.safetensors", size: 5_296_718_232, sha256: "2abdca76ed4a647cfe8af680908894e2709b4e1221ddbbbef1b1edb14f60e303"),
            .init(path: "model-00003-of-00003.safetensors", size: 5_036_507_755, sha256: "a554f0fdb61bc9e510a5318e723a780c31434fd3e3dcdd3c16c700f835ade7b7"),
            .init(path: "model.safetensors.index.json", size: 176940, gitBlob: "ebc8565a0ecf420c25627bc5b0edc699c5ba16e9"),
            .init(path: "tokenizer.json", size: 32_169_626, sha256: "cc8d3a0ce36466ccc1278bf987df5f71db1719b9ca6b4118264f45cb627bfe0f"),
            .init(path: "tokenizer_config.json", size: 21874, gitBlob: "bc035cce296eb8df57b7b07c0f7e0e6aee1872a3"),
        ],
        sizeBytes: 15_641_258_838,
        peakMemoryGB: 16,
        minRAMGB: 32,
        purpose: "The best of the three, in Ukrainian and on hour-long meetings. A 26B model that only wakes 4B per word, so it is as quick as E4B but needs 16 GB.",
        measured: .init(cleanupTokensPerSecond: 39, summaryTokensPerSecond: 35, ukrainianScore: 3.6, englishScore: 3.8)
    )

    static let qwen9B = ModelEntry(
        id: "qwen3.5-9b-uzu",
        name: "Qwen3.5 9B",
        runtime: .uzu,
        // uzu's own conversion (its catalog's alibaba:qwen3.5:9b:mirai:mirai-m:4),
        // with the speculator that makes it fast.
        huggingFaceID: "trymirai/Qwen3.5-9B-M",
        revision: "043e7b66ff298d13352c1d65aa596d099e4b235b",
        files: [
            .init(path: "config.json", size: 74519, gitBlob: "4a586937aac1a8266c80dc9e15394345760d0f0f"),
            .init(path: "model.safetensors", size: 5_189_121_136, sha256: "eb286a083fea0e01af939f618043f938cc4650ba9d77a44a462ed4d465e19985"),
            .init(path: "speculator/config.json", size: 16958, gitBlob: "3b8fad15aa06538aff7f5b57d30496fcc00d41ca"),
            .init(path: "speculator/model.safetensors", size: 755_228_072, sha256: "7bf2f687c01faa67fad46858102bce5a52fd10e88abc8e3a85741c64c4d9f454"),
            .init(path: "speculator/shapes.json", size: 1432, gitBlob: "33b9e08d9376074d7378dc2c8dffbe8beec0d1c7"),
            .init(path: "tokenizer.json", size: 19_989_343, sha256: "87a7830d63fcf43bf241c3c5242e96e62dd3fdc29224ca26fed8ea333db72de4"),
        ],
        // The chat encoding uzu's catalog gives this model; loading by path
        // reads it from the folder instead.
        generatedFiles: ["encoding.json": #"{"name": "qwen3.5", "type": "hanashi"}"#],
        sizeBytes: 5_964_431_460,
        peakMemoryGB: 7,
        minRAMGB: 16,
        purpose: "The fast one. About twice as quick at cleanup and dictation, because a small helper model guesses ahead. Clearly better than E4B in Ukrainian, behind 26B.",
        measured: .init(cleanupTokensPerSecond: 72, summaryTokensPerSecond: 24, ukrainianScore: 2.5, englishScore: 3.3)
    )

    static let entries: [ModelEntry] = [gemmaE4B, gemma26B, qwen9B]

    static func entry(id: String) -> ModelEntry? { entries.first { $0.id == id } }

    /// What a text call is for: Super's arbiter, or everything else.
    enum Role: String, CaseIterable, Sendable {
        case superMerge = "super"
        case general = "general"

        var defaultsKey: String { "text.model.\(rawValue)" }
    }

    /// First-run choice: the 26B where it fits (with room for Whisper and
    /// the app), E4B elsewhere.
    static func defaultEntry(ramGB: Int = Int(ProcessInfo.processInfo.physicalMemory >> 30)) -> ModelEntry {
        ramGB >= gemma26B.minRAMGB ? gemma26B : gemmaE4B
    }

    /// The model picked for `role` in Settings → Models (or this Mac's
    /// default), downloaded or not.
    static func chosen(_ role: Role) -> ModelEntry {
        UserDefaults.standard.string(forKey: role.defaultsKey).flatMap(entry(id:)) ?? defaultEntry()
    }

    /// The model that runs for `role`: the pick when it is downloaded,
    /// else the best downloaded one that fits this Mac, else any downloaded
    /// one, else the pick (whose load then says it needs downloading). A
    /// Mac with nothing on disk starts with the default picked; whatever the
    /// user downloads first is used for both roles.
    static func selected(_ role: Role) -> ModelEntry {
        resolve(pick: chosen(role), ramGB: Int(ProcessInfo.processInfo.physicalMemory >> 30), installed: isInstalled)
    }

    static func resolve(pick: ModelEntry, ramGB: Int, installed isInstalled: (ModelEntry) -> Bool) -> ModelEntry {
        if isInstalled(pick) { return pick }
        let installed = preference.filter(isInstalled)
        return installed.first { ramGB >= $0.minRAMGB } ?? installed.first ?? pick
    }

    /// Best first, for the fallback above.
    static let preference: [ModelEntry] = [gemma26B, qwen9B, gemmaE4B]

    static var anyInstalled: Bool { entries.contains(where: isInstalled) }

    /// The model's folder: `<models>/<org>/<repo>`.
    static func localDirectory(_ entry: ModelEntry) -> URL {
        var dir = durableModelsDirectory()
        for part in entry.huggingFaceID.split(separator: "/") { dir = dir.appendingPathComponent(String(part)) }
        return dir
    }

    /// Written after every file of a model checked out: its presence
    /// is what "installed" means, so a download cut short is not a model.
    static let completeMarker = ".complete"

    static func isInstalled(_ entry: ModelEntry) -> Bool {
        FileManager.default.fileExists(atPath: localDirectory(entry).appendingPathComponent(completeMarker).path)
    }
}

nonisolated extension ModelCatalog {
    /// Purge-proof model storage. ~/Library/Caches is evicted by macOS under
    /// disk pressure (it would silently delete the 10 GB MLX Gemma) — single-file
    /// bundles we manage ourselves live in Application Support instead.
    static func durableModelsDirectory() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Transcriberr/models", isDirectory: true)
    }

    /// The retired LiteRT Gemma bundles (2.6 and 3.7 GB) that older builds
    /// downloaded. Nothing loads them; they only take disk.
    static func removeRetiredModels() {
        let dir = durableModelsDirectory().appendingPathComponent("litert-community", isDirectory: true)
        guard FileManager.default.fileExists(atPath: dir.path) else { return }
        do {
            try FileManager.default.removeItem(at: dir)
            AppLog.info("models", "removed the retired LiteRT Gemma bundles")
        } catch {
            AppLog.warn("models", "could not remove the LiteRT bundles: \(error.localizedDescription)")
        }
    }

    /// Keep the multi-GB model bundles out of Time Machine: they are
    /// downloaded again on demand, and backing them up would cost every backup
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
}
