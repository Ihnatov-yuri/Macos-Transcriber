import AppKit
import SwiftUI

/// Settings → Dictation. Everything the in-app option pills expose, plus the
/// long-tail knobs (polish prompt, spacing, clipboard restore, pause length).
struct DictationSettingsTab: View {
    @Environment(AppContainer.self) private var container
    @Environment(\.settingsFilter) private var filter

    var body: some View {
        let s = container.dictationSettings
        let c = container.dictation
        Form {
            if filter.showsAny(.dictationHotkey, .dictationAccessibility) {
                Section {
                    if filter.shows(.dictationHotkey) {
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
                    }
                    if filter.shows(.dictationAccessibility) {
                        HStack {
                            Text("Accessibility")
                            Spacer()
                            Text(c.accessibilityTrusted ? "Granted" : "Not granted")
                                .foregroundStyle(c.accessibilityTrusted ? .primary : .secondary)
                            if !c.accessibilityTrusted {
                                TapButton { c.openAccessibilitySettings() } label: {
                                    LitButtonChrome(.ghost, compact: true) { Text("Open Settings…") }
                                }
                                TapButton { c.requestAccessibility() } label: {
                                    LitButtonChrome(.ghost, compact: true) { Text("Grant…") }
                                }
                            }
                        }
                        if !c.accessibilityTrusted, DictationController.isAdHocSigned {
                            Text("Ticked already but still not granted? The entry belongs to an earlier build whose signature no longer matches. Remove Transcriberr from the Accessibility list (−) and add /Applications/Transcriberr.app again — once. From 3.1.1 on, releases carry a stable identifier-based signing requirement, so the grant survives updates.")
                                .font(AppFont.text(12)).foregroundStyle(AppColor.statusWarning)
                        }
                    }
                    if filter.shows(.dictationHotkey) {
                        Text(SettingID.dictationHotkey.help)
                            .font(AppFont.text(12)).foregroundStyle(AppColor.ink3)
                    }
                } header: {
                    Text("Hotkey")
                }
            }

            if filter.showsAny(.dictationRecognition, .dictationCleanup) {
                Section("Recognition") {
                    if filter.shows(.dictationRecognition) {
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
                            ForEach(DictationSettings.languageOptions, id: \.self) { Text($0).tag($0) }
                        }
                    }
                    if filter.shows(.dictationCleanup) {
                        Toggle("Spoken commands (“new paragraph”, “comma”, “scratch that”… — also Dutch, German, Ukrainian)",
                               isOn: Binding(get: { s.spokenCommands }, set: { s.spokenCommands = $0 }))
                        Toggle("Collapse fillers and stutters (um, “the the”)",
                               isOn: Binding(get: { s.destutter }, set: { s.destutter = $0 }))
                        Toggle("Apply vocabulary spellings (Settings → Style & Vocabulary)",
                               isOn: Binding(get: { s.applyVocabulary }, set: { s.applyVocabulary = $0 }))
                        Text(SettingID.dictationCleanup.help)
                            .font(AppFont.text(12)).foregroundStyle(AppColor.ink3)
                    }
                }
            }

            if filter.showsAny(.dictationFormatting, .dictationContext) {
                Section("Formatting & context") {
                    if filter.shows(.dictationFormatting) {
                        Picker("Apps without a rule", selection: Binding(get: { s.defaultMode }, set: { s.defaultMode = $0 })) {
                            ForEach(DictationSettings.FormatMode.allCases, id: \.rawValue) { Text($0.label).tag($0) }
                        }
                    }
                    if filter.shows(.dictationContext) {
                        Toggle("Read the text around the cursor (spacing, language, continuity)",
                               isOn: Binding(get: { s.readContext }, set: { s.readContext = $0 }))
                        Toggle("Apply spoken self-corrections (“Monday, no, Tuesday” → “Tuesday”)",
                               isOn: Binding(get: { s.selfCorrections }, set: { s.selfCorrections = $0 }))
                        Toggle("Language on auto: follow the language of the text in the field",
                               isOn: Binding(get: { s.languageFromContext }, set: { s.languageFromContext = $0 }))
                        Toggle("Live preview while speaking (provisional text in the status strip)",
                               isOn: Binding(get: { s.livePreview }, set: { s.livePreview = $0 }))
                        Toggle("Use names learned from my transcripts (Settings → Style & Vocabulary)",
                               isOn: Binding(get: { s.useLearnedTerms }, set: { s.useLearnedTerms = $0 }))
                    }
                    if filter.shows(.dictationFormatting) {
                        Text(SettingID.dictationFormatting.help)
                            .font(AppFont.text(12)).foregroundStyle(AppColor.ink3)
                    }
                }
            }

            if filter.shows(.dictationAppRules) {
                Section("Per-app rules") {
                    AppRulesEditor(settings: s)
                    Text(SettingID.dictationAppRules.help)
                        .font(AppFont.text(12)).foregroundStyle(AppColor.ink3)
                }
            }

            if filter.shows(.dictationPrompt) {
                Section("Smart pass prompt") {
                    TextEditor(text: Binding(get: { s.polishPrompt }, set: { s.polishPrompt = $0 }))
                        .font(.system(.body, design: .monospaced))
                        .frame(minHeight: 100)
                    TapButton { s.polishPrompt = DictationSettings.defaultPolishPrompt } label: {
                        LitButtonChrome(.ghost, compact: true) { Text("Reset to default") }
                    }
                    Text(SettingID.dictationPrompt.help)
                        .font(AppFont.text(12)).foregroundStyle(AppColor.ink3)
                }
            }

            if filter.showsAny(.dictationInsertion, .dictationIndicators, .dictationLinks) {
                Section("Insertion") {
                    if filter.shows(.dictationInsertion) {
                        Picker("Spacing", selection: Binding(get: { s.spacing }, set: { s.spacing = $0 })) {
                            ForEach(DictationSettings.Spacing.allCases, id: \.rawValue) { Text($0.label).tag($0) }
                        }
                        Toggle("Restore the clipboard after pasting",
                               isOn: Binding(get: { s.restoreClipboard }, set: { s.restoreClipboard = $0 }))
                    }
                    if filter.shows(.dictationIndicators) {
                        Toggle("Show the floating status strip",
                               isOn: Binding(get: { s.showHUD }, set: { s.showHUD = $0 }))
                        Toggle("Show in the menu bar",
                               isOn: Binding(get: { s.showMenuBar }, set: { s.showMenuBar = $0 }))
                        Toggle("Start / stop sounds",
                               isOn: Binding(get: { s.playSounds }, set: { s.playSounds = $0 }))
                    }
                    if filter.shows(.dictationLinks) {
                        Toggle("Allow transcriberr://dictate links (text goes to the Dictate screen)",
                               isOn: Binding(get: { s.urlActions }, set: { s.urlActions = $0 }))
                    }
                    if filter.shows(.dictationInsertion) {
                        Text(SettingID.dictationInsertion.help)
                            .font(AppFont.text(12)).foregroundStyle(AppColor.ink3)
                    }
                }
            }

            if filter.shows(.dictationHistory) {
                Section("History") {
                    Toggle("Keep every dictation in the Library (“Dictation” folder)",
                           isOn: Binding(get: { s.keepHistory }, set: { s.keepHistory = $0 }))
                    Text(SettingID.dictationHistory.help)
                        .font(AppFont.text(12)).foregroundStyle(AppColor.ink3)
                }
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
                        set: { mode in update(rule.id) { $0.mode = mode } }
                    )) {
                        ForEach(DictationSettings.FormatMode.allCases, id: \.rawValue) { Text($0.label).tag($0) }
                    }
                    .labelsHidden()
                    .frame(width: 210)
                    Picker("", selection: Binding(
                        get: { rule.tone },
                        set: { tone in update(rule.id) { $0.tone = tone } }
                    )) {
                        ForEach(DictationSettings.Tone.allCases, id: \.rawValue) { Text($0.label).tag($0) }
                    }
                    .labelsHidden()
                    .frame(width: 150)
                    .disabled(rule.mode != .smart)
                    TapButton {
                        settings.appRules.removeAll { $0.id == rule.id }
                    } label: {
                        Image(systemName: "minus.circle").foregroundStyle(AppColor.statusError)
                    }
                    // TapButton can't carry `role: .destructive` the way a
                    // real Button can (it isn't one) — name the action
                    // explicitly so VoiceOver still announces it as removal,
                    // not just an unlabeled glyph.
                    .accessibilityLabel("Remove rule for \(rule.name)")
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
                TapButton { settings.appRules = DictationSettings.defaultAppRules } label: {
                    LitButtonChrome(.ghost, compact: true) { Text("Restore defaults") }
                }
            }
        }
    }

    private var runningApps: [NSRunningApplication] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != nil }
            .sorted { ($0.localizedName ?? "") < ($1.localizedName ?? "") }
    }

    /// Plain closures at the call sites: a generic helper returning a
    /// `@MainActor @Sendable (T) -> Void` for `Binding.set` crashed the
    /// Swift 6.3 compiler in Swift 6 mode (IRGen of its reabstraction thunk).
    private func update(_ id: UUID, _ change: (inout DictationSettings.AppRule) -> Void) {
        guard let idx = settings.appRules.firstIndex(where: { $0.id == id }) else { return }
        var rule = settings.appRules[idx]
        change(&rule)
        settings.appRules[idx] = rule
    }
}
