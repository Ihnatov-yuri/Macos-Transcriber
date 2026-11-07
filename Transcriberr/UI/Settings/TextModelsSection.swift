import SwiftUI

/// Settings → Models: the on-device text models. Two picks (Super's arbiter,
/// everything else), and a card per model with what it costs and what it
/// is good at, measured, so the choice is not a guess. The ⓘ explains how
/// to pick and why these three.
struct TextModelsSection: View {
    @Environment(AppContainer.self) private var container
    @State private var showingInfo = false
    @Environment(\.settingsFilter) private var filter

    static let ramGB = Int(ProcessInfo.processInfo.physicalMemory >> 30)

    var body: some View {
        VStack(alignment: .leading, spacing: AppMetric.m) {
            HStack(alignment: .firstTextBaseline, spacing: AppMetric.s) {
                Text("Text models")
                    .font(AppFont.display(18, weight: .semibold))
                    .foregroundStyle(AppColor.ink)
                Button { showingInfo = true } label: {
                    Image(systemName: "info.circle")
                        .font(.system(size: 15))
                        .foregroundStyle(AppColor.ink3)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("How to pick a model, and why these three")
                .accessibilityLabel("How to pick a model")
                .popover(isPresented: $showingInfo, arrowEdge: .bottom) { TextModelsInfo() }
                Spacer()
            }
            Text("They write the summaries, clean transcripts, name recordings, brief you on people and polish dictation. In Super they settle the words Whisper and Parakeet disagree on. Everything runs on this Mac; nothing is sent anywhere.")
                .font(AppFont.text(13))
                .foregroundStyle(AppColor.ink2)
                .fixedSize(horizontal: false, vertical: true)

            if filter.shows(.textModelPicks) {
                pickers
            }

            if filter.shows(.textModelComparison) {
                comparison
            }
        }
    }

    @ViewBuilder
    private var comparison: some View {
        ModelComparison(ramGB: Self.ramGB)

        VStack(spacing: AppMetric.m) {
            ForEach(ModelCatalog.entries) { entry in
                TextModelCard(entry: entry, roles: roles(of: entry), ramGB: Self.ramGB)
            }
        }
        Text("Speed is words written per second on an M3 Pro (a token is about ¾ of an English word, less in Ukrainian). Quality is a blind test on real meetings and dictation, scored 1 to 5. Memory is what the model takes while it works; it is handed back three minutes after the last use.")
            .font(AppFont.text(12))
            .foregroundStyle(AppColor.ink3)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var pickers: some View {
        VStack(alignment: .leading, spacing: AppMetric.s) {
            Picker("Super merge", selection: Binding(
                get: { container.uiPrefs.superTextModelID },
                set: { container.uiPrefs.superTextModelID = $0 }
            )) {
                ForEach(ModelCatalog.entries) { Text(choiceLabel($0)).tag($0.id) }
            }
            Text("Reads the whole meeting for names and topics, then rules on disputed words. The quality here shows straight in the transcript: pick the best model that fits.")
                .font(AppFont.text(12)).foregroundStyle(AppColor.ink3)
                .fixedSize(horizontal: false, vertical: true)
            stand(in: .superMerge, picked: container.uiPrefs.superTextModelID)
            Picker("Everything else", selection: Binding(
                get: { container.uiPrefs.textModelID },
                set: { container.uiPrefs.textModelID = $0 }
            )) {
                ForEach(ModelCatalog.entries) { Text(choiceLabel($0)).tag($0.id) }
            }
            Text("Summaries, cleanup, titles, person briefs, the speech coach and dictation polish. Speed matters more here: dictation waits for it.")
                .font(AppFont.text(12)).foregroundStyle(AppColor.ink3)
                .fixedSize(horizontal: false, vertical: true)
            stand(in: .general, picked: container.uiPrefs.textModelID)
        }
        .padding(AppMetric.m)
        .litGlass()
    }

    /// When the pick is not downloaded: what runs instead, or that nothing
    /// can. Reads the download state, so it updates when one finishes.
    @ViewBuilder
    private func stand(in role: ModelCatalog.Role, picked id: String) -> some View {
        let downloader = container.modelDownloader
        if let pick = ModelCatalog.entry(id: id), !downloader.isCached(pick) {
            let running = ModelCatalog.selected(role)
            Text(downloader.isCached(running)
                 ? "\(pick.name) is not downloaded yet: \(running.name) does this until it is."
                 : "\(pick.name) is not downloaded yet, and no text model is: download one below. Until then summaries, titles, briefs and Super's rulings are off.")
                .font(AppFont.text(12, weight: .semibold))
                .foregroundStyle(downloader.isCached(running) ? AppColor.statusWarning : AppColor.statusError)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func roles(of entry: ModelEntry) -> [String] {
        var roles: [String] = []
        if container.uiPrefs.superTextModelID == entry.id { roles.append("Super") }
        if container.uiPrefs.textModelID == entry.id { roles.append("Everything else") }
        return roles
    }

    private func choiceLabel(_ entry: ModelEntry) -> String {
        var label = entry.name
        if !container.modelDownloader.isCached(entry) { label += " · not downloaded" }
        if Self.ramGB < entry.minRAMGB { label += " · needs a \(entry.minRAMGB) GB Mac" }
        return label
    }
}

/// One colour per model, the same in the comparison and on its card
/// (Lit Field's data series 2-4: the accent stays on the picks).
extension ModelEntry {
    var chartColor: Color {
        switch id {
        case ModelCatalog.gemmaE4B.id: Color(red: 0x14 / 255, green: 0x50 / 255, blue: 0x7a / 255)   // #14507a
        case ModelCatalog.gemma26B.id: Color(red: 0x0f / 255, green: 0x5d / 255, blue: 0x3a / 255)   // #0f5d3a
        default:                       Color(red: 0x7a / 255, green: 0x4b / 255, blue: 0x00 / 255)   // #7a4b00
        }
    }
}

/// All three models side by side, one measure at a time: three bars on one
/// scale, the best value in each marked. Comparing across separate cards
/// would mean remembering bar lengths from one card to the next.
private struct ModelComparison: View {
    let ramGB: Int

    private struct Measure {
        let title: String
        let note: String
        let higherIsBetter: Bool
        let max: Double
        let value: (ModelEntry) -> Double
        let text: (ModelEntry) -> String
    }

    /// Closed until asked for: the cards below say what most people need.
    @AppStorage("settings.compareOpen") private var open = false
    @Environment(\.settingsFilter) private var filter
    /// A search that found the comparison shows it.
    @State private var closedInSearch = false
    private var isOpen: Bool { filter.isSearching ? !closedInSearch : open }

    private var measures: [Measure] {
        let speedMax = ModelCatalog.entries.map { Swift.max($0.measured.cleanupTokensPerSecond, $0.measured.summaryTokensPerSecond) }.max() ?? 1
        return [
            Measure(title: "Quality in Ukrainian", note: "blind test, 1 to 5", higherIsBetter: true, max: 5,
                    value: { $0.measured.ukrainianScore }, text: { String(format: "%.1f", $0.measured.ukrainianScore) }),
            Measure(title: "Quality in English", note: "blind test, 1 to 5", higherIsBetter: true, max: 5,
                    value: { $0.measured.englishScore }, text: { String(format: "%.1f", $0.measured.englishScore) }),
            Measure(title: "Cleanup and dictation speed", note: "tokens per second", higherIsBetter: true, max: speedMax,
                    value: { $0.measured.cleanupTokensPerSecond }, text: { "\(Int($0.measured.cleanupTokensPerSecond))" }),
            Measure(title: "Summary speed", note: "long meetings, tokens per second", higherIsBetter: true, max: speedMax,
                    value: { $0.measured.summaryTokensPerSecond }, text: { "\(Int($0.measured.summaryTokensPerSecond))" }),
            Measure(title: "Memory while working", note: "GB of this Mac's \(ramGB) GB, less is better", higherIsBetter: false,
                    max: Double(ramGB), value: { Double($0.peakMemoryGB) }, text: { "\($0.peakMemoryGB) GB" }),
        ]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppMetric.m) {
            TapButton {
                if filter.isSearching { closedInSearch.toggle() } else { open.toggle() }
            } label: {
              HStack(spacing: AppMetric.l) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(AppColor.ink2)
                    .rotationEffect(.degrees(isOpen ? 90 : 0))
                Text("How they compare")
                    .font(AppFont.display(15, weight: .semibold))
                    .foregroundStyle(AppColor.ink)
                Spacer()
                ForEach(isOpen ? ModelCatalog.entries : []) { e in
                    HStack(spacing: 6) {
                        Circle().fill(e.chartColor).frame(width: 9, height: 9)
                        Text(e.name).font(AppFont.display(12, weight: .semibold)).foregroundStyle(AppColor.ink2)
                    }
                }
                if !isOpen {
                    Text("Speed, quality and memory").font(AppFont.text(12)).foregroundStyle(AppColor.ink3)
                }
              }
              .contentShape(Rectangle())
            }
            .accessibilityLabel(isOpen ? "Hide how the models compare" : "Show how the models compare")
            if isOpen {
            ForEach(measures, id: \.title) { m in
                let best = m.higherIsBetter
                    ? ModelCatalog.entries.map(m.value).max()
                    : ModelCatalog.entries.map(m.value).min()
                VStack(alignment: .leading, spacing: 5) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(m.title).font(AppFont.display(13, weight: .semibold)).foregroundStyle(AppColor.ink)
                        Text(m.note).font(AppFont.text(12)).foregroundStyle(AppColor.ink3)
                    }
                    ForEach(ModelCatalog.entries) { e in
                        ComparisonBar(name: e.name, color: e.chartColor, fraction: m.value(e) / m.max,
                                      text: m.text(e), best: m.value(e) == best)
                    }
                }
            }
            }
        }
        .padding(AppMetric.m)
        .litGlass()
    }
}

/// One model's bar in a measure: its colour, its value, and "best" when it
/// leads that measure.
private struct ComparisonBar: View {
    let name: String
    let color: Color
    let fraction: Double
    let text: String
    let best: Bool

    var body: some View {
        HStack(spacing: AppMetric.s) {
            Text(name)
                .font(AppFont.text(12))
                .foregroundStyle(AppColor.ink3)
                .frame(width: 130, alignment: .leading)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(AppColor.hair)
                    Capsule()
                        .fill(color)
                        .frame(width: geo.size.width * CGFloat(Swift.min(1, Swift.max(0.02, fraction))))
                }
            }
            .frame(height: 10)
            HStack(spacing: 6) {
                Text(text)
                    .font(AppFont.display(12, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(best ? AppColor.ink : AppColor.ink3)
                if best {
                    Text("best")
                        .font(AppFont.display(10, weight: .semibold))
                        .foregroundStyle(AppColor.ink)
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(Capsule().fill(AppColor.accent))
                }
            }
            .frame(width: 90, alignment: .leading)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(name): \(text)\(best ? ", best" : "")")
    }
}

/// One model: what it is, what it is picked for, and download / delete.
private struct TextModelCard: View {
    @Environment(AppContainer.self) private var container
    let entry: ModelEntry
    let roles: [String]
    let ramGB: Int

    @State private var confirmingDelete = false

    var body: some View {
        VStack(alignment: .leading, spacing: AppMetric.s) {
            HStack(alignment: .top, spacing: AppMetric.m) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: AppMetric.s) {
                        Circle().fill(entry.chartColor).frame(width: 10, height: 10)
                        Text(entry.name)
                            .font(AppFont.display(15, weight: .semibold))
                            .foregroundStyle(AppColor.ink)
                        ForEach(roles, id: \.self) { role in
                            Text(role)
                                .font(AppFont.display(11, weight: .semibold))
                                .foregroundStyle(AppColor.ink)
                                .padding(.horizontal, 8).padding(.vertical, 2)
                                .background(Capsule().fill(AppColor.accent))
                        }
                    }
                    Text(entry.purpose)
                        .font(AppFont.text(12.5))
                        .foregroundStyle(AppColor.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: AppMetric.m)
                VStack(alignment: .trailing, spacing: 6) {
                    Text(Self.gigabytes(entry.sizeBytes) + " download").uiLabel(10, color: AppColor.ink3)
                    action
                }
                .frame(minWidth: 120, alignment: .trailing)
            }

            if Double(entry.peakMemoryGB) > Double(ramGB) * 0.6 {
                Text("Too big for this Mac: it would leave too little memory for Whisper and your other apps.")
                    .font(AppFont.text(12))
                    .foregroundStyle(AppColor.statusWarning)
            }
            if let info = container.modelDownloader.progress[entry.id],
               container.modelDownloader.isDownloading.contains(entry.id) {
                ProgressView(value: info.fractionComplete) {
                    Text(info.status).uiLabel(10, color: AppColor.ink2)
                }
                .progressViewStyle(.linear)
                .tint(AppColor.accent)
            } else if let info = container.modelDownloader.progress[entry.id], info.status.hasPrefix("Failed") {
                Text(info.status).font(AppFont.text(12)).foregroundStyle(AppColor.statusError)
            }
            Text("\(entry.runtime == .mlx ? "Runs on MLX" : "Runs on uzu") · huggingface.co/\(entry.huggingFaceID)")
                .uiLabel(10, color: AppColor.ink3)
        }
        .padding(AppMetric.m)
        .litGlass()
    }

    @ViewBuilder
    private var action: some View {
        let downloader = container.modelDownloader
        if downloader.isCached(entry) {
            Text("Installed").uiLabel(11, color: AppColor.accentOnLight)
            TapButton { confirmingDelete = true } label: {
                LitButtonChrome(.destructive, compact: true) { Text("Delete") }
            }
            .confirmationDialog("Delete \(entry.name)?", isPresented: $confirmingDelete, titleVisibility: .visible) {
                Button("Delete", role: .destructive) { downloader.deleteCached(entry) }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(deleteMessage)
            }
        } else if downloader.isDownloading.contains(entry.id) {
            TapButton { downloader.cancel(entry.id) } label: {
                LitButtonChrome(.secondary, compact: true) { Text("Cancel") }
            }
        } else {
            TapButton {
                Task { try? await downloader.download(entry) }
            } label: {
                LitButtonChrome(.primary, compact: true) { Text("Download") }
            }
        }
    }

    /// Says what the delete changes when the model is in use.
    private var deleteMessage: String {
        let base = "Frees \(Self.gigabytes(entry.sizeBytes)). You can download it again any time."
        guard !roles.isEmpty else { return base }
        let others = ModelCatalog.preference.filter { $0.id != entry.id && container.modelDownloader.isCached($0) }
        let instead = others.first.map { "\($0.name) will be used instead" }
            ?? "no other model is downloaded, so summaries, titles, briefs and Super's rulings stop"
        return "It is your pick for \(roles.joined(separator: " and ")): \(instead). " + base
    }

    static func gigabytes(_ bytes: Int64) -> String {
        String(format: "%.1f GB", Double(bytes) / 1e9)
    }
}

/// The ⓘ: how to pick, and why these three.
private struct TextModelsInfo: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppMetric.m) {
                heading("How to pick")
                point("Super merge", "Give it the best model your Mac can hold. It reads the whole meeting once and then rules on the words the two speech engines disagree on, so its quality shows straight in the transcript. On a 32 GB Mac or bigger that is Gemma 4 26B.")
                point("Everything else", "Summaries, cleanup, titles, person briefs, the coach and dictation polish. Qwen3.5 9B if you want them quick; Gemma 4 26B if you mostly work in Ukrainian and have the memory; Gemma 4 E4B on an 8 or 16 GB Mac.")
                point("Memory", "A model takes its memory only while it works and hands it back three minutes after the last use. Leave room for Whisper (about 3 GB) and your other apps: a model that takes more than about 60% of the Mac's memory makes everything else slow.")
                point("Speed", "Cleanup and dictation copy most of the text, which a helper model can guess ahead: that is where Qwen on uzu is twice as fast. Long summaries write new text, and there all three are close.")

                heading("Why these three")
                point("How they were chosen", "In November 2026 we ran eight local models on the same real recordings, in Ukrainian and English: cleanup, summaries, minutes of hour-long meetings, person briefs and dictation. The answers were judged blind, without knowing which model wrote them.")
                point("Gemma 4 26B-A4B", "Won almost every Ukrainian task and the hour-long meetings. It has 26B parameters but uses 4B per word, so it is as fast as E4B.")
                point("Qwen3.5 9B", "In the middle on quality, first on speed, with modest memory. It runs on uzu, a second engine, because uzu decodes it twice as fast as MLX does.")
                point("Gemma 4 E4B", "The model the app used before. Still the best at English dictation and the only one that fits an 8 GB Mac, but it is the weakest in Ukrainian and often answers a Ukrainian meeting in English.")
                point("Left out", "Gemma 4 12B (more memory than Qwen 9B, no better), Qwen3.6 35B (good, but 22 GB), Qwen3 8B and Qwen3.5 4B (weaker), and Tiny Aya (weakest, and its licence forbids commercial use).")
            }
            .padding(AppMetric.l)
        }
        .frame(width: 440, height: 520)
    }

    private func heading(_ text: String) -> some View {
        Text(text)
            .font(AppFont.display(16, weight: .semibold))
            .foregroundStyle(AppColor.ink)
    }

    private func point(_ title: String, _ body: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(AppFont.display(13, weight: .semibold)).foregroundStyle(AppColor.ink)
            Text(body).font(AppFont.text(13)).foregroundStyle(AppColor.ink2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
