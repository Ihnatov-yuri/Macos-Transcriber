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
        Toggle("Polish with Gemma", isOn: Binding(get: { s.polish }, set: { s.polish = $0 }))
        Toggle("Keep history in Library", isOn: Binding(get: { s.keepHistory }, set: { s.keepHistory = $0 }))
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
