import FluidAudio
import Foundation

/// `transcriberrcli transcribe --json`: the transcript with word-level start/end
/// times, for tools that align audio against a known text (Leesbaar's reading
/// highlight). Words are grouped by `ParakeetBackend.timedWords`, the same
/// grouping the app uses, so the CLI and the app agree on word boundaries.
struct TranscriptJSON: Encodable {
    struct Word: Encodable, Equatable {
        let word: String
        let start: Double
        let end: Double
        let confidence: Double
    }

    let text: String
    let confidence: Double
    let durationS: Double
    let language: String?
    let words: [Word]

    enum CodingKeys: String, CodingKey {
        case text, confidence, language, words
        case durationS = "duration_s"
    }

    init(text: String, confidence: Float, durationS: Double, language: String?, timings: [TokenTiming]) {
        self.text = text
        self.confidence = Self.round3(Double(confidence))
        self.durationS = Self.round3(durationS)
        self.language = language
        self.words = ParakeetBackend.timedWords(from: timings).map {
            Word(word: $0.word.surface,
                 start: Self.round3($0.start),
                 end: Self.round3($0.end),
                 confidence: Self.round3(Double($0.word.confidence)))
        }
    }

    /// Times to the millisecond: finer than the decoder's 80 ms frames anyway.
    static func round3(_ x: Double) -> Double { (x * 1000).rounded() / 1000 }

    func encoded() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(self), as: UTF8.self)
    }
}
