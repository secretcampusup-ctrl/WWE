import Foundation
import Security

/// Small Keychain wrapper for credentials that must not be persisted in UserDefaults.
enum SecureCredentialStore {
    private static let service = "com.mortaza.minoz.VideoPlayer.credentials"

    static func data(for account: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    static func string(for account: String) -> String? {
        data(for: account).flatMap { String(data: $0, encoding: .utf8) }
    }

    @discardableResult
    static func set(_ data: Data?, for account: String) -> Bool {
        guard let data, !data.isEmpty else { return remove(account) }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        if SecItemUpdate(
            query as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        ) == errSecSuccess {
            return true
        }
        var item = query
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }

    @discardableResult
    static func set(_ value: String?, for account: String) -> Bool {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return set(trimmed.isEmpty ? nil : Data(trimmed.utf8), for: account)
    }

    @discardableResult
    static func remove(_ account: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}

enum AppCredentialKeys {
    static let tmdb = "tmdb-read-access-token"
    static let thePornDB = "theporndb-api-key"
    static let pikpakAccount = "pikpak-account"
    static func webDAVPassword(serverID: UUID) -> String { "webdav-password-\(serverID.uuidString)" }
}
