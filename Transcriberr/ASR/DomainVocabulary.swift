import Foundation

/// Mirror of `asr/DomainVocabulary.kt` — quick-fill curated term packs.
/// Terms live in Resources/Vocab/vocab.json keyed by pack × language.
enum DomainVocabulary {
    enum Pack: String, CaseIterable, Sendable {
        case medical, it, construction, legal, finance

        var displayName: String {
            switch self {
            case .medical:      return "Medical"
            case .it:           return "IT / Software"
            case .construction: return "Construction"
            case .legal:        return "Legal"
            case .finance:      return "Finance"
            }
        }
    }

    static func terms(pack: Pack, languages: Set<String>) -> [String] {
        guard let data = loadJSON() else { return [] }
        guard let packJSON = data[pack.rawValue] as? [String: Any] else { return [] }
        // Always include English; layer in the user-selected languages.
        var keys: Set<String> = ["en"]
        for lang in languages {
            keys.insert(iso639(lang))
        }
        var out = Set<String>()
        for k in keys {
            if let arr = packJSON[k] as? [String] {
                for t in arr { out.insert(t) }
            }
        }
        return out.sorted()
    }

    @MainActor
    static func apply(pack: Pack, to store: PromptStore, languages: Set<String>) {
        let new = terms(pack: pack, languages: languages)
        let existing = Set(
            store.vocabulary
                .split(whereSeparator: { $0 == "," || $0.isNewline })
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        )
        store.vocabulary = existing.union(new).sorted().joined(separator: ", ")
    }

    // MARK: - JSON

    private static var cached: [String: Any]?
    private static func loadJSON() -> [String: Any]? {
        if let cached { return cached }
        guard let url = Bundle.main.url(forResource: "vocab", withExtension: "json") else {
            return nil
        }
        guard
            let data = try? Data(contentsOf: url),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return nil
        }
        cached = json
        return json
    }

    private static func iso639(_ name: String) -> String {
        switch name.lowercased() {
        case "english", "en":   return "en"
        case "arabic", "ar":    return "ar"
        case "ukrainian", "uk": return "uk"
        case "dutch", "nl":     return "nl"
        default:                return name.lowercased()
        }
    }
}
