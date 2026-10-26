import SwiftUI

/// Settings → AI assistants: whether Claude and other assistants may read
/// the library through the Transcriberr MCP server (`transcriberrcli mcp`)
/// and `transcriberrcli kb`. They can only ever read, never change
/// anything; off, they cannot read either.
struct AssistantsSettingsSection: View {
    @AppStorage(AssistantAccess.allowedKey) private var allowed = true
    @State private var lastRead = AssistantAccess.lastRead

    var body: some View {
        VStack(alignment: .leading, spacing: AppMetric.s) {
            Toggle(isOn: $allowed) {
                Text("Let AI assistants read my library")
                    .font(AppFont.text(13, weight: .bold))
            }
            .toggleStyle(.switch)
            Text(allowed
                 ? "Claude and other assistants connected to Transcriberr can list, search and read your transcripts, outputs, folders and tags. They can never change or delete anything."
                 : "Off: assistants see no Transcriberr tools, and one that is already connected gets a refusal on its next request. Nothing in the library can be read.")
                .font(AppFont.text(11)).foregroundStyle(AppColor.ink2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 520, alignment: .leading)
            Text(lastRead.map { "Last read by an assistant \($0.formatted(.relative(presentation: .named)))." }
                 ?? "No assistant has read the library yet.")
                .font(AppFont.text(11)).foregroundStyle(AppColor.ink3)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear { lastRead = AssistantAccess.lastRead }
        .onChange(of: allowed) { lastRead = AssistantAccess.lastRead }
    }
}
