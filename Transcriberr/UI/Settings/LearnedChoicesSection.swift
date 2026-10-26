import SwiftUI

/// Settings → Style & vocabulary: the disputed words the user settled by
/// hand (`DisputeLearning`). The vote obeys each one, so a wrong click must
/// be easy to take back.
struct LearnedChoicesSection: View {
    @State private var pairs: [String] = []
    @State private var showAll = false

    var body: some View {
        Section("Your word choices") {
            if pairs.isEmpty {
                Text("None yet. Click an underlined word in a Super transcript to use the other engine's reading; Super then picks that reading whenever the engines split the same way.")
                    .font(AppFont.text(12)).foregroundStyle(AppColor.ink3)
            } else {
                FlowLayout(spacing: 6) {
                    ForEach(showAll ? pairs : Array(pairs.prefix(LearnedTermsSection.folded)), id: \.self) { pair in
                        let parts = pair.split(separator: ">", maxSplits: 1).map(String.init)
                        WordChip(parts.last ?? "", struck: parts.first ?? "",
                                 help: "Super picks “\(parts.last ?? "")” over “\(parts.first ?? "")” when the engines split this way. × forgets the choice.",
                                 remove: {
                                     DisputeLearning.remove(pair)
                                     pairs = DisputeLearning.ordered()
                                 })
                    }
                }
                if pairs.count > LearnedTermsSection.folded {
                    TapButton { showAll.toggle() } label: {
                        Text(showAll ? "Show fewer" : "Show all \(pairs.count)")
                            .font(AppFont.text(12)).foregroundStyle(AppColor.accentOnLight)
                    }
                }
                Text("Names you chose also went into your vocabulary above; remove them there.")
                    .font(AppFont.text(12)).foregroundStyle(AppColor.ink3)
            }
        }
        .onAppear { pairs = DisputeLearning.ordered() }
    }
}
