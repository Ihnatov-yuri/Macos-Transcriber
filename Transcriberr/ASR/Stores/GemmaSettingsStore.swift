import Foundation
import Observation

/// Mirror of `asr/GemmaSettingsStore.kt`.
/// Compute knobs honored by `Gemma4MLXBackend.load()` and the underlying
/// MLX `Device` selection.
@Observable
final class GemmaSettingsStore: @unchecked Sendable {
    enum ComputeBackend: String, CaseIterable, Sendable {
        case auto, gpu, cpu

        var displayName: String {
            switch self {
            case .auto: return "Auto (GPU when available)"
            case .gpu:  return "GPU only (Metal)"
            case .cpu:  return "CPU only"
            }
        }
    }

    private let defaults = UserDefaults.standard
    private enum Key {
        static let backend = "gemma.backend"
        static let context = "gemma.context"
        static let threads = "gemma.threads"
        static let modelID = "gemma.modelID"
    }

    var backend: ComputeBackend {
        didSet { defaults.set(backend.rawValue, forKey: Key.backend) }
    }
    var maxNumTokens: Int {
        didSet { defaults.set(maxNumTokens, forKey: Key.context) }
    }
    var cpuThreads: Int {
        didSet { defaults.set(cpuThreads, forKey: Key.threads) }
    }
    /// Selected model identifier (matches `ModelEntry.id`). Defaults to the
    /// smallest audio-capable Gemma 4 — `gemma-4-e2b-it-4bit`.
    var selectedModelID: String {
        didSet { defaults.set(selectedModelID, forKey: Key.modelID) }
    }

    init() {
        // Default: GPU. The user can still pick CPU / Auto in Settings, but
        // on Apple Silicon Metal is dramatically faster than CPU for Gemma 4
        // and "Auto" was leaving the chip underused in earlier builds.
        backend = ComputeBackend(rawValue: defaults.string(forKey: Key.backend) ?? "") ?? .gpu
        maxNumTokens = (defaults.object(forKey: Key.context) as? Int) ?? 8192
        cpuThreads = (defaults.object(forKey: Key.threads) as? Int) ?? 0

        if let saved = defaults.string(forKey: Key.modelID) {
            selectedModelID = saved
        } else {
            // Auto-pick the biggest audio-capable variant the Mac can handle.
            let ramGB = Int(ProcessInfo.processInfo.physicalMemory / 1_000_000_000)
            switch ramGB {
            case 32...:                 selectedModelID = "gemma-4-e4b-it-bf16"
            case 16..<32:               selectedModelID = "gemma-4-e4b-it-8bit"
            case 8..<16:                selectedModelID = "gemma-4-e4b-it-4bit"
            default:                    selectedModelID = "gemma-4-e2b-it-4bit"
            }
        }
    }

    static let contextChoices = [4096, 8192, 16384, 32768]
    static let threadChoices = [0, 2, 4, 6, 8]
}
