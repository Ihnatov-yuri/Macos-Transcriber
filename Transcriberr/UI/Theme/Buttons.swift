import SwiftUI

/// Chrome for a button LABEL — not a `ButtonStyle`. Half the app's
/// interactive elements are `TapButton` (see Primitives.swift), the
/// `.onTapGesture`-based replacement for `Button` required to avoid a
/// macOS-26.5 SwiftUI crash, and a `ButtonStyle` only ever attaches to a
/// real `Button`. Every real `Button` left in this app is
/// Menu/alert/contextMenu/`.commands`-hosted native chrome that can't be
/// (and shouldn't be) reskinned — same reasoning as leaving system
/// scrollbars and `Form` chrome alone.
///
/// Usage: `TapButton(action: run) { LitButtonChrome(.primary) { Text("Run Transcription") } }`
enum LitButtonVariant {
    case primary, accent, secondary, ghost, destructive
}

struct LitButtonChrome<Label: View>: View {
    var variant: LitButtonVariant
    /// Full-size (48pt min-height pill, per `.btn`) or a compact inline
    /// form-row size — used for the few buttons living inside native
    /// `Form`/`Section` rows (Settings) rather than as standalone CTAs.
    var compact: Bool = false
    @ViewBuilder var label: () -> Label

    @State private var hovering = false

    init(_ variant: LitButtonVariant, compact: Bool = false, @ViewBuilder label: @escaping () -> Label) {
        self.variant = variant
        self.compact = compact
        self.label = label
    }

    var body: some View {
        label()
            .font(AppFont.display(compact ? 13 : 15, weight: .semibold))
            .tracking(-0.1)
            .foregroundStyle(foreground)
            .padding(.horizontal, compact ? AppMetric.m : AppMetric.btnPaddingH)
            .frame(minHeight: compact ? 28 : AppMetric.btnMinHeight)
            .background {
                background
            }
            // No outer .clipShape(Capsule()) here: every `background` case is
            // already a self-contained Capsule (fill/stroke/clear), so it
            // never overflows the label's bounds — and a clip here would cut
            // off .litLift's drop shadow, which is deliberately drawn outside
            // its own inner clip (see Materials.swift). Confirmed by review:
            // this used to silently flatten every primary/accent button.
            .opacity(hovering ? 0.92 : 1)
            .onHover { hovering = $0 }
    }

    @ViewBuilder private var background: some View {
        switch variant {
        case .primary:
            Capsule().fill(AppColor.night).litLift(.one, in: Capsule())
        case .accent:
            Capsule().fill(AppColor.accent).litLift(.one, in: Capsule())
        case .secondary:
            Capsule().fill(Color.white.opacity(0.6))
                .overlay(Capsule().stroke(AppColor.controlBorder))
        case .ghost:
            Color.clear
        case .destructive:
            Capsule().stroke(AppColor.statusError)
        }
    }

    private var foreground: Color {
        switch variant {
        case .primary:     AppColor.onNight
        case .accent:      AppColor.ink
        case .secondary:   AppColor.ink
        case .ghost:       AppColor.ink2
        case .destructive: AppColor.statusError
        }
    }
}
