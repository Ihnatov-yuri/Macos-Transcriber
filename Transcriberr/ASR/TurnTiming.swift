import Foundation

/// Split-track meetings are transcribed in ~26 s chunks per track, and until
/// this step every chunk became one segment with the chunk's span: the mic's
/// chunks and the far side's overlap on the clock, so the transcript read as
/// alternating 26 s blocks — a reply printed before the question it answers,
/// sentences cut in half by the other side's block — and a far-side chunk
/// carried ONE speaker (the diarizer cluster overlapping it most) however
/// many people spoke in it. 2026-10-14 meeting: five voices on the far side,
/// 98% of segments overlapping the next.
///
/// Parakeet reads each whole track with word times in seconds (the far side
/// for echo-by-timing already). The chunk's final text is aligned onto those
/// words, so every word gets a time; the segment is then cut where the
/// speaker stops for a breath and, on the far side, where the diarizer hears
/// another voice. Pieces carry their own word span, so sorting by start puts
/// replies after what they answer, and same-speaker pieces still coalesce
/// into turns downstream.
nonisolated enum TurnTiming {
    /// A silence this long inside one track is a place another track's words
    /// may fall between. Shorter pauses are breathing inside a sentence.
    static let pauseSplitSeconds = 1.0
    /// A diarizer run shorter than this (and under `minRunTokens` words) is
    /// cluster jitter, not a turn: it joins its neighbour.
    static let minRunSeconds = 1.0
    static let minRunTokens = 3
    /// A word repeated this many times running with no support in the
    /// track's own reading is a decoder loop ("So. So. So. So.", "Silence.
    /// Silence.") — Whisper writes them over echo residue on the mic.
    static let loopRun = 3
    /// Slack around the recorder's mic-dominance intervals for short pieces:
    /// they open on energy, a little after the first syllable.
    static let micSpeechPad = 1.0
    /// Pieces at least this long must be this much covered by the intervals.
    /// 2026-10-14 call on speakers: the user's real lines were 59-64%
    /// covered, Whisper's inventions over echo residue (26 s unanchored
    /// chunks, "Hello, I'm Joe" x8) under 5% — single 0.3 s blips.
    static let longPieceSeconds = 3.0
    static let minAnchoredShare = 0.5
    /// The speech timeline only ever removes what the mic's own Parakeet
    /// reading was unsure of. It misses the user whenever the far side is
    /// louder in the tap than the user on the mic (headphones, a loud
    /// coach): a 72-min Ukrainian session lost 27% of the user's words to
    /// it, all read at median confidence 0.91. Echo residue on the speaker
    /// call read at median 0.51 (p75 0.62); the user's real lines there 0.87.
    static let confidentSpeech: Float = 0.7

    static func meanConfidence(_ tokens: [Token]) -> Float {
        tokens.isEmpty ? 0 : tokens.map(\.confidence).reduce(0, +) / Float(tokens.count)
    }
    static func meanConfidence(_ words: [TimedWord]) -> Float {
        words.isEmpty ? 0 : words.map(\.word.confidence).reduce(0, +) / Float(words.count)
    }
    static let minSpeechCoverage = 0.25

    /// Any speech interval (padded) inside `a`…`b`.
    static func overlapsSpeech(_ a: Double, _ b: Double, micSpeech: [ClosedRange<Double>]) -> Bool {
        micSpeech.contains { $0.upperBound + micSpeechPad > a && $0.lowerBound - micSpeechPad < b }
    }

    static func isSpoken(_ a: Double, _ b: Double, micSpeech: [ClosedRange<Double>]) -> Bool {
        if b - a < longPieceSeconds {
            return overlapsSpeech(a, b, micSpeech: micSpeech)
        }
        let covered = micSpeech.reduce(0.0) { $0 + max(0, min(b, $1.upperBound) - max(a, $1.lowerBound)) }
        return covered >= minSpeechCoverage * (b - a)
    }

    struct Token {
        var surface: String
        var norm: String
        var start: Double = 0
        var end: Double = 0
        var anchored = false
        /// The track reading's confidence in the word this token aligned to.
        var confidence: Float = 0
    }

    /// `timelines`: whole-track word readings keyed by track — 0 the far
    /// side (system audio), 1 the echo-cancelled mic. ME segments align to
    /// track 1, everything else to track 0. `diarization` clusters the far
    /// side; empty keeps each piece's existing speaker.
    static func retime(
        _ segments: [RawSegment],
        timelines: [Int: [TimedWord]],
        diarization: [DiarizationRunner.SpeakerSegment],
        micSpeech: [ClosedRange<Double>]? = nil,
        micVoice: [ClosedRange<Double>]? = nil,
        micEcho: Bool = false,
        logs: Bool = true
    ) -> [RawSegment] {
        guard !timelines.isEmpty else { return segments }
        var out: [RawSegment] = []
        var loopsDropped = 0, echoDropped = 0, split = 0, unspoken = 0, unvoiced = 0
        // With echo on the mic, a piece the mic's own reading mostly lacks
        // is Whisper writing over residue ("I to it's a. of").
        func heard(_ t: [Token]) -> Bool {
            guard micSpeech != nil || (micVoice != nil && micEcho) else { return true }
            let content = t.filter { !$0.norm.isEmpty }
            return Double(content.filter(\.anchored).count) >= minAnchoredShare * Double(content.count)
        }
        func spoken(_ a: Double, _ b: Double) -> Bool {
            guard let micSpeech else { return true }
            return isSpoken(a, b, micSpeech: micSpeech)
        }
        // The voice print's timeline (see VoiceActivity) decides on its own:
        // it does not miss the user under a loud far side, so there is no
        // confidence escape — another voice bleeding into the mic reads
        // confidently, and that is exactly what it must remove.
        func voiced(_ a: Double, _ b: Double) -> Bool {
            guard let micVoice else { return true }
            return isSpoken(a, b, micSpeech: micVoice)
        }
        for seg in segments {
            let isMe = seg.speakerKey == "ME"
            guard let line = timelines[isMe ? 1 : 0], !line.isEmpty else { out.append(seg); continue }
            var tokens = tokenize(seg.text)
            guard !tokens.isEmpty else { out.append(seg); continue }
            let candidates = wordsNear(line, from: seg.startSeconds - 1, to: seg.endSeconds + 1)
            align(&tokens, to: candidates)
            guard tokens.contains(where: \.anchored) else {
                // Nothing to time it by: keep the chunk span, but the mic's
                // own reading not hearing these words is the second signal
                // that loops and stock words over residue are phantoms.
                guard isMe else { out.append(seg); continue }
                if micVoice != nil {
                    if !voiced(seg.startSeconds, seg.endSeconds) { unvoiced += tokens.count; continue }
                } else if !spoken(seg.startSeconds, seg.endSeconds),
                   meanConfidence(candidates) < confidentSpeech { unspoken += tokens.count; continue }
                if let far = timelines[0], isEcho(tokens, farWords: wordsNear(far, from: seg.startSeconds - 1, to: seg.endSeconds + 1)) {
                    echoDropped += tokens.count
                    continue
                }
                let kept = dropPhantoms(tokens)
                loopsDropped += tokens.count - kept.count
                if kept.isEmpty { continue }
                var s = seg
                s.text = kept.map(\.surface).joined(separator: " ")
                out.append(s)
                continue
            }
            interpolate(&tokens)
            let before = tokens.count
            tokens = isMe ? dropPhantoms(tokens) : dropUnanchoredLoops(tokens)
            loopsDropped += before - tokens.count
            if isMe, let far = timelines[0], !far.isEmpty {
                // Echo by timing, as Super does per chunk: the far side's
                // words heard again on the mic sit at the same time as the
                // originals. The Parakeet draft had only the sentence scrub,
                // which misses copies mixed into the user's own line.
                let n = tokens.count
                tokens = echoFree(tokens, farSide: far)
                echoDropped += n - tokens.count
            }
            guard !tokens.isEmpty else { continue }
            let pieces = cut(tokens, speaker: seg.speakerKey, isMe: isMe, diarization: diarization)
            split += pieces.count - 1
            for var p in pieces {
                if isMe, let far = timelines[0] {
                    let n = p.tokens.count
                    p.tokens = withoutEchoEdges(p.tokens, farSide: far)
                    echoDropped += n - p.tokens.count
                    if p.tokens.isEmpty { continue }
                    let a = p.tokens.first!.start, b = p.tokens.last!.end
                    if !voiced(a, b) { unvoiced += p.tokens.count; continue }
                    if !spoken(a, b) || !heard(p.tokens),
                       meanConfidence(p.tokens.filter(\.anchored)) < confidentSpeech {
                        unspoken += p.tokens.count; continue
                    }
                }
                var s = seg
                s.startSeconds = p.tokens.first!.start
                s.endSeconds = max(p.tokens.last!.end, s.startSeconds + 0.1)
                s.text = p.tokens.map(\.surface).joined(separator: " ")
                s.speakerKey = p.speaker
                out.append(s)
            }
        }
        if logs, split > 0 || loopsDropped > 0 || echoDropped > 0 || unspoken > 0 || unvoiced > 0 {
            AppLog.info("runner", "turn timing: \(segments.count) chunk segments → \(out.count) timed pieces, \(loopsDropped) looped, \(echoDropped) echoed, \(unspoken) unspoken and \(unvoiced) not-your-voice mic words dropped")
        }
        return out.sorted { $0.startSeconds < $1.startSeconds }
    }

    // MARK: - Steps

    static func tokenize(_ text: String) -> [Token] {
        text.split(whereSeparator: \.isWhitespace).map {
            Token(surface: String($0), norm: norm($0))
        }
    }

    static func norm(_ s: some StringProtocol) -> String {
        String(s.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(Character.init))
    }

    /// Parakeet glues a number to the word before it ("have17", "Europe12")
    /// where the merged text has two words; split them so both align.
    static func splitGlued(_ words: [TimedWord]) -> [TimedWord] {
        words.flatMap { w -> [TimedWord] in
            let n = w.word.norm
            guard let cut = n.firstIndex(where: \.isNumber), cut != n.startIndex,
                  n[cut...].allSatisfy(\.isNumber), n[..<cut].allSatisfy(\.isLetter) else { return [w] }
            let head = String(n[..<cut]), tail = String(n[cut...])
            let mid = w.start + (w.end - w.start) * Double(head.count) / Double(n.count)
            return [TimedWord(word: ScoredWord(surface: head, norm: head, confidence: w.word.confidence), start: w.start, end: mid),
                    TimedWord(word: ScoredWord(surface: tail, norm: tail, confidence: w.word.confidence), start: mid, end: w.end)]
        }
    }

    /// Timeline words whose midpoint falls in [from, to). `line` is sorted.
    static func wordsNear(_ line: [TimedWord], from: Double, to: Double) -> [TimedWord] {
        var lo = 0, hi = line.count
        while lo < hi { let m = (lo + hi) / 2; if line[m].end < from { lo = m + 1 } else { hi = m } }
        var out: [TimedWord] = []
        var k = lo
        while k < line.count, line[k].start < to {
            let mid = (line[k].start + line[k].end) / 2
            if mid >= from && mid < to { out.append(line[k]) }
            k += 1
        }
        return splitGlued(out)
    }

    /// Longest common subsequence on normalized words (near-equal spellings
    /// count: the merged text is often Whisper's spelling of Parakeet's word).
    static func align(_ tokens: inout [Token], to words: [TimedWord]) {
        let n = tokens.count, m = words.count
        guard n > 0, m > 0 else { return }
        var dp = [[Int]](repeating: [Int](repeating: 0, count: m + 1), count: n + 1)
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                dp[i][j] = similar(tokens[i].norm, words[j].word.norm)
                    ? dp[i + 1][j + 1] + 1
                    : max(dp[i + 1][j], dp[i][j + 1])
            }
        }
        var i = 0, j = 0
        while i < n && j < m {
            if similar(tokens[i].norm, words[j].word.norm) && dp[i][j] == dp[i + 1][j + 1] + 1 {
                tokens[i].start = words[j].start
                tokens[i].end = words[j].end
                tokens[i].anchored = true
                tokens[i].confidence = words[j].word.confidence
                i += 1; j += 1
            } else if dp[i + 1][j] >= dp[i][j + 1] {
                i += 1
            } else {
                j += 1
            }
        }
    }

    static func similar(_ a: String, _ b: String) -> Bool {
        if a.isEmpty || b.isEmpty { return false }
        if a == b { return true }
        guard min(a.count, b.count) >= 4, abs(a.count - b.count) <= 1 else { return false }
        return editDistance(Array(a), Array(b)) <= 1
    }

    private static func editDistance(_ a: [Character], _ b: [Character]) -> Int {
        var prev = Array(0...b.count)
        for i in 1...a.count {
            var cur = [i] + [Int](repeating: 0, count: b.count)
            for j in 1...b.count {
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            prev = cur
        }
        return prev[b.count]
    }

    /// Seconds an unanchored word is assumed to take.
    static let unanchoredWordSeconds = 0.3

    /// Unanchored words follow the anchored word before them at a speaking
    /// pace, not spread across the whole gap to the next anchor: spread, two
    /// words Whisper added ("Okay. Nice place.") bridged a 3 s pause and the
    /// user's answer printed before the question asked in it. Before the
    /// first anchor or after the last they sit on it.
    static func interpolate(_ tokens: inout [Token]) {
        let anchors = tokens.indices.filter { tokens[$0].anchored }
        guard let first = anchors.first, let last = anchors.last else { return }
        for i in 0..<first { tokens[i].start = tokens[first].start; tokens[i].end = tokens[first].start }
        for i in (last + 1)..<tokens.count { tokens[i].start = tokens[last].end; tokens[i].end = tokens[last].end }
        for (a, b) in zip(anchors, anchors.dropFirst()) where b - a > 1 {
            let t0 = tokens[a].end, t1 = max(tokens[b].start, t0)
            let step = min(unanchoredWordSeconds, (t1 - t0) / Double(b - a))
            for i in (a + 1)..<b {
                tokens[i].start = t0 + step * Double(i - a - 1)
                tokens[i].end = t0 + step * Double(i - a)
            }
        }
    }

    /// Words Whisper writes over near-silence that nobody says in a meeting
    /// unless the mic's own reading also has them.
    static let phantomWords: Set<String> = ["silence"]

    /// Mic only: unanchored loops and unanchored stock words.
    static func dropPhantoms(_ tokens: [Token]) -> [Token] {
        dropUnanchoredLoops(tokens).filter { $0.anchored || !phantomWords.contains($0.norm) }
    }

    static func dropUnanchoredLoops(_ tokens: [Token]) -> [Token] {
        var keep = [Bool](repeating: true, count: tokens.count)
        var i = 0
        while i < tokens.count {
            var j = i
            while j + 1 < tokens.count, !tokens[j + 1].norm.isEmpty, tokens[j + 1].norm == tokens[i].norm { j += 1 }
            let run = i...j
            if run.count >= loopRun, !run.contains(where: { tokens[$0].anchored }) {
                for k in run { keep[k] = false }
            }
            i = j + 1
        }
        return tokens.indices.filter { keep[$0] }.map { tokens[$0] }
    }

    static func echoFree(_ tokens: [Token], farSide: [TimedWord]) -> [Token] {
        let timed = tokens.enumerated().map { i, t in
            // The index rides in `confidence` so survivors map back to tokens.
            TimedWord(word: ScoredWord(surface: t.surface, norm: t.norm, confidence: Float(i)),
                      start: t.start, end: t.end)
        }
        let kept = Set(EnsembleBackend.echoFiltered(timed, farSide: farSide).map { Int($0.word.confidence) })
        return tokens.indices.filter { kept.contains($0) }.map { tokens[$0] }
    }

    /// A mic piece (cut at pauses) this much of which is the far side's
    /// words at the same moment is the far side heard again. Runs of two
    /// count here, unlike `echoFiltered`'s three inside a line: a piece is
    /// already bounded by silence, so "We are" alone between pauses, timed
    /// on the far side's "We are", is not the user talking.
    static let echoPieceShare = 0.7
    static let echoTolerance = 1.0

    /// Which tokens are the far side's words at the same moment. Near
    /// spellings count, and so do two tokens the far reading wrote as one
    /// ("we are" / "we're"): the two engines and the two tracks disagree on
    /// both, and the mic hears the far side ~0.3 s late.
    static func echoFlags(_ tokens: [Token], farSide: [TimedWord]) -> [Bool] {
        guard let first = tokens.first, let last = tokens.last else { return [] }
        let near = wordsNear(farSide, from: first.start - 2, to: last.end + 2)
        func hit(_ norm: String, at mid: Double) -> Bool {
            near.contains { abs(($0.start + $0.end) / 2 - mid) <= echoTolerance && echoMatch(norm, $0.word.norm) }
        }
        var flags = [Bool](repeating: false, count: tokens.count)
        for i in tokens.indices where !tokens[i].norm.isEmpty {
            if hit(tokens[i].norm, at: (tokens[i].start + tokens[i].end) / 2) { flags[i] = true; continue }
            if i + 1 < tokens.count,
               hit(tokens[i].norm + tokens[i + 1].norm, at: (tokens[i].start + tokens[i + 1].end) / 2) {
                flags[i] = true; flags[i + 1] = true
            }
        }
        return flags
    }

    /// A mic piece mostly made of the far side's words goes whole; otherwise
    /// echoed words at its edges go — the far side's last words before the
    /// user answers, and its first words after.
    static func withoutEchoEdges(_ tokens: [Token], farSide: [TimedWord]) -> [Token] {
        let flags = echoFlags(tokens, farSide: farSide)
        let content = tokens.indices.filter { !tokens[$0].norm.isEmpty }
        guard !content.isEmpty else { return tokens }
        let share = Double(content.filter { flags[$0] }.count) / Double(content.count)
        if content.count >= 2 && share >= echoPieceShare { return [] }
        // Runs of two or more, or one long word: a short shared word ("It's",
        // "yeah") at the same second is as often both people talking as it
        // is echo, but nobody repeats "architecture" in step with the speaker.
        // A lone long word must also START with the far one, at the echo's
        // ~0.3 s lag: repeating the other person's word comes later (uk-b:
        // "логику" / "логіку" 0.7 s apart, both really said; "architecture"
        // echoed 0.4 s after "architect").
        let near = wordsNear(farSide, from: (tokens.first?.start ?? 0) - 2, to: (tokens.last?.end ?? 0) + 2)
        func strong(_ r: Range<Int>) -> Bool {
            r.count >= 2 || r.contains { i in
                tokens[i].norm.count >= longEchoWord && near.contains {
                    abs($0.start - tokens[i].start) <= loneEchoStartLag && echoMatch(tokens[i].norm, $0.word.norm)
                }
            }
        }
        var lo = 0, hi = tokens.count
        while lo < hi, flags[lo] { lo += 1 }
        if !strong(0..<lo) { lo = 0 }
        while hi > lo, flags[hi - 1] { hi -= 1 }
        if !strong(hi..<tokens.count) { hi = tokens.count }
        return lo < hi ? Array(tokens[lo..<hi]) : []
    }

    static let longEchoWord = 5
    static let loneEchoStartLag = 0.5

    /// Near spellings, or a long word cut short by the other reading
    /// ("architect" for "architecture").
    static func echoMatch(_ a: String, _ b: String) -> Bool {
        if similar(a, b) { return true }
        let (short, long) = a.count <= b.count ? (a, b) : (b, a)
        return short.count >= 6 && long.hasPrefix(short)
    }

    /// An unaligned mic line whose words are, in order, the far side's words
    /// from the same stretch (the user said none of it).
    static func isEcho(_ tokens: [Token], farWords: [TimedWord]) -> Bool {
        let content = tokens.filter { !$0.norm.isEmpty }
        guard content.count >= 2, !farWords.isEmpty else { return false }
        var probe = content
        align(&probe, to: farWords)
        return Double(probe.filter(\.anchored).count) / Double(content.count) >= echoPieceShare
    }

    struct Piece {
        var tokens: [Token]
        var speaker: String?
    }

    /// Cut at pauses, and on the far side where the diarizer's voice changes.
    static func cut(
        _ tokens: [Token], speaker: String?, isMe: Bool,
        diarization: [DiarizationRunner.SpeakerSegment]
    ) -> [Piece] {
        var voices: [String?] = tokens.map { _ in speaker }
        if !isMe, !diarization.isEmpty {
            voices = tokens.map { voice(at: $0, in: diarization) }
            // Words the diarizer left unclustered take the previous voice.
            var last: String? = voices.first { $0 != nil } ?? speaker
            for i in voices.indices {
                if let v = voices[i] { last = v } else { voices[i] = last }
            }
            voices = smoothed(voices, tokens: tokens)
        }
        var pieces: [Piece] = []
        for (i, t) in tokens.enumerated() {
            if var cur = pieces.last,
               cur.speaker == voices[i],
               t.start - cur.tokens.last!.end < pauseSplitSeconds {
                cur.tokens.append(t)
                pieces[pieces.count - 1] = cur
            } else {
                pieces.append(Piece(tokens: [t], speaker: voices[i]))
            }
        }
        return pieces
    }

    static func voice(at t: Token, in diar: [DiarizationRunner.SpeakerSegment]) -> String? {
        let a = t.start, b = max(t.end, t.start + 0.05)
        var best: (String, Double)?
        for d in diar where d.endSeconds > a && d.startSeconds < b {
            let overlap = min(b, d.endSeconds) - max(a, d.startSeconds)
            if best == nil || overlap > best!.1 { best = (d.speakerId, overlap) }
        }
        if let best { return best.0 }
        // Between regions: the nearer one, within a second.
        let mid = (a + b) / 2
        let near = diar.min { abs(($0.startSeconds + $0.endSeconds) / 2 - mid) < abs(($1.startSeconds + $1.endSeconds) / 2 - mid) }
        guard let near, min(abs(near.startSeconds - mid), abs(near.endSeconds - mid)) < 1 else { return nil }
        return near.speakerId
    }

    /// Short runs of another voice inside a turn are jitter: fold each into
    /// the run before it (or after it, at the start).
    static func smoothed(_ voices: [String?], tokens: [Token]) -> [String?] {
        var runs: [(voice: String?, range: Range<Int>)] = []
        for i in voices.indices {
            if let last = runs.last, last.voice == voices[i] {
                runs[runs.count - 1].range = last.range.lowerBound..<(i + 1)
            } else {
                runs.append((voices[i], i..<(i + 1)))
            }
        }
        guard runs.count > 1 else { return voices }
        var changed = true
        while changed && runs.count > 1 {
            changed = false
            for k in runs.indices {
                let r = runs[k].range
                let dur = tokens[r.upperBound - 1].end - tokens[r.lowerBound].start
                guard r.count < minRunTokens && dur < minRunSeconds else { continue }
                let into = k > 0 ? k - 1 : k + 1
                let lo = min(runs[into].range.lowerBound, r.lowerBound)
                let hi = max(runs[into].range.upperBound, r.upperBound)
                runs[into].range = lo..<hi
                runs.remove(at: k)
                // Neighbours that now share a voice become one run.
                var merged: [(voice: String?, range: Range<Int>)] = []
                for run in runs {
                    if let last = merged.last, last.voice == run.voice {
                        merged[merged.count - 1].range = last.range.lowerBound..<run.range.upperBound
                    } else {
                        merged.append(run)
                    }
                }
                runs = merged
                changed = true
                break
            }
        }
        var out = voices
        for run in runs { for i in run.range { out[i] = run.voice } }
        return out
    }
}
