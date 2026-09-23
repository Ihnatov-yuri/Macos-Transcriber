import SwiftUI
import SwiftData

// Folder + tag organization chrome for the Library and Detail screens.
// Small eyebrow labels, chips, hairlines — no system list/outline chrome.

// MARK: - FolderStrip

/// Wrap-layout chip row: All · one chip per folder (Name (count)) · + New.
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
            chip(label: "All", selected: selectedFolderID == nil) {
                selectedFolderID = nil
            }
            ForEach(folders.filter { !$0.isDictation }, id: \.id) { folder in
                chip(label: "\(folder.name) (\(folder.recordings.count))",
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
            chip(label: "+ New", selected: false, muted: true) {
                folderName = ""
                newFolderPrompt = true
            }
            // Dictation history: out of "All", reachable here, set apart
            // at the end. No rename/delete menu — dictation looks it up by name.
            if let history = folders.first(where: \.isDictation) {
                chip(label: "Dictation history (\(history.recordings.count))",
                     selected: selectedFolderID == history.id,
                     muted: selectedFolderID != history.id) {
                    selectedFolderID = history.id
                }
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
                .uiLabel(9, color: selected ? AppColor.accentOnLight
                                  : muted ? AppColor.ink3 : AppColor.ink)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(selected ? AppColor.accent.opacity(0.10) : Color.clear)
                .overlay(alignment: .bottom) {
                    Rectangle()
                        .fill(selected ? AppColor.accent : AppColor.hair)
                        .frame(height: selected ? 2 : 1)
                }
        }
    }
}

// MARK: - TagFilterMenu

/// Compact `Tag: All ▾` menu — a chip-wrap of every tag would crowd the
/// 380 pt list column.
struct TagFilterMenu: View {
    let tags: [Tag]
    @Binding var selectedTagID: UUID?

    private var selectedName: String {
        tags.first { $0.id == selectedTagID }?.name ?? "All"
    }

    var body: some View {
        Menu {
            Button("All") { selectedTagID = nil }
            Divider()
            ForEach(tags, id: \.id) { tag in
                Button("\(tag.name) (\(tag.recordings.count))") { selectedTagID = tag.id }
            }
        } label: {
            Text("Tag: \(selectedName) ▾")
                .uiLabel(9, color: selectedTagID == nil ? AppColor.ink2 : AppColor.accentOnLight)
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
            Text("Tags").uiLabel(9, color: AppColor.ink3)
            ForEach(recording.tags.sorted { $0.name < $1.name }, id: \.id) { tag in
                HStack(spacing: 5) {
                    Text(tag.name).uiLabel(9)
                    TapButton {
                        try? container.repository.removeTag(tag, from: recording)
                    } label: {
                        Text("✕").uiLabel(9, color: AppColor.ink3)
                    }
                }
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
                .overlay(alignment: .bottom) {
                    Rectangle().fill(AppColor.hair).frame(height: 1)
                }
            }
            TextField("add tag…", text: $draft)
                .textFieldStyle(.plain)
                .font(AppFont.text(11))
                .foregroundStyle(AppColor.ink)
                .tint(AppColor.accentOnLight)
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
