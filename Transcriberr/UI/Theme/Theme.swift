import SwiftUI

/// Lit Field design system, ported from the portable token file at
/// `~/Documents/Landing/docs/lit-field-tokens.css` — glass/veil panels over
/// an atmospheric field, one hot accent, Archivo + Schibsted Grotesk.
///
/// Key principles to preserve:
///   - One accent, the "Two-Oranges Rule": `AppColor.accent` is fills and
///     large graphics only (2.92:1 on light); `AppColor.accentOnLight` is
///     the only value legal for text/icons on a light ground (4.86:1).
///     Never use `accent` for text.
///   - Glass belongs in the functional/chrome layer (panels, HUDs, buttons)
///     — never the content layer (transcript text, list rows stay solid).
///   - This app is 100% "Operate mode" (dense working UI, no hero/marketing
///     screen anywhere) — `veil`/`veilStrong` are set to the token file's
///     own Operate-mode override values, not its hero-page default, and the
///     animated atmosphere/bloom background is not used on the main shell.
///   - `night`/`onNight` are a fixed component-level inversion (a dark CTA
///     on an otherwise-light screen, e.g. `InverseFooter`) — not app-wide
///     dark mode, which this app deliberately doesn't have yet.
///   - Two fonts, each with one job: Archivo (headings/buttons/labels),
///     Schibsted Grotesk (body copy). No monospace family.
///   - System fonts fall back if the bundled TTFs aren't present.

// MARK: - Palette

enum AppColor {
    // Base surface
    static let base     = Color(red: 236/255, green: 238/255, blue: 237/255) // #ECEEED
    static let baseDeep = Color(red: 226/255, green: 230/255, blue: 230/255) // #E2E6E6

    // Ink — four discrete steps. Don't add a fifth.
    static let ink  = Color(red: 11/255, green: 12/255, blue: 14/255)  // #0B0C0E
    static let ink2 = Color(red: 35/255, green: 38/255, blue: 43/255)  // #23262B
    static let ink3 = Color(red: 69/255, green: 74/255, blue: 82/255)  // #454A52
    static let ink4 = Color(red: 92/255, green: 98/255, blue: 107/255) // #5C626B

    // Accent — see the "Two-Oranges Rule" note above.
    static let accent        = Color(red: 255/255, green: 71/255, blue: 38/255) // #FF4726
    static let accentOnLight = Color(red: 192/255, green: 50/255, blue: 16/255) // #C03210

    // Night — fixed component-level inversion, not app-wide dark mode.
    static let night    = Color(red: 11/255, green: 12/255, blue: 14/255)    // #0B0C0E
    static let onNight  = Color(red: 244/255, green: 245/255, blue: 245/255) // #F4F5F5
    static let onNight2 = Color(red: 169/255, green: 176/255, blue: 184/255) // #A9B0B8

    // Veils (glass panels) — Operate-mode values (see doc comment above),
    // not the token file's 0.54 hero-page default.
    static let veil       = Color.white.opacity(0.78)
    static let veilStrong = Color.white.opacity(0.88)

    // Hairlines — internal dividers and chip outlines ONLY. Never a panel's
    // outer edge (Lit Field: "border: 0... stated explicitly").
    static let hair       = ink.opacity(0.12)
    static let hairStrong = ink.opacity(0.22)

    // Status — functional, never decorative. Never reuse for anything else
    // (e.g. DetailView's speaker palette — see SpeakerPalette.swift).
    static let statusError   = Color(red: 159/255, green: 18/255, blue: 57/255)  // #9F1239
    static let statusSuccess = Color(red: 15/255, green: 93/255, blue: 58/255)   // #0F5D3A
    static let statusWarning = Color(red: 122/255, green: 75/255, blue: 0/255)   // #7A4B00

    // Form controls — native SwiftUI controls (Form/TextField/Picker/etc.)
    // stay native and unstyled; this backs LitButtonChrome's `.secondary`
    // outline, the one custom-drawn border the app currently has.
    static let controlBorder = Color(red: 122/255, green: 129/255, blue: 136/255) // #7A8188
}

private extension Color {
    init(light: Color, dark: Color) {
        #if canImport(AppKit)
        self.init(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(isDark ? dark : light)
        })
        #else
        self = light
        #endif
    }
}

// MARK: - Typography
//
// Two font helpers, gracefully falling back to system fonts if the bundled
// TTFs aren't installed. Drop new weights into Resources/Fonts/ and add
// them to the target's Fonts provided by application list to change this:
//   - Archivo-SemiBold.ttf (600), Archivo-Bold.ttf (700)
//   - SchibstedGrotesk-Regular.ttf (400), SchibstedGrotesk-Bold.ttf (700)
// (Both on Google Fonts under the SIL Open Font License; instantiated here
// from the variable-font sources since neither ships pre-cut static TTFs.)

enum AppFont {
    // Real embedded PostScript names — verified from the actual font
    // files, not guessed from filenames. Archivo's source family is
    // internally "Archivo Roman" (it separates upright from italic at the
    // family level), hence the "Roman" in both PostScript names.
    private static let displaySemiboldPS = "ArchivoRoman-SemiBold"
    private static let displayBoldPS = "ArchivoRoman-Bold"
    private static let textRegularPS = "SchibstedGrotesk-Regular"
    private static let textBoldPS = "SchibstedGrotesk-Bold"

    /// Archivo — headings, buttons, field labels, chip text. Bundled at
    /// 600 (the token file's default display weight) and 700 (h1–h4 only);
    /// any other requested weight resolves to whichever cut is closer.
    static func display(_ size: CGFloat, weight: Font.Weight = .semibold) -> Font {
        let bold = (weight == .bold || weight == .heavy || weight == .black)
        let name = bold ? displayBoldPS : displaySemiboldPS
        if isFontAvailable(name) {
            return Font.custom(name, size: size)
        }
        return Font.system(size: size, weight: weight, design: .default)
    }

    /// Schibsted Grotesk — body copy, everything else. Bundled at 400 and
    /// 700 (`strong`). The token file's one 600-weight outlier (`.chip b`)
    /// isn't worth a third bundled cut — anything non-regular renders Bold.
    static func text(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        let name = weight == .regular ? textRegularPS : textBoldPS
        if isFontAvailable(name) {
            return Font.custom(name, size: size)
        }
        return Font.system(size: size, weight: weight, design: .default)
    }

    /// Cached "is this PostScript name registered" probe.
    private static var available = Set<String>()
    private static var checked = Set<String>()
    private static func isFontAvailable(_ name: String) -> Bool {
        if checked.contains(name) { return available.contains(name) }
        checked.insert(name)
        #if canImport(AppKit)
        if NSFont(name: name, size: 12) != nil {
            available.insert(name)
            return true
        }
        #endif
        return false
    }
}

// MARK: - Metrics

enum AppMetric {
    static let xs: CGFloat = 4
    static let s:  CGFloat = 8
    static let m:  CGFloat = 12
    static let l:  CGFloat = 18
    static let xl: CGFloat = 28

    static let sheetPadding:         CGFloat = 18
    static let sheetVerticalPadding: CGFloat = 14
    static let rowVPad:              CGFloat = 11

    static let radiusSm: CGFloat = 14 // panels

    // Component-scoped constants sourced directly from Lit Field's literal
    // component recipes. The token file doesn't derive these from a shared
    // scale either (e.g. `.chip { padding: 6px 11px }`) — matching that
    // fidelity instead of rounding onto xs/s/m/l/xl.
    static let chipPaddingH: CGFloat = 11
    static let chipPaddingV: CGFloat = 6
    static let btnPaddingH:  CGFloat = 20
    static let btnMinHeight: CGFloat = 48
}

// MARK: - Convenience modifiers

extension Text {
    /// General-purpose small label — eyebrows, metadata, chip text,
    /// sidebar rows, section indexes. Same call shape as the old
    /// `monoLabel`, just Archivo and normal case: Lit Field has no
    /// uppercase or letter-spacing styling anywhere.
    func uiLabel(_ size: CGFloat = 11, color: Color = AppColor.ink) -> some View {
        self
            .font(AppFont.display(size, weight: .semibold))
            .foregroundStyle(color)
    }
}
