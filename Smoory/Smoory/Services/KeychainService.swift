import Foundation
import Security

enum KeychainService {
    static let anthropicAPIKeyService = "com.assistant.smoory.anthropic.apikey"

    static func read(service: String, account: String = "default") -> String? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecAttrSynchronizable: false,
            kSecMatchLimit: kSecMatchLimitOne,
            kSecReturnData: true
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let data = result as? Data,
              let string = String(data: data, encoding: .utf8) else {
            return nil
        }
        return string
    }

    /// Upsert: deletes any existing item then adds the new one.
    /// Stored locally only — kSecAttrSynchronizable is false so the API key never reaches iCloud Keychain.
    static func write(_ value: String, service: String, account: String = "default") throws {
        try? delete(service: service, account: account)

        guard let data = value.data(using: .utf8) else {
            throw KeychainError.underlying(errSecParam)
        }
        let attributes: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecAttrSynchronizable: false,
            kSecValueData: data
        ]
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainError.underlying(status)
        }
    }

    static func delete(service: String, account: String = "default") throws {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecAttrSynchronizable: false
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.underlying(status)
        }
    }
}

enum KeychainError: Error {
    case underlying(OSStatus)
}
