import SwiftUI
import SwiftData

// Folder + tag organization chrome for the Library and Detail screens.
// Same editorial idiom as the rest of the UI: mono eyebrow labels, chips,
// hairlines — no system list/outline chrome.

// MARK: - FolderStrip

/// Wrap-layout chip row: ALL · one chip per folder (NAME (count)) · + NEW.
/// Selection is owned by the parent; folder CRUD goes through the repository.
struct FolderStrip: View {
    let folders: [Folder]
    @Binding var selectedFolderID: UUID?
    @Environment(AppContainer.self) private var container

    @State private var newFolderPrompt = false
    @State private var renamingFolder: Folder?
    @State private var folderName = ""
    @State private var organizeError: String?

    var body: some View {
        FlowLayout(spacing: 8) {
            chip(label: "ALL", selected: selectedFolderID == nil) {
                selectedFolderID = nil
            }
            ForEach(folders, id: \.id) { folder in
                chip(label: "\(folder.name.uppercased()) (\(folder.recordings.count))",
                     selected: selectedFolderID == folder.id) {
                    selectedFolderID = folder.id
                }
                .contextMenu {
                    Button("Rename…") {
                        folderName = folder.name
                        renamingFolder = folder
                    }
                    Button("Delete Folder", role: .destructive) {
                        if selectedFolderID == folder.id { selectedFolderID = nil }
                        try? container.repository.deleteFolder(folder)
                    }
                }
            }
            chip(label: "+ NEW", selected: false, muted: true) {
                folderName = ""
                newFolderPrompt = true
            }
        }
        .alert("New Folder", isPresented: $newFolderPrompt) {
            TextField("Name", text: $folderName)
            Button("Create") { commit { try container.repository.createFolder(named: folderName) } }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Rename Folder", isPresented: Binding(
            get: { renamingFolder != nil },
            set: { if !$0 { renamingFolder = nil } }
        )) {
            TextField("Name", text: $folderName)
            Button("Rename") {
                if let folder = renamingFolder {
                    commit { try container.repository.renameFolder(folder, to: folderName) }
                }
                renamingFolder = nil
            }
            Button("Cancel", role: .cancel) { renamingFolder = nil }
        }
        .alert("Folders", isPresented: Binding(
            get: { organizeError != nil },
            set: { if !$0 { organizeError = nil } }
        )) {
            Button("OK", role: .cancel) { organizeError = nil }
        } message: {
            Text(organizeError ?? "")
        }
    }

    private func commit(_ op: () throws -> some Any) {
        do { _ = try op() } catch { organizeError = error.localizedDescription }
    }

    private func chip(label: String, selected: Bool, muted: Bool = false,
                      action: @escaping () -> Void) -> some View {
        TapButton(action: action) {
            Text(label)
                .monoLabel(9, color: selected ? AppColor.accent
                                  : muted ? AppColor.inkMuted : AppColor.ink)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(selected ? AppColor.accent.opacity(0.10) : Color.clear)
                .overlay(alignment: .bottom) {
                    Rectangle()
                        .fill(selected ? AppColor.accent : AppColor.hairline)
                        .frame(height: selected ? 2 : 1)
                }
        }
    }
}

// MARK: - TagFilterMenu

/// Compact `TAG: ALL ▾` menu — a chip-wrap of every tag would crowd the
/// 380 pt list column.
struct TagFilterMenu: View {
    let tags: [Tag]
    @Binding var selectedTagID: UUID?

    private var selectedName: String {
        tags.first { $0.id == selectedTagID }?.name.uppercased() ?? "ALL"
    }

    var body: some View {
        Menu {
            Button("All") { selectedTagID = nil }
            Divider()
            ForEach(tags, id: \.id) { tag in
                Button("\(tag.name) (\(tag.recordings.count))") { selectedTagID = tag.id }
            }
        } label: {
            Text("TAG: \(selectedName) ▾")
                .monoLabel(9, color: selectedTagID == nil ? AppColor.inkSoft : AppColor.accent)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }
}

// MARK: - TagEditorRow

/// Detail-screen tag editor: current tags as chips with ✕, plus an inline
/// "add tag…" field committing on return or comma.
struct TagEditorRow: View {
    let recording: Recording
    @Environment(AppContainer.self) private var container
    @State private var draft = ""

    var body: some View {
        FlowLayout(spacing: 8) {
            Text("TAGS").monoLabel(9, color: AppColor.inkMuted)
            ForEach(recording.tags.sorted { $0.name < $1.name }, id: \.id) { tag in
                HStack(spacing: 5) {
                    Text(tag.name.uppercased()).monoLabel(9, color: AppColor.ink)
                    TapButton {
                        try? container.repository.removeTag(tag, from: recording)
                    } label: {
                        Text("✕").monoLabel(9, color: AppColor.inkMuted)
                    }
                }
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
                .overlay(alignment: .bottom) {
                    Rectangle().fill(AppColor.hairline).frame(height: 1)
                }
            }
            TextField("add tag…", text: $draft)
                .textFieldStyle(.plain)
                .font(AppFont.inter(11))
                .foregroundStyle(AppColor.ink)
                .tint(AppColor.accent)
                .frame(width: 90)
                .onSubmit { commitDraft() }
                .onChange(of: draft) { _, value in
                    if value.hasSuffix(",") {
                        draft = String(value.dropLast())
                        commitDraft()
                    }
                }
        }
    }

    private func commitDraft() {
        let name = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        draft = ""
        guard !name.isEmpty else { return }
        try? container.repository.addTag(named: name, to: recording)
    }
}
