import Foundation

/// A speaking goal on the You page: one measured number, a target, and a
/// text model's words on why and how. The model picks which goals to set
/// and writes their wording; the target is computed here from the user's
/// own numbers, and only `GoalJudge` decides whether it was met.
struct SpeechGoal: Codable, Equatable, Identifiable {
    enum Status: String, Codable { case active, achieved, retired }

    var id: UUID
    var metric: SpeechMetric
    /// "en", "uk", or nil for every meeting.
    var language: String?
    var lowerIsBetter: Bool
    var target: Double
    /// The average when the goal was set or last revised.
    var baseline: Double
    var title: String
    var why: String
    var tips: [String]
    var created: Date
    /// When the goal was set or last rethought; it is judged from here.
    var revised: Date
    var revisions: Int = 0
    var status: Status = .active
    var closed: Date?

    func meets(_ v: Double) -> Bool { lowerIsBetter ? v <= target : v >= target }

    var targetText: String {
        "\(lowerIsBetter ? "at most" : "at least") \(metric.format(target)) \(metric.unit)"
    }
}

/// Whether a goal is met, decided from measured meetings only.
enum GoalJudge {
    /// Met in this many of the last `window` measured meetings.
    static let hitsNeeded = 3
    static let window = 4
    /// Not met after this many measured meetings, or this many days, the
    /// goal is rethought.
    static let staleMeetings = 6
    static let staleDays = 21.0

    struct Verdict: Equatable {
        /// Newest first, since the goal was last revised.
        var values: [Double]
        var hits: Int
        var achieved: Bool
        var stale: Bool
        var latest: Double? { values.first }
    }

    static func judge(_ goal: SpeechGoal, meetings: [MeetingSpeech], now: Date = Date()) -> Verdict {
        let values = meetings
            .filter { $0.date > goal.revised && (goal.language == nil || $0.language == goal.language) }
            .sorted { $0.date > $1.date }
            .compactMap { $0.value(goal.metric) }
        let recent = values.prefix(window)
        let hits = recent.filter(goal.meets).count
        let achieved = values.count >= hitsNeeded && hits >= hitsNeeded
        let days = now.timeIntervalSince(goal.revised) / 86_400
        let stale = !achieved && (values.count >= staleMeetings || (days >= staleDays && !values.isEmpty))
        return Verdict(values: values, hits: hits, achieved: achieved, stale: stale)
    }
}

/// Where a metric should be, and the next step towards it.
enum SpeechTargets {
    static func paceBand(_ language: String?) -> ClosedRange<Double> {
        language == "uk" ? 110...160 : 120...165
    }

    /// The healthy value, and which side of it is better; nil when the
    /// average is already fine.
    static func ideal(_ m: SpeechMetric, average: Double,
                      language: String?) -> (value: Double, lowerIsBetter: Bool)? {
        switch m {
        case .talkShare:
            // Against a fair share, so 1:1s and groups count alike.
            if average > 130 { return (110, true) }
            if average < 50 { return (80, false) }
            return nil
        case .pace:
            let band = paceBand(language)
            if average > band.upperBound { return (band.upperBound - 5, true) }
            if average < band.lowerBound { return (band.lowerBound + 5, false) }
            return nil
        case .longestTurn: return average > 90 ? (90, true) : nil
        case .interruptions: return average > 1 ? (1, true) : nil
        case .questions: return average < 1.5 ? (1.5, false) : nil
        case .fillers: return average > 2 ? (2, true) : nil
        case .hedges: return average > 2 ? (2, true) : nil
        }
    }

    /// Half the way to the ideal, but one step of at least 10% (of today's
    /// value or of the ideal, whichever is larger: from zero questions 10%
    /// of zero is no step) and at most three such steps. Never past the ideal.
    static func nextTarget(average: Double, ideal: Double, lowerIsBetter: Bool) -> Double {
        let step = max(abs(average), abs(ideal)) * 0.1
        let half = average + (ideal - average) / 2
        if lowerIsBetter {
            return max(ideal, min(average - step, max(average - 3 * step, half)))
        }
        return min(ideal, max(average + step, min(average + 3 * step, half)))
    }

    struct Gap: Equatable {
        var metric: SpeechMetric
        var language: String?
        var average: Double
        var ideal: Double
        var lowerIsBetter: Bool
        var target: Double
        /// How far off, relative to the ideal: what ranks the gaps.
        var size: Double
    }

    /// Meetings a gap is read from, newest: targets follow how the user
    /// speaks now, not a month-long average a reached goal would undercut.
    static let recentMeetings = 10

    /// Every metric that is off, in each language with enough meetings
    /// (and over all meetings for the language-free ones), worst first.
    static func gaps(_ all: [MeetingSpeech]) -> [Gap] {
        let meetings = Array(all.sorted { $0.date > $1.date }.prefix(recentMeetings))
        guard !meetings.isEmpty else { return [] }
        let languages = Set(meetings.compactMap(\.language)).filter { l in meetings.filter { $0.language == l }.count >= 3 }
        var out: [Gap] = []
        for m in SpeechMetric.allCases {
            // Pace and the word lists differ by language; the rest do not.
            let scopes: [String?] = [.pace, .fillers, .hedges].contains(m) ? languages.sorted().map { $0 } : [nil]
            for lang in scopes {
                guard let avg = SpeechMeasure.average(m, over: meetings, language: lang),
                      let ideal = ideal(m, average: avg, language: lang) else { continue }
                let size = abs(avg - ideal.value) / max(1, abs(ideal.value))
                out.append(Gap(metric: m, language: lang, average: avg, ideal: ideal.value,
                               lowerIsBetter: ideal.lowerIsBetter,
                               target: nextTarget(average: avg, ideal: ideal.value, lowerIsBetter: ideal.lowerIsBetter),
                               size: size))
            }
        }
        return out.sorted { $0.size > $1.size }
    }
}

/// What the text model is asked, and how its answer is read. It may only
/// pick among the measured gaps; anything else it writes is dropped.
enum SpeechCoach {
    static let maxActive = 2
    /// Goals are set from this many measured meetings on.
    static let minMeetings = 3
    /// A goal reached or replaced is not proposed again for this long.
    static let restDays = 21.0
    static let maxOutputTokens = 500

    static let systemPrompt = """
    You coach someone on how they speak in meetings. You get measured numbers about their speech, the gaps worth working on (each with a code), and some of their own lines. Answer in EXACTLY this format, nothing else:
    GOAL: <gap code> | <short goal title, under 8 words> | <why it matters for them, one sentence>
    TIP: <gap code> | <one concrete thing to try in the next meeting; may quote one of their lines>
    NOTE: <one observation about how clearly or how well-structured they speak, quoting a short line of theirs>
    Rules:
    - Use only gap codes from the list. At most the number of goals asked for, and 2 TIP lines per goal.
    - At most 2 NOTE lines. Write in English. Be specific and kind. Never invent numbers.
    """

    static func code(_ g: SpeechTargets.Gap) -> String { g.metric.rawValue + (g.language.map { "-\($0)" } ?? "") }

    static func userMessage(gaps: [SpeechTargets.Gap], want: Int, achieved: [SpeechGoal],
                            retired: [SpeechGoal], lines: [String]) -> String {
        var out = ["Goals asked for: \(want)", "", "GAPS (code: measured average → next target):"]
        for g in gaps {
            let lang = g.language.map { " in \($0 == "uk" ? "Ukrainian" : "English")" } ?? ""
            out.append("\(code(g)): \(g.metric.title)\(lang) \(g.metric.format(g.average)) \(g.metric.unit) → \(g.lowerIsBetter ? "at most" : "at least") \(g.metric.format(g.target)). \(g.metric.explanation)")
        }
        if !achieved.isEmpty {
            out.append("")
            out.append("Already achieved: " + achieved.prefix(5).map(\.title).joined(separator: "; "))
        }
        if !retired.isEmpty {
            out.append("Tried without success, suggest a different angle: " + retired.prefix(5).map(\.title).joined(separator: "; "))
        }
        out.append("")
        out.append("THEIR LINES:")
        out += lines
        return out.joined(separator: "\n")
    }

    struct Reply: Equatable {
        var goals: [(code: String, title: String, why: String)]
        var tips: [String: [String]]
        var notes: [String]
        static func == (a: Reply, b: Reply) -> Bool {
            a.goals.map { "\($0.code)|\($0.title)|\($0.why)" } == b.goals.map { "\($0.code)|\($0.title)|\($0.why)" }
                && a.tips == b.tips && a.notes == b.notes
        }
    }

    static func parse(_ raw: String, codes: Set<String>) -> Reply {
        var reply = Reply(goals: [], tips: [:], notes: [])
        for rawLine in raw.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "-*• "))
            guard let colon = line.firstIndex(of: ":") else { continue }
            let tag = line[..<colon].trimmingCharacters(in: .whitespaces).uppercased()
            let parts = line[line.index(after: colon)...].split(separator: "|", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            switch tag {
            case "GOAL" where parts.count >= 3 && codes.contains(parts[0]) && !parts[1].isEmpty:
                guard !reply.goals.contains(where: { $0.code == parts[0] }) else { continue }
                reply.goals.append((parts[0], parts[1], parts[2...].joined(separator: " | ")))
            case "TIP" where parts.count >= 2 && codes.contains(parts[0]) && !parts[1].isEmpty:
                let tip = parts[1...].joined(separator: " | ")
                if (reply.tips[parts[0]]?.count ?? 0) < 2, !(reply.tips[parts[0]] ?? []).contains(tip) {
                    reply.tips[parts[0], default: []].append(tip)
                }
            case "NOTE" where !parts.isEmpty && !parts[0].isEmpty:
                // The model sometimes leads with a gap code, as on GOAL lines.
                let body = parts.count > 1 && codes.contains(parts[0]) ? Array(parts.dropFirst()) : parts
                let note = body.joined(separator: " | ")
                if reply.notes.count < 2, !reply.notes.contains(note) { reply.notes.append(note) }
            default:
                continue
            }
        }
        return reply
    }

    /// Plain wording for when the model is unavailable or answers nothing
    /// usable: the goals still come from the same gaps.
    static func fallbackTitle(_ g: SpeechTargets.Gap) -> (title: String, why: String, tip: String) {
        switch g.metric {
        case .talkShare where g.lowerIsBetter:
            return ("Leave more room for others", "You speak more than your share of most meetings.",
                    "After making a point, ask someone else what they think.")
        case .talkShare:
            return ("Speak up more often", "You speak well under your share of most meetings.",
                    "Say one thing early in the meeting, even a short one.")
        case .pace where g.lowerIsBetter:
            return ("Slow down a little", "Fast speech is harder to follow, more so on calls.",
                    "Pause for a breath after each sentence that matters.")
        case .pace:
            return ("Pick up the pace a little", "Slow speech can lose people's attention.",
                    "Prepare your first sentence so you start crisply.")
        case .longestTurn:
            return ("Shorter turns", "Long monologues make others wait to come in.",
                    "Stop after your main point and check if it landed.")
        case .interruptions:
            return ("Let people finish", "Starting while someone talks cuts their point short.",
                    "Count one beat after they stop before you start.")
        case .questions:
            return ("Ask more questions", "Questions bring others in and test your assumptions.",
                    "Turn one statement per meeting into a question.")
        case .fillers:
            return ("Fewer fillers", "Fillers make points sound less certain than they are.",
                    "Replace the filler with a short silent pause.")
        case .hedges:
            return ("State things plainly", "Hedging makes clear views sound unsure.",
                    "Drop one \"I think\" or \"maybe\" when you are sure.")
        }
    }

    /// New goals for the worst gaps not already worked on.
    static func goals(from gaps: [SpeechTargets.Gap], reply: Reply?, want: Int,
                      taken: Set<String>, now: Date) -> [SpeechGoal] {
        let open = gaps.filter { !taken.contains(code($0)) }
        // The model's picks first, in its order, then the worst gaps.
        let picked = (reply?.goals.compactMap { g in open.first { code($0) == g.code } } ?? [])
            + open
        var seen = Set<String>(), out: [SpeechGoal] = []
        for g in picked where seen.insert(code(g)).inserted && out.count < want {
            let fallback = fallbackTitle(g)
            let words = reply?.goals.first { $0.code == code(g) }
            let tips = reply?.tips[code(g)] ?? []
            out.append(SpeechGoal(
                id: UUID(), metric: g.metric, language: g.language, lowerIsBetter: g.lowerIsBetter,
                target: g.target, baseline: g.average,
                title: words?.title ?? fallback.title, why: words?.why ?? fallback.why,
                tips: tips.isEmpty ? [fallback.tip] : tips, created: now, revised: now))
        }
        return out
    }
}

/// Goals, past and present, and the model's notes, in
/// ~/Library/Application Support/Transcriberr/coach.json.
struct CoachStore {
    let url: URL

    static var shared: CoachStore {
        let path = ProcessInfo.processInfo.environment["TRANSCRIBERR_COACH"]
        return CoachStore(url: path.map { URL(fileURLWithPath: $0) }
            ?? VoiceprintStore.directory.deletingLastPathComponent().appendingPathComponent("coach.json"))
    }

    struct State: Codable, Equatable {
        var version = 1
        var goals: [SpeechGoal] = []
        var notes: [String] = []
        var refreshed: Date?
        var active: [SpeechGoal] { goals.filter { $0.status == .active } }
    }

    func load() -> State {
        guard let data = try? Data(contentsOf: url),
              let s = try? JSONDecoder().decode(State.self, from: data), s.version == 1 else { return State() }
        return s
    }

    func save(_ state: State) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(state).write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    func reset() { try? FileManager.default.removeItem(at: url) }
}
