import AppKit
import Carbon.HIToolbox

/// Puts dictated text into whatever app has keyboard focus.
///
/// Strategy: pasteboard + synthetic ⌘V. It is the only insertion path that
/// works in every text field, terminal, and web editor alike (typing
/// characters one by one breaks on IMEs and is slow; the Accessibility
/// `AXInsertText` route is unsupported by most apps). Posting the key
/// event requires Accessibility trust; without it the text is left on the
/// clipboard for a manual ⌘V.
@MainActor
enum TextInserter {
    enum Outcome: Equatable {
        case pasted
        case copiedOnly
    }

    /// Snapshot of the pasteboard so the user's clipboard survives the paste.
    private struct Snapshot {
        let items: [NSPasteboardItem]
        init(_ pb: NSPasteboard) {
            items = (pb.pasteboardItems ?? []).compactMap { item in
                let copy = NSPasteboardItem()
                var any = false
                for type in item.types {
                    if let data = item.data(forType: type) {
                        copy.setData(data, forType: type)
                        any = true
                    }
                }
                return any ? copy : nil
            }
        }
        func restore(to pb: NSPasteboard) {
            pb.clearContents()
            if !items.isEmpty { pb.writeObjects(items) }
        }
    }

    /// Only one restore may be pending; a second insert before the first
    /// restore fires must not put the FIRST dictation back on the clipboard.
    private static var pendingRestore: Task<Void, Never>?

    static func insert(_ text: String, restoreClipboard: Bool) -> Outcome {
        let pb = NSPasteboard.general
        pendingRestore?.cancel()
        pendingRestore = nil
        let snapshot = restoreClipboard ? Snapshot(pb) : nil

        pb.clearContents()
        pb.setString(text, forType: .string)

        guard HotkeyMonitor.isTrusted(), postPaste() else {
            AppLog.warn("dictation", "no Accessibility trust — text left on clipboard")
            return .copiedOnly
        }

        if let snapshot {
            // Apps read the pasteboard asynchronously after the key event;
            // 0.8 s covers slow Electron editors on a busy machine.
            pendingRestore = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 800_000_000)
                guard !Task.isCancelled else { return }
                // Don't clobber something the user copied in the meantime.
                if pb.string(forType: .string) == text {
                    snapshot.restore(to: pb)
                }
            }
        }
        return .pasted
    }

    static func copyOnly(_ text: String) {
        pendingRestore?.cancel()
        pendingRestore = nil
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    /// ⌘V via the HID event tap. Returns false if the events couldn't be built.
    private static func postPaste() -> Bool {
        guard let source = CGEventSource(stateID: .combinedSessionState) else { return false }
        let v = CGKeyCode(kVK_ANSI_V)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: v, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: v, keyDown: false)
        else { return false }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        return true
    }
}
