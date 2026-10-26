import SwiftUI

/// In-window settings (selected from the sidebar). Wraps the existing
/// macOS-Settings-scene tabs in Sheet so the look stays consistent with
/// the rest of the app.
struct SettingsScreen: View {
    @Environment(AppContainer.self) private var container
    /// Letters of the sections folded away, kept between launches. Style &
    /// vocabulary starts folded: it is the longest and the least visited.
    @AppStorage("settings.collapsed") private var collapsedRaw = "E"
    private var collapsed: Set<String> { Set(collapsedRaw.split(separator: ",").map(String.init)) }

    private func toggle(_ letter: String) {
        var c = collapsed
        if c.contains(letter) { c.remove(letter) } else { c.insert(letter) }
        collapsedRaw = c.sorted().joined(separator: ",")
    }

    var body: some View {
        Sheet {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    BrandStrip {
                        Text("On-device").uiLabel(9, color: AppColor.ink3)
                    }
                    .padding(.horizontal, AppMetric.sheetPadding)
                    .padding(.top, AppMetric.sheetVerticalPadding)

                    Spacer().frame(height: AppMetric.sheetVerticalPadding)
                    InkRule()
                    Spacer().frame(height: AppMetric.l)

                    SectionIndex(5, "Settings",
                                 summary: "Per-recording overrides live in the Library detail Run sheet. Everything here is global defaults.")
                        .padding(.horizontal, AppMetric.sheetPadding)

                    Spacer().frame(height: AppMetric.l)

                    // Embedded Form/List tabs need explicit heights (they
                    // collapse inside a ScrollView) and hidden system
                    // backgrounds (white grouped chrome clashes with the
                    // surrounding base fill).
                    sectionBlock("A", "Audio input") {
                        RecorderSettingsTab()
                    }

                    sectionBlock("B", "Engines") {
                        EnginesSettingsTab()
                            .scrollContentBackground(.hidden)
                            .frame(minHeight: 430)
                    }

                    sectionBlock("C", "Models") {
                        ModelsSettingsTab()
                    }

                    sectionBlock("D", "Post-processing presets") {
                        PresetsSettingsTab()
                    }

                    sectionBlock("E", "Style & vocabulary") {
                        StyleSettingsTab()
                            .scrollContentBackground(.hidden)
                            .frame(minHeight: 900)
                    }

                    sectionBlock("F", "Snippets") {
                        SnippetsSettingsTab()
                            .scrollContentBackground(.hidden)
                            .frame(minHeight: 260)
                    }

                    sectionBlock("G", "Gemma prompts") {
                        PromptsSettingsTab()
                            .scrollContentBackground(.hidden)
                            .frame(minHeight: 480)
                    }

                    sectionBlock("H", "API keys") {
                        APIKeysSettingsTab()
                            .scrollContentBackground(.hidden)
                            .frame(minHeight: 480)
                    }

                    sectionBlock("I", "Dictation") {
                        DictationSettingsTab()
                            .scrollContentBackground(.hidden)
                            .frame(minHeight: 760)
                    }

                    sectionBlock("J", "Updates") {
                        UpdatesSettingsTab()
                            .scrollContentBackground(.hidden)
                            .frame(minHeight: 200)
                    }

                    sectionBlock("K", "AI assistants") {
                        AssistantsSettingsSection()
                    }
                }
                .padding(.bottom, AppMetric.xl)
            }
        }
    }

    @ViewBuilder
    private func sectionBlock<Content: View>(
        _ letter: String,
        _ label: String,
        @ViewBuilder _ content: () -> Content
    ) -> some View {
        let open = !collapsed.contains(letter)
        VStack(alignment: .leading, spacing: 0) {
            Spacer().frame(height: AppMetric.l)
            InkRule()
            TapButton { withAnimation(.easeOut(duration: 0.15)) { toggle(letter) } } label: {
                HStack(spacing: 0) {
                    Text("\(letter) · ")
                        .uiLabel(11, color: AppColor.accentOnLight)
                    Text(label)
                        .uiLabel(11)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(AppColor.ink3)
                        .rotationEffect(.degrees(open ? 90 : 0))
                }
                .padding(.horizontal, AppMetric.sheetPadding)
                .padding(.vertical, 14)
                .contentShape(Rectangle())
            }
            .help(open ? "Fold \(label) away" : "Show \(label)")
            .accessibilityValue(open ? "expanded" : "collapsed")
            if open {
                HairlineSoft()
                Spacer().frame(height: 12)
                content()
                    .padding(.horizontal, AppMetric.sheetPadding)
            }
        }
    }
}
