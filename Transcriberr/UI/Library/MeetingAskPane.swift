import SwiftUI
import SwiftData

/// One question at a time, kept in `AppContainer` so that the answer is
/// still there after opening a source or visiting another section.
@Observable
nonisolated final class MeetingAskSession: @unchecked Sendable {
    enum Phase: Equatable {
        case idle
        case thinking(String)
        case answered(MeetingAsk.Answer)
        case failed(String, message: String)
    }

    var isOpen = false
    var question = ""
    var phase: Phase = .idle
    /// A source open in the detail pane.
    var opened: (id: UUID, at: Double)?
    @ObservationIgnored private var task: Task<Void, Never>?

    @MainActor
    func ask(store: ModelContainer, factory: BackendFactory, me: String) {
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        task?.cancel()
        phase = .thinking(q)
        let model = OnDeviceMeetingAskModel(factory: factory)
        task = Task { @MainActor [weak self] in
            let next: Phase
            do {
                let lines = try await Task.detached(priority: .userInitiated) {
                    try MeetingAsk.lines(context: ModelContext(store))
                }.value
                let answer = try await MeetingAsk.ask(q, lines: lines, me: me, model: model)
                next = .answered(answer)
                AppLog.info("ask", "\(lines.count) lines, \(answer.cited.count) cited, found=\(answer.found)")
            } catch is CancellationError {
                return
            } catch {
                next = .failed(q, message: error.localizedDescription)
            }
            guard !Task.isCancelled, let self, self.phase == .thinking(q) else { return }
            self.phase = next
        }
    }

    @MainActor
    func cancel() {
        task?.cancel()
        task = nil
        phase = .idle
    }
}

/// The right-hand pane of the Library while asking. Find, in the list on
/// the left, stays what it was and works alongside it.
struct MeetingAskPane: View {
    @Bindable var ask: MeetingAskSession
    var onSubmit: () -> Void
    var onOpen: (MeetingAsk.Source) -> Void
    var onClose: () -> Void

    @FocusState private var focused: Bool

    private var isThinking: Bool {
        if case .thinking = ask.phase { return true }
        return false
    }
    private var canAsk: Bool {
        !isThinking && !ask.question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        Sheet {
            ScrollView {
                VStack(alignment: .leading, spacing: AppMetric.l) {
                    header
                    field
                    content
                }
                .padding(AppMetric.xl)
                .frame(maxWidth: 720, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .onAppear { focused = true }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Ask your meetings").font(AppFont.display(22, weight: .semibold)).foregroundStyle(AppColor.ink)
                Text("Answered on this Mac by the on-device text model, from your transcripts. Nothing leaves it.")
                    .font(AppFont.text(13)).foregroundStyle(AppColor.ink2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: AppMetric.m)
            TapButton(action: onClose) {
                LitButtonChrome(.ghost, compact: true) { Text("Close") }
            }
        }
    }

    private var field: some View {
        HStack(spacing: AppMetric.s) {
            TextField("What did we decide about pricing?", text: $ask.question)
                .textFieldStyle(.plain)
                .font(AppFont.text(15))
                .foregroundStyle(AppColor.ink)
                .tint(AppColor.accentOnLight)
                .focused($focused)
                .onSubmit { if canAsk { onSubmit() } }
                .padding(.horizontal, 12).padding(.vertical, 9)
                .background(RoundedRectangle(cornerRadius: AppMetric.radiusSm).fill(AppColor.base))
                .overlay(RoundedRectangle(cornerRadius: AppMetric.radiusSm).stroke(AppColor.hairStrong, lineWidth: 1))
                .accessibilityLabel("Question about your meetings")
            TapButton(action: { if canAsk { onSubmit() } }) {
                LitButtonChrome(.primary, compact: true) {
                    Label("Ask", systemImage: "sparkles").labelStyle(.titleAndIcon)
                }
            }
            .opacity(canAsk ? 1 : 0.45)
            .accessibilityLabel("Ask")
        }
    }

    @ViewBuilder private var content: some View {
        switch ask.phase {
        case .idle:
            Text("Ask in English or Ukrainian, about any recording. Every claim in the answer links to the moment it was said. To find a word or a title, use Find on the left.")
                .font(AppFont.text(13)).foregroundStyle(AppColor.ink3)
                .fixedSize(horizontal: false, vertical: true)
        case .thinking:
            HStack(spacing: AppMetric.s) {
                ProgressView().controlSize(.small)
                Text("Searching your transcripts and reading the best passages. The first question of the day takes up to a minute while the model loads.")
                    .font(AppFont.text(13)).foregroundStyle(AppColor.ink2)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                TapButton(action: { ask.cancel() }) {
                    LitButtonChrome(.ghost, compact: true) { Text("Cancel") }
                }
            }
        case .failed(_, let message):
            Text("That didn't work: \(message)")
                .font(AppFont.text(14)).foregroundStyle(AppColor.ink)
                .fixedSize(horizontal: false, vertical: true)
        case .answered(let answer):
            answered(answer)
        }
    }

    @ViewBuilder private func answered(_ answer: MeetingAsk.Answer) -> some View {
        if answer.widened {
            Text("Nothing matched inside those dates, so this looked through every recording.")
                .font(AppFont.text(12)).foregroundStyle(AppColor.ink3)
        }
        if answer.found {
            Text(Self.linked(answer.text))
                .font(AppFont.text(16))
                .foregroundStyle(AppColor.ink)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .environment(\.openURL, OpenURLAction { url in
                    if let n = url.host.flatMap(Int.init), let s = answer.cited.first(where: { $0.number == n }) { onOpen(s) }
                    return .handled
                })
            sources("Where this comes from", answer.cited, numbered: true)
        } else {
            Text("Your recordings don't answer this.")
                .font(AppFont.text(16)).foregroundStyle(AppColor.ink)
            if !answer.nearby.isEmpty { sources("Closest passages", answer.nearby, numbered: false) }
        }
    }

    private func sources(_ title: String, _ list: [MeetingAsk.Source], numbered: Bool) -> some View {
        VStack(alignment: .leading, spacing: AppMetric.s) {
            Text(title).uiLabel(11, color: AppColor.ink2)
            ForEach(list) { source in
                TapButton(action: { onOpen(source) }) {
                    HStack(alignment: .top, spacing: AppMetric.s) {
                        if numbered {
                            Text("\(source.number)").uiLabel(11, color: AppColor.accentOnLight).frame(width: 16, alignment: .leading)
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(source.passage.title).font(AppFont.text(14, weight: .medium)).foregroundStyle(AppColor.ink)
                            Text("\(Self.dateLabel(source.passage.date)) · \(Self.clock(source.passage.start))")
                                .uiLabel(10, color: AppColor.ink3)
                            Text(source.passage.text.replacingOccurrences(of: "\n", with: " "))
                                .font(AppFont.text(12)).foregroundStyle(AppColor.ink3)
                                .lineLimit(2)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
                }
                .accessibilityLabel("Open \(source.passage.title) at \(Self.clock(source.passage.start))")
            }
        }
    }

    /// `[3]` as a tappable mark in the running text.
    static func linked(_ text: String) -> AttributedString {
        var out = AttributedString()
        var rest = Substring(text)
        while let open = rest.firstIndex(of: "["), let close = rest[open...].firstIndex(of: "]"),
              let n = Int(rest[rest.index(after: open)..<close]) {
            out += AttributedString(String(rest[..<open]))
            var mark = AttributedString(" \(n)")
            mark.link = URL(string: "ask://\(n)")
            mark.foregroundColor = AppColor.accentOnLight
            out += mark
            rest = rest[rest.index(after: close)...]
        }
        return out + AttributedString(String(rest))
    }

    static func clock(_ seconds: Double) -> String {
        let s = Int(seconds)
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
                         : String(format: "%d:%02d", s / 60, s % 60)
    }

    static func dateLabel(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .omitted)
    }
}
