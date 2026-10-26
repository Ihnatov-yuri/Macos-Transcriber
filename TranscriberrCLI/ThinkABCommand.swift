import Foundation
import SwiftData

/// Gemma thinking A/B on the judgement tasks: auto-titles, person briefs and
/// the speech coach's wording, on real library data. Read-only: it opens a
/// copy of the store (pass `TRANSCRIBERR_STORE`) without saving, never
/// writes the brief cache or coach.json. Run once with and once without
/// `TRANSCRIBERR_GEMMA_THINKING` and compare the two JSON files.
///
///   transcriberrcli thinkab <out.json> [titles] [people] [lines]
@MainActor
func cmdThinkAB(out: String, titleCount: Int, peopleCount: Int, maxLines: Int) async -> Int32 {
    let factory = BackendFactory(gemma: GemmaSettingsStore(), prompts: PromptStore(), apiKeys: APIKeyStore())
    let backend = factory.backend(for: .gemmaLiteRT)
    do {
        try await backend.load(modelPath: nil)
        let warm = try await backend.generateText(systemInstruction: "You answer in one word.", userMessage: "Say OK.", maxTokens: 8)
        print("[thinkab] Gemma ready: \(warm)")
    } catch {
        print("[thinkab] ❌ Gemma: \(error)"); return 1
    }
    let storeURL = KBService.defaultStoreURL()
    let schema = Schema(TranscriberrSchema.models)
    let container: ModelContainer
    do {
        container = try ModelContainer(for: schema, configurations:
            ModelConfiguration("Transcriberr", schema: schema, url: storeURL, allowsSave: false))
    } catch {
        print("[thinkab] ❌ store: \(error)"); return 1
    }
    let repo = RecordingRepository(context: ModelContext(container))
    func generate(_ system: String, _ user: String, _ maxTokens: Int) async throws -> (String, Double) {
        let t0 = Date()
        let raw = try await backend.generateText(systemInstruction: system, userMessage: user, maxTokens: maxTokens)
        return (raw, Date().timeIntervalSince(t0))
    }
    let app = UserDefaults(suiteName: "nl.ihnatov.Transcriberr")
    let me = TranscriptionRunner.meName(app?.string(forKey: "ui.myName"))
    let recordings = ((try? repo.all()) ?? []).filter { !$0.isDeleted && $0.segments.count >= 20 }
    var result: [String: Any] = ["thinking": GemmaLiteRTBackend.thinkingBudget.map { "\($0)" } ?? "off"]
    // Written after every task: a native call that never returns (thinking
    // past LiteRT's 10-minute session limit) must not lose what came before.
    func save() {
        guard let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]) else { return }
        try? data.write(to: URL(fileURLWithPath: NSString(string: out).expandingTildeInPath))
    }
    let skip = Set((ProcessInfo.processInfo.environment["TRANSCRIBERR_THINKAB_SKIP"] ?? "")
        .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })

    // Auto-titles: the newest recordings, exactly as the app samples them.
    var titles: [[String: Any]] = []
    for rec in recordings.prefix(titleCount) {
        let segs = rec.segments.sorted { $0.startSeconds < $1.startSeconds }
        guard let sample = AutoTitle.sample(segs.map { (start: $0.startSeconds, text: $0.text) }) else { continue }
        do {
            let (raw, s) = try await generate(AutoTitle.systemPrompt, AutoTitle.userMessage(excerpts: sample), AutoTitle.maxOutputTokens)
            titles.append(["id": rec.id.uuidString, "current": rec.title, "raw": raw,
                           "title": AutoTitle.clean(raw) ?? "", "seconds": s])
            print("[thinkab] title \(titles.count): \(AutoTitle.clean(raw) ?? "∅")  (\(String(format: "%.1f", s))s)")
        } catch { print("[thinkab] title failed: \(error)") }
    }
    result["titles"] = titles
    save()

    // Person briefs: the people in the most recordings, on their newest one.
    func who(_ s: Segment) -> String? { s.speakerName.flatMap { $0.isEmpty ? nil : $0 } }
    var counts: [String: Int] = [:]
    for rec in recordings {
        for name in Set(rec.segments.compactMap(who)) where name.caseInsensitiveCompare(me) != .orderedSame
            && !name.hasPrefix("Speaker") && name != "Me" { counts[name, default: 0] += 1 }
    }
    // TRANSCRIBERR_THINKAB_PEOPLE=a,b names them; otherwise the most frequent
    // (ties sort by name so two runs pick the same people).
    let named = (ProcessInfo.processInfo.environment["TRANSCRIBERR_THINKAB_PEOPLE"] ?? "")
        .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
    let people = !named.isEmpty ? named : counts.sorted { ($0.value, $1.key) > ($1.value, $0.key) }
        .prefix(peopleCount).map(\.key)
    var briefs: [[String: Any]] = []
    for name in people where !skip.contains(name) {
        guard let rec = recordings.first(where: { $0.segments.contains { who($0) == name } }) else { continue }
        let lines = rec.segments.sorted { $0.startSeconds < $1.startSeconds }.compactMap { s -> PersonBriefBuilder.Line? in
            guard let sp = who(s) ?? s.speaker else { return nil }
            return .init(start: s.startSeconds, speaker: sp, text: s.text)
        }
        let transcript = PersonBriefBuilder.transcript(lines, name: name)
        var raws: [String] = []
        var seconds = 0.0
        do {
            let built = try await PersonBriefBuilder.build(
                transcript: transcript, name: name,
                lineStarts: lines.filter { $0.speaker == name }.map(\.start)
            ) { system, user, maxTokens in
                let (raw, s) = try await generate(system, user, maxTokens)
                raws.append(raw); seconds += s
                return raw
            }
            let b = built.brief
            briefs.append(["name": name, "recording": rec.title, "raw": raws, "seconds": seconds,
                           "gist": b.gist ?? [], "commitments": b.commitments.map(\.text),
                           "questions": b.questions.map(\.text),
                           "topics": b.topics.map { ($0.topic.map { "\($0): " } ?? "") + $0.text }])
            result["briefs"] = briefs
            save()
            print("[thinkab] brief \(name) on \"\(rec.title)\" (\(String(format: "%.0f", seconds))s)")
        } catch { print("[thinkab] brief \(name) failed: \(error)") }
    }
    result["briefs"] = briefs

    // Speech coach: the user's own measured meetings, as the You page reads them.
    var measured: [MeetingSpeech] = []
    var ownLines: [String] = []
    let mine = recordings.filter { r in r.segments.contains {
        $0.speaker == TranscriptionRunner.micSpeakerKey || who($0)?.caseInsensitiveCompare(me) == .orderedSame } }
    for rec in mine.prefix(30) {
        let all = rec.segments.sorted { $0.startSeconds < $1.startSeconds }.compactMap { s -> SpeechLine? in
            let sp = s.speaker == TranscriptionRunner.micSpeakerKey ? me : who(s) ?? s.speaker
            guard let sp else { return nil }
            return SpeechLine(start: s.startSeconds, end: s.endSeconds, speaker: sp, text: s.text)
        }
        let date = Date(timeIntervalSince1970: Double(rec.createdAtMillis) / 1000)
        if let m = SpeechMeasure.measure(all, name: me, recordingId: rec.id, title: rec.title, date: date) {
            measured.append(m)
        }
        if measured.count <= 5 {
            ownLines += all.filter { $0.speaker.caseInsensitiveCompare(me) == .orderedSame }
                .map(\.text).filter { SpeechLexicon.words($0).count >= 6 }.prefix(12)
        }
    }
    let gaps = SpeechTargets.gaps(measured)
    let state = CoachStore.shared.load()
    if gaps.isEmpty {
        print("[thinkab] coach: no gaps over \(measured.count) meetings")
    } else {
        let user = SpeechCoach.userMessage(
            gaps: gaps, want: SpeechCoach.maxActive,
            achieved: state.goals.filter { $0.status == .achieved }.reversed(),
            retired: state.goals.filter { $0.status == .retired }.reversed(),
            lines: Array(ownLines.prefix(maxLines)))
        do {
            let (raw, s) = try await generate(SpeechCoach.systemPrompt, user, SpeechCoach.maxOutputTokens)
            let reply = SpeechCoach.parse(raw, codes: Set(gaps.map(SpeechCoach.code)))
            result["coach"] = ["prompt": user, "raw": raw, "seconds": s,
                               "goals": reply.goals.map { "\($0.code) | \($0.title) | \($0.why)" },
                               "tips": reply.tips.sorted { $0.key < $1.key }.flatMap { k, v in v.map { "\(k) | \($0)" } },
                               "notes": reply.notes]
            print("[thinkab] coach: \(reply.goals.count) goals (\(String(format: "%.1f", s))s)")
        } catch { print("[thinkab] coach failed: \(error)") }
    }

    do {
        let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: URL(fileURLWithPath: NSString(string: out).expandingTildeInPath))
        print("[thinkab] ✓ \(out)")
        return 0
    } catch {
        print("[thinkab] ❌ write: \(error)"); return 1
    }
}
