import Foundation
import Observation

/// Someone's measured meetings, newest first, from the library.
nonisolated enum SpeechHistory {
    /// Fewer words than this between everyone, and it is not a meeting: a
    /// microphone test, a stray few seconds. Counted, they dragged every
    /// "lately" down (four 7-18 s tests on 27 Oct).
    static let minimumMeetingWords = 80

    /// `meetings` when the caller already has them; `micIsThem` counts the
    /// split-track microphone lines as `name` (the user's own page).
    static func load(_ name: String, repository: RecordingRepository, meetings: [PersonMeeting]? = nil,
                     micIsThem: Bool = false)
        -> (meetings: [MeetingSpeech], lines: [String]) {
        var out: [MeetingSpeech] = []
        var lines: [String] = []
        let list = meetings ?? (micIsThem ? PersonMeetings.loadMine(name, repository: repository)
                                          : PersonMeetings.load(name, repository: repository))
        // Every meeting: measuring is text work over the lines (75 meetings,
        // about 15,000 lines, a fraction of a second). Each language and
        // each goal needs its own latest meetings, and a cap of the newest
        // 30 hid Ukrainian (one of six meetings in it).
        for m in list {
            guard let rec = try? repository.get(id: m.id), !rec.isDeleted else { continue }
            let all = rec.segments.compactMap { s -> SpeechLine? in
                let who = micIsThem && s.speaker == TranscriptionRunner.micSpeakerKey
                    ? name : s.speakerName.flatMap { $0.isEmpty ? nil : $0 } ?? s.speaker
                guard let who else { return nil }
                return SpeechLine(start: s.startSeconds, end: s.endSeconds, speaker: who, text: s.text)
            }
            if let measured = SpeechMeasure.measure(all, name: name, recordingId: m.id, title: m.title, date: m.date),
               measured.meetingWords >= minimumMeetingWords {
                out.append(measured)
            }
            // Their own longer lines from the five newest meetings, for the coach.
            if out.count <= 5 {
                lines += all.filter { $0.speaker.caseInsensitiveCompare(name) == .orderedSame }
                    .map(\.text).filter { SpeechLexicon.words($0).count >= 6 }.prefix(12)
            }
        }
        return (out, Array(lines.prefix(60)))
    }
}

/// Keeps the user's goals current: judges each against the measured
/// meetings, closes the achieved ones, rethinks the stale ones (twice, then
/// replaces them), and fills up to two with the text model's help.
@MainActor
@Observable
final class SpeechCoachRunner {
    static let shared = SpeechCoachRunner()

    private(set) var isRunning = false
    private(set) var lastError: String?
    private(set) var revision = 0
    @ObservationIgnored private var task: Task<Void, Never>?

    /// Whether a refresh would change anything: no goals yet while there
    /// are gaps, or a goal that is now achieved or stale.
    static func needsRefresh(_ state: CoachStore.State, meetings: [MeetingSpeech]) -> Bool {
        let active = state.active
        guard meetings.count >= SpeechCoach.minMeetings else { return false }
        if active.count < SpeechCoach.maxActive, !SpeechTargets.gaps(meetings).isEmpty {
            // Not more than once a day for an unfillable slot.
            if let r = state.refreshed, Date().timeIntervalSince(r) < 86_400, !active.isEmpty { return false }
            return true
        }
        return active.contains { let v = GoalJudge.judge($0, meetings: meetings); return v.achieved || v.stale }
    }

    func refresh(meetings: [MeetingSpeech], lines: [String], container: AppContainer) {
        guard !isRunning, meetings.count >= SpeechCoach.minMeetings else { return }
        isRunning = true
        lastError = nil
        task = Task { @MainActor in
            defer { isRunning = false; task = nil }
            let store = CoachStore.shared
            var state = store.load()
            let now = Date()
            var revise: [Int] = []
            for i in state.goals.indices where state.goals[i].status == .active {
                let v = GoalJudge.judge(state.goals[i], meetings: meetings, now: now)
                if v.achieved {
                    state.goals[i].status = .achieved
                    state.goals[i].closed = now
                } else if v.stale {
                    if state.goals[i].revisions >= 2 {
                        state.goals[i].status = .retired
                        state.goals[i].closed = now
                    } else {
                        revise.append(i)
                    }
                }
            }
            // A goal just reached or replaced rests a while before it can
            // come back, so "replaced" does not mean "set again at once".
            let resting = Set(state.goals.filter {
                $0.status != .active && now.timeIntervalSince($0.closed ?? .distantPast) < SpeechCoach.restDays * 86_400
            }.map { Self.code($0) })
            let reviseCodesEarly = Set(revise.map { Self.code(state.goals[$0]) })
            let gaps = SpeechTargets.gaps(meetings).filter {
                !resting.contains(SpeechCoach.code($0)) || reviseCodesEarly.contains(SpeechCoach.code($0))
            }
            let activeCodes = Set(state.active.map { Self.code($0) })
            let want = max(0, SpeechCoach.maxActive - state.active.count)
            let reviseCodes = Set(revise.map { Self.code(state.goals[$0]) })
            let offered = gaps.filter { !activeCodes.contains(SpeechCoach.code($0)) || reviseCodes.contains(SpeechCoach.code($0)) }

            var reply: SpeechCoach.Reply?
            if (want > 0 || !revise.isEmpty), !offered.isEmpty {
                let user = SpeechCoach.userMessage(
                    gaps: offered, want: want + revise.count,
                    achieved: state.goals.filter { $0.status == .achieved }.reversed(),
                    retired: state.goals.filter { $0.status == .retired }.reversed() + revise.map { state.goals[$0] },
                    lines: lines)
                let backend = container.backendFactory.backend(for: PersonBriefRunner.engine(container))
                do {
                    if !(await backend.isReady) {
                        try await PersonBriefBuilder.bounded(seconds: 180) { try await backend.load(modelPath: nil) }
                    }
                    let raw = try await PersonBriefBuilder.bounded(seconds: 120) {
                        try await backend.generateText(systemInstruction: SpeechCoach.systemPrompt,
                                                       userMessage: user, maxTokens: SpeechCoach.maxOutputTokens)
                    }
                    reply = SpeechCoach.parse(raw, codes: Set(offered.map(SpeechCoach.code)))
                } catch is CancellationError {
                    return
                } catch {
                    // The goals still come from the same gaps, in plain words.
                    lastError = "The text engine could not write the coaching (\(error.localizedDescription)). Goals use plain wording."
                    if case ASRError.chunkTimeout = error, let litert = backend as? GemmaLiteRTBackend {
                        try? await litert.recoverWedge(modelPath: nil)
                    }
                }
            }
            if Task.isCancelled { return }
            // Started over meanwhile: the reset wins.
            if store.load().goals.isEmpty, !state.goals.filter({ $0.created < now }).isEmpty { return }

            // Rethink: a new target from today's numbers and a new angle.
            for i in revise {
                let code = Self.code(state.goals[i])
                guard let gap = gaps.first(where: { SpeechCoach.code($0) == code }) else {
                    // It no longer stands out, but it was never met as the
                    // rule says: retired, not reached.
                    state.goals[i].status = .retired
                    state.goals[i].closed = now
                    continue
                }
                state.goals[i].baseline = gap.average
                state.goals[i].target = gap.target
                state.goals[i].revised = now
                state.goals[i].revisions += 1
                state.goals[i].tips = reply?.tips[code].flatMap { $0.isEmpty ? nil : $0 }
                    ?? [SpeechCoach.fallbackTitle(gap).tip]
            }
            let taken = Set(state.active.map { Self.code($0) }).union(resting)
            state.goals += SpeechCoach.goals(from: gaps, reply: reply, want: max(0, SpeechCoach.maxActive - state.active.count),
                                             taken: taken, now: now)
            if let notes = reply?.notes, !notes.isEmpty { state.notes = notes }
            state.refreshed = now
            do { try store.save(state) } catch { lastError = error.localizedDescription }
            revision &+= 1
        }
    }

    func cancel() { task?.cancel() }

    static func code(_ g: SpeechGoal) -> String { g.metric.rawValue + (g.language.map { "-\($0)" } ?? "") }
}
