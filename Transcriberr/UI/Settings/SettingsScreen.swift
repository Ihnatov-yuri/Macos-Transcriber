import SwiftUI

/// In-window settings (selected from the sidebar). Wraps the existing
/// macOS-Settings-scene tabs in Sheet so the look stays consistent with
/// the rest of the app.
struct SettingsScreen: View {
    @Environment(AppContainer.self) private var container

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

                    SectionIndex(4, "Settings",
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
        VStack(alignment: .leading, spacing: 0) {
            Spacer().frame(height: AppMetric.l)
            InkRule()
            HStack(spacing: 0) {
                Text("\(letter) · ")
                    .uiLabel(11, color: AppColor.accentOnLight)
                Text(label)
                    .uiLabel(11)
                Spacer()
            }
            .padding(.horizontal, AppMetric.sheetPadding)
            .padding(.vertical, 14)
            HairlineSoft()
            Spacer().frame(height: 12)
            content()
                .padding(.horizontal, AppMetric.sheetPadding)
        }
    }
}
