import Foundation
import CryptoKit

// MARK: - Models

struct PikPakAccount: Codable, Equatable {
    var email: String
    var accessToken: String
    var refreshToken: String
    var expiresAt: Date
    var userId: String?
    var displayName: String?
    /// PikPak requires a short-lived shield token in addition to OAuth.
    /// rclone stores the same value beside `token` in rclone.conf.
    var captchaToken: String?
    var captchaExpiresAt: Date?

    var isExpired: Bool {
        // Refresh 2 minutes early
        Date() >= expiresAt.addingTimeInterval(-120)
    }
}

struct PikPakRcloneRemote: Identifiable, Equatable {
    let name: String
    let configuration: String
    var id: String { name }
}

struct PikPakFileItem: Identifiable, Hashable {
    let id: String
    let name: String
    let kind: String          // "drive#folder" / "drive#file"
    let size: Int64
    let mimeType: String?
    let parentId: String?
    let thumbnailLink: String?
    let webContentLink: String?
    let phase: String?

    var isFolder: Bool {
        kind.contains("folder") || mimeType == "application/vnd.pikpak.folder"
    }

    var isVideo: Bool {
        if isFolder { return false }
        guard VideoLibraryVisibility.allows(sizeBytes: size) else { return false }
        if let mime = mimeType?.lowercased(), mime.hasPrefix("video/") { return true }
        return LinkResolver.isVideoFileName(name)
    }
    var displayName: String {
        isFolder ? name : VideoTitleFormatter.title(from: name)
    }

    var resolutionLabel: String? { VideoTitleFormatter.resolution(from: name) }

    var fileExtension: String {
        let ext = (name as NSString).pathExtension.uppercased()
        return ext.isEmpty ? "FILE" : ext
    }

    var sizeFormatted: String {
        guard size > 0 else { return "" }
        let gb = Double(size) / 1_073_741_824
        let mb = Double(size) / 1_048_576
        if gb >= 1 { return String(format: "%.1f GB", gb) }
        if mb >= 1 { return String(format: "%.0f MB", mb) }
        return String(format: "%.0f KB", Double(size) / 1024)
    }
}

struct PikPakOfflineTask: Sendable {
    let id: String
    let fileID: String?
    let fileName: String?
    let phase: String
    let message: String?

    var isComplete: Bool { phase.uppercased() == "PHASE_TYPE_COMPLETE" }
    var isFailed: Bool {
        let value = phase.uppercased()
        return value.contains("ERROR") || value.contains("FAILED") || value.contains("DELETED")
    }
}

/// A playable server-side rendition reported by PikPak for one cloud file.
/// The URLs are short lived, so callers must fetch this list immediately before
/// offering a quality change rather than persisting it with the library item.
struct PikPakStreamQuality: Identifiable, Hashable, Sendable {
    let id: String
    let label: String
    let height: Int
    let url: URL
}

enum PikPakError: LocalizedError {
    case invalidCredentials
    case notLoggedIn
    case network(String)
    case api(String)
    case noStreamURL
    case invalidShareLink
    case needPassword
    case decode

    var errorDescription: String? {
        switch self {
        case .invalidCredentials: return "Invalid PikPak email or password"
        case .notLoggedIn: return "Sign in to PikPak first"
        case .network(let m): return m
        case .api(let m): return m
        case .noStreamURL: return "No playable stream found for this file"
        case .invalidShareLink: return "Invalid PikPak share link"
        case .needPassword: return "This share requires a password"
        case .decode: return "Could not read PikPak response"
        }
    }
}

// MARK: - Client

/// PikPak Drive API client (auth, files, share links, offline magnets, stream URLs).
final class PikPakClient {
    static let shared = PikPakClient()

    // Match rclone PikPak client so pasted rclone tokens can refresh correctly.
    private let clientId = "YUMx5nI8ZU8Ap8pm"
    private let packageName = "mypikpak.com"
    private let clientVersion = "2.0.0"
    private let userBase = "https://user.mypikpak.com"
    private let driveBase = "https://api-drive.mypikpak.com"

    private let session: URLSession
    private let accountKey = "pikpak_account_v1"
    private let deviceKey = "pikpak_device_id_v1"
    // These salts are part of rclone's PikPak v1.75 shield-token flow.
    private let captchaSignSalts = [
        "C9qPpZLN8ucRTaTiUMWYS9cQvWOE",
        "+r6CQVxjzJV6LCV",
        "F",
        "pFJRC",
        "9WXYIDGrwTCz2OiVlgZa90qpECPD6olt",
        "/750aCr4lm/Sly/c",
        "RB+DT/gZCrbV",
        "",
        "CyLsf7hdkIRxRm215hl",
        "7xHvLi2tOYP0Y92b",
        "ZGTXXxu8E/MIWaEDB+Sm/",
        "1UI3",
        "E7fP5Pfijd+7K+t6Tg/NhuLq0eEUVChpJSkrKxpO",
        "ihtqpG6FMt65+Xk+tWUH2",
        "NhXXU9rg4XXdzo7u5o"
    ]

    private var deviceId: String {
        if let existing = UserDefaults.standard.string(forKey: deviceKey), !existing.isEmpty {
            return existing
        }
        let id = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        UserDefaults.standard.set(id, forKey: deviceKey)
        return id
    }

    private init() {
        let config = URLSessionConfiguration.default
        config.networkServiceType = .responsiveData // API/auth JSON: prioritize UI responsiveness, not bulk throughput.
        config.timeoutIntervalForRequest = 35
        config.timeoutIntervalForResource = 120
        config.waitsForConnectivity = true
        session = URLSession(configuration: config)
    }

    private func commonHeaders(token: String?) -> [String: String] {
        var h: [String: String] = [
            "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:129.0) Gecko/20100101 Firefox/129.0",
            "Referer": "https://mypikpak.com/",
            "X-Client-Id": clientId,
            "X-Device-Id": deviceId,
            "X-Client-Version": clientVersion,
            "X-Package-Name": packageName,
            "Accept": "application/json",
            "Content-Type": "application/json"
        ]
        if let token, !token.isEmpty {
            h["Authorization"] = "Bearer \(token)"
        }
        return h
    }

    /// Headers required by PikPak's signed download servers when AVPlayer opens
    /// a direct CDN URL outside the app's normal web session.
    func directPlaybackHeaders() -> [String: String] {
        // These are media GET/Range requests, not Drive API JSON requests.
        // Sending Content-Type: application/json and the API-only X-* headers
        // makes AVURLAsset's request differ from the request VLC successfully
        // sends for the same signed URL, and some PikPak CDN edges reject it.
        return [
            "User-Agent": "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1",
            "Referer": "https://mypikpak.com/",
            "Accept": "*/*"
        ]
    }

    // MARK: - Account storage

    func loadAccount() -> PikPakAccount? {
        if let data = SecureCredentialStore.data(for: AppCredentialKeys.pikpakAccount),
           let account = try? JSONDecoder().decode(PikPakAccount.self, from: data) {
            return account
        }

        // One-time migration for builds that stored the native PikPak session
        // in UserDefaults before the rclone import flow was introduced.
        guard let legacyData = UserDefaults.standard.data(forKey: accountKey),
              let account = try? JSONDecoder().decode(PikPakAccount.self, from: legacyData) else {
            return nil
        }
        if SecureCredentialStore.set(legacyData, for: AppCredentialKeys.pikpakAccount) {
            UserDefaults.standard.removeObject(forKey: accountKey)
        }
        return account
    }

    func saveAccount(_ account: PikPakAccount) {
        if let data = try? JSONEncoder().encode(account) {
            _ = SecureCredentialStore.set(data, for: AppCredentialKeys.pikpakAccount)
            UserDefaults.standard.removeObject(forKey: accountKey)
        }
    }

    func logout() {
        _ = SecureCredentialStore.remove(AppCredentialKeys.pikpakAccount)
        UserDefaults.standard.removeObject(forKey: accountKey)
    }

    // MARK: - Auth

    func rcloneRemotes(from rawConfiguration: String) -> [PikPakRcloneRemote] {
        Self.rcloneSections(from: rawConfiguration).compactMap { section in
            guard Self.extractConfigValue(named: "type", from: section)?.lowercased() == "pikpak",
                  Self.extractAccessTokenJSON(from: section) != nil,
                  let firstLine = section.split(whereSeparator: { $0.isNewline }).first else {
                return nil
            }
            let header = String(firstLine).trimmingCharacters(in: .whitespacesAndNewlines)
            guard header.hasPrefix("["), header.hasSuffix("]"), header.count > 2 else { return nil }
            let name = String(header.dropFirst().dropLast())
            return PikPakRcloneRemote(name: name, configuration: section)
        }
    }

    func loginWithPersonalAccessToken(_ rawToken: String, label: String = "PikPak token") async throws -> PikPakAccount {
        let parsed = try parseRcloneOrBearerToken(rawToken)
        if let deviceId = parsed.deviceId, !deviceId.isEmpty {
            UserDefaults.standard.set(deviceId, forKey: deviceKey)
        }
        let account = PikPakAccount(
            email: label,
            accessToken: parsed.accessToken,
            refreshToken: parsed.refreshToken ?? parsed.accessToken,
            expiresAt: parsed.expiry ?? Date().addingTimeInterval(60 * 60),
            userId: Self.subject(fromJWT: parsed.accessToken),
            displayName: label,
            captchaToken: parsed.captchaToken,
            captchaExpiresAt: parsed.captchaExpiry
        )
        saveAccount(account)
        do {
            _ = try await listFiles(parentId: "")
            return loadAccount() ?? account
        } catch {
            // Keep the imported session. A transient network/shield failure must
            // not destroy a valid rclone OAuth token and force another CAPTCHA.
            throw error
        }
    }

    private func parseRcloneOrBearerToken(_ rawToken: String) throws -> (accessToken: String, refreshToken: String?, expiry: Date?, deviceId: String?, captchaToken: String?, captchaExpiry: Date?) {
        var raw = rawToken.trimmingCharacters(in: .whitespacesAndNewlines)

        if raw.lowercased().hasPrefix("bearer ") {
            raw = String(raw.dropFirst(7)).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // A full rclone.conf may contain multiple PikPak remotes. Select the
        // exact section that owns a token so its device_id cannot accidentally
        // be taken from another, incomplete remote.
        let scopedRaw = Self.preferredRclonePikPakSection(from: raw) ?? raw
        let jsonText = Self.extractAccessTokenJSON(from: scopedRaw) ?? scopedRaw
        if jsonText.hasPrefix("{"), let data = jsonText.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let access = json["access_token"] as? String,
           access.count > 20 {
            let refresh = json["refresh_token"] as? String
            let expiryText = json["expiry"] as? String
            let captcha = Self.parseRcloneCaptcha(from: scopedRaw)
            return (
                access,
                refresh,
                Self.parseRcloneDate(expiryText),
                Self.extractConfigValue(named: "device_id", from: scopedRaw),
                captcha.token,
                captcha.expiry
            )
        }

        guard scopedRaw.count > 20, !scopedRaw.contains("...") else { throw PikPakError.invalidCredentials }
        return (scopedRaw, nil, nil, Self.extractConfigValue(named: "device_id", from: scopedRaw), nil, nil)
    }

    private static func parseRcloneCaptcha(from raw: String) -> (token: String?, expiry: Date?) {
        guard let value = extractConfigValue(named: "captcha_token", from: raw),
              let data = value.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return (nil, nil)
        }
        return (
            json["captcha_token"] as? String,
            parseRcloneDate(json["expiry"] as? String)
        )
    }

    private static func subject(fromJWT token: String) -> String? {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count > 1 else { return nil }
        var base64 = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = base64.count % 4
        if remainder != 0 {
            base64 += String(repeating: "=", count: 4 - remainder)
        }
        guard let data = Data(base64Encoded: base64),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return (json["sub"] as? String) ?? (json["user_id"] as? String)
    }

    private static func preferredRclonePikPakSection(from raw: String) -> String? {
        rcloneSections(from: raw).first { section in
            let isPikPak = extractConfigValue(named: "type", from: section)?.lowercased() == "pikpak"
            return isPikPak && extractAccessTokenJSON(from: section) != nil
        }
    }

    private static func rcloneSections(from raw: String) -> [String] {
        var sections: [String] = []
        var current: [Substring] = []

        func appendCurrent() {
            guard !current.isEmpty else { return }
            sections.append(current.map(String.init).joined(separator: "\n"))
        }

        for line in raw.split(omittingEmptySubsequences: false, whereSeparator: { $0.isNewline }) {
            let trimmed = String(line).trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("["), trimmed.hasSuffix("]") {
                appendCurrent()
                current = [line]
            } else {
                current.append(line)
            }
        }
        appendCurrent()
        return sections
    }

    private static func extractConfigValue(named name: String, from raw: String) -> String? {
        let pattern = "(?im)^\\s*" + NSRegularExpression.escapedPattern(for: name) + "\\s*=\\s*(.+?)\\s*$"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(raw.startIndex..<raw.endIndex, in: raw)
        guard let match = regex.firstMatch(in: raw, range: range),
              let valueRange = Range(match.range(at: 1), in: raw) else { return nil }
        let value = String(raw[valueRange]).trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private static func extractAccessTokenJSON(from raw: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: #"\{[^{}]*\"access_token\"[^{}]*\}"#, options: [.dotMatchesLineSeparators]) else { return nil }
        let range = NSRange(raw.startIndex..<raw.endIndex, in: raw)
        guard let match = regex.firstMatch(in: raw, range: range),
              let tokenRange = Range(match.range, in: raw) else { return nil }
        return String(raw[tokenRange])
    }

    private static func parseRcloneDate(_ raw: String?) -> Date? {
        guard let raw, !raw.isEmpty else { return nil }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = iso.date(from: raw) { return date }
        // rclone can serialize micro/nanoseconds while some iOS versions only
        // accept milliseconds in ISO8601DateFormatter.
        if let regex = try? NSRegularExpression(
            pattern: #"^(.*\.\d{3})\d*(Z|[+-]\d{2}:\d{2})$"#
        ) {
            let range = NSRange(raw.startIndex..<raw.endIndex, in: raw)
            let milliseconds = regex.stringByReplacingMatches(
                in: raw,
                range: range,
                withTemplate: "$1$2"
            )
            if let date = iso.date(from: milliseconds) { return date }
        }
        iso.formatOptions = [.withInternetDateTime]
        return iso.date(from: raw)
    }

    private func captchaToken(for action: String) async throws -> String {
        if let account = loadAccount(),
           let token = account.captchaToken,
           !token.isEmpty,
           let expiry = account.captchaExpiresAt,
           expiry.addingTimeInterval(-10) > Date() {
            return token
        }

        guard var account = loadAccount() else { throw PikPakError.notLoggedIn }
        let timestamp = String(Int64(Date().timeIntervalSince1970 * 1_000))
        var signature = clientId + clientVersion + packageName + deviceId + timestamp
        for salt in captchaSignSalts {
            signature = Self.md5Hex(signature + salt)
        }

        var meta: [String: Any] = [
            "captcha_sign": "1.\(signature)",
            "timestamp": timestamp,
            "client_version": clientVersion,
            "package_name": packageName
        ]
        let resolvedUserId = account.userId ?? Self.subject(fromJWT: account.accessToken)
        if let resolvedUserId, !resolvedUserId.isEmpty {
            meta["user_id"] = resolvedUserId
            account.userId = resolvedUserId
        }

        var body: [String: Any] = [
            "action": action,
            "client_id": clientId,
            "device_id": deviceId,
            "meta": meta
        ]
        // rclone passes the previous shield token even when it has expired.
        if let oldToken = account.captchaToken, !oldToken.isEmpty {
            body["captcha_token"] = oldToken
        }

        guard let url = URL(string: "\(userBase)/v1/shield/captcha/init") else {
            throw PikPakError.network("Bad PikPak verification URL")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        for (key, value) in commonHeaders(token: nil) {
            request.setValue(value, forHTTPHeaderField: key)
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let json = try await perform(request)

        if let verificationURL = json["url"] as? String, !verificationURL.isEmpty,
           (json["captcha_token"] as? String)?.isEmpty != false {
            throw PikPakError.api("PikPak verification required: \(verificationURL)")
        }
        guard let token = json["captcha_token"] as? String, !token.isEmpty else {
            throw PikPakError.api("PikPak did not return a verification token")
        }
        let expiresIn = (json["expires_in"] as? Double)
            ?? (json["expires_in"] as? Int).map(Double.init)
            ?? 300
        account.captchaToken = token
        account.captchaExpiresAt = Date().addingTimeInterval(expiresIn)
        saveAccount(account)
        return token
    }

    private func invalidateCaptchaToken() {
        guard var account = loadAccount() else { return }
        account.captchaToken = nil
        account.captchaExpiresAt = nil
        saveAccount(account)
    }

    private static func md5Hex(_ text: String) -> String {
        Insecure.MD5.hash(data: Data(text.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private func isCaptchaFailure(_ error: Error) -> Bool {
        let message = error.localizedDescription.lowercased()
        return message.contains("captcha")
            || message.contains("verification code is invalid")
            || message.contains("verification token")
    }

    func login(email: String, password: String, captchaToken: String = "") async throws -> PikPakAccount {
        let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        let captcha = captchaToken.trimmingCharacters(in: .whitespacesAndNewlines)
        let body: [String: Any] = [
            "client_id": clientId,
            "username": trimmedEmail,
            "password": password,
            "captcha_token": captcha
        ]
        // Primary endpoint
        do {
            let json = try await postJSON(
                url: "\(userBase)/v1/auth/signin",
                body: body,
                auth: nil
            )
            return try parseAuth(json, fallbackEmail: trimmedEmail)
        } catch {
            // Alternate package-style body used by some clients
            let alt: [String: Any] = [
                "client_id": clientId,
                "username": trimmedEmail,
                "password": password,
                "captcha_token": captcha
            ]
            let json = try await postJSON(
                url: "\(userBase)/v1/auth/signin",
                body: alt,
                auth: nil
            )
            return try parseAuth(json, fallbackEmail: trimmedEmail)
        }
    }
    func ensureValidToken() async throws -> PikPakAccount {
        guard var account = loadAccount() else { throw PikPakError.notLoggedIn }
        if !account.isExpired { return account }

        let body: [String: Any] = [
            "client_id": clientId,
            "grant_type": "refresh_token",
            "refresh_token": account.refreshToken
        ]
        do {
            let json = try await postOAuthForm(url: "\(userBase)/v1/auth/token", body: body)
            account = try parseAuth(json, fallbackEmail: account.email)
            saveAccount(account)
            return account
        } catch {
            // Preserve the imported rclone session. Network and shield failures
            // are recoverable and must not silently disconnect the account.
            throw error
        }
    }

    private func parseAuth(_ json: [String: Any], fallbackEmail: String) throws -> PikPakAccount {
        guard let access = json["access_token"] as? String,
              let refresh = json["refresh_token"] as? String else {
            if let error = json["error"] as? String {
                throw PikPakError.api(error)
            }
            if let msg = json["error_description"] as? String {
                throw PikPakError.api(msg)
            }
            throw PikPakError.invalidCredentials
        }
        let expiresIn = (json["expires_in"] as? Double)
            ?? (json["expires_in"] as? Int).map(Double.init)
            ?? 7200
        let sub = (json["sub"] as? String) ?? (json["user_id"] as? String)
        let name = (json["name"] as? String)
        let current = loadAccount()
        let acc = PikPakAccount(
            email: fallbackEmail,
            accessToken: access,
            refreshToken: refresh,
            expiresAt: Date().addingTimeInterval(expiresIn),
            userId: sub ?? Self.subject(fromJWT: access),
            displayName: name,
            captchaToken: current?.captchaToken,
            captchaExpiresAt: current?.captchaExpiresAt
        )
        saveAccount(acc)
        return acc
    }

    // MARK: - Files

    func listFiles(parentId: String = "") async throws -> [PikPakFileItem] {
        let account = try await ensureValidToken()
        let parent = parentId.isEmpty ? "*" : parentId
        var pageToken = ""
        var seenPageTokens = Set<String>()
        var seenFileIDs = Set<String>()
        var result: [PikPakFileItem] = []

        repeat {
            var components = URLComponents(string: "\(driveBase)/drive/v1/files")!
            var queryItems = [
                URLQueryItem(name: "parent_id", value: parent),
                URLQueryItem(name: "thumbnail_size", value: "SIZE_MEDIUM"),
                URLQueryItem(name: "with_audit", value: "true"),
                URLQueryItem(name: "limit", value: "200"),
                URLQueryItem(name: "filters", value: "{\"trashed\":{\"eq\":false}}")
            ]
            if !pageToken.isEmpty {
                queryItems.append(URLQueryItem(name: "page_token", value: pageToken))
            }
            components.queryItems = queryItems

            let json = try await getJSON(url: components.url!.absoluteString, token: account.accessToken)
            let page = (json["files"] as? [[String: Any]] ?? []).compactMap { mapFile($0) }
            for file in page where seenFileIDs.insert(file.id).inserted {
                result.append(file)
            }

            let next = (json["next_page_token"] as? String) ?? ""
            guard !next.isEmpty, seenPageTokens.insert(next).inserted else { break }
            pageToken = next
        } while result.count < 10_000

        return result
    }

    func getFile(id: String) async throws -> (item: PikPakFileItem, streamURL: URL?) {
        let account = try await ensureValidToken()
        var components = URLComponents(string: "\(driveBase)/drive/v1/files/\(id)")!
        components.queryItems = [
            URLQueryItem(name: "thumbnail_size", value: "SIZE_LARGE"),
            URLQueryItem(name: "usage", value: "FETCH")
        ]
        let json = try await getJSON(url: components.url!.absoluteString, token: account.accessToken)
        guard let item = mapFile(json) else { throw PikPakError.decode }
        let stream = extractStreamURL(from: json)
        return (item, stream)
    }

    /// Fresh original-quality URL for a cloud file, with a playable variant fallback.
    func streamURL(forFileId id: String) async throws -> URL {
        let (_, url) = try await getFile(id: id)
        guard let url else { throw PikPakError.noStreamURL }
        return url
    }

    /// Fetch all visible, immediately playable renditions for the quality menu.
    /// This deliberately uses the same FETCH request as normal playback, so a
    /// quality switch always receives fresh signed CDN URLs.
    func streamQualities(forFileId id: String) async throws -> [PikPakStreamQuality] {
        let account = try await ensureValidToken()
        var components = URLComponents(string: "\(driveBase)/drive/v1/files/\(id)")!
        components.queryItems = [
            URLQueryItem(name: "thumbnail_size", value: "SIZE_LARGE"),
            URLQueryItem(name: "usage", value: "FETCH")
        ]
        let json = try await getJSON(url: components.url!.absoluteString, token: account.accessToken)
        let medias = json["medias"] as? [[String: Any]] ?? []

        var seenURLs = Set<String>()
        var qualities: [PikPakStreamQuality] = []
        for media in medias {
            guard (media["is_visible"] as? Bool) != false,
                  let url = mediaLinkURL(media),
                  seenURLs.insert(url.absoluteString).inserted else { continue }
            let score = mediaResolutionScore(media)
            qualities.append(PikPakStreamQuality(
                id: url.absoluteString,
                label: mediaQualityLabel(media, score: score),
                height: score,
                url: url
            ))
        }

        // Some files expose the original route only through links. Keep it
        // selectable too, but never let an unknown original displace a known
        // encoded quality in the automatic selection.
        if let original = applicationOctetStreamURL(in: json),
           seenURLs.insert(original.absoluteString).inserted {
            qualities.append(PikPakStreamQuality(
                id: original.absoluteString,
                label: "Original",
                height: 1,
                url: original
            ))
        }
        return qualities.sorted {
            if $0.height != $1.height { return $0.height > $1.height }
            return $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending
        }
    }

    /// Extracts the stable PikPak file id when it is embedded in a signed URL.
    func fileID(fromPlaybackURL url: URL) -> String? {
        pikPakFileID(in: url)
    }

    // MARK: - Share links (all common PikPak share shapes)

    /// Resolve a PikPak share URL and return files + pass token for further calls.
    func resolveShare(link: String, password: String? = nil) async throws -> (files: [PikPakFileItem], shareId: String, passToken: String) {
        guard let parsed = LinkResolver.parsePikPakShare(link) else {
            throw PikPakError.invalidShareLink
        }
        let shareId = parsed.shareId
        let pass = password ?? parsed.password ?? ""

        // 1) Fetch share meta (works logged-out for public shares; better with token)
        let token: String? = try? await ensureValidToken().accessToken

        var components = URLComponents(string: "\(driveBase)/drive/v1/share")!
        components.queryItems = [
            URLQueryItem(name: "share_id", value: shareId),
            URLQueryItem(name: "pass_code", value: pass),
            URLQueryItem(name: "thumbnail_size", value: "SIZE_LARGE"),
            URLQueryItem(name: "limit", value: "100")
        ]

        var json: [String: Any]
        do {
            json = try await getJSON(url: components.url!.absoluteString, token: token)
        } catch {
            // Retry without auth for public shares
            json = try await getJSON(url: components.url!.absoluteString, token: nil)
        }

        if let err = json["error"] as? String {
            if err.lowercased().contains("pass") || err.lowercased().contains("password") {
                throw PikPakError.needPassword
            }
            throw PikPakError.api(err)
        }

        let passToken = (json["pass_code_token"] as? String) ?? ""

        // Files may be under "files" or nested share info
        var rawFiles = json["files"] as? [[String: Any]] ?? []
        if rawFiles.isEmpty, let fileInfo = json["file_info"] as? [String: Any] {
            rawFiles = [fileInfo]
        }
        if rawFiles.isEmpty, let data = json["data"] as? [String: Any],
           let files = data["files"] as? [[String: Any]] {
            rawFiles = files
        }

        // 2) If still empty, try share detail endpoint
        if rawFiles.isEmpty {
            var c2 = URLComponents(string: "\(driveBase)/drive/v1/share/detail")!
            c2.queryItems = [
                URLQueryItem(name: "share_id", value: shareId),
                URLQueryItem(name: "pass_code_token", value: passToken),
                URLQueryItem(name: "limit", value: "100"),
                URLQueryItem(name: "thumbnail_size", value: "SIZE_LARGE")
            ]
            if let detail = try? await getJSON(url: c2.url!.absoluteString, token: token) {
                rawFiles = detail["files"] as? [[String: Any]] ?? rawFiles
            }
        }

        let files = rawFiles.compactMap { mapFile($0) }
        if files.isEmpty && pass.isEmpty && passToken.isEmpty {
            // Might need password
            if (json["share_status"] as? String)?.contains("PASS") == true {
                throw PikPakError.needPassword
            }
        }
        return (files, shareId, passToken)
    }

    /// Get a stream URL for a file inside a share (without necessarily restoring).
    func streamURLFromShare(shareId: String, fileId: String, passToken: String) async throws -> URL {
        let token: String? = try? await ensureValidToken().accessToken
        var components = URLComponents(string: "\(driveBase)/drive/v1/share/file_info")!
        components.queryItems = [
            URLQueryItem(name: "share_id", value: shareId),
            URLQueryItem(name: "file_id", value: fileId),
            URLQueryItem(name: "pass_code_token", value: passToken),
            URLQueryItem(name: "thumbnail_size", value: "SIZE_LARGE")
        ]
        let json: [String: Any]
        do {
            json = try await getJSON(url: components.url!.absoluteString, token: token)
        } catch {
            json = try await getJSON(url: components.url!.absoluteString, token: nil)
        }

        if let url = extractStreamURL(from: json) {
            return url
        }
        // Some responses nest under file_info
        if let info = json["file_info"] as? [String: Any], let url = extractStreamURL(from: info) {
            return url
        }

        // Fallback: restore into own drive then stream (requires login)
        let account = try await ensureValidToken()
        _ = try await restoreShare(shareId: shareId, fileIds: [fileId], passToken: passToken, token: account.accessToken)
        // After restore, list recent / get by id is flaky; try file get
        return try await streamURL(forFileId: fileId)
    }

    private func restoreShare(shareId: String, fileIds: [String], passToken: String, token: String) async throws -> [String: Any] {
        let body: [String: Any] = [
            "share_id": shareId,
            "pass_code_token": passToken,
            "file_ids": fileIds,
            "folder_type": "",
            "parent_id": ""
        ]
        return try await postJSON(
            url: "\(driveBase)/drive/v1/share/restore",
            body: body,
            auth: token
        )
    }

    // MARK: - Offline (magnet / remote URL → PikPak)

    @discardableResult
    func addOfflineTask(urlOrMagnet: String, parentId: String = "") async throws -> String {
        let account = try await ensureValidToken()
        let body: [String: Any] = [
            "kind": "drive#file",
            "name": "",
            "upload_type": "UPLOAD_TYPE_URL",
            "url": ["url": urlOrMagnet],
            "folder_type": parentId.isEmpty ? "DOWNLOAD" : "",
            "parent_id": parentId
        ]
        let json = try await postJSON(
            url: "\(driveBase)/drive/v1/files",
            body: body,
            auth: account.accessToken
        )
        if let task = json["task"] as? [String: Any], let id = task["id"] as? String {
            return id
        }
        if let file = json["file"] as? [String: Any], let id = file["id"] as? String {
            return id
        }
        if let id = json["id"] as? String { return id }
        if let err = json["error"] as? String { throw PikPakError.api(err) }
        throw PikPakError.api("Could not create offline task")
    }

    /// Mirrors rclone's task polling flow. The ID returned by an offline add is
    /// a task ID, not necessarily the final Drive file ID.
    func offlineTask(id: String) async throws -> PikPakOfflineTask {
        let account = try await ensureValidToken()
        let json = try await getJSON(
            url: "\(driveBase)/drive/v1/tasks/\(id)",
            token: account.accessToken
        )
        return PikPakOfflineTask(
            id: (json["id"] as? String) ?? id,
            fileID: json["file_id"] as? String,
            fileName: json["file_name"] as? String,
            phase: (json["phase"] as? String) ?? "",
            message: json["message"] as? String
        )
    }

    // MARK: - Mapping / stream extraction

    private func mapFile(_ dict: [String: Any]) -> PikPakFileItem? {
        guard let id = dict["id"] as? String,
              let name = dict["name"] as? String else { return nil }
        let kind = (dict["kind"] as? String) ?? "drive#file"
        let size: Int64
        if let s = dict["size"] as? Int64 { size = s }
        else if let s = dict["size"] as? Int { size = Int64(s) }
        else if let s = dict["size"] as? String { size = Int64(s) ?? 0 }
        else { size = 0 }
        let mime = dict["mime_type"] as? String
        let parent = dict["parent_id"] as? String
        let thumb = dict["thumbnail_link"] as? String
        let web = dict["web_content_link"] as? String
        let phase = dict["phase"] as? String
        return PikPakFileItem(
            id: id,
            name: name,
            kind: kind,
            size: size,
            mimeType: mime,
            parentId: parent,
            thumbnailLink: thumb,
            webContentLink: web,
            phase: phase
        )
    }

    private func extractStreamURL(from dict: [String: Any]) -> URL? {
        let medias = dict["medias"] as? [[String: Any]] ?? []
        let originalFileURL = applicationOctetStreamURL(in: dict)

        // PikPak returns every server-side rendition in `medias`. Playback
        // should start at 4K when it is available, otherwise use the highest
        // visible rendition instead of always locking the user to Original.
        let availableMedia = medias.compactMap { media -> (metadata: [String: Any], url: URL)? in
            guard (media["is_visible"] as? Bool) != false,
                  let url = self.mediaLinkURL(media) else { return nil }
            return (media, url)
        }
        if let selected = availableMedia.max(by: {
            self.mediaResolutionScore($0.metadata) < self.mediaResolutionScore($1.metadata)
        }) {
            DiagnosticLogger.log("[PikPakStream] route=best-quality score=\(mediaResolutionScore(selected.metadata)) host=\(selected.url.host ?? "unknown")")
            return selected.url
        }

        // Match rclone/PikPak's fast path: begin with the stable original-file
        // link, read its fid, then select the media URL carrying that same fid.
        // Media URLs allow less restrictive concurrent Range requests; choosing
        // merely the first item labelled "Original" can select a stale/hidden
        // rendition belonging to another backend object.
        if let originalFileURL,
           let expectedFileID = pikPakFileID(in: originalFileURL) {
            let matchingMedia: [(metadata: [String: Any], url: URL)] = medias.compactMap { media in
                guard let url = self.mediaLinkURL(media),
                      self.pikPakFileID(in: url) == expectedFileID else { return nil }
                return (media, url)
            }
            let selected = matchingMedia.first(where: {
                (self.isOriginalMedia($0.metadata) || self.isOriginalPikPakURL($0.url))
                    && ($0.metadata["is_visible"] as? Bool) != false
            }) ?? matchingMedia.first(where: {
                self.isOriginalMedia($0.metadata) || self.isOriginalPikPakURL($0.url)
            }) ?? matchingMedia.first
            if let selected {
                DiagnosticLogger.log("[PikPakStream] route=original-media-fid-match host=\(selected.url.host ?? "unknown")")
                return selected.url
            }
        }

        // Prefer a visible original rendition next. `is_origin` is the actual
        // API field; older payloads may instead use is_original or a name/category.
        if let url = medias.lazy
            .filter({ self.isOriginalMedia($0) && ($0["is_visible"] as? Bool) != false })
            .compactMap({ self.mediaLinkURL($0) })
            .first {
            DiagnosticLogger.log("[PikPakStream] route=visible-original-media host=\(url.host ?? "unknown")")
            return url
        }
        if let url = medias.lazy
            .filter({ self.isOriginalMedia($0) })
            .compactMap({ self.mediaLinkURL($0) })
            .first {
            DiagnosticLogger.log("[PikPakStream] route=original-media-fallback host=\(url.host ?? "unknown")")
            return url
        }

        // If PikPak supplied no matching media route, use its original-file URL.
        if let originalFileURL {
            DiagnosticLogger.log("[PikPakStream] route=octet-stream host=\(originalFileURL.host ?? "unknown")")
            return originalFileURL
        }
        if let download = dict["download_url"] as? String,
           let url = URL(string: download),
           !download.isEmpty {
            return url
        }
        if let web = dict["web_content_link"] as? String,
           let url = URL(string: web),
           !web.isEmpty {
            return url
        }
        if let url = medias.reversed().compactMap({ self.mediaLinkURL($0) }).first {
            return url
        }
        // 3) links map (mime → { url })
        if let links = dict["links"] as? [String: Any] {
            for (_, value) in links {
                if let entry = value as? [String: Any],
                   let u = entry["url"] as? String,
                   let url = URL(string: u), !u.isEmpty {
                    return url
                }
            }
        }
        // 4) Nested file / data
        if let file = dict["file"] as? [String: Any], let url = extractStreamURL(from: file) {
            return url
        }
        if let data = dict["data"] as? [String: Any], let url = extractStreamURL(from: data) {
            return url
        }
        if let media = dict["media"] as? [String: Any],
           let link = media["link"] as? [String: Any],
           let u = link["url"] as? String,
           let url = URL(string: u) {
            return url
        }
        return nil
    }

    private func applicationOctetStreamURL(in dict: [String: Any]) -> URL? {
        guard let links = dict["links"] as? [String: Any] else { return nil }
        let entry = links.first { element in
            element.key.caseInsensitiveCompare("application/octet-stream") == .orderedSame
        }?.value as? [String: Any]
        guard let raw = entry?["url"] as? String, !raw.isEmpty else { return nil }
        return URL(string: raw)
    }

    private func mediaLinkURL(_ media: [String: Any]) -> URL? {
        guard (media["need_more_quota"] as? Bool) != true,
              let link = media["link"] as? [String: Any],
              let raw = link["url"] as? String,
              !raw.isEmpty else { return nil }
        return URL(string: raw)
    }

    private func pikPakFileID(in url: URL) -> String? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
            .first(where: { $0.name.caseInsensitiveCompare("fid") == .orderedSame })?
            .value
    }

    private func isOriginalPikPakURL(_ url: URL) -> Bool {
        guard let category = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first(where: { $0.name.caseInsensitiveCompare("category") == .orderedSame })?
            .value?
            .lowercased() else { return false }
        return category.contains("original") || category.contains("origin")
    }

    private func isOriginalMedia(_ media: [String: Any]) -> Bool {
        if (media["is_origin"] as? Bool) == true || (media["is_original"] as? Bool) == true {
            return true
        }
        for key in ["media_name", "name", "category", "type"] {
            if let value = media[key] as? String,
               value.lowercased().contains("original") {
                return true
            }
        }
        if let link = media["link"] as? [String: Any],
           let rawURL = link["url"] as? String,
           let components = URLComponents(string: rawURL),
           components.queryItems?.contains(where: {
               guard $0.name.caseInsensitiveCompare("category") == .orderedSame,
                     let value = $0.value else { return false }
               return value.caseInsensitiveCompare("original") == .orderedSame
           }) == true {
            return true
        }
        return false
    }

    private func mediaResolutionScore(_ media: [String: Any]) -> Int {
        if let video = media["video"] as? [String: Any] {
            if let height = video["height"] as? Int { return height }
            if let height = video["height"] as? String, let value = Int(height) { return value }
        }
        for key in ["height", "resolution_name", "media_name", "name", "category", "type"] {
            let value: String?
            if let number = media[key] as? NSNumber { return number.intValue }
            value = media[key] as? String
            guard let value else { continue }
            let normalized = value.lowercased()
            if normalized.contains("4320") || normalized.contains("8k") { return 4320 }
            if normalized.contains("2160") || normalized.contains("4k") { return 2160 }
            if normalized.contains("1440") || normalized.contains("2k") { return 1440 }
            if normalized.contains("1080") { return 1080 }
            if normalized.contains("720") { return 720 }
            if normalized.contains("480") { return 480 }
        }
        // Keep an unlabelled original route usable, but never let it outrank a
        // confirmed 720p+ rendition.
        return isOriginalMedia(media) ? 1 : 0
    }

    private func mediaQualityLabel(_ media: [String: Any], score: Int) -> String {
        if score >= 4320 { return "8K" }
        if score >= 2160 { return "4K" }
        if score >= 1440 { return "1440p" }
        if score >= 1080 { return "1080p" }
        if score >= 720 { return "720p" }
        if score >= 480 { return "480p" }
        if isOriginalMedia(media) { return "Original" }
        return "Auto"
    }

    // MARK: - HTTP

    private func getJSON(url: String, token: String?) async throws -> [String: Any] {
        guard let u = URL(string: url) else { throw PikPakError.network("Bad URL") }
        var req = URLRequest(url: u)
        req.httpMethod = "GET"
        for (k, v) in commonHeaders(token: token) {
            req.setValue(v, forHTTPHeaderField: k)
        }
        return try await performPikPakRequest(req, url: u, action: "GET:\(u.path)")
    }

    private func postJSON(url: String, body: [String: Any], auth: String?) async throws -> [String: Any] {
        guard let u = URL(string: url) else { throw PikPakError.network("Bad URL") }
        var req = URLRequest(url: u)
        req.httpMethod = "POST"
        for (k, v) in commonHeaders(token: auth) {
            req.setValue(v, forHTTPHeaderField: k)
        }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        return try await performPikPakRequest(req, url: u, action: "POST:\(u.path)")
    }

    private func postOAuthForm(url: String, body: [String: Any]) async throws -> [String: Any] {
        guard let u = URL(string: url) else { throw PikPakError.network("Bad URL") }
        var request = URLRequest(url: u)
        request.httpMethod = "POST"
        for (key, value) in commonHeaders(token: nil) {
            request.setValue(value, forHTTPHeaderField: key)
        }
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var components = URLComponents()
        components.queryItems = body.map { URLQueryItem(name: $0.key, value: String(describing: $0.value)) }
        request.httpBody = components.percentEncodedQuery?.data(using: .utf8)
        return try await perform(request)
    }

    private func performPikPakRequest(_ original: URLRequest, url: URL, action: String) async throws -> [String: Any] {
        // OAuth refresh is handled by PikPak's OAuth endpoint itself. rclone's
        // extra shield token is attached to Drive API calls.
        let needsCaptcha = url.host == URL(string: driveBase)?.host && loadAccount() != nil
        guard needsCaptcha else { return try await perform(original) }

        var request = original
        request.setValue(try await captchaToken(for: action), forHTTPHeaderField: "X-Captcha-Token")
        do {
            return try await perform(request)
        } catch {
            guard isCaptchaFailure(error) else { throw error }
            // A token can be revoked before its nominal five-minute expiry.
            // Match rclone: invalidate it, initialize a fresh token, retry once.
            invalidateCaptchaToken()
            request.setValue(try await captchaToken(for: action), forHTTPHeaderField: "X-Captcha-Token")
            return try await perform(request)
        }
    }

    private func perform(_ request: URLRequest) async throws -> [String: Any] {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw PikPakError.network("Network: \(error.localizedDescription)")
        }
        guard let http = response as? HTTPURLResponse else {
            throw PikPakError.network("No HTTP response from PikPak")
        }
        let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        if !(200...299).contains(http.statusCode) {
            let msg = (obj["error_description"] as? String)
                ?? (obj["error"] as? String)
                ?? (obj["message"] as? String)
                ?? "HTTP \(http.statusCode)"
            // Surface captcha / verification needs clearly
            if msg.lowercased().contains("captcha") || msg.lowercased().contains("verification") {
                throw PikPakError.api("PikPak requires extra verification. Open verification, finish it, then try signing in again. (\(msg))")
            }
            if http.statusCode == 401 || http.statusCode == 403 {
                throw PikPakError.api("Auth failed: \(msg)")
            }
            throw PikPakError.api(msg)
        }
        // Some success payloads still embed error
        if let err = obj["error"] as? String, !err.isEmpty, obj["access_token"] == nil {
            throw PikPakError.api(err)
        }
        return obj
    }
}

