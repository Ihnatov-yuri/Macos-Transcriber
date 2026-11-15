import AppKit

/// The interface language: English, Ukrainian or Dutch, or whatever macOS
/// picks from the system's preferred languages. Stored the way macOS stores a
/// per-app language (`AppleLanguages` in the app's own defaults, the same key
/// System Settings › Language & Region › Applications writes), so it takes
/// effect at the next launch. Transcripts, prompts and the model's answers
/// are not affected: they follow the speech and the presets.
nonisolated enum AppLanguage: String, CaseIterable, Sendable {
    case system, en, uk, nl

    /// Each language in its own name, so it can be found from any of them.
    var name: String {
        switch self {
        case .system: String(localized: "System")
        case .en: "English"
        case .uk: "Українська"
        case .nl: "Nederlands"
        }
    }

    private static let key = "AppleLanguages"

    /// The app's own choice, not the global list macOS also answers with.
    static func chosen(in defaults: UserDefaults = .standard,
                       domain: String = Bundle.main.bundleIdentifier ?? "nl.ihnatov.Transcriberr") -> AppLanguage {
        let own = defaults.persistentDomain(forName: domain)?[key] as? [String]
        guard let first = own?.first else { return .system }
        return AppLanguage(rawValue: String(first.prefix(2))) ?? .system
    }

    static func choose(_ language: AppLanguage, in defaults: UserDefaults = .standard) {
        if language == .system {
            defaults.removeObject(forKey: key)
        } else {
            defaults.set([language.rawValue], forKey: key)
        }
    }

    /// The language the running app shows.
    static var showing: AppLanguage {
        AppLanguage(rawValue: Bundle.main.preferredLocalizations.first.map { String($0.prefix(2)) } ?? "en") ?? .en
    }

    /// Quit and open again, for the new language to take effect.
    @MainActor
    static func relaunch() {
        let path = Bundle.main.bundleURL.path
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        // Wait for this copy to be gone, or `open` brings it forward
        // instead of starting a new one.
        p.arguments = ["-c", "while /bin/kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do /bin/sleep 0.2; done; /usr/bin/open \"$0\"", path]
        do {
            try p.run()
            NSApp.terminate(nil)
        } catch {
            AppLog.warn("app", "could not relaunch for the language change: \(error.localizedDescription)")
        }
    }
}
