import Foundation
import Observation

/// Mirror of `asr/SnippetStore.kt`.
/// Named text fragments referenced in preset templates via `{snippet:name}`.
struct Snippet: Sendable, Codable, Identifiable, Equatable {
    var name: String
    var body: String
    var id: String { name }
}

@Observable
final class SnippetStore: @unchecked Sendable {
    private let defaults = UserDefaults.standard
    private let key = "snippets.v1"

    var snippets: [Snippet] {
        didSet { persist() }
    }

    init() {
        if let data = defaults.data(forKey: key),
           let decoded = try? JSONDecoder().decode([Snippet].self, from: data)
        {
            snippets = decoded
        } else {
            snippets = []
        }
    }

    /// Replace every `{snippet:name}` with its body. Unknown names left intact.
    func substitute(_ text: String) -> String {
        guard !snippets.isEmpty else { return text }
        var out = text
        for snip in snippets {
            out = out.replacingOccurrences(of: "{snippet:\(snip.name)}", with: snip.body)
        }
        return out
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(snippets) {
            defaults.set(data, forKey: key)
        }
    }
}
