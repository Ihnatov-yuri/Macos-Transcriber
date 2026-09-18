import SwiftUI

// Reusable Lit Field building blocks. Every screen composes from these.

// MARK: - TapButton
//
// Replacement for SwiftUI.Button used as a tappable surface. SwiftUI's
// _ButtonGesture has a regression in macOS 26.5 that crashes in
// swift_task_isMainExecutorImpl whenever its action captures a
// @MainActor @Observable model and creates a Task. .onTapGesture
// sidesteps that entire gesture machinery.
//
// Use TapButton anywhere you'd otherwise write
//     Button { ... } label: { ... } .buttonStyle(.plain)
// Inside Menu / ContextMenu / Alert, keep using SwiftUI.Button — those
// hosts don't go through _ButtonGesture and don't crash.
//
// This is a behavioral workaround, not a visual concern — it stays exactly
// as-is regardless of design system.

struct TapButton<Label: View>: View {
    let action: () -> Void
    @ViewBuilder var label: () -> Label

    init(action: @escaping () -> Void, @ViewBuilder label: @escaping () -> Label) {
        self.action = action
        self.label = label
    }

    @State private var pressed = false

    var body: some View {
        label()
            .opacity(pressed ? 0.6 : 1.0)
            .contentShape(Rectangle())
            .onTapGesture(perform: action)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in if !pressed { pressed = true } }
                    .onEnded { _ in pressed = false }
            )
    }
}

extension TapButton where Label == Text {
    init(_ title: String, action: @escaping () -> Void) {
        self.action = action
        self.label = { Text(title) }
    }
}

// MARK: - Hairlines & rules
//
// Internal dividers and chip outlines ONLY — never a panel or section's
// outer edge. Lit Field: "border: 0... stated explicitly" for any surface's
// own frame; separation between surfaces comes from glass + lift shadow,
// not a drawn line.

/// 1.5pt divider at `hairStrong` (22% ink — the strongest hairline Lit
/// Field defines; it's still a light touch by design, not the old opaque
/// rule). The harder of the two internal-divider strengths — sparing use,
/// e.g. a list's single most important split.
struct InkRule: View {
    var body: some View {
        Rectangle()
            .fill(AppColor.hairStrong)
            .frame(height: 1.5)
    }
}

/// 1pt divider at `hair`. Interior row dividers.
struct Hairline: View {
    var body: some View {
        Rectangle()
            .fill(AppColor.hair)
            .frame(height: 1)
    }
}

/// 1pt divider softer than `Hairline`. Tightly-packed sub-rows.
struct HairlineSoft: View {
    var body: some View {
        Rectangle()
            .fill(AppColor.hair.opacity(0.7))
            .frame(height: 1)
    }
}

/// Vertical counterpart to `Hairline`.
struct VRule: View {
    var body: some View {
        Rectangle()
            .fill(AppColor.hair)
            .frame(width: 1)
            .frame(maxHeight: .infinity)
    }
}

// MARK: - Sheet

/// Flat `base`-colored full-page wrapper. Every screen lives inside one.
/// No animated atmosphere/gradient background — this app is 100% Operate
/// mode (dense working UI), and Lit Field's own guidance is that a
/// drifting light behind a form is a distraction, not atmosphere.
struct Sheet<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(AppColor.base)
    }
}

// MARK: - BrandStrip

/// `transcriberr● [meta?]` — the top wordmark + 7pt accent dot, optional
/// right-aligned label.
struct BrandStrip<RightSlot: View>: View {
    @ViewBuilder var right: RightSlot

    init(@ViewBuilder right: () -> RightSlot = { EmptyView() }) {
        self.right = right()
    }

    var body: some View {
        HStack(alignment: .lastTextBaseline, spacing: 6) {
            Text("transcriberr")
                .font(AppFont.display(20, weight: .semibold))
                .tracking(0.1)
                .foregroundStyle(AppColor.ink)
            Circle()
                .fill(AppColor.accent)
                .frame(width: 7, height: 7)
                .offset(y: -2)
            Spacer(minLength: AppMetric.s)
            right
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - SectionIndex

/// `01 / Library [summary]` block. Anchors the main content section.
struct SectionIndex: View {
    let number: Int
    let label: String
    let summary: String?

    init(_ number: Int, _ label: String, summary: String? = nil) {
        self.number = number
        self.label = label
        self.summary = summary
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 0) {
                Text(String(format: "%02d", number))
                    .uiLabel(11, color: AppColor.accentOnLight)
                Text(" / ")
                    .uiLabel(11, color: AppColor.ink3)
                Text(label)
                    .uiLabel(11)
            }
            if let summary {
                Text(summary)
                    .font(AppFont.text(13))
                    .foregroundStyle(AppColor.ink2)
                    .frame(maxWidth: 320, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - BigNumber

/// Archivo tabular numeral with optional accent suffix.
struct BigNumber: View {
    let value: String
    let suffix: String?
    let size: CGFloat

    init(_ value: String, suffix: String? = nil, size: CGFloat = 42) {
        self.value = value
        self.suffix = suffix
        self.size = size
    }

    var body: some View {
        HStack(alignment: .top, spacing: 5) {
            Text(value)
                .font(AppFont.display(size, weight: .semibold))
                .monospacedDigit()
                .tracking(-size * 0.015)
                .foregroundStyle(AppColor.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.55)
            if let suffix {
                // Fixed size, not proportional to `size`: this is a small
                // qualifier mark (yr/%/×), not a scaled-down echo of the
                // numeral — it should read the same regardless of how big
                // the number next to it is.
                Text(suffix)
                    .uiLabel(11, color: AppColor.accentOnLight)
                    .padding(.top, size * 0.18)
            }
        }
    }
}

// MARK: - LedgerRow

/// `[label]  [body]  [meta?]` — the workhorse row used in Settings,
/// metadata strips, etc.
struct LedgerRow<Body: View, Meta: View>: View {
    let label: String
    @ViewBuilder var rowBody: Body
    @ViewBuilder var meta: Meta

    init(
        _ label: String,
        @ViewBuilder rowBody: () -> Body,
        @ViewBuilder meta: () -> Meta = { EmptyView() }
    ) {
        self.label = label
        self.rowBody = rowBody()
        self.meta = meta()
    }

    var body: some View {
        HStack(alignment: .top, spacing: AppMetric.m) {
            Text(label)
                .uiLabel(10, color: AppColor.ink2)
                .frame(width: 74, alignment: .leading)
            rowBody
                .font(AppFont.text(13.5))
                .foregroundStyle(AppColor.ink)
                .frame(maxWidth: .infinity, alignment: .leading)
            meta
        }
        .padding(.vertical, AppMetric.rowVPad)
    }
}

// MARK: - PulseDot

/// 8pt accent dot with a continuous expand-and-fade ring. The ONLY
/// infinite animation in the app; respects Reduce Motion (the ring stays
/// static rather than looping).
struct PulseDot: View {
    var diameter: CGFloat = 8
    @State private var phase: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Circle()
                .stroke(AppColor.accent.opacity(0.55 * (1 - phase)), lineWidth: 1)
                .frame(width: diameter * (1 + 1.4 * phase),
                       height: diameter * (1 + 1.4 * phase))
            Circle().fill(AppColor.accent)
                .frame(width: diameter, height: diameter)
        }
        .frame(width: diameter * 2.4, height: diameter * 2.4)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.linear(duration: 1.8).repeatForever(autoreverses: false)) {
                phase = 1
            }
        }
    }
}

// MARK: - InverseFooter

/// Edge-to-edge `night`-ground CTA row — Lit Field's `.btn-primary` recipe
/// applied to a full-bleed bar rather than a pill, since this replaces
/// buttons for primary actions (RECORD, RUN TRANSCRIPTION, etc.) at the
/// bottom of a screen. The fixed component-level inversion idiom: the rest
/// of the screen stays light, this one bar goes dark.
struct InverseFooter<Left: View, Right: View>: View {
    let title: String
    let subtitle: String?
    let action: () -> Void
    @ViewBuilder var left: Left
    @ViewBuilder var right: Right

    init(
        _ title: String,
        subtitle: String? = nil,
        action: @escaping () -> Void = {},
        @ViewBuilder left: () -> Left = { EmptyView() },
        @ViewBuilder right: () -> Right = { EmptyView() }
    ) {
        self.title = title
        self.subtitle = subtitle
        self.action = action
        self.left = left()
        self.right = right()
    }

    var body: some View {
        // Uses TapButton (not SwiftUI.Button) to avoid the macOS 26.5
        // _ButtonGesture crash when the action captures a @MainActor model.
        TapButton(action: action) {
            content
        }
    }

    // Broken out of `body` so the chain type-checks independently of
    // TapButton's generic Label inference — `.background(_:in:)` (not the
    // bare-ShapeStyle overload, which is ambiguous when the style also
    // conforms to View, as Color does) is what actually lets `.litLift`
    // resolve here.
    @ViewBuilder private var content: some View {
        HStack(alignment: .center, spacing: AppMetric.m) {
            left
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(AppFont.display(17, weight: .semibold))
                    .tracking(0.1)
                    .foregroundStyle(AppColor.onNight)
                if let subtitle {
                    Text(subtitle)
                        .uiLabel(9.5, color: AppColor.onNight2)
                }
            }
            Spacer(minLength: AppMetric.s)
            right
        }
        .padding(.horizontal, AppMetric.l)
        .padding(.vertical, AppMetric.sheetVerticalPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppColor.night, in: Rectangle())
        .litLift(.one, in: Rectangle())
    }
}

// MARK: - TagPair (options row)

/// `LABEL  VALUE` underline pair used on the Record screen options row.
struct TagPair: View {
    let label: String
    let value: String
    var active: Bool = false
    var action: () -> Void = {}

    var body: some View {
        TapButton(action: action) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    Text(label).uiLabel(10, color: AppColor.ink2)
                    Text(value).uiLabel(10)
                }
                // One line, at its own width — in a crowded row a pair used
                // to wrap mid-value; rows of pairs wrap as a whole instead
                // (FlowLayout).
                .lineLimit(1)
                .fixedSize()
                // No fixed width: a VStack proposes its own resolved width
                // (set by its widest child, the HStack above) to every
                // child, so a Rectangle with only a height constraint
                // stretches to match the text's actual width instead of a
                // guessed constant that reads wrong on longer values.
                Rectangle()
                    .fill(active ? AppColor.accent : Color.clear)
                    .frame(height: 1.5)
            }
        }
    }
}

// MARK: - Eyebrow row

/// `LABEL [middle?] [right?]` row above lists.
struct EyebrowRow<Middle: View, Right: View>: View {
    let label: String
    @ViewBuilder var middle: Middle
    @ViewBuilder var right: Right

    init(
        _ label: String,
        @ViewBuilder middle: () -> Middle = { EmptyView() },
        @ViewBuilder right: () -> Right = { EmptyView() }
    ) {
        self.label = label
        self.middle = middle()
        self.right = right()
    }

    var body: some View {
        HStack(spacing: AppMetric.s) {
            Text(label).uiLabel(10, color: AppColor.ink2)
            Spacer(minLength: 0)
            middle
            right
        }
    }
}

// MARK: - LitChip

/// Pill chip, direct port of `.chip`/`.chip-night`: translucent-white
/// outlined pill at rest, solid `night` ground with Archivo when active.
struct LitChip: View {
    let label: String
    var active: Bool = false
    var action: () -> Void = {}

    var body: some View {
        TapButton(action: action) {
            Text(label)
                .font(active ? AppFont.display(12.5, weight: .semibold) : AppFont.text(13.5))
                .foregroundStyle(active ? AppColor.onNight : AppColor.ink2)
                .padding(.horizontal, AppMetric.chipPaddingH)
                .padding(.vertical, AppMetric.chipPaddingV)
                .background {
                    if active {
                        Capsule().fill(AppColor.night)
                    } else {
                        Capsule().fill(Color.white.opacity(0.66))
                            .overlay(Capsule().stroke(AppColor.hair))
                    }
                }
        }
    }
}
