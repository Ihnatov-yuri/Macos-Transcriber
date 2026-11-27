import AppKit
import SwiftUI

/// A pop-out note for something that happened to a running recording while
/// the user is in another app (the meeting itself, usually): the same
/// floating card as the dictation HUD — non-activating, ignores the mouse,
/// on every Space — with the recording's own label, and gone by itself after
/// a few seconds. First use: the microphone changed mid-meeting.
@MainActor
final class RecordingNoticeHUD {
    static let shared = RecordingNoticeHUD()

    /// How long a note stays up. Longer than dictation's 2.4 s: this one
    /// arrives unasked, while the user is looking at a call.
    static let visibleSeconds: TimeInterval = 6

    private var panel: NSPanel?
    private var hideTask: Task<Void, Never>?
    private let model = Model()

    @Observable @MainActor
    final class Model {
        var title = ""
        var text = ""
    }

    private let cardSize = NSSize(width: 360, height: 88)
    private let shadowMargin: CGFloat = 24
    private var size: NSSize {
        NSSize(width: cardSize.width + shadowMargin * 2, height: cardSize.height + shadowMargin * 2)
    }

    func show(title: String, text: String) {
        model.title = title
        model.text = text
        if panel == nil { build() }
        guard let panel else { return }
        position(panel)
        panel.alphaValue = 1
        panel.orderFrontRegardless()
        hideTask?.cancel()
        hideTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.visibleSeconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.panel?.orderOut(nil)
        }
    }

    private func build() {
        let p = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        p.level = .floating
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.ignoresMouseEvents = true
        p.hidesOnDeactivate = false
        p.isFloatingPanel = true
        p.becomesKeyOnlyIfNeeded = true
        p.isReleasedWhenClosed = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        p.appearance = NSAppearance(named: .darkAqua)
        let host = NSHostingView(rootView: RecordingNoticeView(model: model, cardSize: cardSize, margin: shadowMargin))
        host.frame = NSRect(origin: .zero, size: size)
        // See DictationHUD.build: without a clear layer nothing inside can
        // be translucent.
        host.wantsLayer = true
        host.layer?.backgroundColor = NSColor.clear.cgColor
        p.contentView = host
        panel = p
    }

    /// Where the dictation HUD sits (bottom centre of the pointer's screen),
    /// a card's height higher, so the two never cover each other.
    private func position(_ panel: NSPanel) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let frame = screen?.visibleFrame else { return }
        let origin = NSPoint(
            x: frame.midX - size.width / 2,
            y: frame.minY + 56 + cardSize.height + 12 - shadowMargin
        )
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
    }
}

private struct RecordingNoticeView: View {
    let model: RecordingNoticeHUD.Model
    let cardSize: NSSize
    let margin: CGFloat

    var body: some View {
        HStack(alignment: .center, spacing: AppMetric.m) {
            Rectangle().fill(AppColor.accent).frame(width: 8, height: 8)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 4) {
                Text(model.title).uiLabel(9, color: AppColor.accent)
                Text(model.text)
                    .font(AppFont.text(14))
                    .foregroundStyle(AppColor.onNight)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, AppMetric.m)
        .padding(.vertical, AppMetric.s)
        .frame(width: cardSize.width, height: cardSize.height)
        .background {
            RoundedRectangle(cornerRadius: AppMetric.radiusSm, style: .continuous)
                .fill(AppColor.night.opacity(0.55))
                .shadow(color: .black.opacity(0.06), radius: 1, x: 0, y: 1)
                .shadow(color: .black.opacity(0.38), radius: 13, x: 0, y: 7)
        }
        .padding(margin)
    }
}
