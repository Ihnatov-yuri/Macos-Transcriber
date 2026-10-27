import SwiftUI
import SwiftData
import AppKit

@main
struct TranscriberrApp: App {
    @State private var container: AppContainer
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        FontLoader.registerBundledFonts()
        AppLog.bootBanner()
        AppLog.info("app", "log file: \(AppLog.logFileURL.path)")
        WhisperModel.migrateSettings()
        // Transcript backups are written off the caller's thread now; make
        // sure a quit waits for whatever is still in that queue.
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { _ in BackupService.flush() }
        _container = State(initialValue: AppContainer())
        // The Transcriberr Microphone, when it is on: calls can use it from
        // launch, not only once a meeting records.
        if !AppContainer.isTestHost { VirtualMicrophone.shared.refresh() }
    }

    var body: some Scene {
        WindowGroup {
            AppShell()
                .onOpenURL { url in container.dictation.handle(url: url) }
                .environment(container)
                .modelContainer(container.modelContainer)
                .frame(minWidth: 980, minHeight: 640)
                .background(AppColor.base.ignoresSafeArea())
                .preferredColorScheme(.light)
        }
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unifiedCompact(showsTitle: false))
        // First launch opened at the 980×640 minimum, where the detail pane
        // is 398 pt wide — the layout breathes from ~1250 pt up.
        .defaultSize(width: 1320, height: 860)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About Transcriberr") { Self.showAbout() }
                Button("Check for Updates…") {
                    let updates = container.updates
                    Task { @MainActor in Self.showUpdateResult(await updates.check(), container: container) }
                }
            }
            CommandGroup(replacing: .newItem) {
                Button("New Recording") { container.requestNewRecording() }
                    .keyboardShortcut("n")
                Button("Delete Recording…") { container.requestDeleteRecording() }
                    .keyboardShortcut(.delete, modifiers: .command)
                    .disabled(container.librarySelection == nil)
            }
            CommandMenu("Dictation") {
                Button(container.dictation.phase == .listening ? "Stop Dictation" : "Start Dictation") {
                    container.dictation.toggleFromMenu()
                }
                .keyboardShortcut("d", modifiers: [.command, .shift])
                Button("Cancel Dictation") { container.dictation.cancel() }
                    .disabled(container.dictation.phase != .listening)
                Divider()
                Button("Show Dictate Screen") {
                    NSApp.activate(ignoringOtherApps: true)
                    container.requestDictatePane()
                }
            }
        }

        // Menu bar presence so dictation is reachable without the window.
        MenuBarExtra(isInserted: Binding(
            get: { container.dictationSettings.showMenuBar },
            set: { container.dictationSettings.showMenuBar = $0 }
        )) {
            DictationMenu(container: container)
        } label: {
            DictationMenuBarLabel(controller: container.dictation)
        }
        .menuBarExtraStyle(.menu)

        Settings {
            SettingsView()
                .environment(container)
                // People → Add person lists recordings with @Query: without
                // the store here that sheet had no container to read.
                .modelContainer(container.modelContainer)
                .frame(minWidth: 560, minHeight: 480)
        }
    }

    /// Result of a manual check from the app menu.
    @MainActor
    private static func showUpdateResult(_ status: UpdateChecker.Status, container: AppContainer) {
        let alert = NSAlert()
        switch status {
        case .available(let r):
            alert.messageText = "Transcriberr \(r.version) is available"
            alert.informativeText = r.title.isEmpty ? "The release page has the download and what changed." : r.title
            if r.installable { alert.addButton(withTitle: "Update Now") }
            alert.addButton(withTitle: "What's New…")
            alert.addButton(withTitle: "Later")
            switch (alert.runModal(), r.installable) {
            case (.alertFirstButtonReturn, true): container.installUpdate(r)
            case (.alertFirstButtonReturn, false), (.alertSecondButtonReturn, true): NSWorkspace.shared.open(r.pageURL)
            default: break
            }
            return
        case .failed(let why):
            alert.messageText = why
            alert.informativeText = "Try again later."
        default:
            alert.messageText = "Transcriberr is up to date"
            alert.informativeText = "This is the latest version."
        }
        alert.runModal()
    }

    /// Standard macOS About panel with author credits (macOS menu → About).
    @MainActor
    private static func showAbout() {
        let body: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor.labelColor,
        ]
        let quiet: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        func link(_ title: String, _ url: String) -> NSAttributedString {
            NSAttributedString(string: title, attributes: [
                .font: NSFont.systemFont(ofSize: 11),
                .link: URL(string: url)!,
            ])
        }
        let credits = NSMutableAttributedString(
            string: "Local-first transcription studio.\nParakeet · Whisper · Gemma — everything on-device.\n",
            attributes: body
        )

        // What's new in the running version, from the bundled notes.
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
        let notes = ReleaseNotes.bundled().map { ReleaseNotes.entries(for: version, in: $0) } ?? []
        if !notes.isEmpty {
            let left = NSMutableParagraphStyle()
            left.alignment = .left
            left.headIndent = 10
            left.paragraphSpacing = 3
            credits.append(NSAttributedString(string: "\nWhat's new in \(version)\n", attributes: [
                .font: NSFont.boldSystemFont(ofSize: 11),
                .foregroundColor: NSColor.labelColor,
            ]))
            for item in notes {
                credits.append(NSAttributedString(string: "•  \(item)\n", attributes: body.merging([.paragraphStyle: left]) { $1 }))
            }
            credits.append(link("All release notes", "https://github.com/Ihnatov-yuri/Macos-Transcriber/releases"))
            credits.append(NSAttributedString(string: "\n", attributes: body))
        }

        credits.append(NSAttributedString(string: "\nCreated by Yuri Ihnatov\n", attributes: body))
        credits.append(link("How it was built", "https://ihnatov.nl/transcriber/macos"))
        credits.append(NSAttributedString(string: "  ·  ", attributes: quiet))
        credits.append(link("ihnatov.nl", "https://ihnatov.nl"))
        credits.append(NSAttributedString(string: "  ·  ", attributes: quiet))
        credits.append(link("GitHub", "https://github.com/Ihnatov-yuri/Macos-Transcriber"))
        NSApp.orderFrontStandardAboutPanel(options: [
            .credits: credits,
            NSApplication.AboutPanelOptionKey(rawValue: "Copyright"):
                "© 2026 Yuri Ihnatov · PolyForm Noncommercial 1.0.0",
        ])
    }
}

/// Quit with a call on the Transcriberr Microphone: the call's mic goes
/// away with us (the device disappears and the call app picks another mic,
/// or none), so ask first.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard VirtualMicrophone.shared.isInUseByCall else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "A call is using the Transcriberr Microphone"
        alert.informativeText = "If you quit, the microphone disappears from the call. Most call apps then switch to your Mac's microphone without the echo filter; some go silent until you pick a microphone again."
        alert.addButton(withTitle: "Quit Anyway")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn ? .terminateNow : .terminateCancel
    }

    func applicationWillTerminate(_ notification: Notification) {
        VirtualMicrophone.shared.shutdown()
    }
}
