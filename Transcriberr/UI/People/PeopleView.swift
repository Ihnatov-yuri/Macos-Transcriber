import SwiftUI
import SwiftData

/// People: everyone whose voice is saved, a page for each, the user's own
/// page (You) with speaking goals, and an overview across all of them.
struct PeopleView: View {
    @Environment(AppContainer.self) private var container
    @State private var people = PeopleStore.shared.load()
    @State private var selection: Selection = .overview
    @State private var adding = false
    @State private var query = ""
    @AppStorage("people.sort") private var sort: Sort = .name
    /// A meeting opened from a page, at one of the person's lines.
    @State private var opened: (recording: Recording, at: Double)?
    /// The user's own print, read once: every row compares against it.
    @State private var mine = VoiceprintStore.load()

    enum Selection: Hashable { case overview, you, person(UUID) }
    enum Sort: String, CaseIterable { case name = "Name", confidence = "Confidence", toConfirm = "To confirm" }

    private let listColumnWidth: CGFloat = 300

    var body: some View {
        HStack(spacing: 0) {
            listColumn
                .frame(width: listColumnWidth)
                .background(AppColor.base)
            Rectangle().fill(AppColor.hair).frame(width: 1)
            Group {
                if let opened {
                    DetailView(recording: opened.recording, onClose: { self.opened = nil }, startAt: opened.at,
                               focusName: focusName)
                        .id("\(opened.recording.id)-\(opened.at)")
                } else {
                    switch selection {
                    case .overview:
                        PeopleOverview(people: people, open: open) { selection = .person($0) }
                    case .you:
                        YouDashboard(others: people.map { (name: $0.name, centroid: $0.print.centroid) }, open: open)
                    case .person(let id):
                        if let person = people.first(where: { $0.id == id }) {
                            PersonPage(person: person, people: people, others: others(than: person), open: open)
                                .id(person.id)
                        } else {
                            PeopleOverview(people: people, open: open) { selection = .person($0) }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(AppColor.base)
        }
        .onReceive(NotificationCenter.default.publisher(for: PeopleStore.didChange)) { _ in
            people = PeopleStore.shared.load()
        }
        .onReceive(NotificationCenter.default.publisher(for: VoiceprintStore.didChange)) { _ in
            mine = VoiceprintStore.load()
        }
        .onAppear {
            people = PeopleStore.shared.load()
            consumeRequest()
        }
        .onChange(of: container.peoplePaneRequested) { consumeRequest() }
        .onChange(of: selection) { opened = nil }
        .sheet(isPresented: $adding) { AddPersonSheet { adding = false } }
    }

    private func open(_ rec: Recording, _ at: Double) { opened = (rec, at) }

    /// Whose lines a recording opened from here marks: the person whose page
    /// it was opened from, or the user's own on the You page.
    private var focusName: String? {
        switch selection {
        case .person(let id): return people.first { $0.id == id }?.name
        case .you: return TranscriptionRunner.meName(UserDefaults.standard.string(forKey: "ui.myName"))
        case .overview: return nil
        }
    }

    /// A recording's speaker asked for their page (DetailView).
    private func consumeRequest() {
        guard container.peoplePaneRequested > 0 else { return }
        if let id = container.pendingPerson { selection = .person(id) }
        container.pendingPerson = nil
        opened = nil
    }

    /// Every other saved voice, and the user's own as "you".
    private func others(than person: Person) -> [(name: String, centroid: [Float])] {
        var out = people.filter { $0.id != person.id }.map { (name: $0.name, centroid: $0.print.centroid) }
        if let mine { out.append((name: "you", centroid: mine.centroid)) }
        return out
    }

    private var shown: [(person: Person, confidence: VoiceConfidence)] {
        // The field shows from four people on; a query typed then must not
        // go on hiding everyone once a delete takes the list back to three.
        let q = people.count > 3 ? query.trimmingCharacters(in: .whitespaces) : ""
        let rows = people
            .filter { q.isEmpty || $0.name.localizedCaseInsensitiveContains(q) }
            .map { (person: $0, confidence: PeopleConfidence.assess($0, others: others(than: $0), unmatched: ["you"])) }
        switch sort {
        case .name: return rows
        case .confidence: return rows.sorted { $0.confidence.score < $1.confidence.score }
        case .toConfirm:
            return rows.sorted { ($0.person.candidates?.count ?? 0) > ($1.person.candidates?.count ?? 0) }
        }
    }

    private var listColumn: some View {
        Sheet {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("People").font(AppFont.display(22, weight: .semibold)).foregroundStyle(AppColor.ink)
                        Spacer()
                        TapButton { adding = true } label: {
                            LitButtonChrome(.secondary, compact: true) { Text("Add person…") }
                        }
                    }
                    .padding(.horizontal, AppMetric.sheetPadding)
                    .padding(.vertical, AppMetric.sheetVerticalPadding)
                    InkRule()
                    fixedRow("Overview", detail: "Everyone at a glance", .overview)
                    HairlineSoft()
                    fixedRow("You", detail: "How you speak, your goals and voice", .you)
                    InkRule()
                    if people.count > 3 {
                        HStack(spacing: AppMetric.s) {
                            TextField("Search", text: $query).textFieldStyle(.roundedBorder)
                            Picker("", selection: $sort) {
                                ForEach(Sort.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                            }
                            .labelsHidden()
                            .frame(width: 110)
                        }
                        .padding(.horizontal, AppMetric.sheetPadding)
                        .padding(.vertical, AppMetric.s)
                        HairlineSoft()
                    }
                    ForEach(shown, id: \.person.id) { row in
                        personRow(row.person, row.confidence)
                        HairlineSoft()
                    }
                    if people.isEmpty {
                        Text("No one saved yet. Add person records someone reading, or learns them from a speaker in a recording.")
                            .font(AppFont.text(12)).foregroundStyle(AppColor.ink2)
                            .padding(AppMetric.sheetPadding)
                    }
                }
            }
        }
    }

    private func fixedRow(_ title: String, detail: String, _ s: Selection) -> some View {
        let selected = selection == s && opened == nil
        return TapButton { selection = s; opened = nil } label: {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(AppFont.text(15, weight: .bold)).foregroundStyle(AppColor.ink)
                Text(detail).uiLabel(9, color: AppColor.ink3)
            }
            .padding(.horizontal, AppMetric.sheetPadding)
            .padding(.vertical, 11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? AppColor.accent.opacity(0.10) : Color.clear)
            .overlay(alignment: .leading) { Rectangle().fill(selected ? AppColor.accent : Color.clear).frame(width: 3) }
            .contentShape(Rectangle())
        }
    }

    private func personRow(_ person: Person, _ confidence: VoiceConfidence) -> some View {
        let selected = selection == .person(person.id)
        let waiting = person.candidates?.count ?? 0
        return TapButton { selection = .person(person.id); opened = nil } label: {
            HStack(alignment: .center, spacing: AppMetric.m) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(person.name).font(AppFont.text(15)).foregroundStyle(AppColor.ink).lineLimit(1)
                    HStack(spacing: 6) {
                        LevelMark(level: confidence.level)
                        if waiting > 0 {
                            Text("·").uiLabel(9, color: AppColor.ink3)
                            Text(waiting == 1 ? "1 to confirm" : "\(waiting) to confirm")
                                .uiLabel(9, color: AppColor.accentOnLight)
                        }
                    }
                }
                Spacer()
                Text("\(confidence.percent)%")
                    .font(AppFont.display(16, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(AppColor.ink)
            }
            .padding(.horizontal, AppMetric.sheetPadding)
            .padding(.vertical, 13)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? AppColor.accent.opacity(0.10) : Color.clear)
            .overlay(alignment: .leading) {
                Rectangle().fill(selected ? AppColor.accent : Color.clear).frame(width: 3)
            }
            .contentShape(Rectangle())
        }
        .accessibilityLabel("\(person.name), voice recognition \(confidence.level.rawValue), \(confidence.percent) percent\(waiting > 0 ? ", \(waiting) to confirm" : "")")
        .help("\(confidence.percent)%: how sure Transcriberr is to recognise \(person.name) in a new recording.")
    }
}

/// The confidence level as a word with a small square in its colour.
struct LevelMark: View {
    let level: VoiceConfidence.Level
    var body: some View {
        HStack(spacing: 5) {
            Rectangle().fill(color).frame(width: 6, height: 6)
            Text(level.rawValue).uiLabel(9, color: color)
        }
    }
    private var color: Color {
        switch level {
        case .learning: return AppColor.statusWarning
        case .good: return AppColor.ink2
        case .strong: return AppColor.statusSuccess
        }
    }
}

// MARK: - Overview

/// Everyone at a glance: who you meet most, what is open, whose voice
/// waits for an answer, and the scan that fills all of it for old recordings.
struct PeopleOverview: View {
    let people: [Person]
    var open: (Recording, Double) -> Void
    var select: (UUID) -> Void
    @Environment(AppContainer.self) private var container
    private var scan: LibraryPeopleScan { LibraryPeopleScan.shared }

    struct Row: Identifiable {
        let person: Person
        let meetings: [PersonMeeting]
        let recent: [PersonMeeting]
        var id: UUID { person.id }
    }
    @State private var rows: [Row] = []
    @State private var commitments: [(person: Person, row: PersonBriefView.Row, id: String)] = []
    @State private var named: [VoiceSuggestions.Named] = []
    @State private var groups: [VoiceSuggestions.Group] = []
    @State private var titles: [UUID: String] = [:]
    @State private var drafts: [String: String] = [:]
    @State private var scanned = false
    private var suggest: PeopleSuggestionRunner { PeopleSuggestionRunner.shared }
    private var briefs: PersonBriefRunner { PersonBriefRunner.shared }

    static let recentDays = 30.0

    var body: some View {
        Sheet {
            ScrollView {
                VStack(alignment: .leading, spacing: AppMetric.xl) {
                    VStack(alignment: .leading, spacing: AppMetric.s) {
                        Text("Everyone").font(AppFont.display(34, weight: .semibold)).foregroundStyle(AppColor.ink)
                        Text(summary).font(AppFont.text(14)).foregroundStyle(AppColor.ink2)
                    }
                    scanCard
                    suggestionsCard
                    if !rows.isEmpty { togetherCard }
                    if !commitments.isEmpty || rows.contains(where: { !$0.meetings.isEmpty }) { commitmentsCard }
                    let waiting = people.filter { ($0.candidates?.count ?? 0) > 0 }
                    if !waiting.isEmpty { waitingCard(waiting) }
                }
                .padding(AppMetric.xl)
                .frame(maxWidth: 820, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .task(id: people.map(\.updated)) { reload() }
        .onChange(of: scan.isRunning) { if !scan.isRunning { reload() } }
        .onChange(of: suggest.busy) { if suggest.busy == nil { reload() } }
        .onChange(of: briefs.revision) { reload() }
    }

    private var summary: String {
        let n = people.count
        guard n > 0 else { return "No one saved yet." }
        let waiting = people.map { $0.candidates?.count ?? 0 }.reduce(0, +)
        return "\(n == 1 ? "1 person" : "\(n) people") saved"
            + (waiting > 0 ? ", \(waiting) \(waiting == 1 ? "voice" : "voices") waiting for you to confirm." : ".")
    }

    private var scanCard: some View {
        VStack(alignment: .leading, spacing: AppMetric.s) {
            Text("Find people in all recordings").cardTitle()
            Text("Listens to every recording with speakers: names the people it is sure of, and asks on their pages about the ones it is not. Run it after training someone, or once for recordings made before this version.")
                .font(AppFont.text(12)).foregroundStyle(AppColor.ink2)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: AppMetric.s) {
                if scan.isRunning {
                    TapButton { scan.cancel() } label: { LitButtonChrome(.ghost, compact: true) { Text("Stop") } }
                    ProgressView().controlSize(.small)
                    Text(scan.progress ?? "Starting…").font(AppFont.text(12)).foregroundStyle(AppColor.ink2).lineLimit(1)
                } else {
                    TapButton { scan.start(container: container) } label: {
                        LitButtonChrome(.primary, compact: true) { Text("Find people") }
                    }
                    if let result = scan.lastResult {
                        Text(result).font(AppFont.text(12)).foregroundStyle(AppColor.ink2)
                    }
                }
            }
        }
        .padding(AppMetric.l)
        .litGlass()
    }

    @ViewBuilder private var suggestionsCard: some View {
        VStack(alignment: .leading, spacing: AppMetric.s) {
            Text("People you meet often").cardTitle()
            Text("Voices in at least \(VoiceSuggestions.minMeetings) of your meetings in the last \(Int(VoiceSuggestions.recentDays)) days that no one saved sounds like, and names you typed in several recordings that have no saved voice.")
                .font(AppFont.text(12)).foregroundStyle(AppColor.ink2)
                .fixedSize(horizontal: false, vertical: true)
            if named.isEmpty && groups.isEmpty {
                Text(scanned ? "No one new stands out yet." : "Find people above also listens for voices you meet often. Run it, then come back.")
                    .font(AppFont.text(13)).foregroundStyle(AppColor.ink3)
            }
            ForEach(named.prefix(VoiceSuggestions.maxShown)) { n in
                HStack(spacing: AppMetric.m) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(n.name).font(AppFont.text(14)).foregroundStyle(AppColor.ink)
                        Text("Named in \(n.recordings) recordings · \(PersonPage.duration(n.seconds)) · no saved voice")
                            .uiLabel(9, color: AppColor.ink3)
                    }
                    Spacer()
                    TapButton { suggest.saveNamed(n.name, container: container) } label: {
                        LitButtonChrome(.secondary, compact: true) { Text("Save voice") }
                    }
                    .disabled(suggest.busy != nil)
                }
                HairlineSoft()
            }
            ForEach(groups.prefix(VoiceSuggestions.maxShown)) { g in
                HStack(spacing: AppMetric.m) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("A voice in \(g.members.count) of your meetings").font(AppFont.text(14)).foregroundStyle(AppColor.ink)
                        Text("\(PersonPage.duration(g.seconds)) · last \(g.last.formatted(date: .abbreviated, time: .omitted)) · " +
                             g.members.sorted { $0.date > $1.date }.prefix(2).compactMap { titles[$0.recordingId] }.joined(separator: ", "))
                            .uiLabel(9, color: AppColor.ink3).lineLimit(1)
                    }
                    Spacer()
                    TapButton { listen(g) } label: { LitButtonChrome(.ghost, compact: true) { Text("Listen") } }
                    TextField("Who is this?", text: Binding(get: { drafts[g.id] ?? "" }, set: { drafts[g.id] = $0 }))
                        .textFieldStyle(.roundedBorder).frame(width: 140)
                        .onSubmit { save(g) }
                    TapButton { save(g) } label: { LitButtonChrome(.primary, compact: true) { Text("Save") } }
                        .disabled(suggest.busy != nil || (drafts[g.id] ?? "").trimmingCharacters(in: .whitespaces).isEmpty)
                    TapButton { suggest.dismiss(g); reload() } label: { LitButtonChrome(.ghost, compact: true) { Text("Not now") } }
                }
                HairlineSoft()
            }
            if let busy = suggest.busy {
                HStack(spacing: AppMetric.s) {
                    ProgressView().controlSize(.small)
                    Text(busy).font(AppFont.text(12)).foregroundStyle(AppColor.ink2)
                }
            }
            if let note = suggest.note {
                Text(note.text).font(AppFont.text(12))
                    .foregroundStyle(note.failed ? AppColor.statusWarning : AppColor.ink2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(AppMetric.l)
        .litGlass()
    }

    private func save(_ g: VoiceSuggestions.Group) {
        guard let name = drafts[g.id]?.trimmingCharacters(in: .whitespaces), !name.isEmpty else { return }
        suggest.saveGroup(g, as: name, container: container)
        drafts[g.id] = nil
    }

    /// The newest meeting of the voice, at its first line.
    private func listen(_ g: VoiceSuggestions.Group) {
        guard let m = g.members.max(by: { $0.date < $1.date }),
              let rec = try? container.repository.get(id: m.recordingId), !rec.isDeleted else { return }
        open(rec, rec.segments.filter { $0.speaker == m.speaker }.map(\.startSeconds).min() ?? 0)
    }

    private var togetherCard: some View {
        VStack(alignment: .leading, spacing: AppMetric.s) {
            Text("Most meetings together, last \(Int(Self.recentDays)) days").cardTitle()
            let top = rows.filter { !$0.recent.isEmpty }.sorted { $0.recent.count > $1.recent.count }.prefix(8)
            if top.isEmpty {
                Text("No saved person spoke in a recording in the last \(Int(Self.recentDays)) days.")
                    .font(AppFont.text(13)).foregroundStyle(AppColor.ink2)
            }
            let most = Double(top.first?.recent.count ?? 1)
            ForEach(Array(top)) { r in
                TapButton { select(r.person.id) } label: {
                    HStack(spacing: AppMetric.m) {
                        Text(r.person.name).font(AppFont.text(14)).foregroundStyle(AppColor.ink)
                            .frame(width: 140, alignment: .leading).lineLimit(1)
                        GeometryReader { geo in
                            Capsule().fill(AppColor.ink3)
                                .frame(width: max(4, geo.size.width * Double(r.recent.count) / most), height: 8)
                                .frame(maxHeight: .infinity, alignment: .center)
                        }
                        .frame(height: 14)
                        Text("\(r.recent.count) · \(PersonPage.duration(r.recent.map(\.seconds).reduce(0, +)))")
                            .uiLabel(9, color: AppColor.ink2).frame(width: 90, alignment: .trailing)
                    }
                    .contentShape(Rectangle())
                }
                .accessibilityLabel("\(r.person.name): \(r.recent.count) meetings")
            }
        }
        .padding(AppMetric.l)
        .litGlass()
    }

    private var commitmentsCard: some View {
        VStack(alignment: .leading, spacing: AppMetric.s) {
            HStack(alignment: .firstTextBaseline) {
                Text("Open commitments").cardTitle()
                Spacer()
                if briefs.batch > 1 {
                    TapButton { briefs.cancel() } label: { LitButtonChrome(.ghost, compact: true) { Text("Stop") } }
                } else {
                    TapButton {
                        briefs.buildAll(rows.filter { !$0.meetings.isEmpty }.map { ($0.person, $0.meetings) },
                                        container: container)
                    } label: { LitButtonChrome(.secondary, compact: true) { Text("Refresh all") } }
                    .disabled(briefs.running != nil)
                    .help("Read everyone's meetings from the last month, one person at a time. Meetings read before are skipped.")
                }
            }
            if briefs.batch > 1, let progress = briefs.progress {
                HStack(spacing: AppMetric.s) {
                    ProgressView().controlSize(.small)
                    Text(progress).font(AppFont.text(12)).foregroundStyle(AppColor.ink2).lineLimit(1)
                }
            }
            Text(commitments.isEmpty
                 ? "Nothing open from the last month. Refresh all reads everyone's meetings to find what they committed to."
                 : "What people committed to in the last month, newest first. Mark items done on their pages.")
                .font(AppFont.text(12)).foregroundStyle(AppColor.ink3)
            ForEach(commitments.prefix(10), id: \.id) { c in
                TapButton { openMeeting(c.row.meeting, at: c.row.item.seconds ?? c.row.meeting.firstLine) } label: {
                    HStack(alignment: .firstTextBaseline, spacing: AppMetric.m) {
                        Text(c.person.name).font(AppFont.text(13, weight: .bold)).foregroundStyle(AppColor.ink)
                            .frame(width: 110, alignment: .leading).lineLimit(1)
                        Text(c.row.item.text).font(AppFont.text(13)).foregroundStyle(AppColor.ink)
                            .multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: AppMetric.m)
                        Text(c.row.meeting.date.formatted(date: .abbreviated, time: .omitted)).uiLabel(9, color: AppColor.ink3)
                    }
                    .contentShape(Rectangle())
                }
            }
        }
        .padding(AppMetric.l)
        .litGlass()
    }

    private func waitingCard(_ waiting: [Person]) -> some View {
        VStack(alignment: .leading, spacing: AppMetric.s) {
            Text("Voices to confirm").cardTitle()
            ForEach(waiting) { p in
                TapButton { select(p.id) } label: {
                    HStack {
                        Text(p.name).font(AppFont.text(14)).foregroundStyle(AppColor.ink)
                        Spacer()
                        Text("\(p.candidates?.count ?? 0) to confirm").uiLabel(9, color: AppColor.accentOnLight)
                    }
                    .contentShape(Rectangle())
                }
            }
        }
        .padding(AppMetric.l)
        .litGlass()
    }

    private func reload() {
        let since = Date().addingTimeInterval(-Self.recentDays * 86_400)
        // One fetch of every named line and one read of the brief file,
        // however many people are saved.
        let byName = (try? container.repository.segmentsByNamedSpeaker()) ?? [:]
        rows = people.map { p in
            let m = PersonMeetings.group(byName[p.name.lowercased()] ?? [])
            return Row(person: p, meetings: m, recent: m.filter { $0.date >= since })
        }
        // Suggestions: hand-typed names without a voice, recurring unnamed voices.
        let me = TranscriptionRunner.meName(UserDefaults.standard.string(forKey: "ui.myName"))
        named = VoiceSuggestions.named(
            byName.values.flatMap { $0 }.compactMap { s in
                guard let n = s.speakerName, let r = s.recording, !r.isDeleted else { return nil }
                return (n, r.id, max(0, s.endSeconds - s.startSeconds))
            },
            saved: Set(people.map { $0.name.lowercased() }), me: me)
        let unknown = UnknownVoiceStore.shared.load()
        scanned = !unknown.entries.isEmpty
        groups = VoiceSuggestions.groups(unknown, people: people.map { (name: $0.name, centroid: $0.print.centroid) },
                                         me: VoiceprintStore.load()?.centroid)
        titles = Dictionary(groups.flatMap(\.members).compactMap { m in
            (try? container.repository.get(id: m.recordingId)).map { (m.recordingId, $0.title) }
        }, uniquingKeysWith: { a, _ in a })
        let all = PersonBriefStore.shared.all()
        commitments = rows.flatMap { r in
            PersonBriefView.combine(all.entries[r.person.id] ?? [], meetings: r.meetings,
                                    closed: Set(all.closed[r.person.id] ?? []), period: .month)
                .commitments.map { (person: r.person, row: $0, id: r.person.id.uuidString + $0.id) }
        }
        .sorted { $0.row.meeting.date > $1.row.meeting.date }
    }

    private func openMeeting(_ m: PersonMeeting, at seconds: Double) {
        guard let rec = try? container.repository.get(id: m.id), !rec.isDeleted else { return }
        open(rec, seconds)
    }
}
