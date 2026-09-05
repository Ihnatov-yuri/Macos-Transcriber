import SwiftUI

/// Settings → Dictation. Everything the in-app option pills expose, plus the
/// long-tail knobs (polish prompt, spacing, clipboard restore, pause length).
struct DictationSettingsTab: View {
    @Environment(AppContainer.self) private var container

    private let languageOptions = ["English", "Dutch", "Ukrainian", "German", "French", "Spanish", "Italian", "Portuguese", "Polish", "Arabic"]

    var body: some View {
        let s = container.dictationSettings
        let c = container.dictation
        Form {
            Section {
                Picker("Hotkey", selection: Binding(get: { s.hotkey }, set: { s.hotkey = $0 })) {
                    ForEach(DictationSettings.Hotkey.allCases, id: \.rawValue) { Text($0.label).tag($0) }
                }
                Picker("Mode", selection: Binding(get: { s.mode }, set: { s.mode = $0 })) {
                    ForEach(DictationSettings.Mode.allCases, id: \.rawValue) { Text($0.label).tag($0) }
                }
                if s.mode == .toggle {
                    Slider(value: Binding(get: { s.pauseFlushSeconds }, set: { s.pauseFlushSeconds = $0 }),
                           in: 0.8 ... 4.0, step: 0.1) {
                        Text("Flush after a pause of \(String(format: "%.1f", s.pauseFlushSeconds)) s")
                    }
                }
                HStack {
                    Text("Accessibility")
                    Spacer()
                    Text(c.accessibilityTrusted ? "Granted" : "Not granted")
                        .foregroundStyle(c.accessibilityTrusted ? .primary : .secondary)
                    if !c.accessibilityTrusted {
                        Button("Grant…") { c.requestAccessibility() }
                    }
                }
                Text("A right-hand modifier is never a shortcut on its own, so it can't collide with the app you're typing in. If you pick fn / Globe, set “Press 🌐 key to” → Do Nothing in System Settings → Keyboard so macOS dictation doesn't also start. Accessibility access is what lets Transcriberr see the key in other apps and paste the result.")
                    .font(.caption).foregroundStyle(.secondary)
            } header: {
                Text("Hotkey")
            }

            Section("Recognition") {
                Picker("Engine", selection: Binding(get: { s.engine }, set: { s.engine = $0 })) {
                    ForEach(BackendFactory.Kind.allCases.filter(\.supportsLive), id: \.rawValue) {
                        Text($0.displayName).tag($0)
                    }
                }
                Picker("Language", selection: Binding(
                    get: { s.languages.sorted().first ?? "" },
                    set: { s.languages = $0.isEmpty ? [] : [$0] }
                )) {
                    Text("Auto-detect").tag("")
                    ForEach(languageOptions, id: \.self) { Text($0).tag($0) }
                }
                Toggle("Spoken commands (“new paragraph”, “comma”, “question mark”…)",
                       isOn: Binding(get: { s.spokenCommands }, set: { s.spokenCommands = $0 }))
                Toggle("Collapse fillers and stutters (um, “the the”)",
                       isOn: Binding(get: { s.destutter }, set: { s.destutter = $0 }))
                Toggle("Apply vocabulary spellings (Settings → Style & Vocabulary)",
                       isOn: Binding(get: { s.applyVocabulary }, set: { s.applyVocabulary = $0 }))
                Text("Parakeet decodes a whole passage in well under a second on the Neural Engine, punctuation and casing included. Vocabulary terms are matched exactly (case- and spacing-insensitive) and rewritten to their canonical spelling — never fuzzily.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Polish") {
                Toggle("Run each passage through the text engine before inserting",
                       isOn: Binding(get: { s.polish }, set: { s.polish = $0 }))
                if s.polish {
                    TextEditor(text: Binding(get: { s.polishPrompt }, set: { s.polishPrompt = $0 }))
                        .font(.system(.body, design: .monospaced))
                        .frame(minHeight: 120)
                    Button("Reset prompt") { s.polishPrompt = DictationSettings.defaultPolishPrompt }
                }
                Text("Uses the post-processing text engine (Settings → Engines). Adds roughly 2–4 s per passage on Gemma LiteRT. A result that isn't clearly the same passage cleaned up (wrong length, answers the text, echoes the prompt) is discarded and the deterministic output is used instead.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Insertion") {
                Picker("Spacing", selection: Binding(get: { s.spacing }, set: { s.spacing = $0 })) {
                    ForEach(DictationSettings.Spacing.allCases, id: \.rawValue) { Text($0.label).tag($0) }
                }
                Toggle("Restore the clipboard after pasting",
                       isOn: Binding(get: { s.restoreClipboard }, set: { s.restoreClipboard = $0 }))
                Toggle("Show the floating status strip",
                       isOn: Binding(get: { s.showHUD }, set: { s.showHUD = $0 }))
                Toggle("Show in the menu bar",
                       isOn: Binding(get: { s.showMenuBar }, set: { s.showMenuBar = $0 }))
                Toggle("Start / stop sounds",
                       isOn: Binding(get: { s.playSounds }, set: { s.playSounds = $0 }))
                Text("Text is inserted with ⌘V into whatever has keyboard focus; the previous clipboard contents come back 0.8 s later. When Transcriberr itself is in front with the Dictate screen open, text goes to its scratch pad instead.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("History") {
                Toggle("Keep every dictation in the Library (“Dictation” folder)",
                       isOn: Binding(get: { s.keepHistory }, set: { s.keepHistory = $0 }))
                Text("Each passage is saved with its audio as a normal recording: playable, re-transcribable with another engine, searchable through the knowledge-base CLI and MCP server.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
