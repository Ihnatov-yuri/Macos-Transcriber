import Foundation
import Security
import Observation

/// Keychain-backed storage for API keys (OpenAI, Anthropic, Google).
/// Not present on Android — new path for the Mac build's API backends.
@Observable
final class APIKeyStore: @unchecked Sendable {
    enum Provider: String, CaseIterable, Sendable {
        case openAI    = "openai"
        case anthropic = "anthropic"
        case gemini    = "gemini"

        var displayName: String {
            switch self {
            case .openAI:    return "OpenAI"
            case .anthropic: return "Anthropic"
            case .gemini:    return "Google Gemini"
            }
        }
    }

    private let service = "nl.ihnatov.Transcriberr.apiKey"

    func value(for provider: Provider) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: provider.rawValue,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func set(_ value: String?, for provider: Provider) {
        let baseQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: provider.rawValue,
        ]
        SecItemDelete(baseQuery as CFDictionary)
        guard let value, !value.isEmpty, let data = value.data(using: .utf8) else { return }
        var add = baseQuery
        add[kSecValueData as String] = data
        SecItemAdd(add as CFDictionary, nil)
    }

    func isSet(_ provider: Provider) -> Bool {
        (value(for: provider)?.isEmpty == false)
    }
}
