import Foundation

/// Mirror of `asr/AsrBackend.kt`.
///
/// Every transcription path — local Gemma 4 (MLX), local Whisper (MLX),
/// or any remote API backend — must implement this protocol.
protocol ASRBackend: Actor {
    nonisolated var id: String { get }
    var isReady: Bool { get }

    func load(modelPath: URL?) async throws
    func release() async

    /// Per-chunk inference. `samples` is 16 kHz mono Float32.
    func transcribeChunk(
        samples: [Float],
        languages: Set<String>,
        translateTo: String?,
        diarize: Bool,
        previousContext: String?,
        speakerHints: [SpeakerHint]
    ) async throws -> String

    /// Text-only call (used by `PostProcessor` for presets).
    func generateText(
        systemInstruction: String,
        userMessage: String,
        maxTokens: Int
    ) async throws -> String
}

/// A recognized word with the recognizer's own confidence — the currency of
/// the ensemble's ROVER merge.
struct ScoredWord: Sendable {
    var surface: String      // as transcribed, punctuation attached
    var norm: String         // lowercased letters/digits only, for alignment
    var confidence: Float
}

struct DetailedTranscription: Sendable {
    let text: String
    let words: [ScoredWord]
}

/// Engines that can expose per-word confidences, enabling the fast
/// word-level ensemble merge (Parakeet, Whisper).
protocol DetailedTranscribing: Actor {
    func transcribeDetailed(
        samples: [Float],
        languages: Set<String>
    ) async throws -> DetailedTranscription
}

struct SpeakerHint: Sendable {
    let startSeconds: Double
    let endSeconds: Double
    let speakerKey: String
}

struct RawSegment: Sendable {
    var startSeconds: Double
    var endSeconds: Double
    var text: String
    var speakerKey: String?
    /// Human name inferred from self-introductions ("Hi, I'm Ahmed") —
    /// filled by the finalize pass, editable later in the UI.
    var speakerName: String?

    init(
        startSeconds: Double,
        endSeconds: Double,
        text: String,
        speakerKey: String? = nil,
        speakerName: String? = nil
    ) {
        self.startSeconds = startSeconds
        self.endSeconds = endSeconds
        self.text = text
        self.speakerKey = speakerKey
        self.speakerName = speakerName
    }
}

enum ASREvent: Sendable {
    case stage(text: String, fraction: Double)
    case partialText(String)
    /// Emitted after each chunk finishes — caller should append these to the
    /// recording immediately so the user sees text appear live.
    case segments(chunkIndex: Int, segments: [RawSegment])
    /// Replaces all segments that fall in `[startSeconds, endSeconds]` with
    /// the supplied list. Used by the second-pass refinement loop in
    /// `TranscriptionRunner` to swap out a chunk's transcription once a
    /// higher-confidence retry comes back.
    case replaceSegments(startSeconds: Double, endSeconds: Double, segments: [RawSegment])
    /// Final event. `segments` is the full set (also re-emitted so callers can
    /// reconcile if they prefer a replace-style save).
    case done(segments: [RawSegment])
    case failed(reason: String)
}

enum ASRError: Error {
    case modelMissing(backend: String)
    case modelLoadFailed(reason: String)
    case chunkTimeout
    case backendUnavailable(reason: String)
    case cancelled
}
