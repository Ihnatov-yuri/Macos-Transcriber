import SwiftUI

/// Centralizes every glass/lift effect so accessibility gating (Reduce
/// Transparency, Reduce Motion) is structural — built into the one place
/// these effects are produced — rather than a discipline repeated at every
/// call site. Consumers call `.litGlass`/`.litLift`, never the raw
/// `.glassEffect`/`.shadow` APIs directly.

enum LitLift {
    case one, two
}

extension View {
    /// Lit Field's `.panel`/`.veil` glass treatment (real macOS 26 Liquid
    /// Glass). Falls back to an opaque material when the user has Reduce
    /// Transparency on — glass belongs in the functional/chrome layer only,
    /// and it must stay legible with transparency off, not just
    /// decoratively degrade.
    func litGlass(strong: Bool = false, in shape: some Shape = RoundedRectangle(cornerRadius: AppMetric.radiusSm, style: .continuous)) -> some View {
        modifier(LitGlassModifier(strong: strong, shape: shape))
    }

    /// Lit Field's `--lift-1/2` (the two tiers this app actually uses — see
    /// the token file for the unported `--lift-3`): a crisp 1pt top-edge
    /// highlight plus two offset drop shadows, applied as real independent
    /// layers (not one shadow faking depth). `shape` clips the highlight so
    /// it doesn't overhang rounded corners; the drop shadows are added
    /// afterward so they aren't clipped away too.
    func litLift(_ tier: LitLift, in shape: some Shape = RoundedRectangle(cornerRadius: AppMetric.radiusSm, style: .continuous)) -> some View {
        modifier(LitLiftModifier(tier: tier, shape: shape))
    }
}

private struct LitGlassModifier<S: Shape>: ViewModifier {
    var strong: Bool
    var shape: S
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        if reduceTransparency {
            content.background(strong ? AppColor.veilStrong : AppColor.veil, in: shape)
        } else {
            content.glassEffect(.regular, in: shape)
        }
    }
}

private struct LitLiftModifier<S: Shape>: ViewModifier {
    var tier: LitLift
    var shape: S

    func body(content: Content) -> some View {
        let highlighted = content
            .overlay(alignment: .top) {
                Rectangle().fill(Color.white.opacity(0.9)).frame(height: 1)
            }
            .clipShape(shape)

        switch tier {
        case .one:
            highlighted
                .shadow(color: .black.opacity(0.05), radius: 1, x: 0, y: 1)
                .shadow(color: .black.opacity(0.30), radius: 6, x: 0, y: 3)
        case .two:
            highlighted
                .shadow(color: .black.opacity(0.06), radius: 1, x: 0, y: 1)
                .shadow(color: .black.opacity(0.38), radius: 13, x: 0, y: 7)
        }
    }
}
