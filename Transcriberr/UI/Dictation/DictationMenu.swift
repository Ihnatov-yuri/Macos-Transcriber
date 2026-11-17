import AppKit
import SwiftUI

/// Menu bar icon: reflects the dictation phase.
struct DictationMenuBarLabel: View {
    let controller: DictationController

    var body: some View {
        switch controller.phase {
        case .listening:
            Image(systemName: "mic.fill")
        case .transcribing, .inserting:
            Image(systemName: "waveform")
        default:
            Image(systemName: "mic")
        }
    }
}

/// Menu bar dropdown. Status-item menus don't activate the app, so "Start
/// Dictation" from here pastes into the app that was in front.
struct DictationMenu: View {
    let container: AppContainer

    var body: some View {
        let c = container.dictation
        let s = container.dictationSettings
        Text(statusLine(c))
        Divider()
        Button(c.phase == .listening ? String(localized: "Stop & Insert") : String(localized: "Start Dictation")) {
            c.toggle(target: .frontmostApp)
        }
        .keyboardShortcut("d", modifiers: [.command, .shift])
        if c.phase == .listening {
            Button("Cancel") { c.cancel() }
        }
        Divider()
        Picker("Mode", selection: Binding(get: { s.mode }, set: { s.mode = $0 })) {
            ForEach(DictationSettings.Mode.allCases, id: \.rawValue) { Text($0.label).tag($0) }
        }
        Picker("Language", selection: Binding(
            get: { s.languages.sorted().first ?? "" },
            set: { s.languages = $0.isEmpty ? [] : [$0] }
        )) {
            Text("Auto-detect").tag("")
            ForEach(DictationSettings.languageOptions, id: \.self) { Text(SettingsLanguageNames.name($0)).tag($0) }
        }
        Picker("Default formatting", selection: Binding(get: { s.defaultMode }, set: { s.defaultMode = $0 })) {
            ForEach(DictationSettings.FormatMode.allCases, id: \.rawValue) { Text($0.label).tag($0) }
        }
        Picker("Write as", selection: Binding(get: { s.style }, set: { s.style = $0 })) {
            ForEach(DictationStyle.allCases, id: \.rawValue) { Text($0.label).tag($0) }
        }
        Toggle("Keep history in Library", isOn: Binding(get: { s.keepHistory }, set: { s.keepHistory = $0 }))
        MicrophonePicker()
        Divider()
        if !c.accessibilityTrusted {
            Button("Enable Global Hotkey (Accessibility)…") { c.requestAccessibility() }
        }
        Button("Open Dictate Screen") {
            NSApp.activate(ignoringOtherApps: true)
            container.requestDictatePane()
        }
        OpenSettingsItem(container: container)
        Divider()
        Button("Quit Transcriberr") { NSApp.terminate(nil) }
    }

    private func statusLine(_ c: DictationController) -> String {
        switch c.phase {
        case .listening:      return String(localized: "Listening…")
        case .transcribing:   return String(localized: "Recognizing…")
        case .inserting:      return String(localized: "Inserting…")
        case .message(let m): return m
        case .idle:
            if c.settings.hotkey == .off { return String(localized: "Hotkey off") }
            let key = c.settings.hotkey.label
            guard c.hotkeyArmed else { return String(localized: "Hotkey needs Accessibility access") }
            return c.settings.mode == .hold
                ? String(localized: "Hold \(key) to dictate", comment: "Menu bar status; the argument is the hotkey name")
                : String(localized: "Tap \(key) to dictate", comment: "Menu bar status; the argument is the hotkey name")
        }
    }
}

/// Microphone choice in the menu bar, so switching headsets mid-day doesn't
/// mean opening Settings. The device list is read when the menu is built —
/// menus are rebuilt every time they open, so a headset that just connected
/// is there without any watching.
struct MicrophonePicker: View {
    @State private var settings = RecorderSettings.shared

    var body: some View {
        let mics = AudioInputDevices.microphones()
        let chosen = settings.inputDeviceUID
        // A stored choice that isn't a microphone (someone picked a loopback
        // device in Settings) still has to appear, or the menu would silently
        // show the wrong thing selected.
        let extra = AudioInputDevices.resolve(uid: chosen).flatMap { $0.isVirtual ? $0 : nil }
        Picker("Microphone", selection: Binding(
            get: { chosen ?? "" },
            set: { settings.inputDeviceUID = $0.isEmpty ? nil : $0 }
        )) {
            Text(AudioInputDevices.systemDefault().map { String(localized: "System default — \($0.name)") }
                 ?? String(localized: "System default", comment: "Microphone menu: follow the macOS input device"))
                .tag("")
            ForEach(mics) { mic in
                Text(mic.isBluetooth ? String(localized: "\(mic.name) (Bluetooth)") : mic.name).tag(mic.uid)
            }
            if let extra {
                Text("\(extra.name) (loopback)").tag(extra.uid)
            }
        }
    }
}
