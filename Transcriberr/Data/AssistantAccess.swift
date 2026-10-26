import Foundation

/// Whether AI assistants (Claude and other MCP clients) may read the
/// library through `transcriberrcli mcp` and `transcriberrcli kb`.
/// Settings → AI assistants switches it; the CLI is a separate process, so
/// it reads the app's preferences fresh on every request: switching it off
/// cuts off an assistant that is already connected, at its next call.
enum AssistantAccess {
    /// The app's preferences domain, which the CLI reads too.
    static let domain = "nl.ihnatov.Transcriberr" as CFString
    static let allowedKey = "assistants.allowed"
    static let lastReadKey = "assistants.lastRead"

    /// On unless switched off: the library has been open to assistants
    /// since 2.3.0.
    static var isAllowed: Bool {
        CFPreferencesAppSynchronize(domain)
        return (CFPreferencesCopyAppValue(allowedKey as CFString, domain) as? Bool) ?? true
    }

    /// When an assistant last read something, for Settings to show.
    static var lastRead: Date? {
        CFPreferencesAppSynchronize(domain)
        return CFPreferencesCopyAppValue(lastReadKey as CFString, domain) as? Date
    }

    static func noteRead(now: Date = Date()) {
        CFPreferencesSetAppValue(lastReadKey as CFString, now as CFDate, domain)
        CFPreferencesAppSynchronize(domain)
    }

    static let refusal = "AI assistant access is switched off in Transcriberr (Settings → AI assistants). Nothing in the library can be read until the user switches it on again."
}
