import EventKit
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
            DictationSettingsTab()
                .tabItem { Label("Dictation", systemImage: "keyboard") }
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
            UpdatesSettingsTab()
                .tabItem { Label("Updates", systemImage: "arrow.down.circle") }
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
    @AppStorage("ui.meetingBrief") private var meetingBrief = true
    @AppStorage(MeetingContext.enabledKey) private var meetingContext = true
    @AppStorage("ui.superGemmaRulings") private var gemmaRulings = "english"
    @Environment(AppContainer.self) private var container
    @AppStorage("ui.myName") private var myName = ""

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
            Section {
                TextField("My name", text: $myName, prompt: Text("e.g. Yuri"))
            } header: {
                Text("You")
            } footer: {
                Text("Meeting mode knows which voice came from your microphone — it labels that speaker with this name automatically.")
            }
            Section("Speech-to-text") {
                EnginePicker(title: "Default engine", kinds: audioEngines, selection: Binding(
                    get: { container.uiPrefs.defaultBackend },
                    set: { container.uiPrefs.defaultBackend = $0 }
                ))
                Picker("Live captions engine", selection: Binding(
                    get: { container.uiPrefs.liveEngine },
                    set: { container.uiPrefs.liveEngine = $0 }
                )) {
                    ForEach(liveEngines, id: \.rawValue) { Text($0.displayName).tag($0) }
                }
                WhisperModelPickers()
                Text("Whisper uses the first model when a recording's languages are English only, the second for anything else, auto-detect included. On the reference set, turbo compressed made English Super about 4x faster at the same accuracy; in Ukrainian every model but large-v3 lost 5-15 points. Speech models download automatically on first use: Parakeet v3/v2/UK (~0.6-1 GB each, Neural Engine) and the Whisper models picked here (0.5-3 GB, CoreML). Whisper models can also be downloaded ahead of time, or deleted, in Models.")
                    .font(AppFont.text(12)).foregroundStyle(AppColor.ink3)
            }
            Section("Super · dual-engine merge") {
                EnginePicker(title: "Merge engine A", kinds: mergeOptions, selection: Binding(
                    get: { container.uiPrefs.ensembleEngineA },
                    set: { newValue in
                        // Keep A ≠ B: picking B's engine swaps them.
                        if newValue == container.uiPrefs.ensembleEngineB {
                            container.uiPrefs.ensembleEngineB = container.uiPrefs.ensembleEngineA
                        }
                        container.uiPrefs.ensembleEngineA = newValue
                    }
                ))
                EnginePicker(title: "Merge engine B", kinds: mergeOptions, selection: Binding(
                    get: { container.uiPrefs.ensembleEngineB },
                    set: { newValue in
                        if newValue == container.uiPrefs.ensembleEngineA {
                            container.uiPrefs.ensembleEngineA = container.uiPrefs.ensembleEngineB
                        }
                        container.uiPrefs.ensembleEngineB = newValue
                    }
                ))
                Toggle("Max quality: arbitrate every disputed chunk with surrounding context + vocabulary", isOn: Binding(
                    get: { container.uiPrefs.superMaxQuality },
                    set: { container.uiPrefs.superMaxQuality = $0 }
                ))
                Toggle("Refine meetings with Super in the background", isOn: Binding(
                    get: { container.uiPrefs.meetingSuperFollowUp },
                    set: { container.uiPrefs.meetingSuperFollowUp = $0 }
                ))
                Text("When a meeting recording stops, the default engine writes a quick draft you can read at once; Super then runs in the background and replaces it when it finishes. The draft stays in VERSIONS.")
                    .font(AppFont.text(12)).foregroundStyle(AppColor.ink3)
                Toggle("Use the meeting's calendar invite", isOn: $meetingContext)
                    .onChange(of: meetingContext) { _, on in
                        if on { Task { _ = await MeetingContext.requestAccess(EKEventStore(), ask: true) } }
                    }
                if meetingContext, EKEventStore.authorizationStatus(for: .event) == .denied {
                    Text("Calendar access is off for Transcriberr. Turn it on in System Settings → Privacy & Security → Calendars.")
                        .font(AppFont.text(12)).foregroundStyle(AppColor.statusError)
                }
                Text("Before a recording is transcribed, the invite it was made in (its title, attendees and the names in its notes) and the names that recur in your earlier meetings with the same people become vocabulary for that run. Read from the Calendar app on this Mac; nothing leaves it.")
                    .font(AppFont.text(12)).foregroundStyle(AppColor.ink3)
                Toggle("Gemma reads the whole transcript first (recording brief)", isOn: $meetingBrief)
                Text("A few extra reads (about a minute per hour of recording) give Gemma the topic, the people and the names as spelled in this recording. Max-quality arbitration and the Clean / Context rewrite / Translate presets all use it, and a name spelled inconsistently is unified when the correction sounds the same.")
                    .font(AppFont.text(12)).foregroundStyle(AppColor.ink3)
                Picker("Gemma rules on disputed chunks", selection: $gemmaRulings) {
                    Text("English runs (measured to help)").tag("english")
                    Text("All languages").tag("all")
                    Text("Never").tag("off")
                }
                Text("Both engines transcribe every chunk in parallel; disagreements are settled word by word by recognizer confidence. With Max quality on, the whole recording is also read at once (long-form Whisper, English stretches re-read in English, echo removed by timing). Gemma's rulings on disputed chunks helped in English and hurt in Ukrainian when measured against checked transcripts, so by default they run for English only.")
                    .font(AppFont.text(12)).foregroundStyle(AppColor.ink3)
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
                    .font(AppFont.text(12)).foregroundStyle(AppColor.ink3)
            }
            Section("Languages by engine") {
                LabeledContent("Parakeet v3", value: "25 European languages — en, de, nl, fr, es, it, pt, pl, uk… (no Arabic/Asian)")
                LabeledContent("Parakeet v2", value: "English only — best English accuracy")
                LabeledContent("Ihnatov Parakeet UK", value: "Parakeet v3 fine-tuned for Ukrainian — keeps v3's English")
                LabeledContent("Whisper", value: "~100 languages incl. Arabic, Korean, Japanese, Chinese (distil-large-v3: English only)")
                LabeledContent("Gemma 4 LiteRT", value: "~140 languages incl. Gulf Arabic — strongest Arabic (as on Android)")
                Text("Recommendations: English → Parakeet v3 (or v2). Ukrainian → Ihnatov Parakeet UK. Other European languages → Parakeet v3. Arabic → Gemma LiteRT (Whisper as second opinion). Korean/Japanese/Chinese → Whisper. Unsure or mixed → Whisper or Super merge.")
                    .font(AppFont.text(12)).foregroundStyle(AppColor.ink3)
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
                    .font(AppFont.text(12)).foregroundStyle(AppColor.ink3)
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
                Text("Speech-to-text — Parakeet v3/v2/UK (automatic)")
                    .uiLabel(10, color: AppColor.ink2)
                Text("Downloaded on first use (~0.6-1 GB each; Parakeet UK from huggingface.co/ihnatov-yuri) · cached in Application Support · engine choice in the Engines tab")
                    .uiLabel(9, color: AppColor.ink3)
            }
            Hairline()

            WhisperModelsSection()
            Hairline()

            HairlineSoft()
            Text("Catalog").uiLabel(10, color: AppColor.ink2)

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
                        .font(AppFont.display(14, weight: .semibold))
                        .foregroundStyle(AppColor.ink)
                    Text(entry.purpose)
                        .font(AppFont.text(12))
                        .foregroundStyle(AppColor.ink2)
                    if let hf = entry.huggingFaceID {
                        Text(hf).uiLabel(9, color: AppColor.ink3)
                    }
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 6) {
                    Text(format(entry.sizeBytes)).uiLabel(10, color: AppColor.ink2)
                    actionButton
                }
                .frame(minWidth: 130, alignment: .trailing)
            }
            if let info = container.modelDownloader.progress[entry.id],
               container.modelDownloader.isDownloading.contains(entry.id) {
                ProgressView(value: info.fractionComplete) {
                    Text(info.status).uiLabel(9, color: AppColor.ink2)
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
                Text("Installed").uiLabel(10, color: AppColor.accentOnLight)
                if let size = container.modelDownloader.diskSize(entry) {
                    Text(formatGB(size)).uiLabel(9, color: AppColor.ink3)
                }
                TapButton { confirmingDelete = true } label: {
                    LitButtonChrome(.destructive, compact: true) { Text("Delete") }
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
            TapButton { container.modelDownloader.cancel(entry.id) } label: {
                LitButtonChrome(.secondary, compact: true) { Text("Cancel") }
            }
        } else {
            TapButton {
                Task { try? await container.modelDownloader.download(entry) }
            } label: {
                LitButtonChrome(.primary, compact: true) { Text("Download") }
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
    @State private var devices: [AudioInputDevices.Device] = []
    @State private var loopbacks: [AudioInputDevices.Device] = []
    @State private var systemDefault: AudioInputDevices.Device?
    @State private var watcher = AudioInputDevices.Watcher()

    /// The device that would actually be used right now, for the caption
    /// under the picker and for the Bluetooth warning.
    private var effective: AudioInputDevices.Device? {
        AudioInputDevices.effective(uid: settings.inputDeviceUID)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppMetric.m) {
            VStack(alignment: .leading, spacing: 4) {
                Picker("Microphone", selection: Binding(
                    get: { settings.inputDeviceUID ?? "" },
                    set: { settings.inputDeviceUID = $0.isEmpty ? nil : $0 }
                )) {
                    Text(systemDefault.map { "System default — \($0.name)" } ?? "System default")
                        .tag("")
                    Divider()
                    ForEach(devices) { device in
                        Text(device.isBluetooth ? "\(device.name) (Bluetooth)" : device.name)
                            .tag(device.uid)
                    }
                    // Loopback drivers expose input channels, so they show up
                    // in any device scan, but they capture what the Mac plays
                    // rather than a room. Offered apart from real mics —
                    // meeting mode already records system audio properly, via
                    // a process tap.
                    if !loopbacks.isEmpty {
                        Divider()
                        Section("Loopback (records system audio, not a room)") {
                            ForEach(loopbacks) { device in
                                Text(device.name).tag(device.uid)
                            }
                        }
                    }
                }
                .pickerStyle(.menu)
                .frame(maxWidth: 420, alignment: .leading)

                if settings.inputDeviceUID != nil, AudioInputDevices.resolve(uid: settings.inputDeviceUID) == nil {
                    Text("That microphone isn't connected — recording falls back to the system default until it comes back.")
                        .font(AppFont.text(11))
                        .foregroundStyle(AppColor.ink2)
                } else if effective?.isBluetooth == true {
                    Text("Recording from a Bluetooth mic drops that link to hands-free — mono, 16 kHz, for its playback too — for as long as capture is open.")
                        .font(AppFont.text(11))
                        .foregroundStyle(AppColor.ink2)
                } else if AudioInputDevices.captureWouldDisturbBluetooth(uid: settings.inputDeviceUID) {
                    Text("This mic has no output channels, so macOS still opens the system default input alongside it — and that default is Bluetooth, which drops to hands-free while recording. Nothing is opened when the app is just sitting there. Setting the system input to this mic too avoids it entirely.")
                        .font(AppFont.text(11))
                        .foregroundStyle(AppColor.ink2)
                } else {
                    Text("Used for dictation, plain recordings and the meeting recorder.")
                        .font(AppFont.text(11))
                        .foregroundStyle(AppColor.ink2)
                }
            }
            .onAppear {
                refreshDevices()
                watcher.start { refreshDevices() }
            }
            .onDisappear { watcher.stop() }

            Divider().frame(maxWidth: 520)

            VoiceprintSection()

            Divider().frame(maxWidth: 520)

            PeopleSection()

            Divider().frame(maxWidth: 520)

            Text("Apple's voice-processing audio unit cleans up the input the same way FaceTime / Voice Memos do — echo cancellation, spectral noise suppression, AGC. Free and very effective.")
                .font(AppFont.text(12))
                .foregroundStyle(AppColor.ink2)
                .frame(maxWidth: 520, alignment: .leading)

            Toggle(isOn: Binding(
                get: { settings.noiseSuppression },
                set: { settings.noiseSuppression = $0 }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Noise suppression while recording")
                        .font(AppFont.text(13, weight: .bold))
                    Text("Recommended. Applied on the input node before each chunk is written. macOS turns other apps down slightly while it runs; they come back when the recording stops.")
                        .font(AppFont.text(11))
                        .foregroundStyle(AppColor.ink2)
                }
            }

            Toggle(isOn: Binding(
                get: { settings.meetingEchoFilter },
                set: { settings.meetingEchoFilter = $0 }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Echo filter in meetings")
                        .font(AppFont.text(13, weight: .bold))
                    Text("Not needed for the transcript: Transcriberr removes the echo of the call from your mic itself. Apple's filter can silence your mic in Teams, so the other people can't hear you, and it drops short pieces of the recording. Off with headphones. Other apps play about 4 dB quieter while a meeting records.")
                        .font(AppFont.text(11))
                        .foregroundStyle(AppColor.ink2)
                }
            }

            VirtualMicrophoneSettings(settings: settings)

            Toggle(isOn: Binding(
                get: { settings.preprocessImports },
                set: { settings.preprocessImports = $0 }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Pre-process imported files")
                        .font(AppFont.text(13, weight: .bold))
                    Text("Runs the same cleanup over MP3 / M4A / WAV files before Gemma sees them. Adds a few seconds to the decode step.")
                        .font(AppFont.text(11))
                        .foregroundStyle(AppColor.ink2)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func refreshDevices() {
        devices = AudioInputDevices.microphones()
        loopbacks = AudioInputDevices.loopbacks()
        systemDefault = AudioInputDevices.systemDefault()
    }
}

/// The Transcriberr Microphone toggle, its driver install and what the
/// call app has to be set to.
private struct VirtualMicrophoneSettings: View {
    let settings: RecorderSettings
    @State private var installed = VirtualMicrophone.isInstalled
    @State private var working = false
    @State private var message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(isOn: Binding(
                get: { settings.virtualMicrophone },
                set: { settings.virtualMicrophone = $0; VirtualMicrophone.shared.refresh() }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Transcriberr Microphone for calls")
                        .font(AppFont.text(13, weight: .bold))
                    Text("Transcriberr runs the echo filter on your mic and passes the cleaned sound to your call through a microphone called \u{201C}\(VirtualMicrophone.micName)\u{201D}. In Teams, Meet or Zoom, choose it as the microphone. The call and the recording then both lose the echo, and the call app no longer fights Transcriberr over your mic. Replaces the echo filter above.")
                        .font(AppFont.text(11))
                        .foregroundStyle(AppColor.ink2)
                    Text("The microphone only exists while Transcriberr is open. When you quit, calls switch to another microphone. With headphones the call gets your plain mic. Other apps play about 4 dB quieter while a call uses it.")
                        .font(AppFont.text(11))
                        .foregroundStyle(AppColor.ink2)
                }
            }
            HStack(spacing: 10) {
                Text(installed ? "Driver installed." : "Needs a small audio driver (administrator password; all sound stops for a second).")
                    .font(AppFont.text(11))
                    .foregroundStyle(AppColor.ink2)
                Button(installed ? "Remove Driver" : "Install Driver") { run(remove: installed) }
                    .disabled(working || (!installed && VirtualMicrophone.bundledDriverURL == nil))
                if working { ProgressView().controlSize(.small) }
            }
            .padding(.leading, 20)
            if let message {
                Text(message)
                    .font(AppFont.text(11))
                    .foregroundStyle(AppColor.ink2)
                    .padding(.leading, 20)
            }
        }
    }

    private func run(remove: Bool) {
        working = true
        message = nil
        Task {
            if remove { VirtualMicrophone.shared.shutdown() }
            let error = await VirtualMicrophone.install(remove: remove)
            // coreaudiod takes a moment to come back and load the plug-in.
            try? await Task.sleep(for: .seconds(3))
            installed = VirtualMicrophone.isInstalled
            working = false
            message = error ?? (remove ? "Removed." : "Installed. Choose \u{201C}\(VirtualMicrophone.micName)\u{201D} as the microphone in your call app.")
            VirtualMicrophone.shared.refresh()
        }
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
                // System monospace, not a design-voice choice: these hold
                // {placeholder}-style template syntax where character
                // alignment carries real information.
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 100)
            }
            Section("Translate") {
                TextEditor(text: Binding(
                    get: { container.promptStore.translatePrompt },
                    set: { container.promptStore.translatePrompt = $0 }
                ))
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 100)
            }
        }
        .formStyle(.grouped)
    }
}

struct PresetsSettingsTab: View {
    @Environment(AppContainer.self) private var container
    @State private var expanded: Set<String> = []
    @State private var deleting: PostProcessingPreset?

    private var store: PresetStore { container.presetStore }

    var body: some View {
        VStack(alignment: .leading, spacing: AppMetric.m) {
            HStack {
                Text("Each preset is a tab in a recording, in this order. Edits save automatically.")
                    .uiLabel(9, color: AppColor.ink2)
                Spacer()
                TapButton {
                    let id = store.add()
                    expanded.insert(id)
                } label: {
                    LitButtonChrome(.secondary, compact: true) { Text("Add preset") }
                }
            }
            ForEach(store.presets) { preset in
                DisclosureGroup(isExpanded: Binding(
                    get: { expanded.contains(preset.id) },
                    set: { if $0 { expanded.insert(preset.id) } else { expanded.remove(preset.id) } }
                )) {
                    editor(preset)
                } label: {
                    HStack(spacing: AppMetric.s) {
                        Text(preset.name.isEmpty ? "Untitled" : preset.name)
                        if preset.kind == .rewrite {
                            Text("Rewrite").uiLabel(9, color: AppColor.ink3)
                        }
                        if !preset.isBuiltin {
                            Text("Yours").uiLabel(9, color: AppColor.accentOnLight)
                        }
                    }
                }
                .font(AppFont.text(13))
                HairlineSoft()
            }
            let deleted = store.deletedWithHistory.filter { !$0.preset.isBuiltin }
            if !deleted.isEmpty {
                Text("Deleted presets").uiLabel(9, color: AppColor.ink2)
                ForEach(deleted) { rev in
                    HStack {
                        Text(rev.preset.name).font(AppFont.text(13))
                        Spacer()
                        TapButton { store.restore(rev) } label: {
                            LitButtonChrome(.ghost, compact: true) { Text("Bring back") }
                        }
                    }
                }
                HairlineSoft()
            }
            TapButton { store.restoreBuiltins() } label: {
                LitButtonChrome(.ghost, compact: true) { Text("Restore built-in presets") }
            }
            .help("Puts the shipped presets back as they were, including deleted ones. Presets you added stay.")
        }
        .confirmationDialog(
            "Delete the preset \u{201C}\(deleting?.name ?? "")\u{201D}?",
            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
            titleVisibility: .visible,
            presenting: deleting
        ) { preset in
            Button("Delete", role: .destructive) {
                store.delete(preset.id)
                expanded.remove(preset.id)
            }
        } message: { preset in
            Text(preset.isBuiltin
                 ? "Outputs it already made stay in their recordings. Restore built-in presets brings it back."
                 : "Outputs it already made stay in their recordings.")
        }
    }

    @ViewBuilder
    private func editor(_ preset: PostProcessingPreset) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: AppMetric.m) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Name").uiLabel(9, color: AppColor.ink2)
                    TextField("Tab name", text: binding(for: preset.id, \.name))
                        .textFieldStyle(.roundedBorder)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Output title").uiLabel(9, color: AppColor.ink2)
                    TextField("Heading of the output", text: binding(for: preset.id, \.outputTitle))
                        .textFieldStyle(.roundedBorder)
                }
            }
            Picker("Runs as", selection: binding(for: preset.id, \.kind)) {
                Text("Analysis: reads the transcript once and writes about it")
                    .tag(PostProcessingPreset.Kind.analysis)
                Text("Rewrite: gives back the whole transcript, changed")
                    .tag(PostProcessingPreset.Kind.rewrite)
            }
            .font(AppFont.text(12))
            Text("System").uiLabel(9, color: AppColor.ink2)
            TextEditor(text: binding(for: preset.id, \.systemTemplate))
                .font(AppFont.text(12))
                .frame(minHeight: 70)
            Text("User template").uiLabel(9, color: AppColor.ink2)
            TextEditor(text: binding(for: preset.id, \.userTemplate))
                .font(AppFont.text(12))
                .frame(minHeight: 110)
            Text(preset.placesTranscript
                 ? "{transcript_with_speakers} is the transcript with names; {transcript} is the text alone."
                 : "No {transcript_with_speakers} in the template, so the transcript is added at the end.")
                .font(AppFont.text(11))
                .foregroundStyle(preset.placesTranscript ? AppColor.ink3 : AppColor.accentOnLight)
            HStack(spacing: AppMetric.m) {
                TapButton { store.move(preset.id, by: -1) } label: {
                    LitButtonChrome(.ghost, compact: true) { Text("Move up") }
                }
                TapButton { store.move(preset.id, by: 1) } label: {
                    LitButtonChrome(.ghost, compact: true) { Text("Move down") }
                }
                TapButton {
                    if let id = store.duplicate(preset.id) { expanded.insert(id) }
                } label: {
                    LitButtonChrome(.ghost, compact: true) { Text("Duplicate") }
                }
                if preset.isBuiltin {
                    TapButton { store.resetBuiltin(preset.id) } label: {
                        LitButtonChrome(.ghost, compact: true) { Text("Reset to shipped") }
                    }
                }
                TapButton { store.checkpoint(preset.id, reason: .saved) } label: {
                    LitButtonChrome(.ghost, compact: true) { Text("Save version") }
                }
                .help("Keep these prompts in the preset's history. Each run also keeps the prompts it used.")
                Spacer()
                TapButton { deleting = preset } label: {
                    LitButtonChrome(.destructive, compact: true) { Text("Delete…") }
                }
            }
            .padding(.top, 4)
            history(preset)
        }
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private func history(_ preset: PostProcessingPreset) -> some View {
        let revisions = store.revisions(for: preset.id)
        if !revisions.isEmpty {
            DisclosureGroup("History (\(revisions.count))") {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(revisions) { rev in
                        HStack(alignment: .top, spacing: AppMetric.m) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(Self.revisionDate.string(from: rev.savedAt)) · \(rev.label)")
                                    .font(AppFont.text(12))
                                Text(rev.preset.userTemplate.prefix(140).replacingOccurrences(of: "\n", with: " "))
                                    .font(AppFont.text(11))
                                    .foregroundStyle(AppColor.ink3)
                                    .lineLimit(2)
                            }
                            Spacer()
                            if rev.preset == preset {
                                Text("Current").uiLabel(9, color: AppColor.accentOnLight)
                            } else {
                                TapButton { store.restore(rev) } label: {
                                    LitButtonChrome(.ghost, compact: true) { Text("Restore") }
                                }
                                .help("Puts these prompts back. The current ones are kept in the history.")
                            }
                        }
                        HairlineSoft()
                    }
                }
                .padding(.vertical, 4)
            }
            .font(AppFont.text(12))
        }
    }

    private static let revisionDate: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "d MMM · HH:mm"
        return f
    }()

    private func binding<T>(for id: String, _ keyPath: WritableKeyPath<PostProcessingPreset, T>) -> Binding<T> {
        Binding(
            get: { store.preset(id)?[keyPath: keyPath] ?? PresetStore.Builtin.summary[keyPath: keyPath] },
            set: { newValue in
                guard let idx = store.presets.firstIndex(where: { $0.id == id }) else { return }
                store.presets[idx][keyPath: keyPath] = newValue
            }
        )
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
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 90)
                Text("Applied to every run. Names that work in any language (people, companies).")
                    .font(AppFont.text(12)).foregroundStyle(AppColor.ink3)
            }
            Section("Vocabulary — per language") {
                VocabularyByLanguageEditor()
                Text("Injected only when a run's LANG matches — keeps Ukrainian runs free of English terms and vice versa.")
                    .font(AppFont.text(12)).foregroundStyle(AppColor.ink3)
            }
            LearnedTermsSection()
            LearnedChoicesSection()
            BenchmarkSection()
            Section("Domain packs") {
                ForEach(DomainVocabulary.Pack.allCases, id: \.self) { pack in
                    // TapButton — inline Button capturing @Observable container
                    // hits the macOS 26.5 _ButtonGesture crash.
                    TapButton {
                        DomainVocabulary.apply(pack: pack, to: container.promptStore, languages: container.uiPrefs.vocabLanguages)
                    } label: {
                        LitButtonChrome(.ghost, compact: true) { Text(pack.displayName) }
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
            .font(.system(.body, design: .monospaced))
            .frame(minHeight: 90)
        }
    }
}

struct SnippetsSettingsTab: View {
    @Environment(AppContainer.self) private var container

    var body: some View {
        Form {
            Section {
                Text("""
                Snippets are reusable text blocks for prompts. Define one here, then \
                write {snippet:name} inside any preset or prompt template (Settings → \
                Presets / Prompts). Before the model runs, the placeholder is replaced \
                with the snippet's text.

                Example: a snippet named team containing "Yuri, Nicole, Kees" lets any \
                preset say "Speakers may include: {snippet:team}" — update the team in \
                one place, every preset follows.
                """)
                .font(AppFont.text(13))
                .foregroundStyle(AppColor.ink2)
            }
            Section("Your snippets") {
                ForEach(container.snippetStore.snippets.indices, id: \.self) { idx in
                    snippetRow(idx)
                }
                TapButton {
                    var s = container.snippetStore.snippets
                    s.append(Snippet(name: "name-me", body: ""))
                    container.snippetStore.snippets = s
                } label: {
                    LitButtonChrome(.ghost, compact: true) { Text("Add snippet") }
                }
                if container.snippetStore.snippets.isEmpty {
                    Text("No snippets yet — most people never need one. This is a power tool for heavy preset users.")
                        .font(AppFont.text(12))
                        .foregroundStyle(AppColor.ink2)
                }
            }
        }
    }

    @ViewBuilder
    private func snippetRow(_ idx: Int) -> some View {
        let snippets = container.snippetStore.snippets
        if idx < snippets.count {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 10) {
                    TextField("name", text: Binding(
                        get: { container.snippetStore.snippets[safe: idx]?.name ?? "" },
                        set: { v in
                            var s = container.snippetStore.snippets
                            guard idx < s.count else { return }
                            s[idx].name = v.replacingOccurrences(of: " ", with: "-")
                            container.snippetStore.snippets = s
                        }
                    ))
                    // Functional monospace: this name is literally the
                    // {snippet:name} placeholder key, not a design voice.
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 170)
                    Text("use as {snippet:\(snippets[idx].name)}")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(AppColor.ink2)
                        .textSelection(.enabled)
                    Spacer()
                    TapButton {
                        var s = container.snippetStore.snippets
                        guard idx < s.count else { return }
                        s.remove(at: idx)
                        container.snippetStore.snippets = s
                    } label: {
                        LitButtonChrome(.destructive, compact: true) { Text("Delete") }
                    }
                }
                TextField("snippet text (what replaces the placeholder)", text: Binding(
                    get: { container.snippetStore.snippets[safe: idx]?.body ?? "" },
                    set: { v in
                        var s = container.snippetStore.snippets
                        guard idx < s.count else { return }
                        s[idx].body = v
                        container.snippetStore.snippets = s
                    }
                ), axis: .vertical)
                .lineLimit(2...6)
                .font(AppFont.text(13))
            }
            .padding(.vertical, 4)
        }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
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
                            // Never let an empty field wipe a stored key. A
                            // key copied with a trailing newline or space was
                            // stored as-is and every request then failed auth.
                            guard let v = inputs[provider.rawValue]?
                                    .trimmingCharacters(in: .whitespacesAndNewlines),
                                  !v.isEmpty else { return }
                            container.apiKeys.set(v, for: provider)
                        } label: {
                            LitButtonChrome(.secondary, compact: true) { Text("Save") }
                        }
                        TapButton {
                            container.apiKeys.set(nil, for: provider)
                            inputs[provider.rawValue] = ""
                        } label: {
                            LitButtonChrome(.destructive, compact: true) { Text("Clear") }
                        }
                        if container.apiKeys.isSet(provider) {
                            Text("Stored in Keychain ✓")
                                .uiLabel(10, color: AppColor.ink2)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}
