import Foundation

/// The bundled ReleaseNotes.md: one "## <version>" section per release,
/// "- " bullets underneath. Read offline, for the About panel.
enum ReleaseNotes {
    static func bundled() -> String? {
        guard let url = Bundle.main.url(forResource: "ReleaseNotes", withExtension: "md") else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    /// The bullets for `version`, continuation lines joined; empty when the
    /// version has no section.
    static func entries(for version: String, in text: String) -> [String] {
        var items: [String] = []
        var inSection = false
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("## ") {
                if inSection { break }
                inSection = line.dropFirst(3).trimmingCharacters(in: .whitespaces) == version
            } else if inSection, line.hasPrefix("- ") {
                items.append(String(line.dropFirst(2)))
            } else if inSection, !line.isEmpty, !line.hasPrefix("#"), !items.isEmpty {
                items[items.count - 1] += " " + line
            }
        }
        return items
    }
}
