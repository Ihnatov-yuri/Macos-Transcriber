import XCTest
@testable import Transcriberr

/// The interface in English, Ukrainian and Dutch (5.8.0): the catalog must
/// keep every format specifier and plural form, and the built app must carry
/// the languages.
final class LocalizationTests: XCTestCase {

    private static let catalogURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Transcriberr/Resources/Localizable.xcstrings")

    private static let spec = try! NSRegularExpression(pattern: #"%(?:\d+\$)?(lld|ld|d|@|\.?\d*f)"#)

    private static func specifiers(_ s: String) -> [String] {
        spec.matches(in: s, range: NSRange(s.startIndex..., in: s))
            .compactMap { Range($0.range(at: 1), in: s).map { String(s[$0]) } }
            .sorted()
    }

    private func catalog() throws -> [String: [String: Any]] {
        let data = try Data(contentsOf: Self.catalogURL)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try XCTUnwrap(json["strings"] as? [String: [String: Any]])
    }

    /// Every translation keeps the key's specifiers (a lost %@ shows a
    /// wrong value or crashes the format); plural forms are complete.
    func testTranslationsKeepSpecifiersAndPluralForms() throws {
        let strings = try catalog()
        XCTAssertGreaterThan(strings.count, 1000)
        let forms = ["uk": Set(["one", "few", "many", "other"]), "nl": Set(["one", "other"]), "en": Set(["one", "other"])]
        var problems: [String] = []
        for (key, entry) in strings {
            let want = Self.specifiers(key)
            for (lang, value) in entry["localizations"] as? [String: [String: Any]] ?? [:] {
                if let unit = value["stringUnit"] as? [String: Any], let v = unit["value"] as? String {
                    if Self.specifiers(v) != want { problems.append("\(lang) \(key) → \(v)") }
                } else if let plural = (value["variations"] as? [String: Any])?["plural"] as? [String: [String: Any]] {
                    if let need = forms[lang], !need.isSubset(of: Set(plural.keys)) {
                        problems.append("\(lang) \(key): plural forms \(plural.keys.sorted())")
                    }
                    for (form, u) in plural {
                        let v = (u["stringUnit"] as? [String: Any])?["value"] as? String ?? ""
                        // A "one" form may spell the number out ("один рядок").
                        if !Set(Self.specifiers(v)).isSubset(of: Set(want)) { problems.append("\(lang) \(key) [\(form)] → \(v)") }
                    }
                }
            }
        }
        XCTAssertEqual(problems, [])
    }

    /// Every key with words has Ukrainian and Dutch.
    func testEveryKeyIsTranslated() throws {
        let missing = try catalog().filter { key, entry in
            let words = Self.spec.stringByReplacingMatches(in: key, range: NSRange(key.startIndex..., in: key), withTemplate: "")
            guard words.contains(where: \.isLetter) else { return false }
            let locs = entry["localizations"] as? [String: Any] ?? [:]
            return locs["uk"] == nil || locs["nl"] == nil
        }.keys.sorted()
        XCTAssertEqual(missing, [], "run scripts/l10n/strings.sh and translate these")
    }

    /// The built app carries the three languages and looks them up.
    func testBuiltAppHasTheLanguages() throws {
        for (lang, library) in [("uk", "Бібліотека"), ("nl", "Bibliotheek"), ("en", "Library")] {
            let path = try XCTUnwrap(Bundle.main.path(forResource: lang, ofType: "lproj"), "no \(lang).lproj")
            let bundle = try XCTUnwrap(Bundle(path: path))
            XCTAssertEqual(bundle.localizedString(forKey: "Library", value: nil, table: nil), library)
        }
    }

    /// English plurals come from the catalog: "1 minute", not "1 minutes".
    func testEnglishPluralForms() throws {
        let path = try XCTUnwrap(Bundle.main.path(forResource: "en", ofType: "lproj"))
        let bundle = try XCTUnwrap(Bundle(path: path))
        let format = bundle.localizedString(forKey: "%lld minutes", value: nil, table: nil)
        XCTAssertEqual(String.localizedStringWithFormat(format, 1), "1 minute")
        XCTAssertEqual(String.localizedStringWithFormat(format, 23), "23 minutes")
    }

    func testLanguageChoiceIsTheAppsOwnAppleLanguages() throws {
        let suite = "transcriberr-test-language-\(UUID().uuidString.prefix(6))"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(AppLanguage.chosen(in: defaults, domain: suite), .system)
        AppLanguage.choose(.uk, in: defaults)
        XCTAssertEqual(defaults.stringArray(forKey: "AppleLanguages"), ["uk"])
        XCTAssertEqual(AppLanguage.chosen(in: defaults, domain: suite), .uk)
        AppLanguage.choose(.system, in: defaults)
        XCTAssertEqual(AppLanguage.chosen(in: defaults, domain: suite), .system)
    }
}
