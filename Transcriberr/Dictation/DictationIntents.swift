import AppIntents
import AppKit

/// Shortcuts / Siri actions. They run inside the app process without
/// activating it, so the app in front keeps focus and receives the text —
/// unlike the URL scheme, which brings Transcriberr forward.
struct StartDictationIntent: AppIntent {
    static var title: LocalizedStringResource = "Start Dictation"
    static var description = IntentDescription("Start listening; the passage is inserted where the cursor is when you stop.")
    static var openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult {
        guard let c = AppContainer.shared?.dictation else { throw DictationIntentError.notRunning }
        c.begin(target: .frontmostApp)
        return .result()
    }
}

struct StopDictationIntent: AppIntent {
    static var title: LocalizedStringResource = "Stop Dictation & Insert"
    static var description = IntentDescription("Stop listening and insert the recognized text.")
    static var openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult {
        guard let c = AppContainer.shared?.dictation else { throw DictationIntentError.notRunning }
        c.finish()
        return .result()
    }
}

struct ToggleDictationIntent: AppIntent {
    static var title: LocalizedStringResource = "Toggle Dictation"
    static var description = IntentDescription("Start dictating, or stop and insert if already listening.")
    static var openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult {
        guard let c = AppContainer.shared?.dictation else { throw DictationIntentError.notRunning }
        c.toggle(target: .frontmostApp)
        return .result()
    }
}

struct CancelDictationIntent: AppIntent {
    static var title: LocalizedStringResource = "Cancel Dictation"
    static var description = IntentDescription("Stop listening and discard the audio.")
    static var openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult {
        guard let c = AppContainer.shared?.dictation else { throw DictationIntentError.notRunning }
        c.cancel()
        return .result()
    }
}

enum DictationIntentError: Error, CustomLocalizedStringResourceConvertible {
    case notRunning
    var localizedStringResource: LocalizedStringResource {
        "Transcriberr isn't running yet — open it once, then try again."
    }
}

/// Pre-made shortcuts with Siri phrases; they show up in the Shortcuts app
/// under Transcriberr without any setup.
struct TranscriberrShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: ToggleDictationIntent(),
            phrases: ["Toggle dictation in \(.applicationName)", "Dictate with \(.applicationName)"],
            shortTitle: "Toggle Dictation",
            systemImageName: "mic"
        )
        AppShortcut(
            intent: StartDictationIntent(),
            phrases: ["Start dictation in \(.applicationName)"],
            shortTitle: "Start Dictation",
            systemImageName: "mic.fill"
        )
        AppShortcut(
            intent: StopDictationIntent(),
            phrases: ["Stop dictation in \(.applicationName)"],
            shortTitle: "Stop & Insert",
            systemImageName: "text.cursor"
        )
    }
}
