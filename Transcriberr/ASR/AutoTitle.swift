import Foundation

/// Generated recording titles. The first version read only the first 20
/// lines — the greetings — so a meeting came out as "Happy Friday Work
/// Updates" or "Meeting Kickoff And Alignment Discussion", and an hour of
/// coaching was named after the radiator covers mentioned in minute one.
/// The model now reads slices from across the whole recording and is told
/// to name the subject, not the fact that people met.
enum AutoTitle {

    /// One read: 3k tokens is what LiteRT Gemma handles stably (see
    /// MeetingBriefBuilder.inputTokenBudget).
    static let tokenBudget = 2_500
    static let maxOutputTokens = 32
    /// Slices taken across the timeline of a longer recording.
    static let sliceCount = 6
    /// The opening of a long recording is mostly hellos and "can you hear
    /// me"; it is skipped once there is enough after it.
    static let openingSkipSeconds: Double = 90

    static let systemPrompt = """
    You name recordings of meetings and conversations. Read the excerpts and output ONLY a title of 3 to 7 words in title case. Rules:
    - Name the main subject: the project, product, company, decision or problem the conversation is about. Keep proper names exactly as written.
    - Ignore greetings, small talk, weather, weekend plans and audio checks.
    - Never use the words Meeting, Discussion, Call, Conversation, Kickoff, Sync, Update or Updates unless they are part of a name.
    - No quotes, no period, no "Title:" prefix, nothing else.
    """

    static func userMessage(excerpts: String) -> String {
        "Excerpts from start to end of the recording:\n\n" + excerpts
    }

    /// Text to title from, or nil when there is too little to go on.
    static func sample(_ segments: [(start: Double, text: String)], tokenBudget: Int = tokenBudget) -> String? {
        var lines = segments
            .sorted { $0.start < $1.start }
            .map { (start: $0.start, text: $0.text.trimmingCharacters(in: .whitespacesAndNewlines)) }
            .filter { !$0.text.isEmpty }
        let all = lines.map(\.text).joined(separator: " ")
        guard all.count > 30 else { return nil }
        if MeetingBriefBuilder.estimatedTokens(all) <= tokenBudget { return all }

        let afterOpening = lines.filter { $0.start >= openingSkipSeconds }
        if MeetingBriefBuilder.estimatedTokens(afterOpening.map(\.text).joined(separator: " ")) > tokenBudget {
            lines = afterOpening
        }
        // Evenly spaced runs of consecutive lines, each filled to its share
        // of the budget, so the middle and end count as much as the start.
        let share = tokenBudget / sliceCount
        var slices: [String] = []
        for i in 0..<sliceCount {
            var j = lines.count * i / sliceCount
            var slice = "", tokens = 0
            while j < lines.count {
                let t = MeetingBriefBuilder.estimatedTokens(lines[j].text)
                if tokens + t > share {
                    if slice.isEmpty { slice = String(lines[j].text.prefix(share * 2)) }
                    break
                }
                slice += (slice.isEmpty ? "" : " ") + lines[j].text
                tokens += t
                j += 1
            }
            if !slice.isEmpty { slices.append(slice) }
        }
        return slices.joined(separator: "\n…\n")
    }

    /// The model's answer as a title, or nil when it isn't usable.
    static func clean(_ raw: String) -> String? {
        guard var t = raw
            .split(whereSeparator: \.isNewline)
            .map({ $0.trimmingCharacters(in: .whitespaces) })
            .first(where: { !$0.isEmpty })
        else { return nil }
        t = t.replacingOccurrences(of: #"^(?i)\**\s*title\s*:\s*\**\s*"#, with: "", options: .regularExpression)
        t = t.trimmingCharacters(in: CharacterSet(charactersIn: "\"'.“”‘’*#`_ ").union(.whitespaces))
        guard t.count >= 3, t.count < 90 else { return nil }
        return t
    }
}
