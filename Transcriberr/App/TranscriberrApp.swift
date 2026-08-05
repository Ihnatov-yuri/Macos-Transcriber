import SwiftUI
import SwiftData

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
            CommandGroup(replacing: .newItem) {
                Button("New Recording") { container.requestNewRecording() }
                    .keyboardShortcut("n")
            }
        }

        Settings {
            SettingsView()
                .environment(container)
                .frame(minWidth: 560, minHeight: 480)
        }
    }
}
