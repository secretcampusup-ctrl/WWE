import Foundation
import Security
import CryptoKit

struct OffcloudTransfer: Identifiable, Codable, Hashable {
    let requestId: String
    let fileName: String
    let status: String
    let progress: Double?
    let message: String?
    let originalLink: String?
    let createdOn: String?

    var id: String { requestId }
    var isDownloaded: Bool { status.lowercased() == "downloaded" }
    var isFailed: Bool { status.lowercased() == "error" }
    var isInstantCache: Bool { requestId.hasPrefix("instant-cache-") }
    var displayProgress: Double { min(max(progress ?? (isDownloaded ? 1 : 0), 0), 1) }
}

struct OffcloudFile: Identifiable, Codable, Hashable {
    let legacyId: String?
    let legacyName: String?
    let size: Int64?
    let path: String?
    let url: String

    /// Stable identity based on path (not signed URL which rotates between API calls).
    /// Ensures SwiftUI ForEach doesn't recreate views and lose cached thumbnails.
    var id: String { path ?? legacyName ?? url }

    var name: String {
        if let path {
            let last = (path as NSString).lastPathComponent
            if !last.isEmpty { return last }
        }
        if let legacyName, !legacyName.isEmpty { return legacyName }
        if let value = URL(string: url)?.lastPathComponent, !value.isEmpty {
            return value.removingPercentEncoding ?? value
        }
        return "Video"
    }
    var displayName: String {
        VideoTitleFormatter.title(from: name)
    }
    var detectedDate: String? { VideoTitleFormatter.date(from: name) }
    var resolutionLabel: String? { VideoTitleFormatter.resolution(from: name) }

    var streamURL: URL? { URL(string: url) }
    var isVideo: Bool {
        LinkResolver.isVideoFileName(name)
            && VideoLibraryVisibility.allows(sizeBytes: size)
    }

    var fileExtension: String {
        let value = (name as NSString).pathExtension.uppercased()
        return value.isEmpty ? "FILE" : value
    }

    var sizeLabel: String {
        guard let size, size > 0 else { return "" }
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: size)
    }

    var folderPath: String {
        guard let path, !path.isEmpty else { return "Files" }
        let folder = (path as NSString).deletingLastPathComponent
        return folder.isEmpty ? "Files" : folder
    }

    init(
        legacyId: String? = nil,
        legacyName: String? = nil,
        size: Int64? = nil,
        path: String? = nil,
        url: String
    ) {
        self.legacyId = legacyId
        self.legacyName = legacyName
        self.size = size
        self.path = path
        self.url = url
    }

    enum CodingKeys: String, CodingKey {
        case legacyId = "id"
        case legacyName = "name"
        case size, path, url
    }
}

private struct OffcloudCreateResponse: Decodable {
    let requestId: String
    let fileName: String
    let status: String
    let originalLink: String?

    var transfer: OffcloudTransfer {
        OffcloudTransfer(
            requestId: requestId,
            fileName: fileName,
            status: status,
            progress: 0,
            message: nil,
            originalLink: originalLink,
            createdOn: nil
        )
    }
}

private struct OffcloudExploreResponse: Decodable {
    let files: [OffcloudFile]
}

private struct OffcloudCacheInfoRequest: Encodable {
    let urls: [String]
    let includeFiles = true
}

private struct OffcloudCacheInfoResponse: Decodable {
    let cached: Bool
}

private struct OffcloudCacheDownloadRequest: Encodable {
    let url: String
}

private struct OffcloudCacheDownloadFile: Decodable {
    let folder: [String]
    let filename: String
    let size: Int64?
    let url: String

    var file: OffcloudFile {
        let fullPath = (folder + [filename]).joined(separator: "/")
        return OffcloudFile(
            legacyName: filename,
            size: size,
            path: fullPath,
            url: url
        )
    }
}

enum OffcloudError: LocalizedError {
    case missingKey
    case invalidResponse
    case badArchive
    case singleFileUnavailable
    case invalidUpload
    case server(Int, String)

    var errorDescription: String? {
        switch self {
        case .missingKey:
            return "Enter your Offcloud API key first."
        case .invalidResponse:
            return "Offcloud returned an unreadable response."
        case .badArchive:
            return "This is a single-file transfer."
        case .singleFileUnavailable:
            return "The single file link could not be recovered. Add this torrent again from the app."
        case .invalidUpload:
            return "Choose a valid .torrent or .nzb file."
        case let .server(code, message):
            return message.isEmpty ? "Offcloud request failed (\(code))." : message
        }
    }
}

struct OffcloudClient {
    private let apiKey: String
    private let baseURL = URL(string: "https://offcloud.com/api/")!

    init(apiKey: String) { self.apiKey = apiKey }

    func history() async throws -> [OffcloudTransfer] {
        try await send(path: "cloud/history", method: "GET", body: Optional<String>.none)
    }

    func create(url: String) async throws -> OffcloudTransfer {
        let response: OffcloudCreateResponse = try await send(
            path: "cloud",
            method: "POST",
            body: ["url": url]
        )
        return response.transfer
    }

    func create(fileURL: URL) async throws -> OffcloudTransfer {
        let ext = fileURL.pathExtension.lowercased()
        guard ext == "torrent" || ext == "nzb" else { throw OffcloudError.invalidUpload }
        let data = try Data(contentsOf: fileURL, options: .mappedIfSafe)
        guard !data.isEmpty else { throw OffcloudError.invalidUpload }

        let response: OffcloudCreateResponse = try await sendMultipart(
            path: "cloud",
            fileName: fileURL.lastPathComponent,
            fileData: data,
            mimeType: ext == "torrent" ? "application/x-bittorrent" : "application/x-nzb"
        )
        return response.transfer
    }

    func explore(requestId: String) async throws -> [OffcloudFile] {
        let safeId = requestId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? requestId
        let response: OffcloudExploreResponse = try await send(
            path: "cloud/explore/\(safeId)?format=detailed",
            method: "GET",
            body: Optional<String>.none
        )
        return response.files
    }

    func cachedFilesIfAvailable(for source: String) async throws -> [OffcloudFile]? {
        guard Self.canCheckCache(source) else { return nil }

        if source.lowercased().hasPrefix("magnet:?") {
            let information: [OffcloudCacheInfoResponse] = try await send(
                path: "cache/info",
                method: "POST",
                body: OffcloudCacheInfoRequest(urls: [source])
            )
            guard information.first?.cached == true else { return nil }
        }

        let downloads: [OffcloudCacheDownloadFile] = try await send(
            path: "cache/download",
            method: "POST",
            body: OffcloudCacheDownloadRequest(url: source)
        )
        return downloads.map(\.file)
    }

    static func canCheckCache(_ source: String) -> Bool {
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.lowercased().hasPrefix("magnet:?") { return true }
        guard let url = URL(string: trimmed) else { return false }
        return url.pathExtension.lowercased() == "torrent"
    }

    static func recoverSource(from originalLink: String?) -> String? {
        guard let originalLink, !originalLink.isEmpty else { return nil }
        if canCheckCache(originalLink) { return originalLink }

        let pattern = "(?i)([a-f0-9]{40}|[a-z2-7]{32})"
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(
                in: originalLink,
                range: NSRange(originalLink.startIndex..., in: originalLink)
              ),
              let range = Range(match.range(at: 1), in: originalLink) else {
            return originalLink
        }
        return "magnet:?xt=urn:btih:\(originalLink[range])"
    }

    private func send<Response: Decodable, Body: Encodable>(
        path: String,
        method: String,
        body: Body?
    ) async throws -> Response {
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw OffcloudError.missingKey
        }
        guard let url = URL(string: path, relativeTo: baseURL)?.absoluteURL else {
            throw OffcloudError.invalidResponse
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 30
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        if let body {
            request.httpBody = try JSONEncoder().encode(body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        let (data, response) = try await HighPriorityNetworkManager.shared.responsiveData(for: request)
        return try decode(data: data, response: response)
    }

    private func sendMultipart<Response: Decodable>(
        path: String,
        fileName: String,
        fileData: Data,
        mimeType: String
    ) async throws -> Response {
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw OffcloudError.missingKey
        }
        guard let url = URL(string: path, relativeTo: baseURL)?.absoluteURL else {
            throw OffcloudError.invalidResponse
        }

        let boundary = "Boundary-\(UUID().uuidString)"
        var body = Data()
        body.append("--\(boundary)\r\n")
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"\(fileName)\"\r\n")
        body.append("Content-Type: \(mimeType)\r\n\r\n")
        body.append(fileData)
        body.append("\r\n--\(boundary)--\r\n")

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body

        let (data, response) = try await HighPriorityNetworkManager.shared.responsiveData(for: request)
        return try decode(data: data, response: response)
    }

    private func decode<Response: Decodable>(
        data: Data,
        response: URLResponse
    ) throws -> Response {
        guard let http = response as? HTTPURLResponse else {
            throw OffcloudError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            let message = (object?["message"] as? String)
                ?? (object?["error"] as? String)
                ?? String(data: data, encoding: .utf8)
                ?? ""
            if message.localizedCaseInsensitiveContains("bad archive") {
                throw OffcloudError.badArchive
            }
            throw OffcloudError.server(http.statusCode, message)
        }

        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let message = object["error"] as? String,
           message.localizedCaseInsensitiveContains("bad archive") {
            throw OffcloudError.badArchive
        }

        do {
            return try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw OffcloudError.invalidResponse
        }
    }
}

private extension Data {
    mutating func append(_ string: String) {
        append(Data(string.utf8))
    }
}

enum TorrentInfoHash {
    static func magnetSource(for fileURL: URL) -> String? {
        guard fileURL.pathExtension.lowercased() == "torrent",
              let data = try? Data(contentsOf: fileURL, options: .mappedIfSafe),
              let range = infoDictionaryRange(in: data) else { return nil }

        let digest = Insecure.SHA1.hash(data: data.subdata(in: range))
        let hash = digest.map { String(format: "%02x", $0) }.joined()
        return "magnet:?xt=urn:btih:\(hash)"
    }

    private static func infoDictionaryRange(in data: Data) -> Range<Int>? {
        let bytes = [UInt8](data)
        var index = 0
        guard index < bytes.count, bytes[index] == 100 else { return nil }
        index += 1

        while index < bytes.count, bytes[index] != 101 {
            guard let keyBytes = readString(bytes, index: &index),
                  let key = String(bytes: keyBytes, encoding: .utf8) else { return nil }
            let valueStart = index
            guard skipValue(bytes, index: &index) else { return nil }
            if key == "info" { return valueStart..<index }
        }
        return nil
    }

    private static func readString(_ bytes: [UInt8], index: inout Int) -> [UInt8]? {
        guard index < bytes.count, bytes[index] >= 48, bytes[index] <= 57 else { return nil }
        var length = 0
        while index < bytes.count, bytes[index] != 58 {
            let value = bytes[index]
            guard value >= 48, value <= 57 else { return nil }
            length = (length * 10) + Int(value - 48)
            index += 1
        }
        guard index < bytes.count, bytes[index] == 58 else { return nil }
        index += 1
        guard length >= 0, index + length <= bytes.count else { return nil }
        let value = Array(bytes[index..<(index + length)])
        index += length
        return value
    }

    private static func skipValue(_ bytes: [UInt8], index: inout Int) -> Bool {
        guard index < bytes.count else { return false }

        switch bytes[index] {
        case 105:
            index += 1
            while index < bytes.count, bytes[index] != 101 { index += 1 }
            guard index < bytes.count else { return false }
            index += 1
            return true

        case 108:
            index += 1
            while index < bytes.count, bytes[index] != 101 {
                guard skipValue(bytes, index: &index) else { return false }
            }
            guard index < bytes.count else { return false }
            index += 1
            return true

        case 100:
            index += 1
            while index < bytes.count, bytes[index] != 101 {
                guard readString(bytes, index: &index) != nil,
                      skipValue(bytes, index: &index) else { return false }
            }
            guard index < bytes.count else { return false }
            index += 1
            return true

        case 48...57:
            return readString(bytes, index: &index) != nil

        default:
            return false
        }
    }
}

enum OffcloudKeyStore {
    private static let service = "com.mortaza.minoz.videoplayer.offcloud"
    private static let account = "api-key"

    static func load() -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var value: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &value) == errSecSuccess,
              let data = value as? Data,
              let key = String(data: data, encoding: .utf8) else { return "" }
        return key
    }

    @discardableResult
    static func save(_ key: String) -> Bool {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return delete() }
        let data = Data(trimmed.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let values: [String: Any] = [kSecValueData as String: data]
        if SecItemUpdate(query as CFDictionary, values as CFDictionary) == errSecSuccess {
            return true
        }

        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    @discardableResult
    static func delete() -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let result = SecItemDelete(query as CFDictionary)
        return result == errSecSuccess || result == errSecItemNotFound
    }
}



