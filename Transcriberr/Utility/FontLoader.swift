import Foundation
import CoreText

/// Registers every TTF under Resources/Fonts/ so `Font.custom(...)` resolves.
/// Bundle resources alone aren't enough on macOS — fonts have to be
/// registered with the font manager. Called once from `TranscriberrApp.init`.
enum FontLoader {
    static func registerBundledFonts() {
        guard let resURL = Bundle.main.resourceURL else { return }
        // XcodeGen adds Resources/Fonts as a group, and Xcode copies group
        // files flat into Contents/Resources, so the fonts were never found
        // under Fonts/ and every custom face fell back to the system font.
        // Both layouts are searched.
        let dirs = [resURL.appendingPathComponent("Fonts", isDirectory: true), resURL]
        for dir in dirs {
            let entries = (try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: nil)) ?? []
            for url in entries where url.pathExtension.lowercased() == "ttf"
                                || url.pathExtension.lowercased() == "otf" {
                CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
            }
        }
    }
}
