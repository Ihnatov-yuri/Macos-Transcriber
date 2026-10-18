import Foundation

/// Everything `finalizeSegments` is given, saved as JSON when the
/// TRANSCRIBERR_DUMP_FINALIZE environment variable names a file (CLI runs),
/// so finalize can be replayed on a real meeting in a second with
/// `transcriberrcli refinalize <dump>` instead of re-running a 30-min Super.
struct FinalizeDump: Codable {
    struct Seg: Codable { var start, end: Double; var text: String; var speaker: String?; var name: String? }
    struct Word: Codable { var surface, norm: String; var start, end: Double; var confidence: Float? }
    struct Region: Codable { var start, end: Double; var speaker: String }

    var segments: [Seg]
    var diarize: Bool
    var splitTracks: Bool
    var expectedSpeakers: Int
    var diarization: [Region]
    var myName: String?
    var timelines: [String: [Word]]
    var micSpeech: [[Double]]?
    var micVoice: [[Double]]?
    var sysVoice: [[Double]]?
    var micEcho: Bool?
    var clusterVoice: [String: Float]?
    /// Where the call track has sound (since 4.4.1).
    var sysSound: [[Double]]?

    init(segments: [RawSegment], diarize: Bool, splitTracks: Bool, expectedSpeakers: Int,
         diarSegments: [DiarizationRunner.SpeakerSegment], myName: String?, timelines: [Int: [TimedWord]],
         micSpeech: [ClosedRange<Double>]? = nil, voice: VoiceTimeline? = nil, micEcho: Bool = false,
         clusterVoice: [String: Float]? = nil, sysSound: [ClosedRange<Double>]? = nil) {
        self.segments = segments.map { Seg(start: $0.startSeconds, end: $0.endSeconds, text: $0.text,
                                           speaker: $0.speakerKey, name: $0.speakerName) }
        self.diarize = diarize
        self.splitTracks = splitTracks
        self.expectedSpeakers = expectedSpeakers
        self.diarization = diarSegments.map { Region(start: $0.startSeconds, end: $0.endSeconds, speaker: $0.speakerId) }
        self.myName = myName
        self.micSpeech = micSpeech?.map { [$0.lowerBound, $0.upperBound] }
        self.micVoice = voice?.mic.map { [$0.lowerBound, $0.upperBound] }
        self.sysVoice = voice?.sys.map { [$0.lowerBound, $0.upperBound] }
        self.micEcho = micEcho
        self.clusterVoice = clusterVoice
        self.sysSound = sysSound?.map { [$0.lowerBound, $0.upperBound] }
        self.timelines = Dictionary(uniqueKeysWithValues: timelines.map { id, words in
            (String(id), words.map { Word(surface: $0.word.surface, norm: $0.word.norm, start: $0.start, end: $0.end, confidence: $0.word.confidence) })
        })
    }

    var rawSegments: [RawSegment] {
        segments.map { RawSegment(startSeconds: $0.start, endSeconds: $0.end, text: $0.text,
                                  speakerKey: $0.speaker, speakerName: $0.name) }
    }
    var micSpeechRanges: [ClosedRange<Double>]? {
        micSpeech?.compactMap { $0.count == 2 && $0[0] <= $0[1] ? $0[0]...$0[1] : nil }
    }
    var sysSoundRanges: [ClosedRange<Double>]? {
        sysSound?.compactMap { $0.count == 2 && $0[0] <= $0[1] ? $0[0]...$0[1] : nil }
    }
    var voice: VoiceTimeline? {
        guard let micVoice else { return nil }
        func ranges(_ r: [[Double]]?) -> [ClosedRange<Double>] {
            (r ?? []).compactMap { $0.count == 2 && $0[0] <= $0[1] ? $0[0]...$0[1] : nil }
        }
        return VoiceTimeline(mic: ranges(micVoice), sys: ranges(sysVoice))
    }
    var diarSegments: [DiarizationRunner.SpeakerSegment] {
        diarization.map { .init(startSeconds: $0.start, endSeconds: $0.end, speakerId: $0.speaker) }
    }
    var timedTimelines: [Int: [TimedWord]] {
        Dictionary(uniqueKeysWithValues: timelines.compactMap { key, words in
            Int(key).map { id in
                (id, words.map { TimedWord(word: ScoredWord(surface: $0.surface, norm: $0.norm, confidence: $0.confidence ?? 1),
                                           start: $0.start, end: $0.end) })
            }
        })
    }

    static func saveIfRequested(_ dump: @autoclosure () -> FinalizeDump) {
        guard let path = ProcessInfo.processInfo.environment["TRANSCRIBERR_DUMP_FINALIZE"], !path.isEmpty else { return }
        do {
            try JSONEncoder().encode(dump()).write(to: URL(fileURLWithPath: path))
            AppLog.info("runner", "finalize inputs saved to \(path)")
        } catch {
            AppLog.warn("runner", "finalize dump failed: \(error.localizedDescription)")
        }
    }
}
