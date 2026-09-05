import SwiftUI

/// Settings → Style & Vocabulary: names harvested from the user's own
/// transcripts, with one-click promotion into the permanent list.
struct LearnedTermsSection: View {
    @Environment(AppContainer.self) private var container

    var body: some View {
        let s = container.dictationSettings
        let c = container.dictation
        Section("Learned from your transcripts") {
            Toggle("Use learned names in dictation automatically",
                   isOn: Binding(get: { s.useLearnedTerms }, set: { s.useLearnedTerms = $0 }))
            let terms = s.learnedTerms.filter { !s.dismissedTermKeys.contains($0.key) }
            if terms.isEmpty {
                Text(s.learnedAt == nil
                     ? "Scanning the library…"
                     : "Nothing new — every recurring name is already in your vocabulary.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(terms.prefix(40)) { term in
                    HStack {
                        Text(term.spelling)
                        Text("\(term.recordings) recordings · \(term.occurrences)×")
                            .font(.caption2).foregroundStyle(.secondary)
                        Spacer()
                        Button("Add") { c.addToVocabulary(term.spelling) }
                            .buttonStyle(.borderless)
                        Button {
                            c.dismissSuggestion(term.spelling)
                        } label: { Image(systemName: "xmark.circle") }
                            .buttonStyle(.borderless)
                    }
                }
                if terms.count > 40 {
                    Text("…and \(terms.count - 40) more, applied automatically while the toggle above is on.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    Button("Add all \(terms.count)") { for t in terms { c.addToVocabulary(t.spelling) } }
                    Button("Rescan library") { c.refreshLearnedTerms() }
                }
            }
            Text("A capitalized word that recurs across recordings and never appears as an ordinary lowercase word is treated as a name. Learned names are applied to dictation (exact spelling, never fuzzy) and offered here; Add makes one permanent, × hides it for good.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
