import Foundation

// MARK: - Models

struct PikPakAccount: Codable, Equatable {
    var email: String
    var accessToken: String
    var refreshToken: String
    var expiresAt: Date
    var userId: String?
    var displayName: String?

    var isExpired: Bool {
        // Refresh 2 minutes early
        Date() >= expiresAt.addingTimeInterval(-120)
    }
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
        config.timeoutIntervalForRequest = 35
        config.timeoutIntervalForResource = 120
        config.waitsForConnectivity = true
        session = URLSession(configuration: config)
    }

    private func commonHeaders(token: String?) -> [String: String] {
        var h: [String: String] = [
            "User-Agent": "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1",
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
        var headers = commonHeaders(token: nil)
        headers["Referer"] = "https://mypikpak.com/"
        headers["Accept"] = "*/*"
        return headers
    }

    // MARK: - Account storage

    func loadAccount() -> PikPakAccount? {
        guard let data = UserDefaults.standard.data(forKey: accountKey),
              let acc = try? JSONDecoder().decode(PikPakAccount.self, from: data) else { return nil }
        return acc
    }

    func saveAccount(_ account: PikPakAccount) {
        if let data = try? JSONEncoder().encode(account) {
            UserDefaults.standard.set(data, forKey: accountKey)
            UserDefaults.standard.synchronize()
        }
    }

    func logout() {
        UserDefaults.standard.removeObject(forKey: accountKey)
    }

    // MARK: - Auth

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
            userId: nil,
            displayName: label
        )
        saveAccount(account)
        _ = try await listFiles(parentId: "")
        return account
    }

    private func parseRcloneOrBearerToken(_ rawToken: String) throws -> (accessToken: String, refreshToken: String?, expiry: Date?, deviceId: String?) {
        var raw = rawToken.trimmingCharacters(in: .whitespacesAndNewlines)

        if raw.lowercased().hasPrefix("bearer ") {
            raw = String(raw.dropFirst(7)).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let jsonText = Self.extractAccessTokenJSON(from: raw) ?? raw
        if jsonText.hasPrefix("{"), let data = jsonText.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let access = json["access_token"] as? String,
           access.count > 20 {
            let refresh = json["refresh_token"] as? String
            let expiryText = json["expiry"] as? String
            return (access, refresh, Self.parseRcloneDate(expiryText), Self.extractConfigValue(named: "device_id", from: raw))
        }

        guard raw.count > 20, !raw.contains("...") else { throw PikPakError.invalidCredentials }
        return (raw, nil, nil, Self.extractConfigValue(named: "device_id", from: raw))
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
        iso.formatOptions = [.withInternetDateTime]
        return iso.date(from: raw)
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
            let json = try await postJSON(
                url: "\(userBase)/v1/auth/token",
                body: body,
                auth: nil
            )
            account = try parseAuth(json, fallbackEmail: account.email)
            saveAccount(account)
            return account
        } catch {
            // Refresh failed — force re-login
            logout()
            throw PikPakError.notLoggedIn
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
        let acc = PikPakAccount(
            email: fallbackEmail,
            accessToken: access,
            refreshToken: refresh,
            expiresAt: Date().addingTimeInterval(expiresIn),
            userId: sub,
            displayName: name
        )
        saveAccount(acc)
        return acc
    }

    // MARK: - Files

    func listFiles(parentId: String = "") async throws -> [PikPakFileItem] {
        let account = try await ensureValidToken()
        let parent = parentId.isEmpty ? "*" : parentId
        var components = URLComponents(string: "\(driveBase)/drive/v1/files")!
        components.queryItems = [
            URLQueryItem(name: "parent_id", value: parent),
            URLQueryItem(name: "thumbnail_size", value: "SIZE_MEDIUM"),
            URLQueryItem(name: "with_audit", value: "true"),
            URLQueryItem(name: "limit", value: "200"),
            URLQueryItem(name: "filters", value: "{\"trashed\":{\"eq\":false}}")
        ]
        let json = try await getJSON(url: components.url!.absoluteString, token: account.accessToken)
        guard let files = json["files"] as? [[String: Any]] else { return [] }
        return files.compactMap { mapFile($0) }
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

    /// Best playable URL for a cloud file (medias → web_content_link).
    func streamURL(forFileId id: String) async throws -> URL {
        let (_, url) = try await getFile(id: id)
        guard let url else { throw PikPakError.noStreamURL }
        return url
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
        var token: String? = try? await ensureValidToken().accessToken

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
        var token: String? = try? await ensureValidToken().accessToken
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
        // 1) medias[].link.url — prefer last (often higher quality) then first
        if let medias = dict["medias"] as? [[String: Any]], !medias.isEmpty {
            for media in medias.reversed() {
                if let link = media["link"] as? [String: Any],
                   let u = link["url"] as? String,
                   let url = URL(string: u), !u.isEmpty {
                    return url
                }
            }
        }
        // 2) web_content_link
        if let web = dict["web_content_link"] as? String, let url = URL(string: web), !web.isEmpty {
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
        if let dl = dict["download_url"] as? String, let url = URL(string: dl), !dl.isEmpty {
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

    // MARK: - HTTP

    private func getJSON(url: String, token: String?) async throws -> [String: Any] {
        guard let u = URL(string: url) else { throw PikPakError.network("Bad URL") }
        var req = URLRequest(url: u)
        req.httpMethod = "GET"
        for (k, v) in commonHeaders(token: token) {
            req.setValue(v, forHTTPHeaderField: k)
        }
        return try await perform(req)
    }

    private func postJSON(url: String, body: [String: Any], auth: String?) async throws -> [String: Any] {
        guard let u = URL(string: url) else { throw PikPakError.network("Bad URL") }
        var req = URLRequest(url: u)
        req.httpMethod = "POST"
        for (k, v) in commonHeaders(token: auth) {
            req.setValue(v, forHTTPHeaderField: k)
        }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        return try await perform(req)
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

