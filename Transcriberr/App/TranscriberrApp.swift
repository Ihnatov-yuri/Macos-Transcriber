import SwiftUI
import SwiftData
import AppKit

@main
struct TranscriberrApp: App {
    @State private var container: AppContainer

    init() {
        FontLoader.registerBundledFonts()
        AppLog.bootBanner()
        AppLog.info("app", "log file: \(AppLog.logFileURL.path)")
        _container = State(initialValue: AppContainer())
    }

    var body: some Scene {
        WindowGroup {
            AppShell()
                .environment(container)
                .modelContainer(container.modelContainer)
                .frame(minWidth: 980, minHeight: 640)
                .background(AppColor.paper.ignoresSafeArea())
                .preferredColorScheme(.light)
        }
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unifiedCompact(showsTitle: false))
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About Transcriberr") { Self.showAbout() }
            }
            CommandGroup(replacing: .newItem) {
                Button("New Recording") { container.requestNewRecording() }
                    .keyboardShortcut("n")
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
                .frame(minWidth: 560, minHeight: 480)
        }
    }

    /// Standard macOS About panel with author credits (macOS menu → About).
    @MainActor
    private static func showAbout() {
        let credits = NSMutableAttributedString(
            string: "Local-first transcription studio.\nParakeet · Whisper · Gemma — everything on-device.\n\nCreated by Yuri Ihnatov\n",
            attributes: [
                .font: NSFont.systemFont(ofSize: 11),
                .foregroundColor: NSColor.labelColor,
            ]
        )
        credits.append(NSAttributedString(
            string: "ihnatov.nl",
            attributes: [
                .font: NSFont.systemFont(ofSize: 11),
                .link: URL(string: "https://ihnatov.nl")!,
            ]
        ))
        credits.append(NSAttributedString(
            string: "  ·  ",
            attributes: [.font: NSFont.systemFont(ofSize: 11),
                         .foregroundColor: NSColor.secondaryLabelColor]
        ))
        credits.append(NSAttributedString(
            string: "github.com/Ihnatov-yuri",
            attributes: [
                .font: NSFont.systemFont(ofSize: 11),
                .link: URL(string: "https://github.com/Ihnatov-yuri")!,
            ]
        ))
        NSApp.orderFrontStandardAboutPanel(options: [
            .credits: credits,
            NSApplication.AboutPanelOptionKey(rawValue: "Copyright"):
                "© 2026 Yuri Ihnatov · PolyForm Noncommercial 1.0.0",
        ])
    }
}
