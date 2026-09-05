import AppKit
import SwiftUI

/// Small floating status strip shown while dictating into another app.
/// A non-activating panel: it never takes keyboard focus away from the app
/// that will receive the text, ignores the mouse, and rides along on every
/// Space (including full-screen apps).
@MainActor
final class DictationHUD {
    private let controller: DictationController
    private var panel: NSPanel?
    private var hideTask: Task<Void, Never>?

    private let size = NSSize(width: 400, height: 84)

    init(controller: DictationController) {
        self.controller = controller
    }

    func show() {
        hideTask?.cancel()
        hideTask = nil
        if panel == nil { build() }
        guard let panel else { return }
        position(panel)
        panel.alphaValue = 1
        panel.orderFrontRegardless()
    }

    func hide(after delay: TimeInterval = 0) {
        hideTask?.cancel()
        guard delay > 0 else { panel?.orderOut(nil); return }
        hideTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
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
        p.hasShadow = true
        p.ignoresMouseEvents = true
        p.hidesOnDeactivate = false
        p.isFloatingPanel = true
        p.becomesKeyOnlyIfNeeded = true
        p.isReleasedWhenClosed = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        // The main window forces light; match it so the paper palette reads.
        p.appearance = NSAppearance(named: .aqua)
        let host = NSHostingView(rootView: DictationHUDView(controller: controller))
        host.frame = NSRect(origin: .zero, size: size)
        p.contentView = host
        panel = p
    }

    /// Bottom-centre of the screen the pointer is on.
    private func position(_ panel: NSPanel) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        guard let frame = screen?.visibleFrame else { return }
        let origin = NSPoint(
            x: frame.midX - size.width / 2,
            y: frame.minY + 56
        )
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
    }
}

/// Paper strip with a hairline border: status label, the live meter, and
/// the last recognized line.
struct DictationHUDView: View {
    let controller: DictationController

    var body: some View {
        HStack(alignment: .center, spacing: AppMetric.m) {
            statusGlyph
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 5) {
                Text(statusLabel).monoLabel(9.5, color: statusColor)
                Text(bodyLine)
                    .font(AppFont.fraunces(15, italic: true))
                    .tracking(-0.2)
                    .foregroundStyle(bodyIsPlaceholder ? AppColor.inkSoft : AppColor.ink)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            meter
                .frame(width: 84, height: 30)
        }
        .padding(.horizontal, AppMetric.l)
        .padding(.vertical, AppMetric.m)
        .frame(width: 400, height: 84)
        .background(AppColor.paperLight)
        .overlay(Rectangle().stroke(AppColor.inkLight, lineWidth: 1.5))
    }

    @ViewBuilder
    private var statusGlyph: some View {
        switch controller.phase {
        case .listening:
            PulseDot(diameter: 7)
        case .transcribing, .inserting:
            ProgressView().controlSize(.small)
        case .message:
            Rectangle().fill(AppColor.accent).frame(width: 8, height: 8)
        case .idle:
            Rectangle().fill(AppColor.inkLight).frame(width: 8, height: 8)
        }
    }

    private var statusLabel: String {
        switch controller.phase {
        case .listening:
            let t = Int(controller.capture.elapsedSeconds)
            let pending = controller.pendingPasses > 0 ? " · WRITING…" : ""
            return String(format: "LISTENING · %d:%02d%@", t / 60, t % 60, pending)
        case .transcribing: return controller.settings.polish ? "RECOGNIZING · POLISHING" : "RECOGNIZING"
        case .inserting:    return "INSERTING"
        case .message:      return "DICTATION"
        case .idle:         return "INSERTED"
        }
    }

    private var statusColor: Color {
        switch controller.phase {
        case .listening, .message: return AppColor.accent
        default:                   return AppColor.inkLight.opacity(0.62)
        }
    }

    private var bodyIsPlaceholder: Bool {
        switch controller.phase {
        case .listening:
            return controller.lastText.isEmpty
        case .message:
            return false
        default:
            return controller.lastText.isEmpty
        }
    }

    private var bodyLine: String {
        switch controller.phase {
        case .message(let m):
            return m
        case .listening:
            if !controller.lastText.isEmpty { return controller.lastText }
            return controller.settings.mode == .hold
                ? "Speak, then release \(controller.settings.hotkey.glyph)."
                : "Speak. Tap \(controller.settings.hotkey.glyph) again to stop."
        case .transcribing, .inserting:
            return controller.lastText.isEmpty ? "…" : controller.lastText
        case .idle:
            return controller.lastText
        }
    }

    private var meter: some View {
        GeometryReader { geo in
            let bars = Array(controller.capture.peakHistory.suffix(24))
            let gap: CGFloat = 2
            let w = max(1.5, (geo.size.width - CGFloat(bars.count - 1) * gap) / CGFloat(max(1, bars.count)))
            HStack(alignment: .center, spacing: gap) {
                ForEach(Array(bars.enumerated()), id: \.offset) { idx, peak in
                    let db = 20 * log10(max(1e-4, Double(peak)))
                    let n = max(0, min(1, CGFloat((db + 60) / 60)))
                    Rectangle()
                        .fill(idx == bars.count - 1 ? AppColor.accent : AppColor.inkLight.opacity(0.8))
                        .frame(width: w, height: max(2, geo.size.height * n))
                }
            }
            .frame(maxHeight: .infinity, alignment: .center)
        }
        .opacity(controller.phase == .listening ? 1 : 0.35)
    }
}
