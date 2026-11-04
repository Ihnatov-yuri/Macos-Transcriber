import Foundation

/// Text models slip LaTeX math into their Markdown ("Send the invite
/// $\rightarrow$ ASAP"), which SwiftUI's Markdown shows literally. Known
/// symbol commands become the characters they stand for; anything else is
/// left as written.
nonisolated enum ModelText {
    static let symbols: [String: String] = [
        "rightarrow": "→", "to": "→", "longrightarrow": "→", "leftarrow": "←", "gets": "←",
        "longleftarrow": "←", "leftrightarrow": "↔", "Rightarrow": "⇒", "Leftarrow": "⇐",
        "Leftrightarrow": "⇔", "implies": "⇒", "uparrow": "↑", "downarrow": "↓", "mapsto": "↦",
        "times": "×", "cdot": "·", "approx": "≈", "sim": "~", "neq": "≠", "ne": "≠",
        "geq": "≥", "ge": "≥", "leq": "≤", "le": "≤", "pm": "±", "checkmark": "✓",
        "infty": "∞", "degree": "°", "ldots": "…", "dots": "…",
    ]

    /// `$\rightarrow$` and `$ \to $` → "→". Only inside `$…$`: a bare
    /// `\leq` may be what the user dictated or wrote, and stays.
    static func replacingLaTeXSymbols(_ text: String) -> String {
        guard text.contains("$\\") || text.contains("$ \\") else { return text }
        return replace(in: text, pattern: #"\$\s*\\([A-Za-z]+)\s*\$"#)
    }

    private static func replace(in text: String, pattern: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let ns = text as NSString
        var result = ""
        var last = 0
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let name = ns.substring(with: match.range(at: 1))
            guard let symbol = symbols[name] else { continue }
            result += ns.substring(with: NSRange(location: last, length: match.range.location - last)) + symbol
            last = match.range.location + match.range.length
        }
        return result + ns.substring(from: last)
    }
}
