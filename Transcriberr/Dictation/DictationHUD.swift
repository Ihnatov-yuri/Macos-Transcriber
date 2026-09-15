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

    /// The visible glass card. The panel itself is larger (see `size`) —
    /// real content needs a transparent margin around it or its lift
    /// shadow hard-clips at the window bounds. `.litLift(.two)`'s largest
    /// shadow layer (radius 13, y offset 7) reaches ~20pt past the card's
    /// bottom edge, so this has to clear that, not just look roomy.
    private let cardSize = NSSize(width: 340, height: 88)
    private let shadowMargin: CGFloat = 24
    private var size: NSSize {
        NSSize(width: cardSize.width + shadowMargin * 2, height: cardSize.height + shadowMargin * 2)
    }

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
        // The glass card draws its own precise lift shadow; the window-level
        // shadow would double up on it (and, being silhouette-based, would
        // roughly coincide with it anyway now that the card is glass, not a
        // flat opaque fill).
        p.hasShadow = false
        p.ignoresMouseEvents = true
        p.hidesOnDeactivate = false
        p.isFloatingPanel = true
        p.becomesKeyOnlyIfNeeded = true
        p.isReleasedWhenClosed = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        // .hudWindow material (below) renders dark by design regardless of
        // the app's own appearance — it's Apple's material for exactly
        // this "floating overlay while doing something else" case (Quick
        // Look info, the volume/brightness HUD). Pin the panel to match so
        // vibrancy computes against the right base, and DictationHUDView's
        // colors below are the night-ground tokens the rest of the app
        // already uses for the same fixed-inversion idiom.
        p.appearance = NSAppearance(named: .darkAqua)
        let host = NSHostingView(rootView: DictationHUDView(controller: controller, cardSize: cardSize, margin: shadowMargin))
        host.frame = NSRect(origin: .zero, size: size)
        // NSHostingView backs itself with an opaque layer by default —
        // independent of the panel's own isOpaque/backgroundColor, and
        // independent of whether the SwiftUI content uses .glassEffect or
        // NSVisualEffectView internally. Without this, nothing inside can
        // ever be genuinely translucent: it composites against this opaque
        // layer before the panel's transparency ever comes into play.
        host.wantsLayer = true
        host.layer?.backgroundColor = NSColor.clear.cgColor
        p.contentView = host
        panel = p
    }

    /// Bottom-centre of the screen the pointer is on. The visible card sits
    /// `shadowMargin` inside the (larger) panel on every side, so the panel
    /// origin is offset up by that margin to keep the CARD's bottom edge —
    /// not the panel's — anchored 56pt above the screen bottom.
    private func position(_ panel: NSPanel) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        guard let frame = screen?.visibleFrame else { return }
        let origin = NSPoint(
            x: frame.midX - size.width / 2,
            y: frame.minY + 56 - shadowMargin
        )
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
    }
}

/// Glass strip: status label, the live meter, and the last recognized line.
struct DictationHUDView: View {
    let controller: DictationController
    let cardSize: NSSize
    let margin: CGFloat

    var body: some View {
        card
            .frame(width: cardSize.width, height: cardSize.height)
            .padding(margin)
    }

    private var card: some View {
        // Lift shadow lives in `.background`, a sibling layer with no
        // dependency on `controller` — not wrapped around `row` directly.
        // `row` contains the level meter, which updates at ~12.5Hz while
        // dictating; if the shadow chain wrapped it, those two shadow
        // layers would recompute on every tick instead of once.
        //
        // Plain translucent fill, not NSVisualEffectView/.glassEffect:
        // three different real-blur mechanisms (.glassEffect, .popover,
        // .hudWindow — all via this same NSPanel/NSHostingView) each came
        // out flat/opaque in practice, not just less transparent than
        // hoped. A flat fill over a truly clear, non-opaque panel needs no
        // live-compositor cooperation — it's ordinary alpha blending — so
        // it's the version that's actually guaranteed to be see-through,
        // traded against losing the frosted-blur quality.
        row
            .padding(.horizontal, AppMetric.m)
            .padding(.vertical, AppMetric.s)
            .frame(width: cardSize.width, height: cardSize.height)
            .background {
                // Not .litLift: its top-edge highlight is a bright white
                // line meant for opaque light/dark panels, and reads as a
                // stray stripe on a translucent card where everything else
                // is soft. Same two drop-shadow layers as .litLift(.two),
                // without that highlight.
                RoundedRectangle(cornerRadius: AppMetric.radiusSm, style: .continuous)
                    .fill(AppColor.night.opacity(0.55))
                    .shadow(color: .black.opacity(0.06), radius: 1, x: 0, y: 1)
                    .shadow(color: .black.opacity(0.38), radius: 13, x: 0, y: 7)
            }
    }

    private var row: some View {
        HStack(alignment: .center, spacing: AppMetric.m) {
            statusGlyph
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 4) {
                Text(statusLabel).uiLabel(9, color: statusColor)
                Text(bodyLine)
                    .font(AppFont.text(14))
                    .foregroundStyle(bodyIsPlaceholder ? AppColor.onNight2 : AppColor.onNight)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            meter
                .frame(width: 56, height: 22)
        }
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
            Rectangle().fill(AppColor.onNight).frame(width: 8, height: 8)
        }
    }

    private var statusLabel: String {
        switch controller.phase {
        case .listening:
            guard controller.micOpen else { return "Opening mic" }
            let t = Int(controller.capture.elapsedSeconds)
            let pending = controller.pendingPasses > 0 ? " · writing…" : ""
            return String(format: "Listening · %d:%02d%@", t / 60, t % 60, pending)
        case .transcribing: return controller.activeMode == .smart ? "Recognizing · formatting" : "Recognizing"
        case .inserting:    return "Inserting"
        case .message:      return "Dictation"
        case .idle:         return "Inserted"
        }
    }

    private var statusColor: Color {
        // accent, not accentOnLight: on a night ground the CSS's own rule
        // flips which accent value is text-safe (see the focus-ring
        // override for .on-night in the token file) — same idiom as
        // InverseFooter, just for text here instead of a focus ring.
        switch controller.phase {
        case .listening, .message: return AppColor.accent
        default:                   return AppColor.onNight2
        }
    }

    private var bodyIsPlaceholder: Bool {
        switch controller.phase {
        case .listening:
            return controller.lastText.isEmpty && controller.previewText.isEmpty
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
            if !controller.previewText.isEmpty { return controller.previewText + " …" }
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
            let bars = Array(controller.capture.peakHistory.suffix(18))
            let gap: CGFloat = 1.5
            let w = max(1.5, (geo.size.width - CGFloat(bars.count - 1) * gap) / CGFloat(max(1, bars.count)))
            HStack(alignment: .center, spacing: gap) {
                ForEach(Array(bars.enumerated()), id: \.offset) { idx, peak in
                    let db = 20 * log10(max(1e-4, Double(peak)))
                    let n = max(0, min(1, CGFloat((db + 60) / 60)))
                    Rectangle()
                        .fill(idx == bars.count - 1 ? AppColor.accent : AppColor.onNight.opacity(0.8))
                        .frame(width: w, height: max(2, geo.size.height * n))
                }
            }
            .frame(maxHeight: .infinity, alignment: .center)
        }
        .opacity(controller.phase == .listening ? 1 : 0.35)
    }
}
