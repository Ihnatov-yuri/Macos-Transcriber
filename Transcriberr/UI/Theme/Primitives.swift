import SwiftUI

// Ported 1:1 from Android `ui/components/Primitives.kt`. Every screen is
// composed from these blocks — keep them visually rigid.

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

/// 1.5dp full-width ink line. Top-level joints (header → content,
/// section → section). NEVER for row-to-row separation.
struct InkRule: View {
    var body: some View {
        Rectangle()
            .fill(AppColor.ink)
            .frame(height: AppMetric.inkRuleWidth)
    }
}

/// 1dp dim line at 16% ink. Interior row dividers.
struct Hairline: View {
    var body: some View {
        Rectangle()
            .fill(AppColor.hairline)
            .frame(height: AppMetric.hairlineWidth)
    }
}

/// 1dp very-dim line at 10% ink. Tightly-packed sub-rows.
struct HairlineSoft: View {
    var body: some View {
        Rectangle()
            .fill(AppColor.hairlineSoft)
            .frame(height: AppMetric.hairlineWidth)
    }
}

// MARK: - Sheet

/// Paper-colored full-page wrapper. Every screen lives inside one.
struct Sheet<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(AppColor.paper)
    }
}

// MARK: - BrandStrip

/// `transcriber● [meta?]` — the top wordmark + 7dp accent dot, optional
/// right-aligned label.
struct BrandStrip<RightSlot: View>: View {
    @ViewBuilder var right: RightSlot

    init(@ViewBuilder right: () -> RightSlot = { EmptyView() }) {
        self.right = right()
    }

    var body: some View {
        HStack(alignment: .lastTextBaseline, spacing: 6) {
            Text("transcriberr")
                .font(AppFont.saira(20, weight: .semibold))
                .tracking(0.4)
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

/// `01 / LIBRARY [summary]` block. Anchors the main content section.
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
                    .monoLabel(11, tracking: 1.0, color: AppColor.accent)
                Text(" / ")
                    .monoLabel(11, tracking: 1.0, color: AppColor.ink.opacity(0.45))
                Text(label)
                    .monoLabel(11, tracking: 1.2)
            }
            if let summary {
                Text(summary)
                    .font(AppFont.inter(13))
                    .foregroundStyle(AppColor.inkSoft)
                    .frame(maxWidth: 320, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - BigNumber

/// Saira Condensed tabular numeral with optional Accent suffix.
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
                .font(AppFont.saira(size, weight: .semibold))
                .monospacedDigit()
                .tracking(-size * 0.015)
                .foregroundStyle(AppColor.ink)
            if let suffix {
                Text(suffix)
                    .monoLabel(10.5, color: AppColor.accent)
                    .padding(.top, size * 0.18)
            }
        }
    }
}

// MARK: - LedgerRow

/// `[label]  [body]  [meta?]` — the workhorse row used in Settings, metadata
/// strips, etc.
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
                .monoLabel(10, color: AppColor.inkSoft)
                .frame(width: 74, alignment: .leading)
            rowBody
                .font(AppFont.inter(13.5))
                .foregroundStyle(AppColor.ink)
                .frame(maxWidth: .infinity, alignment: .leading)
            meta
        }
        .padding(.vertical, AppMetric.rowVPad)
    }
}

// MARK: - PulseDot

/// 8dp accent dot with a continuous expand-and-fade ring. The ONLY infinite
/// animation in the app (matches the Android spec).
struct PulseDot: View {
    var diameter: CGFloat = 8
    @State private var phase: CGFloat = 0

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
            withAnimation(.linear(duration: 1.8).repeatForever(autoreverses: false)) {
                phase = 1
            }
        }
    }
}

// MARK: - InverseFooter

/// Edge-to-edge dark CTA row. Replaces buttons for primary actions
/// (RECORD, RUN TRANSCRIPTION, etc.).
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
            HStack(alignment: .center, spacing: AppMetric.m) {
                left
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(AppFont.saira(17, weight: .semibold))
                        .tracking(0.4)
                        .textCase(.uppercase)
                        .foregroundStyle(AppColor.paper)
                    if let subtitle {
                        Text(subtitle)
                            .monoLabel(9, color: AppColor.paper.opacity(0.55))
                    }
                }
                Spacer(minLength: AppMetric.s)
                right
            }
            .padding(.horizontal, AppMetric.l)
            .padding(.vertical, AppMetric.sheetVerticalPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(AppColor.ink)
        }
    }
}

// MARK: - TagPair (Wispr-style options)

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
                    Text(label).monoLabel(10, color: AppColor.inkSoft)
                    Text(value).monoLabel(10, color: AppColor.ink)
                }
                Rectangle()
                    .fill(active ? AppColor.accent : Color.clear)
                    .frame(width: 56, height: 1.5)
            }
        }
    }
}

// MARK: - Vertical hairline (for MetricStrip)

struct VRule: View {
    var body: some View {
        Rectangle()
            .fill(AppColor.hairline)
            .frame(width: 1)
            .frame(maxHeight: .infinity)
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
            Text(label).monoLabel(10, color: AppColor.inkSoft)
            Spacer(minLength: 0)
            middle
            right
        }
    }
}

// MARK: - Chip (re-skinned, no rounded corners)

struct EditorialChip: View {
    let label: String
    var active: Bool = false
    var action: () -> Void = {}

    var body: some View {
        TapButton(action: action) {
            VStack(spacing: 4) {
                Text(label).monoLabel(10, color: active ? AppColor.ink : AppColor.inkSoft)
                Rectangle()
                    .fill(active ? AppColor.accent : Color.clear)
                    .frame(height: 1.5)
            }
            .padding(.horizontal, AppMetric.s)
            .padding(.vertical, 4)
        }
    }
}
