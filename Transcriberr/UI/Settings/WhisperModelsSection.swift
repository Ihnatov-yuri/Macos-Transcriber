import SwiftUI

/// Whisper models in the Models tab: which are on disk, the one in use, and
/// Download / Delete for each. The engine picks its model in the Engines tab.
struct WhisperModelsSection: View {
    @AppStorage(WhisperModel.settingsKey) private var selected = WhisperModel.defaultID
    @State private var downloads = WhisperDownloads.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Whisper").uiLabel(10, color: AppColor.ink2)
            Text("argmaxinc/whisperkit-coreml · stored in ~/Documents/huggingface · the model in use is picked in the Engines tab")
                .uiLabel(9, color: AppColor.ink3)
            VStack(spacing: 0) {
                ForEach(WhisperModel.all) { model in
                    WhisperModelRow(model: model, inUse: model.id == WhisperModel.model(selected).id,
                                    downloads: downloads, select: { selected = model.id })
                    HairlineSoft()
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct WhisperModelRow: View {
    let model: WhisperModel
    let inUse: Bool
    let downloads: WhisperDownloads
    let select: () -> Void
    @State private var confirmingDelete = false

    var body: some View {
        // Read so the row redraws after a download or delete finishes.
        let _ = downloads.revision
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: AppMetric.m) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Whisper \(model.name)")
                        .font(AppFont.display(14, weight: .semibold))
                        .foregroundStyle(AppColor.ink)
                    Text(model.note)
                        .font(AppFont.text(12))
                        .foregroundStyle(AppColor.ink2)
                    Text(model.id).uiLabel(9, color: AppColor.ink3)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 6) {
                    Text(size(model.sizeBytes)).uiLabel(10, color: AppColor.ink2)
                    actions
                }
                .frame(minWidth: 130, alignment: .trailing)
            }
            if let p = downloads.progress[model.id] {
                ProgressView(value: p) {
                    Text("Downloading… \(Int(p * 100))%").uiLabel(9, color: AppColor.ink2)
                }
                .progressViewStyle(.linear)
                .tint(AppColor.accent)
            }
            if let failure = downloads.failures[model.id] {
                Text("Download failed: \(failure)")
                    .font(AppFont.text(11))
                    .foregroundStyle(AppColor.accentOnLight)
            }
        }
        .padding(.vertical, AppMetric.s)
    }

    @ViewBuilder
    private var actions: some View {
        if downloads.isDownloading(model.id) {
            TapButton { downloads.cancel(model.id) } label: {
                LitButtonChrome(.secondary, compact: true) { Text("Cancel") }
            }
        } else if model.isDownloaded {
            VStack(alignment: .trailing, spacing: 4) {
                Text(inUse ? "In use" : "Installed").uiLabel(10, color: AppColor.accentOnLight)
                HStack(spacing: 6) {
                    if !inUse {
                        TapButton(action: select) {
                            LitButtonChrome(.secondary, compact: true) { Text("Use") }
                        }
                    }
                    TapButton { confirmingDelete = true } label: {
                        LitButtonChrome(.destructive, compact: true) { Text("Delete") }
                    }
                }
            }
            .confirmationDialog("Delete Whisper \(model.name)?", isPresented: $confirmingDelete, titleVisibility: .visible) {
                Button("Delete", role: .destructive) { downloads.delete(model) }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(inUse
                     ? "This is the model in use: Whisper downloads it again the next time it runs. Removes \(model.folder.path)."
                     : "Removes \(model.folder.path).")
            }
        } else {
            TapButton { downloads.download(model) } label: {
                LitButtonChrome(.primary, compact: true) { Text("Download") }
            }
        }
    }

    private func size(_ b: Int64) -> String {
        let mb = Double(b) / 1_000_000
        return mb < 1000 ? String(format: "%.0f MB", mb) : String(format: "%.1f GB", mb / 1000)
    }
}
