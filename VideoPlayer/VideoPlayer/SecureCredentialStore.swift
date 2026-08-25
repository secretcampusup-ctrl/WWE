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
    static let orionUserAPIKey = "orion-user-api-key"
    static let orionAppAPIKey = "orion-app-api-key"
    static let realDebridAPIKey = "realdebrid-api-key"
    static func webDAVPassword(serverID: UUID) -> String { "webdav-password-\(serverID.uuidString)" }
}

enum OnlinePlatformSettings {
    private static let enabledKey = "online_platform_experimental_enabled_v1"

    static var isEnabled: Bool {
        get {
            if UserDefaults.standard.object(forKey: enabledKey) == nil { return true }
            return UserDefaults.standard.bool(forKey: enabledKey)
        }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }
}

enum OrionCredentialStore {
    static var userKey: String { SecureCredentialStore.string(for: AppCredentialKeys.orionUserAPIKey) ?? "" }
    static var appKey: String { SecureCredentialStore.string(for: AppCredentialKeys.orionAppAPIKey) ?? "" }
    static var isReady: Bool { !userKey.isEmpty && !appKey.isEmpty }

    @discardableResult static func save(userKey: String, appKey: String) -> Bool {
        let savedUser = SecureCredentialStore.set(userKey, for: AppCredentialKeys.orionUserAPIKey)
        let savedApp = SecureCredentialStore.set(appKey, for: AppCredentialKeys.orionAppAPIKey)
        return savedUser && savedApp
    }

    static func clear() {
        _ = SecureCredentialStore.remove(AppCredentialKeys.orionUserAPIKey)
        _ = SecureCredentialStore.remove(AppCredentialKeys.orionAppAPIKey)
    }
}

enum RealDebridKeyStore {
    static var key: String { SecureCredentialStore.string(for: AppCredentialKeys.realDebridAPIKey) ?? "" }
    @discardableResult static func save(_ key: String) -> Bool {
        SecureCredentialStore.set(key, for: AppCredentialKeys.realDebridAPIKey)
    }
    @discardableResult static func clear() -> Bool {
        SecureCredentialStore.remove(AppCredentialKeys.realDebridAPIKey)
    }
}
