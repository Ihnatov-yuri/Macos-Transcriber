import Foundation

/// What a meeting's transcript and playback take from its mic track.
nonisolated enum MicMode: String, Codable, CaseIterable, Sendable {
    /// Leave out the stretches the meeting app was muted, except where the
    /// user clearly spoke anyway.
    case follow
    case everything
    /// The whole meeting counts as muted, every stretch of the user's voice
    /// is kept. For meetings recorded without a mute log.
    case myVoice
    case nothing
}

/// `<recording>.mute.json`: when the meeting app was muted, and what the user
/// wants done about it. The `.mic` track itself is never changed, so every
/// mode can be undone after the meeting.
nonisolated struct MicMuteLog: Codable, Equatable, Sendable {
    var mode: MicMode = .follow
    var muted: [[Double]] = []
    /// The voice scoring is the slow part and the draft, the mix and Super
    /// each need it: the last answer, valid while the span is the same.
    var cachedSpan: [[Double]]?
    var cachedKept: [[Double]]?

    /// The mode the user sees: nothing logged means nothing was left out.
    var effectiveMode: MicMode { mode == .follow && muted.isEmpty ? .everything : mode }

    private enum CodingKeys: String, CodingKey { case mode, muted, cachedSpan, cachedKept }

    init(mode: MicMode = .follow, muted: [[Double]] = []) {
        self.mode = mode
        self.muted = muted
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // A mode from a newer version reads as "follow", never as an error
        // that would quietly bring the room back.
        mode = (try? c.decode(MicMode.self, forKey: .mode)) ?? .follow
        muted = try c.decodeIfPresent([[Double]].self, forKey: .muted) ?? []
        cachedSpan = try c.decodeIfPresent([[Double]].self, forKey: .cachedSpan)
        cachedKept = try c.decodeIfPresent([[Double]].self, forKey: .cachedKept)
    }
}

nonisolated enum MicMute {
    /// Seconds of the user's voice, while muted, that count as really
    /// talking. Shorter is a word to someone in the room.
    static let sustainedSeconds = 2.0
    /// A voice stretch this close to the end of a mute is the user starting
    /// to talk just before the app showed them unmuted: kept at any length.
    static let unmuteReach = 0.75
    /// How far before the first window that matched to look for the start
    /// of the speech. Capped: in a noisy room the "sound" around the user
    /// runs on for as long as the others talk.
    static let onsetReach = 1.0

    // MARK: - Sidecar

    static func url(forMain main: URL) -> URL {
        main.deletingPathExtension().appendingPathExtension("mute.json")
    }

    static func load(forMain main: URL) -> MicMuteLog? {
        guard let data = try? Data(contentsOf: url(forMain: main)) else { return nil }
        return try? JSONDecoder().decode(MicMuteLog.self, from: data)
    }

    static func save(_ log: MicMuteLog, forMain main: URL) {
        guard let data = try? JSONEncoder().encode(log) else { return }
        AppLog.attempt("mute", "writing \(url(forMain: main).lastPathComponent)") {
            try data.write(to: url(forMain: main), options: .atomic)
        }
    }

    /// The user's choice, keeping the logged stretches.
    static func setMode(_ mode: MicMode, forMain main: URL) {
        var log = load(forMain: main) ?? MicMuteLog()
        log.mode = mode
        save(log, forMain: main)
    }

    // MARK: - Merge and split

    /// The log of two recordings joined, b's stretches shifted. A mode does
    /// not carry over: the merged recording starts from "follow".
    static func merged(_ a: MicMuteLog?, _ b: MicMuteLog?, offset: Double) -> MicMuteLog? {
        let muted = (a?.muted ?? []) + (b?.muted ?? []).filter { $0.count == 2 }.map { [$0[0] + offset, $0[1] + offset] }
        return muted.isEmpty ? nil : MicMuteLog(mode: .follow, muted: muted)
    }

    /// The log cut in two, each part keeping the mode.
    static func split(_ log: MicMuteLog, at cut: Double) -> (first: MicMuteLog, second: MicMuteLog) {
        var a: [[Double]] = [], b: [[Double]] = []
        for pair in log.muted where pair.count == 2 {
            if pair[0] < cut { a.append([pair[0], min(pair[1], cut)]) }
            if pair[1] > cut { b.append([max(pair[0], cut) - cut, pair[1] - cut]) }
        }
        return (MicMuteLog(mode: log.mode, muted: a), MicMuteLog(mode: log.mode, muted: b))
    }

    // MARK: - Decisions (pure)

    /// The stretches the filter applies to.
    static func span(_ log: MicMuteLog, duration: Double) -> [ClosedRange<Double>] {
        switch log.mode {
        case .everything: return []
        case .myVoice, .nothing: return duration > 0 ? [0...duration] : []
        case .follow:
            return log.muted.compactMap { $0.count == 2 && $0[1] > $0[0] ? $0[0]...$0[1] : nil }
        }
    }

    /// The parts of the muted stretches to keep: the user's own speech,
    /// starting where it really started.
    ///
    /// The voice print decides who it is. Level alone cannot: the whole
    /// problem is someone else talking nearby, and they are loud too. Sound
    /// only moves the start back to the speech onset the 1.5 s windows blur.
    static func keptRanges(muted: [ClosedRange<Double>], voice: [ClosedRange<Double>],
                           sound: [ClosedRange<Double>], minSustained: Double = sustainedSeconds) -> [ClosedRange<Double>] {
        var kept: [ClosedRange<Double>] = []
        for m in muted {
            for v in voice where v.upperBound > m.lowerBound && v.lowerBound < m.upperBound {
                let a = max(v.lowerBound, m.lowerBound), b = min(v.upperBound, m.upperBound)
                guard b - a >= minSustained || m.upperBound - b <= unmuteReach else { continue }
                var start = a
                if let s = sound.first(where: { $0.contains(a) }) {
                    start = max(s.lowerBound, a - onsetReach, m.lowerBound)
                }
                kept.append(start...b)
            }
        }
        return VoiceActivity.merge(kept, gap: 0)
    }

    /// `span` minus `kept`.
    static func holes(span: [ClosedRange<Double>], kept: [ClosedRange<Double>]) -> [ClosedRange<Double>] {
        var out: [ClosedRange<Double>] = []
        let sorted = kept.sorted { $0.lowerBound < $1.lowerBound }
        for s in span {
            var at = s.lowerBound
            for k in sorted where k.upperBound > s.lowerBound && k.lowerBound < s.upperBound {
                if k.lowerBound > at { out.append(at...k.lowerBound) }
                at = max(at, k.upperBound)
            }
            if at < s.upperBound { out.append(at...s.upperBound) }
        }
        return out
    }

    static func silence(_ samples: inout [Float], holes: [ClosedRange<Double>],
                        rate: Double = VoiceActivity.sampleRate) {
        for h in holes {
            let a = max(0, Int(h.lowerBound * rate)), b = min(samples.count, Int((h.upperBound * rate).rounded(.up)))
            guard a < b else { continue }
            for i in a..<b { samples[i] = 0 }
        }
    }

    // MARK: - Applying

    /// Applies the recording's mic mode to its decoded (16 kHz) mic track,
    /// in memory. Returns the voice-score cache suffix when anything may
    /// have changed, nil when the track is as recorded.
    static func apply(to mic: inout [Float], main: URL, print: Voiceprint?) async throws -> String? {
        guard var log = load(forMain: main) else { return nil }
        let duration = Double(mic.count) / VoiceActivity.sampleRate
        let span = span(log, duration: duration)
        guard !span.isEmpty else { return nil }
        if log.mode == .myVoice, print == nil {
            AppLog.warn("mute", "only-my-voice needs a voice print and none is enrolled: keeping the whole mic")
            return nil
        }
        let spanPairs = span.map { [$0.lowerBound, $0.upperBound] }
        var kept: [ClosedRange<Double>] = []
        if log.mode != .nothing, let print {
            if log.cachedSpan == spanPairs, let cached = log.cachedKept {
                kept = cached.compactMap { $0.count == 2 && $0[1] >= $0[0] ? $0[0]...$0[1] : nil }
            } else {
                do {
                    guard let found = try await findKept(mic, span: span, mode: log.mode, print: print) else {
                        return nil   // only-my-voice with a print that does not fit
                    }
                    kept = found
                    log.cachedSpan = spanPairs
                    log.cachedKept = kept.map { [$0.lowerBound, $0.upperBound] }
                    save(log, forMain: main)
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    if log.mode == .myVoice {
                        AppLog.warn("mute", "voice scoring failed, keeping the whole mic: \(error.localizedDescription)")
                        return nil
                    }
                    AppLog.warn("mute", "voice scoring failed, muted stretches stay silent: \(error.localizedDescription)")
                }
            }
        }
        let holes = holes(span: span, kept: kept)
        silence(&mic, holes: holes)
        let total = { (r: [ClosedRange<Double>]) in Int(r.reduce(0) { $0 + $1.upperBound - $1.lowerBound }) }
        AppLog.info("mute", "mic mode \(log.mode.rawValue): \(total(holes)) s left out, \(total(kept)) s of your voice kept")
        return "#mic-\(log.mode.rawValue)"
    }

    /// Nil only when the print cannot be trusted to keep the user's voice.
    private static func findKept(_ mic: [Float], span: [ClosedRange<Double>], mode: MicMode,
                                 print: Voiceprint) async throws -> [ClosedRange<Double>]? {
        let hop = VoiceActivity.hop, window = VoiceActivity.window
        let scores = try await VoiceEmbedder.shared.scores(mic, against: print, only: { cell in
            let t = Double(cell) * hop
            return span.contains { t < $0.upperBound && t + window > $0.lowerBound }
        })
        if mode == .myVoice {
            // Deleting everything else on a print that does not fit this
            // mic would delete the user. In "follow" no fit is expected:
            // the user may have said nothing while muted.
            let fit = VoiceTimeline.fits(scores)
            guard fit.0 else {
                AppLog.warn("mute", "the voice print does not fit this mic (\(fit.strong) clear windows): keeping the whole mic")
                return nil
            }
        }
        return keptRanges(muted: span, voice: VoiceActivity.intervals(scores),
                          sound: VoiceActivity.soundRanges(mic),
                          minSustained: mode == .myVoice ? 0 : sustainedSeconds)
    }
}
