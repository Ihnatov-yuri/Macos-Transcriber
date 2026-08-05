import Foundation
import CoreText

/// Registers every TTF under Resources/Fonts/ so `Font.custom(...)` resolves.
/// Bundle resources alone aren't enough on macOS — fonts have to be
/// registered with the font manager. Called once from `TranscriberrApp.init`.
enum FontLoader {
    static func registerBundledFonts() {
        guard let resURL = Bundle.main.resourceURL else { return }
        let fontsDir = resURL.appendingPathComponent("Fonts", isDirectory: true)
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: fontsDir,
            includingPropertiesForKeys: nil
        ) else { return }
        for url in entries where url.pathExtension.lowercased() == "ttf"
                            || url.pathExtension.lowercased() == "otf" {
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }
}
