import AppKit
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
                        Button("Open Settings…") { c.openAccessibilitySettings() }
                        Button("Grant…") { c.requestAccessibility() }
                    }
                }
                if !c.accessibilityTrusted, DictationController.isAdHocSigned {
                    Text("Ticked already but still not granted? The entry belongs to an earlier build whose signature no longer matches. Remove Transcriberr from the Accessibility list (−) and add /Applications/Transcriberr.app again — once. From 3.1.1 on, releases carry a stable identifier-based signing requirement, so the grant survives updates.")
                        .font(.caption).foregroundStyle(.orange)
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
                Toggle("Spoken commands (“new paragraph”, “comma”, “scratch that”… — also Dutch, German, Ukrainian)",
                       isOn: Binding(get: { s.spokenCommands }, set: { s.spokenCommands = $0 }))
                Toggle("Collapse fillers and stutters (um, “the the”)",
                       isOn: Binding(get: { s.destutter }, set: { s.destutter = $0 }))
                Toggle("Apply vocabulary spellings (Settings → Style & Vocabulary)",
                       isOn: Binding(get: { s.applyVocabulary }, set: { s.applyVocabulary = $0 }))
                Text("Parakeet decodes a whole passage in well under a second on the Neural Engine, punctuation and casing included. Vocabulary terms are matched exactly (case- and spacing-insensitive) and rewritten to their canonical spelling — never fuzzily.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Formatting & context") {
                Picker("Apps without a rule", selection: Binding(get: { s.defaultMode }, set: { s.defaultMode = $0 })) {
                    ForEach(DictationSettings.FormatMode.allCases, id: \.rawValue) { Text($0.label).tag($0) }
                }
                Toggle("Read the text around the cursor (spacing, language, continuity)",
                       isOn: Binding(get: { s.readContext }, set: { s.readContext = $0 }))
                Toggle("Apply spoken self-corrections (“Monday, no, Tuesday” → “Tuesday”)",
                       isOn: Binding(get: { s.selfCorrections }, set: { s.selfCorrections = $0 }))
                Toggle("Language on auto: follow the language of the text in the field",
                       isOn: Binding(get: { s.languageFromContext }, set: { s.languageFromContext = $0 }))
                Text("Verbatim inserts the recognizer's words untouched. Clean applies the deterministic passes (vocabulary, fillers, commands, self-corrections) in well under a second. Smart additionally runs Gemma with the target app, its register, and the text before the cursor — chat stays short and casual, mail gets full sentences, an enumeration becomes a list. Password fields are always verbatim and never read.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Per-app rules") {
                AppRulesEditor(settings: s)
                Text("Rules match the app's bundle identifier; an identifier ending in “.” matches a family (com.jetbrains.). Terminals and code editors default to verbatim, chat apps to smart & casual, mail to smart & formal.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Smart pass prompt") {
                TextEditor(text: Binding(get: { s.polishPrompt }, set: { s.polishPrompt = $0 }))
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 100)
                Button("Reset to default") { s.polishPrompt = DictationSettings.defaultPolishPrompt }
                Text("Appended to the built-in context prompt when you change it. Uses the post-processing text engine (Settings → Engines); roughly 2–4 s per passage on Gemma LiteRT. A result that isn't clearly the same passage (wrong length, answers the text, echoes the prompt) is discarded in favour of the deterministic output.")
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
                Text("Text is inserted with ⌘V into whatever has keyboard focus; the previous clipboard contents come back 0.8 s later. Automatic spacing reads the characters before the cursor through Accessibility (a space only after a word, a capital only at a sentence start) and falls back to a trailing space where an app hides its text. Say “scratch that” to take the last passage back. When Transcriberr itself is in front with the Dictate screen open, text goes to its scratch pad instead.")
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


/// Editable list of per-app formatting rules with an "add current app" menu.
struct AppRulesEditor: View {
    let settings: DictationSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(settings.appRules) { rule in
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(rule.name).font(.body)
                        Text(rule.bundleId).font(.caption2).foregroundStyle(.secondary)
                    }
                    .frame(minWidth: 160, alignment: .leading)
                    Picker("", selection: Binding(
                        get: { rule.mode },
                        set: update(rule.id) { $0.mode = $1 }
                    )) {
                        ForEach(DictationSettings.FormatMode.allCases, id: \.rawValue) { Text($0.label).tag($0) }
                    }
                    .labelsHidden()
                    .frame(width: 210)
                    Picker("", selection: Binding(
                        get: { rule.tone },
                        set: update(rule.id) { $0.tone = $1 }
                    )) {
                        ForEach(DictationSettings.Tone.allCases, id: \.rawValue) { Text($0.label).tag($0) }
                    }
                    .labelsHidden()
                    .frame(width: 150)
                    .disabled(rule.mode != .smart)
                    Button(role: .destructive) {
                        settings.appRules.removeAll { $0.id == rule.id }
                    } label: { Image(systemName: "minus.circle") }
                    .buttonStyle(.borderless)
                }
            }
            HStack {
                Menu("Add running app…") {
                    ForEach(runningApps, id: \.bundleIdentifier) { app in
                        Button(app.localizedName ?? app.bundleIdentifier ?? "?") {
                            guard let id = app.bundleIdentifier,
                                  !settings.appRules.contains(where: { $0.bundleId == id }) else { return }
                            settings.appRules.append(DictationSettings.AppRule(
                                bundleId: id, name: app.localizedName ?? id, mode: .clean))
                        }
                    }
                }
                .frame(width: 180)
                Button("Restore defaults") { settings.appRules = DictationSettings.defaultAppRules }
            }
        }
    }

    private var runningApps: [NSRunningApplication] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != nil }
            .sorted { ($0.localizedName ?? "") < ($1.localizedName ?? "") }
    }

    private func update<T>(_ id: UUID, _ change: @escaping (inout DictationSettings.AppRule, T) -> Void) -> (T) -> Void {
        { value in
            guard let idx = settings.appRules.firstIndex(where: { $0.id == id }) else { return }
            var rule = settings.appRules[idx]
            change(&rule, value)
            settings.appRules[idx] = rule
        }
    }
}
