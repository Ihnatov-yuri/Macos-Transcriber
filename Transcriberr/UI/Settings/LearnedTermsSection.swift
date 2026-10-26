import SwiftUI

/// Settings → Style & Vocabulary: names harvested from the user's own
/// transcripts, with one-click promotion into the permanent list.
struct LearnedTermsSection: View {
    @Environment(AppContainer.self) private var container
    @State private var showAll = false
    static let folded = 16

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
                    .font(AppFont.text(12)).foregroundStyle(AppColor.ink3)
            } else {
                // Chips that wrap: one line used to hold one name, forty
                // names took a screen and a half.
                FlowLayout(spacing: 6) {
                    ForEach(showAll ? terms : Array(terms.prefix(Self.folded))) { term in
                        WordChip(term.spelling,
                                 help: "\(term.recordings) recordings · \(term.occurrences)×. + adds it to your vocabulary; × hides it for good.",
                                 add: { c.addToVocabulary(term.spelling) },
                                 remove: { c.dismissSuggestion(term.spelling) })
                    }
                }
                HStack(spacing: AppMetric.m) {
                    if terms.count > Self.folded {
                        TapButton { showAll.toggle() } label: {
                            Text(showAll ? "Show fewer" : "Show all \(terms.count)")
                                .font(AppFont.text(12)).foregroundStyle(AppColor.accentOnLight)
                        }
                    }
                    Spacer()
                    TapButton { for t in terms { c.addToVocabulary(t.spelling) } } label: {
                        LitButtonChrome(.ghost, compact: true) { Text("Add all \(terms.count)") }
                    }
                    TapButton { c.refreshLearnedTerms() } label: {
                        LitButtonChrome(.ghost, compact: true) { Text("Rescan library") }
                    }
                }
            }
            Text("A capitalized word that recurs across recordings and never appears as an ordinary lowercase word is treated as a name. Learned names are applied to dictation (exact spelling, never fuzzy) and offered here; Add makes one permanent, × hides it for good.")
                .font(AppFont.text(12)).foregroundStyle(AppColor.ink3)
        }
    }
}

/// One word as a small pill: the word, then + (keep) and/or × (drop).
struct WordChip: View {
    let word: String
    var struck: String? = nil
    let help: String
    var add: (() -> Void)? = nil
    var remove: (() -> Void)? = nil

    init(_ word: String, struck: String? = nil, help: String,
         add: (() -> Void)? = nil, remove: (() -> Void)? = nil) {
        self.word = word
        self.struck = struck
        self.help = help
        self.add = add
        self.remove = remove
    }

    var body: some View {
        HStack(spacing: 5) {
            if let struck {
                Text(struck).strikethrough().foregroundStyle(AppColor.ink3)
                Text("→").foregroundStyle(AppColor.ink3)
            }
            Text(word).foregroundStyle(AppColor.ink)
            if let add {
                TapButton(action: add) {
                    Image(systemName: "plus").font(.system(size: 9, weight: .bold)).foregroundStyle(AppColor.ink2)
                }
                .accessibilityLabel("Add \(word) to vocabulary")
            }
            if let remove {
                TapButton(action: remove) {
                    Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(AppColor.ink3)
                }
                .accessibilityLabel("Remove \(word)")
            }
        }
        .font(AppFont.text(12))
        .lineLimit(1)
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(Capsule().fill(Color.white.opacity(0.66)).overlay(Capsule().stroke(AppColor.hair)))
        .help(help)
    }
}
