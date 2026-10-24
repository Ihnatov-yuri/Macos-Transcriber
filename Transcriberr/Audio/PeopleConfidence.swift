import Foundation

/// How sure Transcriberr can be of finding a saved person in a recording,
/// and what would make it surer. Shown on the person page.
///
/// Five things decide it, each scored 0…1: how much speech the voice was
/// learned from, from how many recordings (a voice heard on a call and in a
/// room sounds different), how alike its samples are (someone talking over
/// them spoils a print), how far it stands from the closest other saved
/// voice, the user's own included (two voices close together are left
/// unnamed, see PeopleMatch), and how clearly it has matched lately.
struct VoiceConfidence: Equatable {
    enum Level: String { case learning = "Learning", good = "Good", strong = "Strong" }
    enum Grade: Equatable { case weak, fair, good }

    struct Factor: Equatable, Identifiable {
        enum Kind: String { case speech, recordings, consistency, distinct, matches }
        let kind: Kind
        let title: String
        /// 0…1; nil when there is nothing to judge yet (no match so far).
        let value: Double?
        let detail: String
        var id: String { kind.rawValue }
        var grade: Grade? {
            guard let value else { return nil }
            return value < 0.4 ? .weak : value < 0.75 ? .fair : .good
        }
    }

    let score: Double
    let level: Level
    let factors: [Factor]
    /// What to do next, for the weakest factor; nil when all are good.
    let advice: String?
    /// The closest other saved voice when it is near enough to confuse.
    let soundsLike: String?
    /// Why the level is lower than the percentage alone would make it,
    /// in a sentence; nil when it is not held back.
    var heldBack: String? = nil

    var percent: Int { Int((score * 100).rounded()) }
}

enum PeopleConfidence {
    /// Speech that makes a full print: two minutes, spread over recordings.
    static let fullSeconds = 120.0
    static let fullSources = 3
    /// Matches the track record is read from, newest.
    static let recentMatches = 10

    static let weights: [VoiceConfidence.Factor.Kind: Double] = [
        .speech: 0.25, .recordings: 0.15, .consistency: 0.2, .distinct: 0.2, .matches: 0.2,
    ]

    /// `others` are the other saved voices (and the user's own print, as
    /// "you"), by name and centroid.
    /// `ownVoice` scores the user's print: it has no recordings or match
    /// history to judge, so those are left out instead of holding it down.
    /// `unmatched` names voices recordings never compare against this one
    /// (the user's own, for a saved person): close to them is shown, but
    /// does not leave anyone unnamed.
    static func assess(_ person: Person, others: [(name: String, centroid: [Float])],
                       ownVoice: Bool = false, unmatched: Set<String> = []) -> VoiceConfidence {
        var factors: [VoiceConfidence.Factor] = []

        let seconds = person.print.seconds
        factors.append(.init(
            kind: .speech, title: "Speech learned",
            value: clamp(seconds / fullSeconds),
            detail: "\(Int(seconds)) s of \(ownVoice ? "your" : "their") speech. About \(Int(fullSeconds / 60)) minutes is plenty."))

        let sources = person.sources
        factors.append(.init(
            kind: .recordings, title: "Recordings",
            value: clamp(Double(sources) / Double(fullSources)),
            detail: sources == 1
                ? "Learned from 1 recording or reading. Voices sound different on calls and in rooms; \(fullSources) is plenty."
                : "Learned from \(sources) recordings or readings."))

        let alike = Double(person.print.selfSimilarity)
        factors.append(.init(
            kind: .consistency, title: "Consistency",
            value: clamp((alike - Double(VoiceprintStore.minSelfSimilarity)) / 0.25),
            detail: String(format: "How alike its samples are: %.2f. A clean voice sits around 0.8.", alike)))

        // Told apart the way PeopleMatch tells them apart: their own clips
        // scored against each voice. Centroid against centroid read 0.54 for
        // two different people (Lana, Iryna, 2026-10-23) whose clips scored
        // 0.30-0.39 against the other and 0.71 against their own: averages
        // smooth voices together, so that measure raised false alarms.
        let own = person.print.embeddings
        let selfScore = Double(person.print.selfSimilarity)
        func cross(_ c: [Float]) -> Double {
            guard !own.isEmpty else { return Double(VoiceActivity.cosine(person.print.centroid, c)) }
            return Double(own.map { VoiceActivity.cosine($0, c) }.reduce(0, +)) / Double(own.count)
        }
        let nearest = others
            .map { (name: $0.name, similarity: cross($0.centroid)) }
            .max { $0.similarity < $1.similarity }
        let bar = Double(PeopleMatch.onThreshold)
        let margin = Double(PeopleMatch.margin)
        /// How far their clips stand above the closest other voice.
        let gap = nearest.map { selfScore - $0.similarity } ?? 1
        if let nearest {
            factors.append(.init(
                kind: .distinct, title: "Stands apart",
                value: clamp((gap - margin) / 0.25),
                detail: String(format: "Their samples score %.2f against their own voice and %.2f against %@'s, the closest saved voice. A gap over %.2f tells them apart.",
                               selfScore, nearest.similarity, nearest.name, margin)))
        } else {
            factors.append(.init(kind: .distinct, title: "Stands apart", value: 1,
                                 detail: "No other saved voice to mix them up with."))
        }

        let recent = (person.matches ?? []).suffix(recentMatches).map { Double($0.score) }
        if recent.isEmpty {
            factors.append(.init(kind: .matches, title: "Recent matches", value: nil,
                                 detail: "No match logged yet: matches are logged from 5.0 on. Find people on the People overview logs them for older recordings."))
        } else {
            let median = Double(ClusterVoice.median(recent.map(Float.init)))
            factors.append(.init(
                kind: .matches, title: "Recent matches",
                value: clamp((median - bar) / 0.2),
                detail: String(format: "Median %.2f over the last %d %@. %.2f is the bar.",
                               median, recent.count, recent.count == 1 ? "match" : "matches", bar)))
        }

        if ownVoice { factors.removeAll { $0.kind == .recordings || $0.kind == .matches } }
        let judged = factors.filter { $0.value != nil }
        let total = judged.map { weights[$0.kind] ?? 0 }.reduce(0, +)
        let score = total > 0
            ? judged.map { ($0.value ?? 0) * (weights[$0.kind] ?? 0) }.reduce(0, +) / total
            : 0
        // Close enough that a speaker of theirs would often fall inside the
        // matcher's margin, or score as high against the other voice.
        let confusable = nearest.flatMap {
            (gap < margin * 1.5 || $0.similarity >= bar) && !unmatched.contains($0.name) ? $0.name : nil
        }
        var level: VoiceConfidence.Level = score < 0.45 ? .learning : score < 0.75 ? .good : .strong
        var heldBack: String?
        // A clean but short print scores well on everything it can be
        // judged on; too little evidence is still too little.
        if (factors.first { $0.kind == .speech }?.value ?? 0) < 0.4, level != .learning {
            level = .learning
            heldBack = "Kept at Learning until more of their speech is learned."
        }
        if !ownVoice, recent.isEmpty, sources < 2, level == .strong {
            level = .good
            heldBack = "Kept at Good until they are recognised in a new recording or learned from a second one."
        }
        // Two voices that close are left unnamed whatever else is true.
        if let confusable {
            level = .learning
            heldBack = "Kept at Learning while they sound close to \(confusable): recordings leave such a speaker unnamed rather than guess."
        }

        let weakest = judged.filter { $0.grade != .good }.min { ($0.value ?? 0) < ($1.value ?? 0) }
        return VoiceConfidence(score: score, level: level, factors: factors,
                               advice: weakest.map { advice(for: $0.kind, soundsLike: nearest?.name) },
                               soundsLike: confusable, heldBack: heldBack)
    }

    static func advice(for kind: VoiceConfidence.Factor.Kind, soundsLike: String?) -> String {
        switch kind {
        case .speech: return "Train more: record them reading, or learn from a recording they are named in."
        case .recordings: return "Learn from another recording, ideally one on a different microphone or a call."
        case .consistency: return "Some samples may have someone else in them. A clean reading at this Mac adds a clear one."
        case .distinct: return "They sound close to \(soundsLike ?? "another saved voice"). Train both from more recordings, ideally on different microphones, so they are told apart."
        case .matches: return "Their matches are close to the bar. Confirm the suggested recordings to sharpen the voice."
        }
    }

    private static func clamp(_ x: Double) -> Double { min(1, max(0, x)) }
}
