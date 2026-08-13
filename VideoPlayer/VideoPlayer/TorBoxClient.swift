import Foundation

struct TorBoxFile: Identifiable, Codable, Hashable {
    let id: Int
    let name: String?
    let shortName: String?
    let mimetype: String?
    let size: Int64?

    enum CodingKeys: String, CodingKey {
        case id, name, mimetype, size
        case shortName = "short_name"
    }

    var displayName: String {
        let value = shortName?.trimmingCharacters(in: .whitespacesAndNewlines)
        return value?.isEmpty == false ? value! : (name ?? "Video")
    }

    var isVideo: Bool {
        guard VideoLibraryVisibility.allows(sizeBytes: size) else { return false }
        if mimetype?.lowercased().hasPrefix("video/") == true { return true }
        let ext = (displayName as NSString).pathExtension.lowercased()
        return ["mp4", "mkv", "mov", "m4v", "avi", "webm", "wmv", "flv", "ts", "m2ts", "mts"].contains(ext)
    }
}

struct TorBoxTorrent: Identifiable, Codable, Hashable {
    let id: Int
    let name: String?
    let downloadState: String?
    let downloadFinished: Bool?
    let downloadPresent: Bool?
    let progress: Double?
    let files: [TorBoxFile]?

    enum CodingKeys: String, CodingKey {
        case id, name, progress, files
        case downloadState = "download_state"
        case downloadFinished = "download_finished"
        case downloadPresent = "download_present"
    }

    var isReady: Bool {
        if downloadPresent == true || downloadFinished == true { return true }
        return ["cached", "completed", "uploading"].contains(downloadState?.lowercased() ?? "")
    }

    var videoFiles: [TorBoxFile] { (files ?? []).filter(\.isVideo) }
}

struct TorBoxCreateResult: Decodable {
    let torrentId: Int?
    let queuedId: Int?
    let hash: String?

    enum CodingKeys: String, CodingKey {
        case hash
        case torrentId = "torrent_id"
        case queuedId = "queued_id"
    }
}

private struct TorBoxEnvelope<Value: Decodable>: Decodable {
    let success: Bool
    let detail: String?
    let data: Value?
}

enum TorBoxError: LocalizedError {
    case missingKey
    case invalidResponse
    case server(Int, String)
    case missingDownloadLink

    var errorDescription: String? {
        switch self {
        case .missingKey: return "Add your TorBox API key first."
        case .invalidResponse: return "TorBox returned an unreadable response."
        case let .server(code, detail): return detail.isEmpty ? "TorBox request failed (\(code))." : detail
        case .missingDownloadLink: return "TorBox did not return a playable download link."
        }
    }
}

struct TorBoxClient: Sendable {
    private static let baseURL = URL(string: "https://api.torbox.app/v1/api")!
    private let apiKey: String

    init(apiKey: String) { self.apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines) }

    func validate() async throws {
        _ = try await torrents(bypassCache: false, limit: 1)
    }

    func torrents(bypassCache: Bool, limit: Int = 1_000) async throws -> [TorBoxTorrent] {
        var components = URLComponents(url: Self.baseURL.appendingPathComponent("torrents/mylist"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "bypass_cache", value: bypassCache ? "true" : "false"),
            URLQueryItem(name: "offset", value: "0"),
            URLQueryItem(name: "limit", value: String(limit))
        ]
        let envelope: TorBoxEnvelope<[TorBoxTorrent]> = try await request(url: components.url!)
        return envelope.data ?? []
    }

    func createTorrent(magnet: String) async throws -> TorBoxCreateResult {
        let boundary = "TorBox-\(UUID().uuidString)"
        var request = authorizedRequest(url: Self.baseURL.appendingPathComponent("torrents/createtorrent"))
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        var body = Data()
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"magnet\"\r\n\r\n".data(using: .utf8)!)
        body.append(magnet.data(using: .utf8)!)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        request.httpBody = body
        let envelope: TorBoxEnvelope<TorBoxCreateResult> = try await send(request)
        return envelope.data ?? TorBoxCreateResult(torrentId: nil, queuedId: nil, hash: nil)
    }

    func downloadURL(torrentId: Int, fileId: Int) async throws -> URL {
        var components = URLComponents(url: Self.baseURL.appendingPathComponent("torrents/requestdl"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "token", value: apiKey),
            URLQueryItem(name: "torrent_id", value: String(torrentId)),
            URLQueryItem(name: "file_id", value: String(fileId)),
            URLQueryItem(name: "redirect", value: "false"),
            URLQueryItem(name: "append_name", value: "true")
        ]
        let envelope: TorBoxEnvelope<String> = try await request(url: components.url!)
        guard let raw = envelope.data, let url = URL(string: raw) else { throw TorBoxError.missingDownloadLink }
        return url
    }

    private func request<Value: Decodable>(url: URL) async throws -> TorBoxEnvelope<Value> {
        try await send(authorizedRequest(url: url))
    }

    private func authorizedRequest(url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.timeoutInterval = 45
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    private func send<Value: Decodable>(_ request: URLRequest) async throws -> TorBoxEnvelope<Value> {
        guard !apiKey.isEmpty else { throw TorBoxError.missingKey }
        let (data, response) = try await HighPriorityNetworkManager.shared.responsiveData(for: request)
        guard let http = response as? HTTPURLResponse else { throw TorBoxError.invalidResponse }
        let envelope = try? JSONDecoder().decode(TorBoxEnvelope<Value>.self, from: data)
        guard (200..<300).contains(http.statusCode), envelope?.success == true else {
            throw TorBoxError.server(http.statusCode, envelope?.detail ?? "")
        }
        guard let envelope else { throw TorBoxError.invalidResponse }
        return envelope
    }
}

enum TorBoxKeyStore {
    private static let account = "torbox-api-key"
    static func load() -> String { SecureCredentialStore.string(for: account) ?? "" }
    @discardableResult static func save(_ key: String) -> Bool { SecureCredentialStore.set(key, for: account) }
    @discardableResult static func delete() -> Bool { SecureCredentialStore.remove(account) }
}

enum TorBoxLibraryStore {
    private static let revisionKey = "torbox.library.revision"
    private static var cacheURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let directory = base.appendingPathComponent("TorBox", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("torrents-v1.json")
    }

    static var revision: Int { UserDefaults.standard.integer(forKey: revisionKey) }

    static func load() -> [TorBoxTorrent] {
        guard let data = try? Data(contentsOf: cacheURL) else { return [] }
        return (try? JSONDecoder().decode([TorBoxTorrent].self, from: data)) ?? []
    }

    static func save(_ torrents: [TorBoxTorrent]) {
        if let data = try? JSONEncoder().encode(torrents) { try? data.write(to: cacheURL, options: .atomic) }
        UserDefaults.standard.set(revision + 1, forKey: revisionKey)
    }

    static func clear() {
        try? FileManager.default.removeItem(at: cacheURL)
        UserDefaults.standard.set(revision + 1, forKey: revisionKey)
    }
}
