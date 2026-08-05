import SwiftUI

/// Editorial design system, ported 1:1 from the Android app's
/// `theme/Color.kt` + `theme/Type.kt` + `theme/Spacing.kt`.
///
/// Key principles to preserve:
///   - Paper + ink + ONE accent (no other chromatic color).
///   - Hairlines, not cards. No rounded corners outside specific exceptions.
///   - Four fonts, each with a single job:
///       Saira Condensed → display / brand / big stats
///       Fraunces        → italic "one statement" headings
///       IBM Plex Mono   → metadata, labels (always uppercase, tracked)
///       Inter           → body prose
///   - System fonts fall back if custom TTFs aren't bundled (drop them into
///     Resources/Fonts/ and they'll be picked up automatically).

// MARK: - Palette

enum AppColor {
    // Light mode
    static let paperLight       = Color(red: 246/255, green: 242/255, blue: 234/255) // #F6F2EA
    static let paperEdgeLight   = Color(red: 237/255, green: 231/255, blue: 220/255) // #EDE7DC
    static let inkLight         = Color(red:  22/255, green:  19/255, blue:  15/255) // #16130F

    // Dark mode
    static let paperDark        = Color(red:  22/255, green:  19/255, blue:  15/255) // #16130F
    static let paperEdgeDark    = Color(red:  14/255, green:  12/255, blue:  10/255) // #0E0C0A
    static let paperRaisedDark  = Color(red:  34/255, green:  32/255, blue:  29/255) // #22201D
    static let inkDark          = Color(red: 246/255, green: 242/255, blue: 234/255) // #F6F2EA

    // Accent (the ONLY chromatic color)
    static let accent           = Color(red: 255/255, green:  71/255, blue:  38/255) // #FF4726

    // Adaptive helpers
    static var paper: Color      { Color(light: paperLight,     dark: paperDark) }
    static var paperEdge: Color  { Color(light: paperEdgeLight, dark: paperEdgeDark) }
    static var paperRaised: Color{ Color(light: paperEdgeLight, dark: paperRaisedDark) }
    static var ink: Color        { Color(light: inkLight,       dark: inkDark) }
    static var inkSoft: Color    { ink.opacity(0.62) }
    static var inkMuted: Color   { ink.opacity(0.40) }
    static var inkSubtle: Color  { ink.opacity(0.30) }
    static var inkFaint: Color   { ink.opacity(0.16) }
    static var hairline: Color   { ink.opacity(0.16) }
    static var hairlineSoft: Color { ink.opacity(0.10) }
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
// All four font helpers gracefully fall back to system fonts if the custom
// TTFs aren't installed. To get the exact Android look, drop these files into
// Resources/Fonts/ and add them to the target's Fonts provided by application
// list in Info.plist (UIAppFonts on iOS / ATSApplicationFontsPath on macOS):
//   - SairaCondensed-Medium.ttf, -SemiBold.ttf, -Bold.ttf
//   - Fraunces-Regular.ttf, -Italic.ttf, -MediumItalic.ttf
//   - IBMPlexMono-Medium.ttf, -SemiBold.ttf
//   - Inter-Regular.ttf, -Medium.ttf, -SemiBold.ttf
// (All four families are on Google Fonts under the SIL Open Font License.)

enum AppFont {
    // PostScript names from the bundled TTFs (see Resources/Fonts/).
    // We probe at runtime so the app still ships if a font is missing.
    private static let sairaPS = "SairaCondensed-SemiBold"
    private static let sairaMediumPS = "SairaCondensed-Medium"
    private static let frauncesPS = "Fraunces-9ptBlack"
    private static let frauncesItalicPS = "Fraunces-9ptBlackItalic"
    private static let ibmMonoPS = "IBMPlexMono-Medium"
    private static let interPS = "Inter-Regular"

    /// Saira Condensed — display / brand / big tabular numerals.
    /// `weight: .semibold` gets the SemiBold cut; `.medium` gets Medium.
    /// Other weights resolve through `Font.weight()`.
    static func saira(_ size: CGFloat, weight: Font.Weight = .semibold) -> Font {
        let preferSemibold = (weight == .semibold || weight == .bold || weight == .heavy || weight == .black)
        let name = preferSemibold ? sairaPS : sairaMediumPS
        if isFontAvailable(name) {
            return Font.custom(name, size: size)
        }
        return Font.system(size: size, weight: weight, design: .default).width(.condensed)
    }

    /// Fraunces — italic "one statement" headlines.
    static func fraunces(_ size: CGFloat, italic: Bool = true, weight: Font.Weight = .regular) -> Font {
        let name = italic ? frauncesItalicPS : frauncesPS
        if isFontAvailable(name) {
            return Font.custom(name, size: size)
        }
        // Also try by family — variable fonts often resolve that way.
        if isFontAvailable("Fraunces") {
            let f = Font.custom("Fraunces", size: size)
            return italic ? f.italic() : f
        }
        let f = Font.system(size: size, weight: weight, design: .serif)
        return italic ? f.italic() : f
    }

    /// IBM Plex Mono — metadata, labels (always uppercase, tracked at call site).
    static func mono(_ size: CGFloat, weight: Font.Weight = .medium) -> Font {
        if isFontAvailable(ibmMonoPS) {
            return Font.custom(ibmMonoPS, size: size)
        }
        return Font.system(size: size, weight: weight, design: .monospaced)
    }

    /// Inter — body prose.
    static func inter(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        if isFontAvailable(interPS) {
            return Font.custom(interPS, size: size)
        }
        if isFontAvailable("Inter") {
            return Font.custom("Inter", size: size)
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
//
// "Spacing comes from hairlines, not whitespace" — but here are the
// magic numbers we re-use across screens.
enum AppMetric {
    static let xs: CGFloat = 4
    static let s:  CGFloat = 8
    static let m:  CGFloat = 12
    static let l:  CGFloat = 18
    static let xl: CGFloat = 28

    static let sheetPadding:        CGFloat = 18
    static let sheetVerticalPadding: CGFloat = 14
    static let rowVPad:             CGFloat = 11

    static let inkRuleWidth:        CGFloat = 1.5
    static let hairlineWidth:       CGFloat = 1
}

// MARK: - Convenience modifiers

extension Text {
    /// Force IBM Plex Mono + uppercase + tracking. Use for any "this is data"
    /// label: metadata, button labels, section indexes, etc.
    func monoLabel(_ size: CGFloat = 10.5, tracking: CGFloat = 1.0, color: Color = AppColor.ink) -> some View {
        self
            .font(AppFont.mono(size, weight: .medium))
            .textCase(.uppercase)
            .tracking(tracking)
            .foregroundStyle(color)
    }
}
