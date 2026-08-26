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
    static let stremioAddonManifestURL = "stremio-addon-manifest-url"
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

enum OnlinePlaybackProviderPreference: String, CaseIterable, Identifiable {
    case automatic
    case realDebrid
    case torBox
    case pikpak
    case offcloud
    case directTorrent

    private static let defaultsKey = "online_playback_provider_preference_v1"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .automatic: return "Automatic"
        case .realDebrid: return "Real-Debrid"
        case .torBox: return "TorBox"
        case .pikpak: return "PikPak"
        case .offcloud: return "Offcloud"
        case .directTorrent: return "Direct Torrent"
        }
    }

    static var selected: Self {
        get {
            guard let rawValue = UserDefaults.standard.string(forKey: defaultsKey),
                  let value = Self(rawValue: rawValue) else { return .automatic }
            return value
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: defaultsKey) }
    }
}

enum OnlineSearchProviderPreference: String, CaseIterable, Identifiable {
    case automatic, stremioAddon, orion, pirateBay, nyaa
    private static let defaultsKey = "online_search_provider_preference_v1"
    var id: String { rawValue }
    var title: String {
        switch self {
        case .automatic: return "Automatic"
        case .stremioAddon: return "Manual Add-on"
        case .orion: return "Orion"
        case .pirateBay: return "The Pirate Bay"
        case .nyaa: return "Nyaa"
        }
    }
    static var selected: Self {
        get {
            guard let rawValue = UserDefaults.standard.string(forKey: defaultsKey), let value = Self(rawValue: rawValue) else { return .automatic }
            return value
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: defaultsKey) }
    }
}

enum OnlineSearchProviderSelection {
    private static let defaultsKey = "online_search_providers_v2"

    static var available: [OnlineSearchProviderPreference] {
        [.stremioAddon, .orion, .pirateBay, .nyaa]
    }

    static var selected: Set<OnlineSearchProviderPreference> {
        get {
            if let values = UserDefaults.standard.stringArray(forKey: defaultsKey) {
                return Set(values.compactMap(OnlineSearchProviderPreference.init(rawValue:)))
            }
            // Migrate the old single-provider setting; new users receive all
            // public providers so they get a broader source list immediately.
            let legacy = OnlineSearchProviderPreference.selected
            return legacy == .automatic ? Set(available) : [legacy]
        }
        set { UserDefaults.standard.set(newValue.map(\.rawValue), forKey: defaultsKey) }
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

/// A configured Stremio add-on URL can embed a provider token, so keep it out
/// of UserDefaults and only expose whether an add-on is configured.
enum StremioAddonStore {
    static var manifestURL: String {
        SecureCredentialStore.string(for: AppCredentialKeys.stremioAddonManifestURL) ?? ""
    }

    static var isConfigured: Bool { !manifestURL.isEmpty }

    @discardableResult static func save(_ value: String) -> Bool {
        SecureCredentialStore.set(value, for: AppCredentialKeys.stremioAddonManifestURL)
    }

    @discardableResult static func clear() -> Bool {
        SecureCredentialStore.remove(AppCredentialKeys.stremioAddonManifestURL)
    }
}
