import Foundation

/// Which links in model-written text a click may open.
///
/// Preset outputs (summaries, action items) are Markdown written by the local
/// text model or a cloud model from the transcript, and the transcript is whatever anyone
/// in the meeting said — or what a crafted calendar invite or an imported
/// file put in front of the model. SwiftUI renders `[text](url)` in those
/// outputs as a live link whose label says nothing about where it goes, and
/// the default action hands ANY scheme to Launch Services: `file:` (opens or
/// runs a local file), `transcriberr:` (drives our own dictation), a
/// `x-apple.systempreferences:` pane, a `vnc:` / `ssh:` / `smb:` handler, a
/// custom scheme registered by any installed app. Web links stay clickable;
/// everything else is inert.
nonisolated enum SafeLink {
    static let allowedSchemes: Set<String> = ["https", "http", "mailto"]

    static func isOpenable(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), allowedSchemes.contains(scheme) else { return false }
        if scheme == "mailto" { return true }
        // A web link needs a host: "https:relative" or "http:///etc" is not one.
        guard let host = url.host(percentEncoded: false), !host.isEmpty else { return false }
        return true
    }
}
