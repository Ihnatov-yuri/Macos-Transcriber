import Foundation
import Observation

/// Recorder-side preferences. Lives alongside the other store classes but
/// has process-wide scope (the recorder picks them up at `start()` time).
@Observable
final class RecorderSettings: @unchecked Sendable {
    static let shared = RecorderSettings()

    /// Microphone sensitivity / input gain applied to audio *before Gemma
    /// transcribes it*. Many Macs capture quiet (-50 dB), which both starves
    /// the model and triggers hallucinations. `.auto` normalizes each voiced
    /// chunk to a target level; the fixed steps apply a constant boost.
    enum MicSensitivity: String, CaseIterable, Sendable {
        case auto, x2, x4, x6

        var label: String {
            switch self {
            case .auto: return "AUTO"
            case .x2:   return "2×"
            case .x4:   return "4×"
            case .x6:   return "6×"
            }
        }

        /// Fixed multiplier, or nil for auto (per-chunk normalization).
        var fixedGain: Float? {
            switch self {
            case .auto: return nil
            case .x2:   return 2
            case .x4:   return 4
            case .x6:   return 6
            }
        }
    }

    private let defaults = UserDefaults.standard
    private enum Key {
        static let noiseSuppression = "recorder.noiseSuppression"
        static let preprocessImports = "recorder.preprocessImports"
        static let micSensitivity = "recorder.micSensitivity"
    }

    /// Input sensitivity for transcription. Default `.auto`.
    var micSensitivity: MicSensitivity {
        didSet { defaults.set(micSensitivity.rawValue, forKey: Key.micSensitivity) }
    }

    /// Apply Apple's voice-processing audio unit (echo cancel + noise
    /// suppression + AGC) on the input node when recording.
    var noiseSuppression: Bool {
        didSet { defaults.set(noiseSuppression, forKey: Key.noiseSuppression) }
    }

    /// Run the same noise-suppression pass over *imported* files during
    /// decode. Slower (offline-renders the file once) but worthwhile for
    /// dirty source material.
    var preprocessImports: Bool {
        didSet { defaults.set(preprocessImports, forKey: Key.preprocessImports) }
    }

    private init() {
        // Default OFF until we verify voice processing works on every Mac
        // config we care about. The setting is opt-in in Settings → Audio Input.
        noiseSuppression = (defaults.object(forKey: Key.noiseSuppression) as? Bool) ?? false
        preprocessImports = (defaults.object(forKey: Key.preprocessImports) as? Bool) ?? false
        micSensitivity = (defaults.string(forKey: Key.micSensitivity)
            .flatMap(MicSensitivity.init(rawValue:))) ?? .auto
    }
}
