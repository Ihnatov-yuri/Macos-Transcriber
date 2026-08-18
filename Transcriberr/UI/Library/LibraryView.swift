import SwiftUI
import SwiftData
import AppKit
import AVFoundation
import UniformTypeIdentifiers

/// Editorial port of Android `recordings/RecordingsListScreen.kt`.
/// Two-column layout (list on the left, detail on the right) within the
/// section detail pane — no nested split view, so margins line up cleanly.
struct LibraryView: View {
    @Environment(\.modelContext) private var context
    @Environment(AppContainer.self) private var container
    @Query(sort: \Recording.createdAtMillis, order: .reverse) private var all: [Recording]
    @Query(sort: \Folder.sortOrder) private var allFolders: [Folder]
    @Query(sort: \Tag.name) private var allTags: [Tag]

    @State private var query: String = ""
    @State private var selection: Recording?
    @State private var importError: String?
    @State private var selectedFolderID: UUID?
    @State private var selectedTagID: UUID?

    private let listColumnWidth: CGFloat = 380

    var body: some View {
        HStack(spacing: 0) {
            listColumn
                .frame(width: listColumnWidth)
                .background(AppColor.paper)

            Rectangle().fill(AppColor.hairline).frame(width: 1)

            Group {
                if let selection {
                    DetailView(recording: selection,
                               onClose: { self.selection = nil })
                } else {
                    emptyState
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(AppColor.paper)
        }
        .onChange(of: allFolders.map(\.id)) { _, ids in
            if let sel = selectedFolderID, !ids.contains(sel) { selectedFolderID = nil }
        }
        .onChange(of: allTags.map(\.id)) { _, ids in
            if let sel = selectedTagID, !ids.contains(sel) { selectedTagID = nil }
        }
        .alert("Import failed", isPresented: Binding(
            get: { importError != nil },
            set: { if !$0 { importError = nil } }
        )) {
            Button("OK", role: .cancel) { importError = nil }
        } message: {
            Text(importError ?? "")
        }
    }

    // MARK: - Empty state

    private var emptyState: some View {
        Sheet {
            VStack(alignment: .leading, spacing: 12) {
                Spacer()
                Text("NO RECORDING SELECTED").monoLabel(11, color: AppColor.inkMuted)
                Text("Pick a recording on the left, or tap + Import to bring one in.")
                    .font(AppFont.fraunces(20, italic: true))
                    .foregroundStyle(AppColor.inkSoft)
                    .frame(maxWidth: 420, alignment: .leading)
                Spacer()
            }
            .padding(AppMetric.xl)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - List column

    private var listColumn: some View {
        Sheet {
            VStack(alignment: .leading, spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        BrandStrip {
                            Text(Bundle.versionBadge).monoLabel(9, color: AppColor.inkMuted)
                        }
                        .padding(.horizontal, AppMetric.sheetPadding)
                        .padding(.top, AppMetric.sheetVerticalPadding)
                        .padding(.bottom, AppMetric.sheetVerticalPadding)

                        InkRule()
                        Spacer().frame(height: AppMetric.l)

                        SectionIndex(1, "LIBRARY", summary: countSummary())
                            .padding(.horizontal, AppMetric.sheetPadding)

                        Spacer().frame(height: AppMetric.l)
                        metricStrip
                        Spacer().frame(height: AppMetric.l)
                        InkRule()
                        Spacer().frame(height: AppMetric.s)

                        FolderStrip(folders: allFolders, selectedFolderID: $selectedFolderID)
                            .padding(.horizontal, AppMetric.sheetPadding)
                        if !allTags.isEmpty {
                            Spacer().frame(height: 6)
                            TagFilterMenu(tags: allTags, selectedTagID: $selectedTagID)
                                .padding(.horizontal, AppMetric.sheetPadding)
                        }

                        Spacer().frame(height: AppMetric.sheetVerticalPadding)

                        EyebrowRow("RECORDINGS") {
                            EmptyView()
                        } right: {
                            TapButton { importFile() } label: {
                                Text("+ IMPORT").monoLabel(10, color: AppColor.ink)
                                    .padding(.horizontal, 6).padding(.vertical, 4)
                            }

                            Text("NEWEST ↓").monoLabel(10, color: AppColor.inkSoft)
                        }
                        .padding(.horizontal, AppMetric.sheetPadding)

                        Spacer().frame(height: AppMetric.s)
                        searchField.padding(.horizontal, AppMetric.sheetPadding)
                        Spacer().frame(height: 6)

                        listRows
                    }
                }
                .scrollContentBackground(.hidden)
            }
        }
    }

    // MARK: - Metric strip

    private var metricStrip: some View {
        HStack(spacing: 0) {
            metricCell(value: "\(all.count)", label: "RECS")
            VRule().frame(height: 60)
            metricCell(value: formatHM(all.reduce(0) { $0 + $1.durationSeconds }), label: "TOTAL")
            VRule().frame(height: 60)
            let langs = Set(all.compactMap { $0.sourceLanguage }).count
            metricCell(value: "\(langs)", label: "LANGS")
        }
        .frame(height: 72)
        .padding(.horizontal, AppMetric.sheetPadding)
    }

    private func metricCell(value: String, label: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            BigNumber(value, size: 30)
            Text(label).monoLabel(9, color: AppColor.inkSoft)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
    }

    // MARK: - Search field

    private var searchField: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text("FIND").monoLabel(9, color: AppColor.inkMuted)
                TextField("title or transcript", text: $query)
                    .textFieldStyle(.plain)
                    .font(AppFont.inter(13))
                    .foregroundStyle(AppColor.ink)
                    .tint(AppColor.accent)
                if !query.isEmpty {
                    TapButton { query = "" } label: {
                        Text("✕").monoLabel(11, color: AppColor.inkMuted)
                    }

                }
            }
            Hairline()
        }
    }

    // MARK: - Rows

    private var listRows: some View {
        let rows = filtered
        // Plain VStack, deliberately: LazyVStack re-estimates row heights
        // whenever @Query re-fires (every chunk append during a run), which
        // made the scroll position wobble. The library is small; laziness
        // bought nothing and cost stability.
        return VStack(spacing: 0) {
            if rows.isEmpty {
                Text(query.isEmpty
                     ? "NO RECORDINGS YET · TAP + IMPORT"
                     : "NO MATCHES FOR “\(query)”")
                    .monoLabel(10, color: AppColor.inkMuted)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(AppMetric.l)
            }
            ForEach(rows, id: \.id) { rec in
                TapButton {
                    selection = rec
                } label: {
                    recordingRow(rec, selected: selection?.id == rec.id)
                }

                .contextMenu {
                    Button("Reveal in Finder") {
                        let url = URL(fileURLWithPath: rec.audioPath)
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    }
                    Menu("Move to Folder…") {
                        ForEach(allFolders.filter { $0.id != rec.folder?.id }, id: \.id) { folder in
                            Button(folder.name) {
                                try? container.repository.move(rec, to: folder)
                            }
                        }
                        if rec.folder != nil {
                            Divider()
                            Button("Remove from Folder") {
                                try? container.repository.move(rec, to: nil)
                            }
                        }
                    }
                    if rows.count > 1 {
                        Menu("Merge with…") {
                            ForEach(rows.filter { $0.id != rec.id }, id: \.id) { other in
                                Button("\(other.title)") {
                                    Task { @MainActor in
                                        do {
                                            let merged = try await container.repository.merge(rec, other)
                                            selection = merged
                                        } catch {
                                            AppLog.error("library", "merge failed: \(error.localizedDescription)")
                                            let alert = NSAlert()
                                            alert.messageText = "Merge failed"
                                            alert.informativeText = error.localizedDescription
                                            alert.runModal()
                                        }
                                    }
                                }
                            }
                        }
                    }
                    Divider()
                    Button("Delete", role: .destructive) {
                        if selection?.id == rec.id { selection = nil }
                        // Delete through the VIEW's context — @Query observes
                        // this context, and deleting a view-context object via
                        // the repository's separate context is a no-op (the
                        // row never disappeared).
                        context.delete(rec)
                        try? context.save()
                    }
                }
                HairlineSoft()
            }
        }
        .padding(.horizontal, AppMetric.sheetPadding)
    }

    private func recordingRow(_ rec: Recording, selected: Bool) -> some View {
        let createdDate = Date(timeIntervalSince1970: TimeInterval(rec.createdAtMillis / 1000))
        let isToday = Calendar.current.isDateInToday(createdDate)

        return HStack(alignment: .top, spacing: AppMetric.m) {
            VStack(alignment: .leading, spacing: 2) {
                Text(timeOnly(createdDate))
                    .font(AppFont.saira(14, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(AppColor.ink)
                Text(dayOnly(createdDate))
                    .monoLabel(9, color: AppColor.inkMuted)
            }
            .frame(width: 54, alignment: .leading)

            VStack(alignment: .leading, spacing: 4) {
                Text(rec.title)
                    .font(AppFont.inter(15))
                    .foregroundStyle(AppColor.ink)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                HStack(spacing: 6) {
                    if let lang = rec.sourceLanguage, !lang.isEmpty {
                        Text(lang.uppercased()).monoLabel(9, color: AppColor.inkSoft)
                        Text("·").monoLabel(9, color: AppColor.inkMuted)
                    }
                    if rec.translateToEnglish {
                        Text("TRANSLATED").monoLabel(9, color: AppColor.inkSoft)
                        Text("·").monoLabel(9, color: AppColor.inkMuted)
                    }
                    if isToday {
                        Rectangle().fill(AppColor.accent).frame(width: 5, height: 5)
                        Text("TODAY").monoLabel(9, color: AppColor.accent)
                    }
                    if let folder = rec.folder {
                        Text("▸ \(folder.name.uppercased())").monoLabel(9, color: AppColor.inkSoft)
                    }
                    ForEach(rec.tags.sorted { $0.name < $1.name }, id: \.id) { tag in
                        Text("#\(tag.name.uppercased())").monoLabel(9, color: AppColor.inkMuted)
                    }
                    Spacer(minLength: 0)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .trailing, spacing: 3) {
                Text(formatDuration(rec.durationSeconds))
                    .font(AppFont.saira(16, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(AppColor.ink)
                jobIndicator(for: rec)
            }
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(selected ? AppColor.accent.opacity(0.10) : Color.clear)
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(selected ? AppColor.accent : Color.clear)
                .frame(width: 3)
        }
        .contentShape(Rectangle())
    }

    /// Small per-row status pill: pulses orange while the recording is being
    /// transcribed; red if the last job failed; nothing once successfully done.
    @ViewBuilder
    private func jobIndicator(for rec: Recording) -> some View {
        if let status = container.jobManager.statuses[rec.id] {
            if status.failed {
                Text("FAILED").monoLabel(8, color: .red)
            } else if status.fraction < 1.0 {
                HStack(spacing: 4) {
                    PulseDot(diameter: 5)
                    Text("\(Int((status.fraction * 100).rounded()))%")
                        .monoLabel(8, color: AppColor.accent)
                        .monospacedDigit()
                }
            }
        }
    }

    // MARK: - Data

    private var filtered: [Recording] {
        // Folder → tag → search: search always operates within the active
        // folder/tag scope.
        var rows = all
        if let folderID = selectedFolderID {
            rows = rows.filter { $0.folder?.id == folderID }
        }
        if let tagID = selectedTagID {
            rows = rows.filter { rec in rec.tags.contains { $0.id == tagID } }
        }
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return rows }
        return rows.filter { rec in
            rec.title.lowercased().contains(q)
            || rec.segments.contains { $0.text.lowercased().contains(q) }
        }
    }

    private func countSummary() -> String {
        switch all.count {
        case 0: return "No recordings yet. Tap + Import or open the Record tab."
        case 1: return "1 recording on disk."
        default: return "\(all.count) recordings on disk."
        }
    }

    // MARK: - Import

    private func importFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [
            .audio, .wav, .mp3, .mpeg4Audio,
            UTType("public.aiff-audio") ?? .audio,
            UTType("org.xiph.flac") ?? .audio,
        ]
        panel.prompt = "Import"
        guard panel.runModal() == .OK, let src = panel.url else { return }
        Task { await performImport(src: src) }
    }

    private func performImport(src: URL) async {
        let dir = FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Transcriberr/Recordings", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appendingPathComponent(src.lastPathComponent)

        do {
            if src.path != dest.path {
                if FileManager.default.fileExists(atPath: dest.path) {
                    try FileManager.default.removeItem(at: dest)
                }
                try FileManager.default.copyItem(at: src, to: dest)
            }
            let duration = await readDuration(of: dest)
            let title = src.deletingPathExtension().lastPathComponent
            let rec = Recording(
                title: title,
                audioPath: dest.path,
                durationSeconds: duration
            )
            try container.repository.save(rec)
            selection = rec
        } catch {
            importError = error.localizedDescription
        }
    }

    private func readDuration(of url: URL) async -> Double {
        let asset = AVURLAsset(url: url)
        let dur = try? await asset.load(.duration)
        guard let dur, dur.isValid, dur.seconds.isFinite else { return 0 }
        return dur.seconds
    }

    // MARK: - Formatting

    private func formatDuration(_ s: Double) -> String {
        let total = Int(s)
        let h = total / 3600
        let m = (total % 3600) / 60
        let sec = total % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, sec) }
        return String(format: "%02d:%02d", m, sec)
    }

    private func formatHM(_ s: Double) -> String {
        let total = Int(s)
        let h = total / 3600
        let m = (total % 3600) / 60
        if h > 0 { return "\(h)h\(m)m" }
        return "\(m)m"
    }

    private static let timeF: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()
    private static let dayF: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "d MMM"
        return f
    }()
    private func timeOnly(_ d: Date) -> String { Self.timeF.string(from: d) }
    private func dayOnly(_ d: Date) -> String { Self.dayF.string(from: d).uppercased() }
}
