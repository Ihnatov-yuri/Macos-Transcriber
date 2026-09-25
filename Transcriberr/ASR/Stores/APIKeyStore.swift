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

    /// Updates in place rather than delete-then-add: with the old order a
    /// failed SecItemAdd (locked keychain, ACL prompt denied) had already
    /// deleted the working key, so a botched edit silently cost the user
    /// their saved key. Returns the Keychain status; failures are logged.
    @discardableResult
    func set(_ value: String?, for provider: Provider) -> OSStatus {
        let baseQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: provider.rawValue,
        ]
        guard let value, !value.isEmpty, let data = value.data(using: .utf8) else {
            let status = SecItemDelete(baseQuery as CFDictionary)
            if status != errSecSuccess && status != errSecItemNotFound {
                AppLog.warn("apikeys", "delete \(provider.rawValue) key failed: OSStatus \(status)")
                return status
            }
            return errSecSuccess
        }
        var status = SecItemUpdate(baseQuery as CFDictionary,
                                   [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = baseQuery
            add[kSecValueData as String] = data
            status = SecItemAdd(add as CFDictionary, nil)
        }
        if status != errSecSuccess {
            AppLog.warn("apikeys", "save \(provider.rawValue) key failed: OSStatus \(status)")
        }
        return status
    }

    func isSet(_ provider: Provider) -> Bool {
        (value(for: provider)?.isEmpty == false)
    }
}
