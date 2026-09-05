import SwiftUI

/// In-window settings (selected from the sidebar). Wraps the existing
/// macOS-Settings-scene tabs in the editorial Sheet so the look stays
/// consistent with the rest of the app.
struct SettingsScreen: View {
    @Environment(AppContainer.self) private var container

    var body: some View {
        Sheet {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    BrandStrip {
                        Text("ON-DEVICE").monoLabel(9, color: AppColor.inkMuted)
                    }
                    .padding(.horizontal, AppMetric.sheetPadding)
                    .padding(.top, AppMetric.sheetVerticalPadding)

                    Spacer().frame(height: AppMetric.sheetVerticalPadding)
                    InkRule()
                    Spacer().frame(height: AppMetric.l)

                    SectionIndex(4, "SETTINGS",
                                 summary: "Per-recording overrides live in the Library detail Run sheet. Everything here is global defaults.")
                        .padding(.horizontal, AppMetric.sheetPadding)

                    Spacer().frame(height: AppMetric.l)

                    // Embedded Form/List tabs need explicit heights (they
                    // collapse inside a ScrollView) and hidden system
                    // backgrounds (white grouped chrome clashes with paper).
                    sectionBlock("A", "AUDIO INPUT") {
                        RecorderSettingsTab()
                    }

                    sectionBlock("B", "ENGINES") {
                        EnginesSettingsTab()
                            .scrollContentBackground(.hidden)
                            .frame(minHeight: 430)
                    }

                    sectionBlock("C", "MODELS") {
                        ModelsSettingsTab()
                    }

                    sectionBlock("D", "POST-PROCESSING PRESETS") {
                        PresetsSettingsTab()
                    }

                    sectionBlock("E", "STYLE & VOCABULARY") {
                        StyleSettingsTab()
                            .scrollContentBackground(.hidden)
                            .frame(minHeight: 900)
                    }

                    sectionBlock("F", "SNIPPETS") {
                        SnippetsSettingsTab()
                            .scrollContentBackground(.hidden)
                            .frame(minHeight: 260)
                    }

                    sectionBlock("G", "GEMMA PROMPTS") {
                        PromptsSettingsTab()
                            .scrollContentBackground(.hidden)
                            .frame(minHeight: 480)
                    }

                    sectionBlock("H", "API KEYS") {
                        APIKeysSettingsTab()
                            .scrollContentBackground(.hidden)
                            .frame(minHeight: 480)
                    }

                    sectionBlock("I", "DICTATION") {
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
                    .monoLabel(11, color: AppColor.accent)
                Text(label)
                    .monoLabel(11, color: AppColor.ink)
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
