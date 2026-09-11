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
        Button(c.phase == .listening ? "Stop & Insert" : "Start Dictation") {
            c.toggle(target: .frontmostApp)
        }
        .keyboardShortcut("d", modifiers: [.command, .shift])
        .disabled(c.phase == .transcribing || c.phase == .inserting)
        if c.phase == .listening {
            Button("Cancel") { c.cancel() }
        }
        Divider()
        Picker("Mode", selection: Binding(get: { s.mode }, set: { s.mode = $0 })) {
            ForEach(DictationSettings.Mode.allCases, id: \.rawValue) { Text($0.label).tag($0) }
        }
        Picker("Default formatting", selection: Binding(get: { s.defaultMode }, set: { s.defaultMode = $0 })) {
            ForEach(DictationSettings.FormatMode.allCases, id: \.rawValue) { Text($0.label).tag($0) }
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
        SettingsLink { Text("Settings…") }
        Divider()
        Button("Quit Transcriberr") { NSApp.terminate(nil) }
    }

    private func statusLine(_ c: DictationController) -> String {
        switch c.phase {
        case .listening:      return "Listening…"
        case .transcribing:   return "Recognizing…"
        case .inserting:      return "Inserting…"
        case .message(let m): return m
        case .idle:
            if c.settings.hotkey == .off { return "Hotkey off" }
            return c.hotkeyArmed
                ? "\(c.settings.mode == .hold ? "Hold" : "Tap") \(c.settings.hotkey.label) to dictate"
                : "Hotkey needs Accessibility access"
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
            Text(AudioInputDevices.systemDefault().map { "System default — \($0.name)" } ?? "System default")
                .tag("")
            ForEach(mics) { mic in
                Text(mic.isBluetooth ? "\(mic.name) (Bluetooth)" : mic.name).tag(mic.uid)
            }
            if let extra {
                Text("\(extra.name) (loopback)").tag(extra.uid)
            }
        }
    }
}
