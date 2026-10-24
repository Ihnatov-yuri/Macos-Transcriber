import SwiftUI

/// The user's own page: how they speak, measured; up to two goals that
/// close when met and are rethought when they stall; and their voice print,
/// with the same confidence and training as anyone saved.
struct YouDashboard: View {
    let others: [(name: String, centroid: [Float])]
    var open: (Recording, Double) -> Void
    @Environment(AppContainer.self) private var container
    private var coach: SpeechCoachRunner { SpeechCoachRunner.shared }

    @State private var meetings: [MeetingSpeech] = []
    @State private var lines: [String] = []
    @State private var state = CoachStore.State()
    @State private var language: String?
    @State private var voice = VoiceprintStore.load()
    @State private var addingReading = false
    @State private var confirmReset = false
    @State private var loaded = false

    private var me: String { TranscriptionRunner.meName(UserDefaults.standard.string(forKey: "ui.myName")) }
    private var languages: [String] {
        let counts = Dictionary(grouping: meetings.compactMap(\.language), by: { $0 }).mapValues(\.count)
        return counts.filter { $0.value >= 2 }.keys.sorted()
    }

    var body: some View {
        Sheet {
            ScrollView {
                VStack(alignment: .leading, spacing: AppMetric.xl) {
                    VStack(alignment: .leading, spacing: AppMetric.s) {
                        Text("You").font(AppFont.display(34, weight: .semibold)).foregroundStyle(AppColor.ink)
                        Text(summary).font(AppFont.text(14)).foregroundStyle(AppColor.ink2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if loaded && meetings.isEmpty {
                        emptyCard
                    } else if !meetings.isEmpty {
                        goalsCard
                        if !state.notes.isEmpty { notesCard }
                        metricsCard
                        if state.goals.contains(where: { $0.status != .active }) { historyCard }
                    }
                    voiceCard
                }
                .padding(AppMetric.xl)
                .frame(maxWidth: 820, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .task { reload() }
        .onChange(of: coach.revision) { state = CoachStore.shared.load() }
        .onReceive(NotificationCenter.default.publisher(for: VoiceprintStore.didChange)) { _ in
            voice = VoiceprintStore.load()
        }
        .sheet(isPresented: $addingReading) { AddPersonSheet(myVoice: true) { addingReading = false } }
        .confirmationDialog("Start your goals over?", isPresented: $confirmReset, titleVisibility: .visible) {
            Button("Start over", role: .destructive) {
                CoachStore.shared.reset()
                state = CoachStore.State()
                coach.refresh(meetings: meetings, lines: lines, container: container)
            }
        } message: {
            Text("Current, reached and retired goals and the notes are removed. New goals are set from your recent meetings.")
        }
    }

    private var summary: String {
        guard !meetings.isEmpty else {
            return "Your lines are the ones named \(me): meetings recorded with your microphone, or speakers you renamed to \(me)."
        }
        let talk = meetings.map(\.talkSeconds).reduce(0, +)
        let shown = min(meetings.count, SpeechMeasure.window)
        return "Each number is the average of your last \(shown == 1 ? "meeting" : "\(shown) meetings") (\(meetings.count) measured, \(PersonPage.duration(talk)) of your lines). Numbers come from the transcripts only; the text engine writes the goals' wording and tips."
    }

    private var emptyCard: some View {
        VStack(alignment: .leading, spacing: AppMetric.s) {
            Text("Nothing to measure yet").cardTitle()
            Text("Record a meeting with Record, or rename yourself as a speaker in a recording to \(me). Your name is set in Settings.")
                .font(AppFont.text(13)).foregroundStyle(AppColor.ink2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(AppMetric.l)
        .litGlass()
    }

    // MARK: Goals

    private var goalsCard: some View {
        VStack(alignment: .leading, spacing: AppMetric.m) {
            HStack(alignment: .firstTextBaseline) {
                Text("Your goals").cardTitle()
                Spacer()
                if coach.isRunning {
                    ProgressView().controlSize(.small)
                    Text("Thinking about your goals…").font(AppFont.text(12)).foregroundStyle(AppColor.ink2)
                } else {
                    let due = SpeechCoachRunner.needsRefresh(state, meetings: meetings)
                    TapButton { coach.refresh(meetings: meetings, lines: lines, container: container) } label: {
                        LitButtonChrome(state.active.isEmpty || due ? .primary : .ghost, compact: true) {
                            Text(state.active.isEmpty ? "Set goals" : due ? "Update goals" : "Check again")
                        }
                    }
                    .disabled(meetings.count < SpeechCoach.minMeetings)
                    .help("Judge each goal against your latest meetings, close the ones reached, rethink the stalled ones.")
                }
            }
            if !coach.isRunning, !state.active.isEmpty, SpeechCoachRunner.needsRefresh(state, meetings: meetings) {
                Text("A goal was reached or has stalled since it was last checked. Update goals to close it and set the next.")
                    .font(AppFont.text(12)).foregroundStyle(AppColor.accentOnLight)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !PersonBriefRunner.engine(container).isLocal {
                Text("Your text engine is a cloud service, so setting goals sends your measured numbers and some of your lines to it.")
                    .font(AppFont.text(11)).foregroundStyle(AppColor.ink3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("A goal is reached when it is met in \(GoalJudge.hitsNeeded) of your last \(GoalJudge.window) meetings. One that has not moved after \(GoalJudge.staleMeetings) meetings or \(Int(GoalJudge.staleDays)) days is rethought; after two rethinks it is replaced.")
                .font(AppFont.text(11)).foregroundStyle(AppColor.ink3)
                .fixedSize(horizontal: false, vertical: true)
            if let error = coach.lastError {
                Text(error).font(AppFont.text(12)).foregroundStyle(AppColor.statusWarning)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if state.active.isEmpty && !coach.isRunning {
                Text(SpeechTargets.gaps(meetings).isEmpty
                     ? "Nothing stands out in your recent meetings. Nice. Check again after a few more."
                     : meetings.count < 3 ? "Goals are set after three measured meetings."
                     : "Set goals to pick the two things most worth working on.")
                    .font(AppFont.text(13)).foregroundStyle(AppColor.ink2)
            }
            ForEach(state.active) { goal in
                GoalCard(goal: goal, verdict: GoalJudge.judge(goal, meetings: meetings))
            }
        }
        .padding(AppMetric.l)
        .litGlass()
    }

    private var notesCard: some View {
        VStack(alignment: .leading, spacing: AppMetric.s) {
            Text("Clarity notes").cardTitle()
            Text("Written by the text engine from your own lines; not measured.")
                .font(AppFont.text(11)).foregroundStyle(AppColor.ink3)
            ForEach(state.notes, id: \.self) { n in
                Text(n).font(AppFont.text(13)).foregroundStyle(AppColor.ink)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(AppMetric.l)
        .litGlass()
    }

    private var metricsCard: some View {
        VStack(alignment: .leading, spacing: AppMetric.m) {
            HStack {
                Text("How you speak").cardTitle()
                Spacer()
                if !languages.isEmpty {
                    Picker("", selection: $language) {
                        Text("All languages").tag(String?.none)
                        ForEach(languages, id: \.self) { Text(SpeechMetric.languageName($0)).tag(String?.some($0)) }
                    }
                    .labelsHidden()
                    .frame(width: 150)
                }
            }
            TileGrid {
                ForEach(SpeechMetric.allCases) { m in
                    MetricTile(metric: m, meetings: meetings, language: language)
                }
            }
            Text("Fillers and hedges are counted in English and Ukrainian only. Speech engines leave many fillers out, so those read low; compare them between meetings transcribed the same way.")
                .font(AppFont.text(11)).foregroundStyle(AppColor.ink3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(AppMetric.l)
        .litGlass()
    }

    private var historyCard: some View {
        VStack(alignment: .leading, spacing: AppMetric.s) {
            HStack {
                Text("Past goals").cardTitle()
                Spacer()
                TapButton { confirmReset = true } label: {
                    LitButtonChrome(.ghost, compact: true) { Text("Start over…") }
                }
                .disabled(coach.isRunning)
            }
            ForEach(state.goals.filter { $0.status != .active }.reversed()) { g in
                HStack(alignment: .firstTextBaseline) {
                    Text(g.status == .achieved ? "Reached" : "Replaced")
                        .uiLabel(9, color: g.status == .achieved ? AppColor.statusSuccess : AppColor.ink3)
                        .frame(width: 70, alignment: .leading)
                    Text(g.title).font(AppFont.text(13)).foregroundStyle(AppColor.ink)
                    Spacer()
                    Text(g.closed?.formatted(date: .abbreviated, time: .omitted) ?? "").uiLabel(9, color: AppColor.ink3)
                }
            }
        }
        .padding(AppMetric.l)
        .litGlass()
    }

    // MARK: Voice

    private var voiceCard: some View {
        VStack(alignment: .leading, spacing: AppMetric.m) {
            if let voice {
                // Compared in People's voice model: the same reading
                // re-embedded when another model is picked.
                let mine = PeopleEmbedder.myVoice()
                let me = Person(id: UUID(), name: "You", created: voice.created, updated: voice.created,
                                print: mine ?? voice, sources: 1)
                let c = PeopleConfidence.assess(me, others: mine == nil && VoiceModel.current != .standard ? [] : others,
                                                ownVoice: true)
                HStack(alignment: .firstTextBaseline, spacing: AppMetric.m) {
                    Text("Your voice").cardTitle()
                    LevelMark(level: c.level)
                    Spacer()
                    BigNumber("\(c.percent)", suffix: "%", size: 36)
                }
                Text("Meetings use it to tell your microphone's speech from the call's. More readings, on other days or microphones, make it surer.")
                    .font(AppFont.text(12)).foregroundStyle(AppColor.ink2)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(c.factors) { FactorRow(factor: $0) }
                if let soundsLike = c.soundsLike {
                    Text("Your voice sounds close to \(soundsLike)'s, so your lines in a recording could be named \(soundsLike). Add a reading so the two are told apart.")
                        .font(AppFont.text(12)).foregroundStyle(AppColor.statusWarning)
                }
                TapButton { addingReading = true } label: {
                    LitButtonChrome(.secondary, compact: true) { Text("Add a reading…") }
                }
            } else {
                Text("Your voice").cardTitle()
                Text("Not recorded yet. A 30-second reading lets meetings tell your speech from the call's.")
                    .font(AppFont.text(13)).foregroundStyle(AppColor.ink2)
                TapButton { addingReading = true } label: {
                    LitButtonChrome(.primary, compact: true) { Text("Record your voice…") }
                }
            }
        }
        .padding(AppMetric.l)
        .litGlass()
    }

    /// Measured on open; the text engine runs only on a click, so opening
    /// the page never loads a model or sends anything anywhere.
    private func reload() {
        let history = SpeechHistory.load(me, repository: container.repository, micIsThem: true)
        meetings = history.meetings
        lines = history.lines
        state = CoachStore.shared.load()
        loaded = true
    }
}

/// One active goal: the target, where the latest meetings stand, and tips.
struct GoalCard: View {
    let goal: SpeechGoal
    let verdict: GoalJudge.Verdict

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(goal.title).font(AppFont.text(16, weight: .bold)).foregroundStyle(AppColor.ink)
                Spacer()
                Text(verdict.values.isEmpty ? "Not measured yet"
                     : "\(verdict.hits) of last \(min(GoalJudge.window, verdict.values.count)) met")
                    .uiLabel(9, color: verdict.hits > 0 ? AppColor.statusSuccess : AppColor.ink3)
            }
            Text("\(goal.metric.title)\(goal.language.map { " in \(SpeechMetric.languageName($0))" } ?? ""): \(goal.targetText). Was \(goal.metric.format(goal.baseline))\(verdict.latest.map { ", latest \(goal.metric.format($0))" } ?? ", not measured since").")
                .font(AppFont.text(12)).foregroundStyle(AppColor.ink2)
            if verdict.values.count > 1 {
                Sparkline(values: verdict.values.reversed(), target: goal.target).frame(height: 30)
            }
            Text(goal.why).font(AppFont.text(13)).foregroundStyle(AppColor.ink)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(goal.tips, id: \.self) { tip in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Rectangle().fill(AppColor.accent).frame(width: 5, height: 5)
                    Text(tip).font(AppFont.text(12)).foregroundStyle(AppColor.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if goal.revisions > 0 {
                Text("Rethought \(goal.revisions == 1 ? "once" : "twice"): a target from your recent meetings and new tips.")
                    .font(AppFont.text(11)).foregroundStyle(AppColor.ink3)
            }
        }
        .padding(AppMetric.m)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.45)))
        .accessibilityElement(children: .combine)
    }
}
