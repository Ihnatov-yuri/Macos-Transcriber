import SwiftUI

/// Settings → Style & vocabulary: the checked references the user's
/// corrections have built (`Benchmark`), and how far the engines' own text
/// was from them.
struct BenchmarkSection: View {
    @State private var summary: [Benchmark.Summary] = []
    @State private var count = 0
    @State private var confirmDelete = false
    @AppStorage(Benchmark.enabledKey) private var enabled = true

    var body: some View {
        Section("Your benchmark") {
            Toggle("Keep corrected lines as a benchmark", isOn: $enabled)
                .onChange(of: enabled) { _, on in if !on { Benchmark.cancelQueued() } }
            Text("A line you correct keeps a copy of its audio (every voice in it) in Documents → Transcriberr Backups → benchmark. If Documents syncs to iCloud, so do these clips.")
                .font(AppFont.text(12)).foregroundStyle(AppColor.ink3)
            if summary.isEmpty {
                Text("Nothing yet. Fix a line of a transcript (long-press it), or choose More ⋯ → Mark transcript as checked, and that stretch of audio becomes a reference.")
                    .font(AppFont.text(12)).foregroundStyle(AppColor.ink3)
            } else {
                ForEach(summary, id: \.language) { s in
                    HStack {
                        Text(s.language)
                        Text("\(s.items) lines · \(minutes(s.seconds)) · \(s.words) words")
                            .font(.caption2).foregroundStyle(.secondary)
                        Spacer()
                        Text(String(format: "engine vs you: %.1f%% WER", s.wer * 100))
                            .font(.caption).foregroundStyle(AppColor.ink2)
                    }
                }
                Text("Each reference keeps its audio, the text you approved and the text the engine first wrote, so it survives re-runs. `transcriberrcli bench score` runs any engine on the whole set.")
                    .font(AppFont.text(12)).foregroundStyle(AppColor.ink3)
            }
            HStack {
                TapButton { reload() } label: {
                    LitButtonChrome(.ghost, compact: true) { Text("Refresh") }
                }
                TapButton {
                    try? FileManager.default.createDirectory(at: Benchmark.root, withIntermediateDirectories: true)
                    NSWorkspace.shared.open(Benchmark.root)
                } label: {
                    LitButtonChrome(.ghost, compact: true) { Text("Show in Finder") }
                }
                if count > 0 {
                    TapButton { confirmDelete = true } label: {
                        LitButtonChrome(.ghost, compact: true) { Text("Delete benchmark…") }
                    }
                }
            }
        }
        .onAppear { reload() }
        .confirmationDialog("Delete all \(count) checked lines and their audio clips?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) { Task { await Benchmark.deleteAll(); reload() } }
        }
    }

    private func reload() {
        let items = Benchmark.items()
        count = items.count
        summary = Benchmark.summary(items)
    }

    private func minutes(_ s: Double) -> String {
        s < 60 ? "\(Int(s)) s" : String(format: "%.1f min", s / 60)
    }
}
