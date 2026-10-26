import SwiftUI
import AppKit

/// Training in flight, per person and app-wide: a page rebuilt by
/// switching people must still know its learn is running.
@MainActor
@Observable
final class PeopleTraining {
    static let shared = PeopleTraining()
    var busy: [UUID: String] = [:]
    var notes: [UUID: (text: String, failed: Bool)] = [:]
}

struct PersonPage: View {
    let person: Person
    let people: [Person]
    let others: [(name: String, centroid: [Float])]
    var open: (Recording, Double) -> Void
    @Environment(AppContainer.self) private var container
    private var runner: PersonBriefRunner { PersonBriefRunner.shared }
    private var training: PeopleTraining { PeopleTraining.shared }

    @State private var meetings: [PersonMeeting] = []
    @State private var speech: [MeetingSpeech] = []
    @State private var together: (them: Double, you: Double, rest: Double)?
    @State private var candidates: [(hearing: Person.Hearing, title: String, date: Date)] = []
    @State private var brief = PersonBriefView()
    @AppStorage("people.briefPeriod") private var briefPeriodRaw = PersonBriefView.Period.lastMeeting.rawValue
    private var briefPeriod: PersonBriefView.Period { .init(rawValue: briefPeriodRaw) ?? .lastMeeting }
    @State private var recordingReading = false
    @State private var renaming = false
    @State private var draftName = ""
    @State private var confirmDelete = false
    @State private var merging: Person?
    @State private var forgetting: Person.Sample?
    @State private var pageError: String?
    @State private var showDetail = false

    private var busy: String? { training.busy[person.id] }
    private var confidence: VoiceConfidence { PeopleConfidence.assess(person, others: others, unmatched: ["you"]) }

    /// Named recordings their voice has not been learned from or tried in.
    /// Only hand-tagged lines (single lines, keys of their own) do not count,
    /// and for a file from before samples were kept, recordings older than
    /// the last training are taken as learned.
    private var unlearned: [PersonMeeting] {
        let done = Set((person.learnedFrom ?? []) + (person.triedFrom ?? []))
        var legacyCutoff: Date? = person.legacyCutoff
            ?? (person.samples == nil && person.learnedFrom == nil ? person.updated : nil)
        let named = meetings.filter { m in
            !done.contains(m.id) && m.keys.contains { !$0.hasPrefix(RecordingRepository.taggedKeyPrefix) }
        }
        // More named recordings before the cutoff than the voice was learned
        // from: most of them never were. Offer them all; at worst one is
        // learned twice, which only weighs it a little more.
        if let cut = legacyCutoff, named.filter({ $0.date <= cut }).count > person.sources { legacyCutoff = nil }
        return named.filter { m in legacyCutoff.map { m.date > $0 } ?? true }
    }

    var body: some View {
        Sheet {
            ScrollView {
                VStack(alignment: .leading, spacing: AppMetric.xl) {
                    header
                    confidenceCard
                    samplesCard
                    if !candidates.isEmpty { candidatesCard }
                    if !speech.isEmpty { speechCard }
                    briefCard
                    meetingsCard
                }
                .padding(AppMetric.xl)
                .frame(maxWidth: 820, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        // Any change to the person (a match logged, an answer, a rename).
        .task(id: person) { reload() }
        .onChange(of: runner.revision) { reloadBrief() }
        .sheet(isPresented: $recordingReading) {
            AddPersonSheet(initialName: person.name, personId: person.id) { recordingReading = false }
        }
        // A sheet, not an alert: an alert's text field kept its first state
        // and opened empty the second time (seen in the app, twice).
        .sheet(isPresented: $renaming) {
            RenameSheet(name: person.name) { new in
                renaming = false
                if let new { draftName = new; rename() }
            }
        }
        .confirmationDialog("Delete \(person.name)'s voice?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { delete() }
        } message: {
            Text("The voice and what was read from their meetings are removed from this Mac. Names already in recordings stay.")
        }
        .confirmationDialog("Merge \(person.name) into \(merging?.name ?? "")?",
                            isPresented: Binding(get: { merging != nil }, set: { if !$0 { merging = nil } }),
                            titleVisibility: .visible, presenting: merging) { target in
            Button("Merge") { merge(into: target) }
        } message: { target in
            Text("One person from two: \(person.name)'s voice samples and history join \(target.name)'s, and recordings naming \(person.name) name \(target.name).")
        }
        .confirmationDialog("Forget this sample of \(person.name)'s voice?",
                            isPresented: Binding(get: { forgetting != nil }, set: { if !$0 { forgetting = nil } }),
                            titleVisibility: .visible, presenting: forgetting) { s in
            Button("Forget", role: .destructive) { forget(s) }
        } message: { s in
            Text("\(Int(s.seconds)) s of their voice from “\(sampleTitle(s))” is removed, and that recording is not offered for learning again.")
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: AppMetric.s) {
            HStack(alignment: .firstTextBaseline) {
                Text(person.name).font(AppFont.display(34, weight: .semibold)).foregroundStyle(AppColor.ink)
                Spacer()
                TapButton { draftName = person.name; renaming = true } label: {
                    LitButtonChrome(.ghost, compact: true) { Text("Rename") }
                }
                let mergeable = people.filter { $0.id != person.id }
                if !mergeable.isEmpty {
                    Menu {
                        ForEach(mergeable) { p in Button(p.name) { merging = p } }
                    } label: {
                        LitButtonChrome(.ghost, compact: true) { Text("Merge into…") }
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .help("The same person saved twice: make them one.")
                }
                TapButton { confirmDelete = true } label: {
                    LitButtonChrome(.destructive, compact: true) { Text("Delete…") }
                }
            }
            Text(summary).font(AppFont.text(14)).foregroundStyle(AppColor.ink2)
            if let pageError {
                Text(pageError).font(AppFont.text(12)).foregroundStyle(AppColor.statusError)
            }
        }
    }

    private var summary: String {
        guard let last = meetings.first else { return "Not heard in a recording yet." }
        let talk = meetings.map(\.seconds).reduce(0, +)
        let count = meetings.count == 1 ? "1 recording" : "\(meetings.count) recordings"
        return "Heard in \(count), \(Self.duration(talk)) of talk. Last heard \(last.date.formatted(date: .abbreviated, time: .omitted))."
    }

    // MARK: Confidence and training

    private var confidenceCard: some View {
        let c = confidence
        let weak = c.factors.filter { $0.grade == .weak || $0.grade == .fair }
        return VStack(alignment: .leading, spacing: AppMetric.m) {
            HStack(alignment: .firstTextBaseline, spacing: AppMetric.m) {
                Text("Voice recognition").cardTitle()
                LevelMark(level: c.level)
                Spacer()
                BigNumber("\(c.percent)", suffix: "%", size: 36)
            }
            .accessibilityElement(children: .combine)
            // What the number is, in one sentence.
            Text("How sure Transcriberr is to recognise \(person.name) when they speak in a new recording. Above 75% is Strong; recordings then name them on their own.")
                .font(AppFont.text(13)).foregroundStyle(AppColor.ink2)
                .fixedSize(horizontal: false, vertical: true)
            if !person.hasVoice {
                Text(VoiceModelSwitcher.shared.busy != nil
                     ? "Their voice is being rebuilt for the \(VoiceModel.current.title.lowercased()) voice model."
                     : "No voice in the \(VoiceModel.current.title.lowercased()) voice model yet. Improve from my recordings learns it from the meetings they are named in.")
                    .font(AppFont.text(12)).foregroundStyle(AppColor.statusWarning)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let held = c.heldBack {
                Text(held)
                    .font(AppFont.text(12)).foregroundStyle(AppColor.statusWarning)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // The one thing to press, and what it will do.
            VStack(alignment: .leading, spacing: 6) {
                if !weak.isEmpty {
                    Text("Holding it back: " + weak.map { $0.title.lowercased() }.joined(separator: ", ") + ".")
                        .font(AppFont.text(13, weight: .bold)).foregroundStyle(AppColor.ink)
                }
                HStack(spacing: AppMetric.s) {
                    TapButton { improve() } label: {
                        LitButtonChrome(.primary, compact: true) { Text("Improve from my recordings") }
                    }
                    .disabled(busy != nil || meetings.isEmpty)
                    .help(meetings.isEmpty
                          ? "\(person.name) is not named in any recording yet."
                          : "Re-learns \(person.name)'s voice from the meetings they speak in, using their clearest stretches, drops samples that don't agree, and keeps the result only if it scores higher.")
                    if let busy {
                        ProgressView().controlSize(.small)
                        Text(busy).font(AppFont.text(12)).foregroundStyle(AppColor.ink2)
                    }
                }
                Text(meetings.isEmpty
                     ? "Name \(person.name) in a recording first (Find people on the overview, or a speaker in Library)."
                     : "Uses the \(min(meetings.count, VoiceImprover.maxRecordings)) meetings with the most of \(person.name)'s speech. Nothing changes unless the result is better.")
                    .font(AppFont.text(11)).foregroundStyle(AppColor.ink3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let note = training.notes[person.id] {
                Text(note.text).font(AppFont.text(12))
                    .foregroundStyle(note.failed ? AppColor.statusError : AppColor.ink)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // The detail and the rarer ways, out of the way until wanted.
            DisclosureGroup(isExpanded: $showDetail) {
                VStack(alignment: .leading, spacing: AppMetric.m) {
                    ForEach(c.factors) { FactorRow(factor: $0) }
                    HairlineSoft()
                    Text("More ways to train").uiLabel(11, color: AppColor.ink2)
                    HStack(spacing: AppMetric.s) {
                        TapButton { recordingReading = true } label: {
                            LitButtonChrome(.secondary, compact: true) { Text("Record a reading…") }
                        }
                        .help("Record \(person.name) reading a short passage at this Mac: the cleanest sample there is.")
                        .disabled(busy != nil)
                        let todo = unlearned
                        if !todo.isEmpty {
                            TapButton { learnNamed(todo) } label: {
                                LitButtonChrome(.secondary, compact: true) {
                                    Text(todo.count == 1 ? "Add 1 named recording" : "Add \(todo.count) named recordings")
                                }
                            }
                            .disabled(busy != nil)
                        }
                    }
                }
                .padding(.top, AppMetric.s)
            } label: {
                Text(showDetail ? "Hide the details" : "Why \(c.percent)%? Details and more ways to train")
                    .uiLabel(10, color: AppColor.ink2)
            }
        }
        .padding(AppMetric.l)
        .litGlass()
    }

    private func improve() {
        guard busy == nil else { return }
        let id = person.id
        let snapshot = person
        training.busy[id] = "Listening…"
        Task { @MainActor in
            defer { training.busy[id] = nil }
            let outcome = await VoiceImprover.improve(snapshot, others: others, container: container) { text in
                training.busy[id] = text
            }
            training.notes[id] = (outcome.message, false)
        }
    }

    private var samplesCard: some View {
        let samples = person.allSamples
        let agreement = person.sampleAgreement
        let odd = person.oddSample
        return VStack(alignment: .leading, spacing: AppMetric.s) {
            Text("Voice samples").cardTitle()
            Text("Where their voice was learned. Forget a sample that has someone else in it; the rest stay.")
                .font(AppFont.text(12)).foregroundStyle(AppColor.ink2)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(samples) { s in
                HStack(spacing: AppMetric.m) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(sampleTitle(s)).font(AppFont.text(14)).foregroundStyle(AppColor.ink).lineLimit(1)
                        HStack(spacing: 6) {
                            Text("\(s.date.formatted(date: .abbreviated, time: .omitted)) · \(Int(s.seconds)) s")
                                .uiLabel(9, color: AppColor.ink3)
                            if let a = agreement[s.id] {
                                Text("· \(String(format: "%.2f", a)) like the rest").uiLabel(9, color: AppColor.ink3)
                            }
                            if s.id == odd {
                                Text("· sounds least like them").uiLabel(9, color: AppColor.statusWarning)
                            }
                        }
                    }
                    Spacer()
                    if let rec = s.recordingId {
                        TapButton { openRecording(rec) } label: {
                            LitButtonChrome(.ghost, compact: true) { Text("Open") }
                        }
                    }
                    TapButton { forgetting = s } label: {
                        LitButtonChrome(.ghost, compact: true) { Text("Forget…") }
                    }
                    .disabled(samples.count < 2 || busy != nil)
                    .help(samples.count < 2 ? "The only sample: delete the person instead." : "Remove this sample from their voice.")
                }
                HairlineSoft()
            }
        }
        .padding(AppMetric.l)
        .litGlass()
    }

    private func sampleTitle(_ s: Person.Sample) -> String {
        if s.earlier == true { return "Learned before 5.0 (source not kept)" }
        guard let id = s.recordingId else { return "Reading at this Mac" }
        return meetings.first { $0.id == id }?.title
            ?? (try? container.repository.get(id: id))?.title
            ?? "A recording since deleted"
    }

    private var candidatesCard: some View {
        VStack(alignment: .leading, spacing: AppMetric.m) {
            Text("Was this \(person.name)?").cardTitle()
            Text("These speakers sounded like \(person.name) but not clearly enough to name. Each answer makes their voice easier to find.")
                .font(AppFont.text(12)).foregroundStyle(AppColor.ink2)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(candidates, id: \.hearing.id) { c in
                HStack(spacing: AppMetric.m) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(c.title).font(AppFont.text(14)).foregroundStyle(AppColor.ink).lineLimit(1)
                        Text("\(c.date.formatted(date: .abbreviated, time: .omitted)) · \(String(format: "%.2f", c.hearing.score)) alike")
                            .uiLabel(9, color: AppColor.ink3)
                    }
                    Spacer()
                    TapButton { listen(c.hearing) } label: {
                        LitButtonChrome(.ghost, compact: true) { Text("Listen") }
                    }
                    TapButton { answer(c.hearing, wasThem: true) } label: {
                        LitButtonChrome(.primary, compact: true) { Text("Yes") }
                    }
                    .disabled(busy != nil)
                    .accessibilityLabel("Yes, this was \(person.name)")
                    TapButton { answer(c.hearing, wasThem: false) } label: {
                        LitButtonChrome(.ghost, compact: true) { Text("No") }
                    }
                    .disabled(busy != nil)
                    .accessibilityLabel("No, this was someone else")
                }
                HairlineSoft()
            }
        }
        .padding(AppMetric.l)
        .litGlass()
    }

    // MARK: How they speak

    private var speechCard: some View {
        VStack(alignment: .leading, spacing: AppMetric.m) {
            Text("How they speak").cardTitle()
            Text("Each number is the average of their last \(min(speech.count, SpeechMeasure.window) == 1 ? "meeting" : "\(min(speech.count, SpeechMeasure.window)) meetings"), from the transcripts only.")
                .font(AppFont.text(12)).foregroundStyle(AppColor.ink3)
            if let t = together {
                Text("In meetings with you").uiLabel(11, color: AppColor.ink2)
                // The accent is the user's own figure (Lit Field §10).
                ShareBar(parts: [("You", t.you, AppColor.accent),
                                 (person.name, t.them, AppColor.ink),
                                 ("Others", t.rest, AppColor.ink4)])
            }
            TileGrid {
                ForEach([SpeechMetric.talkShare, .pace, .longestTurn, .questions, .interruptions]) { m in
                    MetricTile(metric: m, meetings: speech)
                }
            }
            weeksStrip
        }
        .padding(AppMetric.l)
        .litGlass()
    }

    /// Meetings together per week, the last eight weeks.
    private var weeksStrip: some View {
        let cal = Calendar.current
        let thisWeek = cal.dateInterval(of: .weekOfYear, for: Date())?.start ?? Date()
        let weeks = (0..<8).reversed().map { cal.date(byAdding: .weekOfYear, value: -$0, to: thisWeek) ?? thisWeek }
        let counts = weeks.map { w in meetings.filter { $0.date >= w && $0.date < w.addingTimeInterval(7 * 86_400) }.count }
        let most = Double(max(1, counts.max() ?? 1))
        return VStack(alignment: .leading, spacing: 6) {
            Text("Meetings per week, last 8 weeks").uiLabel(11, color: AppColor.ink2)
            HStack(alignment: .bottom, spacing: 6) {
                ForEach(weeks.indices, id: \.self) { i in
                    VStack(spacing: 3) {
                        Text(counts[i] > 0 ? "\(counts[i])" : " ").uiLabel(9, color: AppColor.ink2)
                        RoundedRectangle(cornerRadius: 3)
                            .fill(counts[i] > 0 ? AppColor.ink2 : AppColor.hair)
                            .frame(width: 26, height: max(3, 36 * Double(counts[i]) / most))
                        Text(i == weeks.count - 1 ? "now" : weeks[i].formatted(.dateTime.day().month(.abbreviated)))
                            .uiLabel(8, color: AppColor.ink4).lineLimit(1).fixedSize()
                    }
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Meetings per week, last eight weeks: \(counts.map(String.init).joined(separator: ", "))")
    }

    // MARK: Brief

    private var briefCard: some View {
        let building = runner.running == person.id
        let engine = PersonBriefRunner.engine(container)
        let period = briefPeriod
        return VStack(alignment: .leading, spacing: AppMetric.m) {
            HStack(alignment: .firstTextBaseline) {
                Text("What they said").cardTitle()
                Spacer()
                if !brief.isEmpty {
                    TapButton {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(brief.text(for: person.name, period: period), forType: .string)
                    } label: { LitButtonChrome(.ghost, compact: true) { Text("Copy as text") } }
                }
                if building {
                    TapButton { runner.cancel() } label: {
                        LitButtonChrome(.ghost, compact: true) { Text("Stop") }
                    }
                } else if !meetings.isEmpty {
                    let neverRead = brief.readMeetings == 0 && brief.isEmpty
                    TapButton { runner.build(person: person, meetings: meetings, container: container) } label: {
                        LitButtonChrome(neverRead || brief.unread > 0 ? .primary : .secondary, compact: true) {
                            Text(neverRead ? "Read their meetings" : "Refresh")
                        }
                    }
                    .disabled(runner.running != nil)
                    .help(engine.isLocal
                          ? "Read \(person.name)'s meetings from the last month, and their latest one, on this Mac. Meetings read before are skipped."
                          : "Read \(person.name)'s meetings from the last month, and their latest one. Your text engine is a cloud service: their lines are sent to it.")
                }
            }
            if !meetings.isEmpty {
                HStack(spacing: AppMetric.s) {
                    ForEach(PersonBriefView.Period.allCases) { p in
                        LitChip(label: p.label, active: p == period) {
                            briefPeriodRaw = p.rawValue
                            reloadBrief()
                        }
                    }
                }
            }
            if runner.running != nil, !building {
                Text("Reading someone else's meetings. One person at a time.")
                    .font(AppFont.text(12)).foregroundStyle(AppColor.ink3)
            }
            if !engine.isLocal, !building {
                Text("Your text engine is a cloud service, so reading sends \(person.name)'s lines, and the line before each, to it.")
                    .font(AppFont.text(11)).foregroundStyle(AppColor.ink3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if building, let progress = runner.progress {
                HStack(spacing: AppMetric.s) {
                    ProgressView().controlSize(.small)
                    Text(progress).font(AppFont.text(12)).foregroundStyle(AppColor.ink2).lineLimit(1)
                }
            }
            if let error = runner.errors[person.id], !building {
                Text(error).font(AppFont.text(12)).foregroundStyle(AppColor.statusWarning)
                    .fixedSize(horizontal: false, vertical: true)
            }
            briefBody(period)
        }
        .padding(AppMetric.l)
        .litGlass()
    }

    @ViewBuilder
    private func briefBody(_ period: PersonBriefView.Period) -> some View {
        if meetings.isEmpty {
            briefNote("Once \(person.name) is named in a recording, what they said there, what they committed to and the questions they left open can be read from it.")
        } else if brief.meetings.isEmpty, let last = meetings.first {
            briefNote("No meetings with \(person.name) \(period.phrase). The last one was “\(last.title)” on \(last.date.formatted(date: .abbreviated, time: .omitted)).")
        } else {
            briefScope(period)
            if brief.readMeetings == 0 {
                briefNote(brief.meetings.count == 1
                          ? "This meeting hasn't been read yet. Read it to see what \(person.name) said, committed to and left open."
                          : "These meetings haven't been read yet. Read them to see what \(person.name) said, committed to and left open.")
            } else {
                briefGists(period)
                briefList("Committed to", brief.commitments, closable: true, period: period)
                briefList("Open questions", brief.questions, closable: true, period: period)
                briefList("Last said on", brief.topics, closable: false, period: period)
                if brief.isEmpty {
                    briefNote("Nothing to note from \(person.name) \(period.phrase).")
                }
                if brief.closedCount > 0 {
                    Text("\(brief.closedCount) marked done.").font(AppFont.text(11)).foregroundStyle(AppColor.ink3)
                }
            }
        }
    }

    private func briefNote(_ text: String) -> some View {
        Text(text).font(AppFont.text(13)).foregroundStyle(AppColor.ink2)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// Which meetings the period covers, and what is not read yet.
    @ViewBuilder
    private func briefScope(_ period: PersonBriefView.Period) -> some View {
        let unread = brief.unread
        if period == .lastMeeting, let m = brief.meetings.first {
            TapButton { openMeeting(m, at: m.firstLine) } label: {
                HStack(alignment: .firstTextBaseline, spacing: AppMetric.s) {
                    Text(m.title).font(AppFont.text(13, weight: .bold)).foregroundStyle(AppColor.ink).lineLimit(1)
                    Text(m.date.formatted(date: .abbreviated, time: .omitted)).uiLabel(9, color: AppColor.ink3)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .help("Open “\(m.title)”.")
        } else {
            let n = brief.meetings.count
            Text((n == 1 ? "1 meeting" : "\(n) meetings") + " \(period.phrase), newest first."
                 + (unread > 0 && brief.readMeetings > 0 ? " \(unread) not read yet: Refresh reads \(unread == 1 ? "it" : "them")." : ""))
                .font(AppFont.text(12)).foregroundStyle(AppColor.ink3)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// What they mainly said: one paragraph for the last meeting, one line
    /// per meeting for a week or a month.
    @ViewBuilder
    private func briefGists(_ period: PersonBriefView.Period) -> some View {
        if period == .lastMeeting {
            if let g = brief.gists.first {
                Text(g.text).font(AppFont.text(14)).foregroundStyle(AppColor.ink)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else if !brief.gists.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("In short").uiLabel(11, color: AppColor.ink2).padding(.top, AppMetric.s)
                ForEach(brief.gists) { g in
                    TapButton { openMeeting(g.meeting, at: g.meeting.firstLine) } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(alignment: .firstTextBaseline, spacing: AppMetric.s) {
                                Text(g.meeting.title).font(AppFont.text(12, weight: .bold)).foregroundStyle(AppColor.ink2).lineLimit(1)
                                Spacer(minLength: AppMetric.m)
                                Text(g.meeting.date.formatted(date: .abbreviated, time: .omitted)).uiLabel(9, color: AppColor.ink3)
                            }
                            Text(g.text).font(AppFont.text(13)).foregroundStyle(AppColor.ink)
                                .multilineTextAlignment(.leading)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .contentShape(Rectangle())
                    }
                    .help("Open “\(g.meeting.title)”.")
                }
            }
        }
        if brief.gists.count < brief.readMeetings, brief.readMeetings > 0 {
            Text(period == .lastMeeting && brief.gists.isEmpty
                 ? "Read before summaries were added: Refresh adds one."
                 : "Some meetings were read before summaries were added: Refresh adds them.")
                .font(AppFont.text(11)).foregroundStyle(AppColor.ink3)
        }
    }

    @ViewBuilder
    private func briefList(_ title: String, _ rows: [PersonBriefView.Row], closable: Bool,
                           period: PersonBriefView.Period) -> some View {
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text(title).uiLabel(11, color: AppColor.ink2).padding(.top, AppMetric.s)
                ForEach(rows) { row in
                    HStack(alignment: .firstTextBaseline, spacing: AppMetric.m) {
                        TapButton { openMeeting(row.meeting, at: row.item.seconds ?? row.meeting.firstLine) } label: {
                            HStack(alignment: .firstTextBaseline, spacing: AppMetric.m) {
                                VStack(alignment: .leading, spacing: 2) {
                                    if let topic = row.item.topic {
                                        Text(topic).font(AppFont.text(13, weight: .bold)).foregroundStyle(AppColor.ink)
                                    }
                                    Text(row.item.text).font(AppFont.text(13)).foregroundStyle(AppColor.ink)
                                        .multilineTextAlignment(.leading)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                Spacer(minLength: AppMetric.m)
                                if period != .lastMeeting {
                                    Text(row.meeting.date.formatted(date: .abbreviated, time: .omitted))
                                        .uiLabel(9, color: AppColor.ink3)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .help("Open “\(row.meeting.title)” where it was said.")
                        if closable {
                            TapButton { close(row) } label: { Text("Done").uiLabel(9, color: AppColor.accentOnLight) }
                                .help("Mark as done or no longer relevant.")
                        }
                    }
                }
            }
        }
    }

    // MARK: Meetings

    private var meetingsCard: some View {
        VStack(alignment: .leading, spacing: AppMetric.s) {
            Text("Meetings").cardTitle()
            if meetings.isEmpty {
                Text("No recording names \(person.name) yet. Find people on the overview, or on a recording in Library, names them in older ones.")
                    .font(AppFont.text(13)).foregroundStyle(AppColor.ink2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(meetings) { m in
                TapButton { openMeeting(m, at: m.firstLine) } label: {
                    HStack(alignment: .top, spacing: AppMetric.m) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(m.title).font(AppFont.text(14)).foregroundStyle(AppColor.ink).lineLimit(1)
                            Text("“\(m.lastSaid)”").font(AppFont.text(12)).foregroundStyle(AppColor.ink3).lineLimit(1)
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 3) {
                            Text(Self.duration(m.seconds)).font(AppFont.display(14, weight: .semibold))
                                .monospacedDigit().foregroundStyle(AppColor.ink)
                            Text(m.date.formatted(date: .abbreviated, time: .omitted)).uiLabel(9, color: AppColor.ink3)
                        }
                    }
                    .padding(.vertical, 8)
                    .contentShape(Rectangle())
                }
                HairlineSoft()
            }
        }
        .padding(AppMetric.l)
        .litGlass()
    }

    // MARK: Loading

    private func reload() {
        meetings = PersonMeetings.load(person.name, repository: container.repository)
        candidates = (person.candidates ?? []).reversed().compactMap { h in
            guard let rec = try? container.repository.get(id: h.recordingId), !rec.isDeleted else { return nil }
            return (h, rec.title, Date(timeIntervalSince1970: TimeInterval(rec.createdAtMillis) / 1000))
        }
        speech = SpeechHistory.load(person.name, repository: container.repository, meetings: meetings).meetings
        together = Self.together(speech, me: TranscriptionRunner.meName(UserDefaults.standard.string(forKey: "ui.myName")))
        reloadBrief()
    }

    /// Word split over the meetings the user was also named in.
    static func together(_ speech: [MeetingSpeech], me: String) -> (them: Double, you: Double, rest: Double)? {
        var them = 0.0, you = 0.0, rest = 0.0
        for s in speech {
            guard let mine = s.others.first(where: { $0.key.caseInsensitiveCompare(me) == .orderedSame })?.value else { continue }
            them += Double(s.words)
            you += mine
            rest += s.others.filter { $0.key.caseInsensitiveCompare(me) != .orderedSame }.values.reduce(0, +)
        }
        return them + you > 0 ? (them, you, rest) : nil
    }

    private func reloadBrief() {
        let store = PersonBriefStore.shared
        brief = PersonBriefView.combine(store.entries(for: person.id), meetings: meetings,
                                        closed: store.closed(for: person.id), period: briefPeriod)
    }

    // MARK: Actions

    private func openMeeting(_ m: PersonMeeting, at seconds: Double) { openRecording(m.id, at: seconds) }

    private func openRecording(_ id: UUID, at seconds: Double? = nil) {
        guard let rec = try? container.repository.get(id: id), !rec.isDeleted else {
            pageError = "That recording was deleted."
            return
        }
        let at = seconds ?? rec.segments.filter { $0.speakerName?.caseInsensitiveCompare(person.name) == .orderedSame }
            .map(\.startSeconds).min() ?? 0
        open(rec, at)
    }

    private func listen(_ h: Person.Hearing) {
        guard let rec = try? container.repository.get(id: h.recordingId), !rec.isDeleted else { return }
        let first = rec.segments.filter { $0.speaker == h.speaker }.map(\.startSeconds).min() ?? 0
        open(rec, first)
    }

    /// Yes names the speaker after the person and learns their voice from
    /// it; No keeps that speaker from being offered again.
    private func answer(_ h: Person.Hearing, wasThem: Bool) {
        let id = person.id, name = person.name
        guard wasThem else {
            do { try PeopleStore.shared.resolve(h, for: id, wasThem: false) } catch { show(error, for: id) }
            return
        }
        guard busy == nil else { return }
        guard let rec = try? container.repository.get(id: h.recordingId), !rec.isDeleted,
              rec.segments.contains(where: { $0.speaker == h.speaker }) else {
            // Re-run since: that speaker is gone.
            try? PeopleStore.shared.resolve(h, for: id, wasThem: false)
            done("That speaker is no longer in the recording; it was transcribed again.", for: id)
            return
        }
        let recId = rec.id, title = rec.title
        training.busy[id] = "Learning from “\(title)”…"
        Task { @MainActor in
            defer { training.busy[id] = nil }
            do {
                // Named first, before any await: the user said who it is.
                try container.repository.setSpeakerName(name, for: h.speaker, in: rec)
                try? TranscriptExporter.export(recording: rec)
                try PeopleStore.shared.resolve(h, for: id, wasThem: true)
                do {
                    let print = try await PeopleVoice.learn(speaker: h.speaker, in: rec)
                    try PeopleStore.shared.add(print, to: id, from: recId, speakers: Person.Sample.speakers([h.speaker]))
                    done("Named in “\(title)” and added \(Int(print.seconds)) s to \(name)'s voice.", for: id)
                } catch {
                    done("Named in “\(title)”. Their voice was not added: \(error.localizedDescription)", for: id)
                }
            } catch {
                show(error, for: id)
            }
        }
    }

    /// Adds the voice from each named recording not learned from yet, one
    /// sample per recording.
    private func learnNamed(_ todo: [PersonMeeting]) {
        let id = person.id, name = person.name
        guard !todo.isEmpty, busy == nil else { return }
        training.busy[id] = "Listening to 1 of \(todo.count)…"
        Task { @MainActor in
            defer { training.busy[id] = nil }
            var added = 0, seconds = 0.0, skipped = 0, failed = 0, unlike = 0
            var lastFailure = ""
            for (i, m) in todo.enumerated() {
                training.busy[id] = "Listening to \(i + 1) of \(todo.count)…"
                guard let rec = try? container.repository.get(id: m.id), !rec.isDeleted else { continue }
                let keys = m.keys.filter { !$0.hasPrefix(RecordingRepository.taggedKeyPrefix) }.sorted()
                let before = PeopleVoice.signature(rec)
                var prints: [Voiceprint] = []
                var unlearnable = false, failure: Error?, refusedHere = 0
                for key in keys {
                    // Deleted while the previous speaker was read.
                    guard !rec.isDeleted, rec.modelContext != nil else { break }
                    do {
                        let p = try await PeopleVoice.learn(speaker: key, in: rec)
                        // Named is not proof: a name given by a match or a
                        // slip must still sound like them to be learned.
                        do { try PeopleStore.shared.check(p, for: id); prints.append(p) } catch {
                            AppLog.info("people", "learn \(key) in \(m.id) refused: \(error.localizedDescription)")
                            unlike += 1
                            refusedHere += 1
                        }
                    } catch {
                        AppLog.info("people", "learn \(key) in \(m.id) skipped: \(error.localizedDescription)")
                        // Only "nothing usable in it" settles a recording; a
                        // decoder or engine failure leaves it offered.
                        if error is PeopleVoice.LearnError || error is VoiceprintStore.MixedReading { unlearnable = true }
                        else { failure = error }
                    }
                }
                // Deleted or transcribed again while its voices were read:
                // its keys may be other people now, so nothing from it is
                // used and it stays offered.
                guard !rec.isDeleted, rec.modelContext != nil, PeopleVoice.signature(rec) == before else { continue }
                do {
                    if prints.isEmpty {
                        if refusedHere > 0, failure == nil {
                            // Not them there: not offered again, and counted
                            // only as "did not sound like", not as no speech.
                            try PeopleStore.shared.tried(m.id, for: id)
                        } else if unlearnable, failure == nil {
                            try PeopleStore.shared.tried(m.id, for: id)
                            skipped += 1
                        } else if let failure {
                            failed += 1
                            lastFailure = failure.localizedDescription
                        }
                    } else {
                        let joined = Voiceprint(model: prints[0].model, seconds: prints.map(\.seconds).reduce(0, +),
                                                embeddings: prints.flatMap(\.embeddings))
                        try PeopleStore.shared.add(joined, to: id, from: m.id, speakers: Person.Sample.speakers(m.keys))
                        seconds += joined.seconds
                        added += 1
                    }
                } catch {
                    // Deleted (or the file damaged) meanwhile: stop.
                    show(error, for: id)
                    return
                }
            }
            let tail = skipped == 0 ? "" : skipped == 1
                ? " 1 had no clean speech of \(name) to learn and will not be offered again."
                : " \(skipped) had no clean speech of \(name) to learn and will not be offered again."
            let failTail = (failed == 0 ? "" : " \(failed) could not be read (\(lastFailure)); they stay offered.")
                + (unlike == 0 ? "" : " \(unlike) \(unlike == 1 ? "speaker" : "speakers") named \(name) did not sound like \(name)'s voice and \(unlike == 1 ? "was" : "were") left out.")
            done(added == 0
                 ? "Nothing added.\(tail)\(failTail)"
                 : "Added \(Int(seconds)) s of speech from \(added == 1 ? "1 recording" : "\(added) recordings").\(tail)\(failTail)", for: id)
        }
    }

    private func forget(_ s: Person.Sample) {
        do {
            try PeopleStore.shared.forget(sample: s.id, of: person.id)
            done("Forgot \(Int(s.seconds)) s of \(person.name)'s voice. That recording is not offered for learning again. Names already given in recordings stay; rename a wrong one there.", for: person.id)
        } catch { show(error, for: person.id) }
    }

    private func close(_ row: PersonBriefView.Row) {
        do {
            try PersonBriefStore.shared.setClosed(row.id, true, for: person.id)
            reloadBrief()
        } catch { pageError = error.localizedDescription }
    }

    private func rename() {
        do { try PeopleActions.rename(person, to: draftName, container: container); pageError = nil }
        catch { pageError = error.localizedDescription }
    }

    private func merge(into target: Person) {
        PersonBriefRunner.shared.cancel(person: person.id)
        do {
            try PeopleActions.merge(person, into: target, container: container)
            container.requestPeoplePane(person: target.id)
        } catch { pageError = error.localizedDescription }
    }

    private func delete() {
        PersonBriefRunner.shared.cancel(person: person.id)
        do { try PeopleStore.shared.delete(person.id) } catch { pageError = error.localizedDescription }
    }

    private func done(_ text: String, for id: UUID) { training.notes[id] = (text, false) }
    private func show(_ error: Error, for id: UUID) { training.notes[id] = (error.localizedDescription, true) }

    static func duration(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        if s < 60 { return "\(s) s" }
        if s < 3600 { return "\(s / 60) min" }
        return String(format: "%d h %02d min", s / 3600, (s / 60) % 60)
    }
}

/// One factor of the voice confidence: its name, a bar, and why.
struct FactorRow: View {
    let factor: VoiceConfidence.Factor
    var body: some View {
        HStack(alignment: .top, spacing: AppMetric.m) {
            Text(factor.title).uiLabel(10, color: AppColor.ink2).frame(width: 110, alignment: .leading)
            VStack(alignment: .leading, spacing: 4) {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(AppColor.hair)
                        if let v = factor.value {
                            Capsule().fill(fill).frame(width: max(4, geo.size.width * v))
                        }
                    }
                }
                .frame(height: 6)
                Text(factor.detail).font(AppFont.text(12)).foregroundStyle(AppColor.ink3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(factor.title): \(factor.value.map { "\(Int(($0 * 100).rounded())) percent" } ?? "not judged yet"). \(factor.detail)")
    }
    /// Ink for a factor that holds up, the accent fill only for the weak
    /// one the advice is about: status green and red on every bar read as
    /// alarms (Lit Field §9: status colours signal state, never decorate).
    private var fill: Color {
        switch factor.grade {
        case .weak: return AppColor.accent
        case .fair: return AppColor.ink4
        case .good, nil: return AppColor.ink2
        }
    }
}

/// Rename a person: the field starts from their current name every time.
private struct RenameSheet: View {
    @State private var draft: String
    let current: String
    var done: (String?) -> Void

    init(name: String, done: @escaping (String?) -> Void) {
        _draft = State(initialValue: name)
        current = name
        self.done = done
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppMetric.m) {
            Text("Rename \(current)").cardTitle()
            Text("Every recording that names \(current) is renamed too.")
                .font(AppFont.text(12)).foregroundStyle(AppColor.ink2)
            TextField("Name", text: $draft)
                .textFieldStyle(.roundedBorder)
                .onSubmit { submit() }
            HStack {
                TapButton { done(nil) } label: { LitButtonChrome(.ghost, compact: true) { Text("Cancel") } }
                Spacer()
                TapButton { submit() } label: { LitButtonChrome(.primary, compact: true) { Text("Rename") } }
                    .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty || draft == current)
            }
        }
        .padding(AppMetric.l)
        .frame(width: 360)
    }

    private func submit() {
        let t = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, t != current else { return }
        done(t)
    }
}
