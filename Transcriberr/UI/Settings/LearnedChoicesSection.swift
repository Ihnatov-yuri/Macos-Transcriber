import SwiftUI

/// Settings → Style & vocabulary: the disputed words the user settled by
/// hand (`DisputeLearning`). The vote obeys each one, so a wrong click must
/// be easy to take back.
struct LearnedChoicesSection: View {
    @State private var pairs: [String] = []

    var body: some View {
        Section("Your word choices") {
            if pairs.isEmpty {
                Text("None yet. Click an underlined word in a Super transcript to use the other engine's reading; Super then picks that reading whenever the engines split the same way.")
                    .font(AppFont.text(12)).foregroundStyle(AppColor.ink3)
            } else {
                ForEach(pairs.prefix(60), id: \.self) { pair in
                    let parts = pair.split(separator: ">", maxSplits: 1).map(String.init)
                    HStack {
                        Text(parts.first ?? "").strikethrough().foregroundStyle(AppColor.ink3)
                        Text("→")
                        Text(parts.last ?? "")
                        Spacer()
                        TapButton {
                            DisputeLearning.remove(pair)
                            pairs = DisputeLearning.ordered()
                        } label: {
                            Image(systemName: "xmark.circle").foregroundStyle(AppColor.ink3)
                        }
                        .help("Forget this choice")
                    }
                }
                if pairs.count > 60 {
                    Text("…and \(pairs.count - 60) older ones.")
                        .font(AppFont.text(12)).foregroundStyle(AppColor.ink3)
                }
                Text("Names you chose also went into your vocabulary above; remove them there.")
                    .font(AppFont.text(12)).foregroundStyle(AppColor.ink3)
            }
        }
        .onAppear { pairs = DisputeLearning.ordered() }
    }
}
