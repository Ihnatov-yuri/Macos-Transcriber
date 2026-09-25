import AppKit
import SwiftUI

/// Settings → Updates. The new-release check, and exactly what it sends.
struct UpdatesSettingsTab: View {
    @Environment(AppContainer.self) private var container

    var body: some View {
        let u = container.updates
        Form {
            Section {
                Toggle("Check for new versions once a day",
                       isOn: Binding(get: { u.autoCheck }, set: { u.autoCheck = $0 }))
                HStack {
                    Text("This Mac runs \(u.currentVersion)")
                    Spacer()
                    Text(statusText(u)).foregroundStyle(.secondary)
                    if case .available(let r) = u.status {
                        TapButton { NSWorkspace.shared.open(r.pageURL) } label: {
                            LitButtonChrome(.ghost, compact: true) { Text("What's new…") }
                        }
                    }
                    TapButton { Task { await u.check() } } label: {
                        LitButtonChrome(.secondary, compact: true) { Text("Check now") }
                    }
                    .disabled(u.status == .checking)
                }
                Text("The check reads the public “latest release” record of the Transcriberr repository on GitHub. The request is the same on every Mac: it carries no version, account, identifier, locale or cookie, and the comparison with this copy happens here, so GitHub can't tell whether you're up to date. Like any request it reveals your IP address to GitHub; turn the check off and nothing is sent. Nothing is downloaded or installed — the notice links to the release page.")
                    .font(AppFont.text(12)).foregroundStyle(AppColor.ink3)
            }
        }
        .formStyle(.grouped)
    }

    private func statusText(_ u: UpdateChecker) -> String {
        switch u.status {
        case .checking: return "Checking…"
        case .upToDate: return "Up to date"
        case .available(let r): return "\(r.version) is available"
        case .failed(let why): return why
        case .idle:
            guard let last = u.lastCheck else { return "Not checked yet" }
            return "Checked \(last.formatted(.relative(presentation: .named)))"
        }
    }
}
