import SwiftUI

/// Deliberate, scoped exception to Lit Field's one-accent rule. Speaker
/// identity in the transcript is content-layer categorical metadata — a
/// different problem than brand chrome — and needs more than one color to
/// stay legible. Neither of Lit Field's own multi-color sets fit:
/// `AppColor`'s status colors are functional/never-decorative (a speaker
/// tinted `statusError` would read as "this row has a problem"), and the
/// field colors are deliberately low-contrast, meant to sit behind glass
/// rather than serve as foreground marks. Kept out of `AppColor` so that
/// enum stays an honest mirror of the actual Lit Field token set.
///
/// `AppColor.accent` is deliberately NOT included — once the rest of the
/// UI trains the eye that orange is the one actionable/primary color,
/// reusing it for "this happens to be Speaker 1" is a false affordance.
/// Used only as small identity swatches, never as text color or a large
/// fill — the speaker's name is always rendered in a fixed ink color.
enum SpeakerPalette {
    static let colors: [Color] = [
        Color(red: 0.45, green: 0.60, blue: 0.50), // sage
        Color(red: 0.40, green: 0.52, blue: 0.72), // slate blue
        Color(red: 0.65, green: 0.45, blue: 0.62), // plum
        Color(red: 0.78, green: 0.62, blue: 0.30), // amber
        Color(red: 0.55, green: 0.55, blue: 0.55), // gray
        Color(red: 0.47, green: 0.58, blue: 0.68), // dusty blue — replaces the dropped accent slot
    ]
}
