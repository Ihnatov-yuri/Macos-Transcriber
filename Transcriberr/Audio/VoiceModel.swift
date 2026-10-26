@preconcurrency import CoreML
import Foundation

/// Which speaker-embedding model People runs on (Settings → People → Voice
/// model). The user's own voice gate on the microphone stays on WeSpeaker
/// whatever is picked here: it scores 1.5 s windows every half second, and
/// that is the built-in model's job.
///
/// Measured 2026-10-24 on 381 clips of 23 people from the user's meetings
/// (scripts/speaker-eval, report in ~/Documents/Transcriberr-eval): on 3 s
/// clips the built-in WeSpeaker ResNet34 tells two people apart with 6.4%
/// clip error, SimAM-ResNet100 (VoxBlink2, VoxCeleb fine-tune) with 3.1%,
/// and with a wider margin on the closest pair (Lana and Iryna).
enum VoiceModel: String, CaseIterable, Identifiable, Sendable {
    case standard = "wespeaker_v2"
    case simam = "simam_resnet100_vb2_ft"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .standard: return "Standard"
        case .simam: return "High accuracy"
        }
    }

    var detail: String {
        switch self {
        case .standard:
            return "WeSpeaker ResNet34, built in."
        case .simam:
            return "SimAM-ResNet100 trained on VoxBlink2, a \(SimAMModel.totalBytes / 1_000_000) MB download. About twice as good at telling people apart, and slower. Licensed CC BY-NC-SA 4.0: personal, non-commercial use."
        }
    }

    /// The thresholds every People decision uses with this model.
    var scale: VoiceScale {
        switch self {
        case .standard: return .standard
        case .simam: return .simam
        }
    }

    static let key = "people.voiceModel"

    /// The model picked in Settings, if it can run: one whose download went
    /// missing falls back to the built-in model. Always the built-in one in
    /// the unit-test host, whose defaults are the user's.
    static var current: VoiceModel {
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return .standard }
        let chosen = VoiceModel(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .standard
        return chosen == .simam && !SimAMModel.isInstalled() ? .standard : chosen
    }
}

/// The scores People decides on, per model: each model has its own scale
/// (a voice scores higher against itself on one than on another), so each
/// is calibrated on the same clips.
struct VoiceScale: Equatable, Sendable {
    /// Name a speaker at `on` and `margin` above the next person; ask
    /// "Was this them?" from `off`.
    var on: Float
    var off: Float
    var margin: Float
    /// VoiceGate: add a sample at `gateMin` and `gateMargin` above anyone else.
    var gateMin: Float
    var gateMargin: Float
    /// Unknown voices that are one person (centroid to centroid).
    var sameVoice: Float

    /// WeSpeaker ResNet34 on 3 s clips (2026-10-24): the right person at
    /// least 0.52, anyone else at most 0.47, Lana against Iryna 0.41; a
    /// recording's sample at least 0.58 against its own person.
    static let standard = VoiceScale(on: 0.50, off: 0.40, margin: 0.15, gateMin: 0.55, gateMargin: 0.15, sameVoice: 0.62)
    /// SimAM-ResNet100 on 3 s clips, calibrated the same way: the right
    /// person at least 0.51, anyone else at most 0.43, Lana against Iryna
    /// 0.42; unknown voices of one person at least 0.69, of two at most 0.55.
    static let simam = VoiceScale(on: 0.48, off: 0.38, margin: 0.15, gateMin: 0.55, gateMargin: 0.15, sameVoice: 0.62)
}

/// The SimAM-ResNet100 Core ML model, converted by
/// scripts/voice-model/convert_simam.py from WeSpeaker's released weights
/// and hosted on Hugging Face, pinned to one commit and checked file by
/// file like Parakeet UK: it is parsed by native Core ML code in a process
/// holding microphone and Accessibility grants.
enum SimAMModel {
    static let repo = "ihnatov-yuri/wespeaker-simam-resnet100-voxblink2-coreml"
    static let revision = "1c84dc4c6b4db7abd42a3c63f13131e229062f34"
    static let folder = "SimAMResNet100.mlmodelc"

    struct File: Sendable {
        let path: String
        let size: Int64
        let sha256: String
    }

    static let files: [File] = [
        File(path: "analytics/coremldata.bin", size: 243, sha256: "55bde835b0de68d1a9d10f38a39286aacd5d42ceaa130f07cb4e0240d16e1dbc"),
        File(path: "coremldata.bin", size: 587, sha256: "0f71e1eb1b6ee94eb21cffa4c97fefaed767bbdf12304e0cabd67749886f614a"),
        File(path: "metadata.json", size: 2347, sha256: "4c03096d82700ef04a9197f5852fcd59b0ec687dc353286e117846cebde00358"),
        File(path: "model.mil", size: 336_067, sha256: "9801ac370196390ca0746ee6ea86cbdf39dc58fb2c8ee7d1eb1d252726f33601"),
        File(path: "weights/weight.bin", size: 100_437_696, sha256: "fb6d0f95fa31483b07789305c4df5e79400c85aad2a046cac6c88be07eda53e8"),
    ]

    static var totalBytes: Int64 { files.reduce(0) { $0 + $1.size } }

    static var parentDirectory: URL {
        ModelCatalog.durableModelsDirectory()
            .appendingPathComponent("ihnatov-yuri/simam-resnet100", isDirectory: true)
    }
    static var modelURL: URL { parentDirectory.appendingPathComponent(folder, isDirectory: true) }
    private static var stagingDirectory: URL { parentDirectory.appendingPathComponent("download", isDirectory: true) }

    static func isInstalled(at dir: URL = modelURL) -> Bool {
        files.allSatisfy { f in
            (try? FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent(f.path).path))?[.size] as? Int64 == f.size
        }
    }

    static func remoteURL(_ file: File) -> URL {
        URL(string: "https://huggingface.co/\(repo)/resolve/\(revision)/\(folder)/\(file.path)")!
    }

    struct DownloadFailed: LocalizedError {
        let reason: String
        var errorDescription: String? { "The high-accuracy voice model could not be downloaded: \(reason)" }
    }

    /// Downloads the model unless it is installed. Each file is checked
    /// against its hash in a staging folder, which moves into place only
    /// when complete; verified files survive a failed attempt.
    static func ensureDownloaded(progress: (@Sendable (Double) -> Void)? = nil) async throws {
        if isInstalled() { return }
        let fm = FileManager.default
        try fm.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
        var done: Int64 = 0
        for file in files {
            try Task.checkCancellation()
            let target = stagingDirectory.appendingPathComponent(file.path)
            if fm.fileExists(atPath: target.path) {
                if (try? ModelDownloader.sha256(of: target)) == file.sha256 {
                    done += file.size
                    progress?(Double(done) / Double(totalBytes))
                    continue
                }
                try? fm.removeItem(at: target)
            }
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            let (temp, response) = try await URLSession.shared.download(from: remoteURL(file))
            defer { try? fm.removeItem(at: temp) }
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                throw DownloadFailed(reason: "HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1) for \(file.path)")
            }
            guard try ModelDownloader.sha256(of: temp) == file.sha256 else {
                throw DownloadFailed(reason: "\(file.path) did not match its checksum")
            }
            try fm.moveItem(at: temp, to: target)
            done += file.size
            progress?(Double(done) / Double(totalBytes))
        }
        if fm.fileExists(atPath: modelURL.path) { try fm.removeItem(at: modelURL) }
        try fm.moveItem(at: stagingDirectory, to: modelURL)
        AppLog.info("voice", "SimAM-ResNet100 installed at \(modelURL.path)")
    }

    static func delete() {
        try? FileManager.default.removeItem(at: parentDirectory)
    }
}

/// Speaker embeddings from SimAM-ResNet100: 3 s of 16 kHz audio → 298 × 80
/// Kaldi fbanks (KaldiFbank) → 256-d, L2-normalised. A shorter clip is
/// repeat-padded to 3 s, a longer one cut to its middle 3 s.
actor SimAMEmbedder {
    static let shared = SimAMEmbedder()
    static let samples = 48_000
    static let frames = 298

    private var model: MLModel?

    private func loaded() throws -> MLModel {
        if let model { return model }
        let config = MLModelConfiguration()
        config.computeUnits = .all
        let m = try MLModel(contentsOf: SimAMModel.modelURL, configuration: config)
        model = m
        AppLog.info("voice", "SimAM-ResNet100 loaded")
        return m
    }

    /// Drops the model from memory (switching back to the built-in one).
    func unload() { model = nil }

    static func window(_ clip: ArraySlice<Float>) -> ArraySlice<Float> {
        if clip.count >= samples {
            let start = clip.startIndex + (clip.count - samples) / 2
            return clip[start..<(start + samples)]
        }
        guard !clip.isEmpty else { return ArraySlice(repeating: 0, count: samples) }
        var out = [Float]()
        out.reserveCapacity(samples)
        while out.count < samples { out.append(contentsOf: clip.prefix(samples - out.count)) }
        return out[...]
    }

    func embed(_ clips: [ArraySlice<Float>]) async throws -> [[Float]] {
        guard !clips.isEmpty else { return [] }
        let model = try loaded()
        // A shared hold like any engine's: LiteRT must never run beside it.
        let gate = try await InferenceGate.shared.acquire(owner: "voice")
        defer { Task { await InferenceGate.shared.release(gate) } }
        let cancelled = CancelFlag()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<[[Float]], Error>) in
                DispatchQueue.global(qos: .userInitiated).async {
                    do {
                        var out: [[Float]] = []
                        out.reserveCapacity(clips.count)
                        for start in stride(from: 0, to: clips.count, by: 16) {
                            if cancelled.isSet { throw CancellationError() }
                            let batch = try clips[start..<min(clips.count, start + 16)].map { clip -> MLFeatureProvider in
                                let feats = KaldiFbank.shared.features(Self.window(clip))
                                let array = try MLMultiArray(shape: [1, NSNumber(value: Self.frames), 80], dataType: .float32)
                                let p = array.dataPointer.assumingMemoryBound(to: Float.self)
                                feats.withUnsafeBufferPointer { p.update(from: $0.baseAddress!, count: Self.frames * 80) }
                                return try MLDictionaryFeatureProvider(dictionary: ["feats": MLFeatureValue(multiArray: array)])
                            }
                            let results = try model.predictions(fromBatch: MLArrayBatchProvider(array: batch))
                            for i in 0..<results.count {
                                guard let e = results.features(at: i).featureValue(for: "embedding")?.multiArrayValue else {
                                    throw SimAMModel.DownloadFailed(reason: "the model gave no embedding")
                                }
                                var v = (0..<e.count).map { e[$0].floatValue }
                                let n = v.reduce(0) { $0 + $1 * $1 }.squareRoot()
                                if n > 0 { v = v.map { $0 / n } }
                                out.append(v)
                            }
                        }
                        cont.resume(returning: out)
                    } catch {
                        cont.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            cancelled.set()
        }
    }
}

/// The one way People turns audio into voices, on the model picked in
/// Settings. A Voiceprint is tagged with the model that made it, and
/// voices of two models are never compared.
enum PeopleEmbedder {
    static func embed(_ clips: [ArraySlice<Float>], model: VoiceModel = .current) async throws -> [[Float]] {
        switch model {
        case .standard: return try await VoiceEmbedder.shared.embed(clips)
        case .simam: return try await SimAMEmbedder.shared.embed(clips)
        }
    }

    /// A print from continuous speech: voiced `enrollWindow`s, half
    /// overlapping, as VoiceEmbedder.enroll cuts them.
    static func enroll(_ samples: [Float], model: VoiceModel = .current) async throws -> Voiceprint {
        let clips = VoiceEmbedder.enrollClips(samples)
        guard clips.count >= 3 else { throw VoiceprintError.tooLittleSpeech }
        let embeddings = try await embed(clips, model: model)
        let voiced = Double(clips.map(\.count).reduce(0, +)) / VoiceActivity.sampleRate / 2
        return Voiceprint(model: model.rawValue, seconds: voiced, embeddings: embeddings)
    }

    // MARK: The user's voice in People's model

    struct MyVoiceFile: Codable {
        var print: Voiceprint
        /// Size of the enrollment audio it was built from: a new reading
        /// makes it stale.
        var enrollmentBytes: Int64
    }

    static func myVoiceURL(_ model: VoiceModel) -> URL {
        VoiceprintStore.directory.appendingPathComponent("voiceprint-\(model.rawValue).json")
    }

    private static var enrollmentBytes: Int64? {
        (try? FileManager.default.attributesOfItem(atPath: VoiceprintStore.audioURL.path))?[.size] as? Int64
    }

    /// The user's voice as People compares it (so their own lines are never
    /// filed under someone else): the saved print on the built-in model,
    /// the same reading re-embedded on another.
    static func myVoice(_ model: VoiceModel = .current) -> Voiceprint? {
        guard model != .standard else { return VoiceprintStore.load() }
        guard VoiceprintStore.load() != nil,
              let data = try? Data(contentsOf: myVoiceURL(model)),
              let file = try? JSONDecoder().decode(MyVoiceFile.self, from: data),
              file.print.model == model.rawValue, file.enrollmentBytes == enrollmentBytes else { return nil }
        return file.print
    }

    /// Re-embeds the user's kept enrollment reading with `model`.
    static func buildMyVoice(_ model: VoiceModel) async throws {
        // Up to date already: nothing to read again.
        guard model != .standard, let bytes = enrollmentBytes, myVoice(model) == nil else { return }
        let data = try Data(contentsOf: VoiceprintStore.audioURL)
        let samples = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        let print = try await enroll(samples, model: model)
        try JSONEncoder().encode(MyVoiceFile(print: print, enrollmentBytes: bytes))
            .write(to: myVoiceURL(model), options: .atomic)
    }
}
