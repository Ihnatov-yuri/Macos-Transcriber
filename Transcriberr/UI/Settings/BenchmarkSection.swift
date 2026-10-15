import SwiftUI

/// Settings → Style & vocabulary: the checked references the user's
/// corrections have built (`Benchmark`), and how far the engines' own text
/// was from them.
struct BenchmarkSection: View {
    @State private var summary: [Benchmark.Summary] = []
    @State private var count = 0

    var body: some View {
        Section("Your benchmark") {
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
            }
        }
        .onAppear { reload() }
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
