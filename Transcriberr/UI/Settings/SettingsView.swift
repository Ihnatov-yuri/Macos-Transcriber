import SwiftUI

/// Mirror of `ui/settings/SettingsScreen.kt`.
/// Standard macOS `Settings { ... }` scene, sectioned with tabs.
struct SettingsView: View {
    var body: some View {
        TabView {
            EnginesSettingsTab()
                .tabItem { Label("Engines", systemImage: "waveform") }
            ModelsSettingsTab()
                .tabItem { Label("Models", systemImage: "shippingbox") }
            RecorderSettingsTab()
                .tabItem { Label("Audio Input", systemImage: "mic") }
            PromptsSettingsTab()
                .tabItem { Label("Prompts", systemImage: "text.bubble") }
            PresetsSettingsTab()
                .tabItem { Label("Presets", systemImage: "sparkles") }
            StyleSettingsTab()
                .tabItem { Label("Style", systemImage: "textformat") }
            SnippetsSettingsTab()
                .tabItem { Label("Snippets", systemImage: "text.append") }
            APIKeysSettingsTab()
                .tabItem { Label("API Keys", systemImage: "key") }
        }
        .padding(20)
    }
}

// MARK: - Tabs

/// Which engine does what. Speech-to-text runs on Parakeet / Whisper (or the
/// dual-engine merge); Gemma 4 is primarily the TEXT engine — summaries,
/// cleanup, translation, titles, merge arbitration — and is additionally
/// selectable as an EXPERIMENTAL audio engine (known to hallucinate).
struct EnginesSettingsTab: View {
    @Environment(AppContainer.self) private var container

    private var audioEngines: [BackendFactory.Kind] {
        BackendFactory.Kind.allCases.filter(\.supportsAudio)
    }
    private var mergeOptions: [BackendFactory.Kind] {
        BackendFactory.Kind.allCases.filter { $0.isLocal && $0.supportsAudio && $0 != .ensemble }
    }
    private var liveEngines: [BackendFactory.Kind] {
        BackendFactory.Kind.allCases.filter(\.supportsLive)
    }

    var body: some View {
        Form {
            Section("Speech-to-text") {
                Picker("Default engine", selection: Binding(
                    get: { container.uiPrefs.defaultBackend },
                    set: { container.uiPrefs.defaultBackend = $0 }
                )) {
                    ForEach(audioEngines, id: \.rawValue) { Text($0.displayName).tag($0) }
                }
                Picker("Live captions engine", selection: Binding(
                    get: { container.uiPrefs.liveEngine },
                    set: { container.uiPrefs.liveEngine = $0 }
                )) {
                    ForEach(liveEngines, id: \.rawValue) { Text($0.displayName).tag($0) }
                }
                Text("Speech models download automatically on first use: Parakeet v3/v2 (~1 GB each, Neural Engine) and Whisper large-v3 (~3 GB, CoreML).")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Super · dual-engine merge") {
                Picker("Merge engine A", selection: Binding(
                    get: { container.uiPrefs.ensembleEngineA },
                    set: { newValue in
                        // Keep A ≠ B: picking B's engine swaps them.
                        if newValue == container.uiPrefs.ensembleEngineB {
                            container.uiPrefs.ensembleEngineB = container.uiPrefs.ensembleEngineA
                        }
                        container.uiPrefs.ensembleEngineA = newValue
                    }
                )) {
                    ForEach(mergeOptions, id: \.rawValue) { Text($0.displayName).tag($0) }
                }
                Picker("Merge engine B", selection: Binding(
                    get: { container.uiPrefs.ensembleEngineB },
                    set: { newValue in
                        if newValue == container.uiPrefs.ensembleEngineA {
                            container.uiPrefs.ensembleEngineA = container.uiPrefs.ensembleEngineB
                        }
                        container.uiPrefs.ensembleEngineB = newValue
                    }
                )) {
                    ForEach(mergeOptions, id: \.rawValue) { Text($0.displayName).tag($0) }
                }
                Toggle("Max quality (slower): sequential chunks + conversation context for arbitration", isOn: Binding(
                    get: { container.uiPrefs.superMaxQuality },
                    set: { container.uiPrefs.superMaxQuality = $0 }
                ))
                Text("Both engines transcribe every chunk; disagreements are settled word-by-word by recognizer confidence. Gemma 4 arbitrates only hard conflicts — with Max quality on, it also sees the preceding transcript when doing so.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Speaker turns") {
                Picker("Turn granularity (diarized transcripts)", selection: Binding(
                    get: { container.uiPrefs.turnCoalesceGapSeconds },
                    set: { container.uiPrefs.turnCoalesceGapSeconds = $0 }
                )) {
                    Text("Smooth — readable blocks (default)").tag(30.0)
                    Text("Balanced — split on 10 s pauses").tag(10.0)
                    Text("Fine — keep every interjection").tag(2.0)
                }
                Text("How aggressively adjacent same-speaker segments merge into one turn. Fine matches phone-recorder granularity; applies to the next run.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Languages by engine") {
                LabeledContent("Parakeet v3", value: "25 European languages — en, de, nl, fr, es, it, pt, pl, uk, ru… (no Arabic/Asian)")
                LabeledContent("Parakeet v2", value: "English only — best English accuracy")
                LabeledContent("Whisper large-v3", value: "~100 languages incl. Arabic, Korean, Japanese, Chinese")
                LabeledContent("Gemma 4 LiteRT", value: "~140 languages incl. Gulf Arabic — strongest Arabic (as on Android)")
                Text("Recommendations: English → Parakeet v3 (or v2). European languages → Parakeet v3. Arabic → Gemma LiteRT (Whisper as second opinion). Korean/Japanese/Chinese → Whisper. Unsure or mixed → Whisper or Super merge.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Post-processing") {
                Picker("Text engine (summaries · cleanup · translation · titles)", selection: Binding(
                    get: { container.uiPrefs.textEngine },
                    set: { container.uiPrefs.textEngine = $0 }
                )) {
                    ForEach(BackendFactory.Kind.allCases.filter(\.supportsTextGeneration), id: \.rawValue) {
                        Text($0.displayName).tag($0)
                    }
                }
                Text("Gemma 4 (Google LiteRT) generates much faster than the MLX build on Apple GPUs; cloud engines need an API key. Preset prompt templates are editable in the Presets tab; transcription prompts in Prompts.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

struct ModelsSettingsTab: View {
    @Environment(AppContainer.self) private var container

    var body: some View {
        VStack(alignment: .leading, spacing: AppMetric.m) {
            // Speech models are managed automatically; this tab manages the
            // Gemma text model (downloaded explicitly — they're big).
            VStack(alignment: .leading, spacing: 4) {
                Text("SPEECH-TO-TEXT — PARAKEET V3 / V2 · WHISPER LARGE-V3 (AUTOMATIC)")
                    .monoLabel(10, color: AppColor.inkSoft)
                Text("Downloaded on first use (Parakeet ~1 GB each · Whisper ~3 GB) · cached in Application Support · engine choice in the Engines tab")
                    .monoLabel(9, color: AppColor.inkMuted)
            }
            Hairline()

            HairlineSoft()
            Text("CATALOG").monoLabel(10, color: AppColor.inkSoft)

            VStack(spacing: 0) {
                ForEach(ModelCatalog.entries, id: \.id) { entry in
                    ModelRow(entry: entry)
                    HairlineSoft()
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func format(_ b: Int64) -> String {
        let mb = Double(b) / 1_000_000
        if mb < 1000 { return String(format: "%.0f MB", mb) }
        return String(format: "%.1f GB", mb / 1000)
    }
}

private struct ModelRow: View {
    @Environment(AppContainer.self) private var container
    let entry: ModelEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: AppMetric.m) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.name)
                        .font(AppFont.inter(14, weight: .medium))
                        .foregroundStyle(AppColor.ink)
                    Text(entry.purpose)
                        .font(AppFont.inter(12))
                        .foregroundStyle(AppColor.inkSoft)
                    if let hf = entry.huggingFaceID {
                        Text(hf).monoLabel(9, color: AppColor.inkMuted)
                    }
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 6) {
                    Text(format(entry.sizeBytes)).monoLabel(10, color: AppColor.inkSoft)
                    actionButton
                }
                .frame(minWidth: 130, alignment: .trailing)
            }
            if let info = container.modelDownloader.progress[entry.id],
               container.modelDownloader.isDownloading.contains(entry.id) {
                ProgressView(value: info.fractionComplete) {
                    Text(info.status).monoLabel(9, color: AppColor.inkSoft)
                }
                .progressViewStyle(.linear)
                .tint(AppColor.accent)
            }
        }
        .padding(.vertical, AppMetric.s)
    }

    @State private var confirmingDelete = false

    @ViewBuilder
    private var actionButton: some View {
        if container.modelDownloader.isCached(entry) {
            VStack(alignment: .trailing, spacing: 4) {
                Text("INSTALLED").monoLabel(10, color: AppColor.accent)
                if let size = container.modelDownloader.diskSize(entry) {
                    Text(formatGB(size)).monoLabel(9, color: AppColor.inkMuted)
                }
                TapButton {
                    confirmingDelete = true
                } label: {
                    Text("DELETE")
                        .monoLabel(9, color: AppColor.paper)
                        .padding(.horizontal, AppMetric.s)
                        .padding(.vertical, 4)
                        .background(AppColor.inkSoft)
                }
            }
            .confirmationDialog(
                "Delete \(entry.name)?",
                isPresented: $confirmingDelete,
                titleVisibility: .visible
            ) {
                Button("Delete", role: .destructive) {
                    container.modelDownloader.deleteCached(entry)
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Removes the model from \(container.modelDownloader.localPath(entry)?.path ?? "disk").")
            }
        } else if container.modelDownloader.isDownloading.contains(entry.id) {
            TapButton {
                container.modelDownloader.cancel(entry.id)
            } label: {
                Text("CANCEL")
                    .monoLabel(10, color: AppColor.paper)
                    .padding(.horizontal, AppMetric.m)
                    .padding(.vertical, 6)
                    .background(AppColor.inkSoft)
            }

        } else {
            TapButton {
                Task { try? await container.modelDownloader.download(entry) }
            } label: {
                Text("DOWNLOAD")
                    .monoLabel(10, color: AppColor.paper)
                    .padding(.horizontal, AppMetric.m)
                    .padding(.vertical, 6)
                    .background(AppColor.ink)
            }

        }
    }

    private func format(_ b: Int64) -> String {
        let mb = Double(b) / 1_000_000
        if mb < 1000 { return String(format: "%.0f MB", mb) }
        return String(format: "%.1f GB", mb / 1000)
    }

    private func formatGB(_ b: Int64) -> String {
        let mb = Double(b) / 1_000_000
        if mb < 1000 { return String(format: "%.0f MB on disk", mb) }
        return String(format: "%.1f GB on disk", mb / 1000)
    }
}

struct RecorderSettingsTab: View {
    @State private var settings = RecorderSettings.shared

    var body: some View {
        VStack(alignment: .leading, spacing: AppMetric.m) {
            Text("Apple's voice-processing audio unit cleans up the input the same way FaceTime / Voice Memos do — echo cancellation, spectral noise suppression, AGC. Free and very effective.")
                .font(AppFont.inter(12))
                .foregroundStyle(AppColor.inkSoft)
                .frame(maxWidth: 520, alignment: .leading)

            Toggle(isOn: Binding(
                get: { settings.noiseSuppression },
                set: { settings.noiseSuppression = $0 }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Noise suppression while recording")
                        .font(AppFont.inter(13, weight: .medium))
                    Text("Recommended. Applied on the input node before each chunk is written.")
                        .font(AppFont.inter(11))
                        .foregroundStyle(AppColor.inkSoft)
                }
            }

            Toggle(isOn: Binding(
                get: { settings.preprocessImports },
                set: { settings.preprocessImports = $0 }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Pre-process imported files")
                        .font(AppFont.inter(13, weight: .medium))
                    Text("Runs the same cleanup over MP3 / M4A / WAV files before Gemma sees them. Adds a few seconds to the decode step.")
                        .font(AppFont.inter(11))
                        .foregroundStyle(AppColor.inkSoft)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct PromptsSettingsTab: View {
    @Environment(AppContainer.self) private var container
    var body: some View {
        Form {
            Section("Transcribe") {
                TextEditor(text: Binding(
                    get: { container.promptStore.transcribePrompt },
                    set: { container.promptStore.transcribePrompt = $0 }
                ))
                .font(AppFont.mono(12))
                .frame(minHeight: 100)
            }
            Section("Translate") {
                TextEditor(text: Binding(
                    get: { container.promptStore.translatePrompt },
                    set: { container.promptStore.translatePrompt = $0 }
                ))
                .font(AppFont.mono(12))
                .frame(minHeight: 100)
            }
        }
        .formStyle(.grouped)
    }
}

struct PresetsSettingsTab: View {
    @Environment(AppContainer.self) private var container

    var body: some View {
        VStack(alignment: .leading, spacing: AppMetric.m) {
            Text("EDITS SAVE AUTOMATICALLY · EXPAND A PRESET TO EDIT ITS PROMPTS")
                .monoLabel(9, color: AppColor.inkSoft)
            ForEach(container.presetStore.presets) { preset in
                DisclosureGroup(preset.name) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("SYSTEM").monoLabel(9, color: AppColor.inkSoft)
                        TextEditor(text: binding(for: preset.id, \.systemTemplate))
                            .font(AppFont.mono(11))
                            .frame(minHeight: 70)
                        Text("USER TEMPLATE").monoLabel(9, color: AppColor.inkSoft)
                        TextEditor(text: binding(for: preset.id, \.userTemplate))
                            .font(AppFont.mono(11))
                            .frame(minHeight: 110)
                    }
                    .padding(.vertical, 6)
                }
                .font(AppFont.inter(13))
                HairlineSoft()
            }
            TapButton { container.presetStore.resetToDefaults() } label: {
                Text("RESET ALL PRESETS TO DEFAULTS").monoLabel(9, color: AppColor.accent)
            }
        }
    }

    private func binding(for id: String, _ keyPath: WritableKeyPath<PostProcessingPreset, String>) -> Binding<String> {
        Binding(
            get: { container.presetStore.preset(id)?[keyPath: keyPath] ?? "" },
            set: { newValue in
                guard let idx = container.presetStore.presets.firstIndex(where: { $0.id == id }) else { return }
                container.presetStore.presets[idx][keyPath: keyPath] = newValue
            }
        )
    }
}

struct PresetEditor: View {
    @Environment(AppContainer.self) private var container
    let presetId: String

    var body: some View {
        if let idx = container.presetStore.presets.firstIndex(where: { $0.id == presetId }) {
            Form {
                TextField("Name", text: Binding(
                    get: { container.presetStore.presets[idx].name },
                    set: { container.presetStore.presets[idx].name = $0 }
                ))
                Section("System") {
                    TextEditor(text: Binding(
                        get: { container.presetStore.presets[idx].systemTemplate },
                        set: { container.presetStore.presets[idx].systemTemplate = $0 }
                    ))
                    .font(AppFont.mono(12))
                    .frame(minHeight: 80)
                }
                Section("User") {
                    TextEditor(text: Binding(
                        get: { container.presetStore.presets[idx].userTemplate },
                        set: { container.presetStore.presets[idx].userTemplate = $0 }
                    ))
                    .font(AppFont.mono(12))
                    .frame(minHeight: 140)
                }
            }
            .formStyle(.grouped)
        }
    }
}

struct StyleSettingsTab: View {
    @Environment(AppContainer.self) private var container
    var body: some View {
        Form {
            Picker("Tone", selection: Binding(
                get: { container.promptStore.tone },
                set: { container.promptStore.tone = $0 }
            )) {
                ForEach(PromptStore.Tone.allCases, id: \.self) { t in
                    Text(t.rawValue.capitalized).tag(t)
                }
            }
            Toggle("Remove fillers", isOn: Binding(
                get: { container.promptStore.removeFillers },
                set: { container.promptStore.removeFillers = $0 }
            ))
            Toggle("Verbatim", isOn: Binding(
                get: { container.promptStore.verbatim },
                set: { container.promptStore.verbatim = $0 }
            ))
            Section("Vocabulary — all languages") {
                TextEditor(text: Binding(
                    get: { container.promptStore.vocabulary },
                    set: { container.promptStore.vocabulary = $0 }
                ))
                .font(AppFont.mono(12))
                .frame(minHeight: 90)
                Text("Applied to every run. Names that work in any language (people, companies).")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Vocabulary — per language") {
                VocabularyByLanguageEditor()
                Text("Injected only when a run's LANG matches — keeps Ukrainian runs free of English terms and vice versa.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Domain packs") {
                ForEach(DomainVocabulary.Pack.allCases, id: \.self) { pack in
                    // TapButton — inline Button capturing @Observable container
                    // hits the macOS 26.5 _ButtonGesture crash.
                    TapButton {
                        DomainVocabulary.apply(pack: pack, to: container.promptStore, languages: container.uiPrefs.vocabLanguages)
                    } label: {
                        Text(pack.displayName).foregroundStyle(AppColor.accent)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

struct VocabularyByLanguageEditor: View {
    @Environment(AppContainer.self) private var container
    @State private var lang = "Ukrainian"
    private let langs = ["English", "Arabic", "Ukrainian", "Dutch"]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("Language", selection: $lang) {
                ForEach(langs, id: \.self) { Text($0).tag($0) }
            }
            .pickerStyle(.segmented)
            TextEditor(text: Binding(
                get: { container.promptStore.vocabularyByLanguage[lang] ?? "" },
                set: { container.promptStore.vocabularyByLanguage[lang] = $0 }
            ))
            .font(AppFont.mono(12))
            .frame(minHeight: 90)
        }
    }
}

struct SnippetsSettingsTab: View {
    @Environment(AppContainer.self) private var container
    var body: some View {
        List {
            ForEach(container.snippetStore.snippets) { snip in
                VStack(alignment: .leading) {
                    Text(snip.name).font(AppFont.mono(12, weight: .semibold))
                    Text(snip.body).font(AppFont.fraunces(13, italic: false)).foregroundStyle(AppColor.inkSoft)
                }
            }
            TapButton {
                var s = container.snippetStore.snippets
                s.append(Snippet(name: "untitled-\(s.count + 1)", body: ""))
                container.snippetStore.snippets = s
            } label: {
                Text("Add snippet").foregroundStyle(AppColor.accent)
            }
        }
    }
}

struct APIKeysSettingsTab: View {
    @Environment(AppContainer.self) private var container
    @State private var inputs: [String: String] = [:]

    var body: some View {
        Form {
            ForEach(APIKeyStore.Provider.allCases, id: \.self) { provider in
                Section(provider.displayName) {
                    SecureField("API key", text: Binding(
                        get: { inputs[provider.rawValue] ?? "" },
                        set: { inputs[provider.rawValue] = $0 }
                    ))
                    HStack {
                        TapButton {
                            // Never let an empty field wipe a stored key.
                            guard let v = inputs[provider.rawValue],
                                  !v.trimmingCharacters(in: .whitespaces).isEmpty else { return }
                            container.apiKeys.set(v, for: provider)
                        } label: {
                            Text("Save").foregroundStyle(AppColor.accent)
                        }
                        TapButton {
                            container.apiKeys.set(nil, for: provider)
                            inputs[provider.rawValue] = ""
                        } label: {
                            Text("Clear").foregroundStyle(.red)
                        }
                        if container.apiKeys.isSet(provider) {
                            Text("Stored in Keychain ✓")
                                .font(AppFont.mono(10))
                                .foregroundStyle(AppColor.inkSoft)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}
