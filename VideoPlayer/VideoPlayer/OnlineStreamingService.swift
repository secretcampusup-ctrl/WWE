import Foundation

enum OnlineStreamQuality: Int, CaseIterable, Comparable, Sendable {
    case p720 = 720
    case p1080 = 1080
    case p1440 = 1440
    case p2160 = 2160

    var label: String {
        switch self {
        case .p720: return "720p"
        case .p1080: return "1080p"
        case .p1440: return "1440p"
        case .p2160: return "4K"
        }
    }

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    static func detect(hint: String?, fileName: String) -> Self? {
        let value = "\(hint ?? "") \(fileName)".lowercased()
        if value.contains("2160") || value.contains("4k") || value.contains("uhd") { return .p2160 }
        if value.contains("1440") || value.contains("qhd") || value.range(of: #"\b2k\b"#, options: .regularExpression) != nil { return .p1440 }
        if value.contains("1080") || value.contains("full hd") || value.contains("fhd") { return .p1080 }
        if value.contains("720") { return .p720 }
        return nil
    }
}

struct OnlineTorrentSource: Identifiable, Hashable, Sendable {
    enum Origin: String, Sendable {
        case orion = "Orion"
        case pirateBay = "The Pirate Bay"
        case manual = "Manual Magnet"
    }

    let id: String
    let name: String
    let magnet: String
    let quality: OnlineStreamQuality
    let seeders: Int
    let sizeBytes: Int64
    let origin: Origin

    var sizeLabel: String {
        guard sizeBytes > 0 else { return "Unknown size" }
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: sizeBytes)
    }
}

struct OnlineSourceLookupContext: Sendable {
    let title: String
    let year: String?
    let mediaType: String
    let tmdbID: Int
    let imdbID: String?
    let season: Int?
    let episode: Int?

    var displaySubtitle: String? {
        guard mediaType == "tv" else { return year }
        return String(format: "S%02d · E%02d", season ?? 1, episode ?? 1)
    }

    var fallbackQuery: String {
        var values = [title]
        if mediaType == "tv" {
            values.append(String(format: "S%02dE%02d", season ?? 1, episode ?? 1))
        } else if let year, !year.isEmpty {
            values.append(year)
        }
        return values.joined(separator: " ")
    }
}

enum OnlineSourceSearchError: LocalizedError {
    case missingIMDbID
    case invalidResponse
    case provider(String)

    var errorDescription: String? {
        switch self {
        case .missingIMDbID: return "IMDb ID is unavailable for this title."
        case .invalidResponse: return "The source service returned an unreadable response."
        case let .provider(message): return message
        }
    }
}

actor OnlineSourceSearchService {
    static let shared = OnlineSourceSearchService()
    private let minimumVisibleSize: Int64 = 400 * 1_024 * 1_024

    func search(_ context: OnlineSourceLookupContext) async throws -> [OnlineTorrentSource] {
        let raw: [OnlineTorrentSource]
        if OrionCredentialStore.isReady {
            guard let imdb = context.imdbID, !imdb.isEmpty else { throw OnlineSourceSearchError.missingIMDbID }
            raw = try await searchOrion(context, imdbID: imdb)
        } else {
            raw = try await searchPirateBay(context)
        }
        return bestPerQuality(raw)
    }

    private func bestPerQuality(_ values: [OnlineTorrentSource]) -> [OnlineTorrentSource] {
        let eligible = values.filter { source in
            source.sizeBytes == 0 || source.sizeBytes >= minimumVisibleSize
        }
        return OnlineStreamQuality.allCases.compactMap { quality in
            eligible
                .filter { $0.quality == quality }
                .max {
                    if $0.seeders != $1.seeders { return $0.seeders < $1.seeders }
                    if $0.sizeBytes == 0 { return true }
                    if $1.sizeBytes == 0 { return false }
                    return $0.sizeBytes > $1.sizeBytes
                }
        }
    }

    private func searchOrion(_ context: OnlineSourceLookupContext, imdbID: String) async throws -> [OnlineTorrentSource] {
        var parameters: [String: String] = [
            "keyapp": OrionCredentialStore.appKey,
            "keyuser": OrionCredentialStore.userKey,
            "mode": "stream",
            "action": "retrieve",
            "type": context.mediaType == "tv" ? "show" : "movie",
            "idimdb": imdbID,
            "limitcount": "100",
            "sort": "best",
            "streamtype": "torrent",
            "protocoltorrent": "magnet",
            "filename": "true",
            "fileunknown": "false",
            "debridlookup": "false"
        ]
        if context.mediaType == "tv" {
            parameters["numberseason"] = String(context.season ?? 1)
            parameters["numberepisode"] = String(context.episode ?? 1)
        }

        var request = URLRequest(url: URL(string: "https://api.orionoid.com")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 35
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var form = URLComponents()
        form.queryItems = parameters.map { URLQueryItem(name: $0.key, value: $0.value) }
        request.httpBody = form.percentEncodedQuery?.data(using: .utf8)

        let (data, response) = try await HighPriorityNetworkManager.shared.responsiveData(for: request)
        guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode,
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw OnlineSourceSearchError.invalidResponse
        }
        if let result = root["result"] as? [String: Any],
           let status = result["status"] as? String,
           status.lowercased() != "success" {
            let message = (result["message"] as? String) ?? "Orion search failed."
            throw OnlineSourceSearchError.provider(message)
        }
        let streams = ((root["data"] as? [String: Any])?["streams"] as? [[String: Any]]) ?? []
        return streams.compactMap { stream in
            let file = stream["file"] as? [String: Any] ?? [:]
            let video = stream["video"] as? [String: Any] ?? [:]
            let streamInfo = stream["stream"] as? [String: Any] ?? [:]
            let links = stream["links"] as? [String] ?? []
            guard let magnet = links.first(where: { $0.lowercased().hasPrefix("magnet:?") }) else { return nil }
            let name = (file["name"] as? String) ?? context.fallbackQuery
            guard let quality = OnlineStreamQuality.detect(
                hint: Self.stringValue(video["quality"]),
                fileName: name
            ) else { return nil }
            let id = (stream["id"] as? String) ?? Self.infoHash(from: magnet) ?? magnet
            return OnlineTorrentSource(
                id: "orion|\(id)",
                name: name,
                magnet: magnet,
                quality: quality,
                seeders: Self.intValue(streamInfo["seeds"]),
                sizeBytes: Self.int64Value(file["size"]),
                origin: .orion
            )
        }
    }

    private func searchPirateBay(_ context: OnlineSourceLookupContext) async throws -> [OnlineTorrentSource] {
        var queries: [String] = []
        if let imdbID = context.imdbID, !imdbID.isEmpty { queries.append(imdbID) }
        queries.append(context.fallbackQuery)
        var combined: [OnlineTorrentSource] = []
        var seen = Set<String>()

        for query in queries {
            var components = URLComponents(string: "https://apibay.org/q.php")!
            components.queryItems = [
                URLQueryItem(name: "q", value: query),
                URLQueryItem(name: "cat", value: "0")
            ]
            var request = URLRequest(url: components.url!)
            request.timeoutInterval = 30
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            let (data, response) = try await HighPriorityNetworkManager.shared.responsiveData(for: request)
            guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else { continue }
            let payload = (try? JSONDecoder().decode([PirateBaySearchPayload].self, from: data)) ?? []
            for value in payload where value.id != "0" && !value.infoHash.isEmpty {
                guard let quality = OnlineStreamQuality.detect(hint: nil, fileName: value.name) else { continue }
                let key = value.infoHash.lowercased()
                guard seen.insert(key).inserted else { continue }
                combined.append(OnlineTorrentSource(
                    id: "tpb|\(key)",
                    name: value.name,
                    magnet: Self.magnet(infoHash: value.infoHash, name: value.name),
                    quality: quality,
                    seeders: Int(value.seeders) ?? 0,
                    sizeBytes: Int64(value.size) ?? 0,
                    origin: .pirateBay
                ))
            }
            if Set(combined.map(\.quality)).count == OnlineStreamQuality.allCases.count { break }
        }
        return combined
    }

    private static func magnet(infoHash: String, name: String) -> String {
        var components = URLComponents()
        components.scheme = "magnet"
        components.queryItems = [
            URLQueryItem(name: "xt", value: "urn:btih:\(infoHash)"),
            URLQueryItem(name: "dn", value: name),
            URLQueryItem(name: "tr", value: "udp://tracker.opentrackr.org:1337/announce"),
            URLQueryItem(name: "tr", value: "udp://open.stealth.si:80/announce"),
            URLQueryItem(name: "tr", value: "udp://tracker.torrent.eu.org:451/announce")
        ]
        return components.string ?? "magnet:?xt=urn:btih:\(infoHash)"
    }

    private static func infoHash(from magnet: String) -> String? {
        URLComponents(string: magnet)?.queryItems?
            .first(where: { $0.name.lowercased() == "xt" })?.value?
            .replacingOccurrences(of: "urn:btih:", with: "", options: .caseInsensitive)
    }

    private static func stringValue(_ value: Any?) -> String? {
        if let value = value as? String { return value }
        if let value = value as? NSNumber { return value.stringValue }
        return nil
    }

    private static func intValue(_ value: Any?) -> Int {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        if let value = value as? String { return Int(value) ?? 0 }
        return 0
    }

    private static func int64Value(_ value: Any?) -> Int64 {
        if let value = value as? Int64 { return value }
        if let value = value as? NSNumber { return value.int64Value }
        if let value = value as? String { return Int64(value) ?? 0 }
        return 0
    }
}

private struct PirateBaySearchPayload: Decodable {
    let id: String
    let name: String
    let infoHash: String
    let seeders: String
    let size: String

    enum CodingKeys: String, CodingKey {
        case id, name, seeders, size
        case infoHash = "info_hash"
    }
}

struct ResolvedOnlinePlayback: Sendable {
    let url: URL
    let title: String
    let provider: String
    let headers: [String: String]?
}

enum OnlinePlaybackResolutionError: LocalizedError {
    case noPlayableFile(String)
    case timedOut(String)
    case allProvidersFailed(String)
    case torrentEngine(String)

    var errorDescription: String? {
        switch self {
        case let .noPlayableFile(provider): return "\(provider) did not return a playable video file."
        case let .timedOut(provider): return "\(provider) is still preparing the file. Try again in a moment."
        case let .allProvidersFailed(message): return message
        case let .torrentEngine(message): return message
        }
    }
}

actor OnlinePlaybackResolver {
    static let shared = OnlinePlaybackResolver()

    private enum Provider: String, CaseIterable {
        case realDebrid = "Real-Debrid"
        case torBox = "TorBox"
        case pikpak = "PikPak"
        case offcloud = "Offcloud"
    }

    func resolve(_ source: OnlineTorrentSource) async throws -> ResolvedOnlinePlayback {
        let preference = OnlinePlaybackProviderPreference.selected
        if preference == .directTorrent {
            let url = try await DirectTorrentPlaybackEngine.shared.start(magnet: source.magnet)
            return ResolvedOnlinePlayback(url: url, title: source.name, provider: "Direct Torrent", headers: nil)
        }

        let providers: [Provider]
        if preference == .automatic {
            providers = configuredProviders
        } else if let selected = provider(for: preference) {
            guard configuredProviders.contains(selected) else {
                throw OnlineSourceSearchError.provider(
                    "\(selected.rawValue) is selected, but its account is not configured."
                )
            }
            providers = [selected]
        } else {
            providers = []
        }

        guard !providers.isEmpty else {
            let url = try await DirectTorrentPlaybackEngine.shared.start(magnet: source.magnet)
            return ResolvedOnlinePlayback(url: url, title: source.name, provider: "Direct Torrent", headers: nil)
        }

        var failures: [String] = []
        for provider in providers {
            do {
                switch provider {
                case .pikpak: return try await resolvePikPak(source)
                case .torBox: return try await resolveTorBox(source)
                case .realDebrid: return try await resolveRealDebrid(source)
                case .offcloud: return try await resolveOffcloud(source)
                }
            } catch {
                if error is CancellationError || Task.isCancelled { throw CancellationError() }
                failures.append("\(provider.rawValue): \(error.localizedDescription)")
            }
        }
        throw OnlinePlaybackResolutionError.allProvidersFailed(failures.joined(separator: "\n"))
    }

    private func provider(for preference: OnlinePlaybackProviderPreference) -> Provider? {
        switch preference {
        case .realDebrid: return .realDebrid
        case .torBox: return .torBox
        case .pikpak: return .pikpak
        case .offcloud: return .offcloud
        case .automatic, .directTorrent: return nil
        }
    }

    private var configuredProviders: [Provider] {
        Provider.allCases.filter { provider in
            switch provider {
            case .pikpak: return PikPakClient.shared.loadAccount() != nil
            case .torBox: return !TorBoxKeyStore.load().isEmpty
            case .realDebrid: return !RealDebridKeyStore.key.isEmpty
            case .offcloud: return !OffcloudKeyStore.load().isEmpty
            }
        }
    }

    private func resolvePikPak(_ source: OnlineTorrentSource) async throws -> ResolvedOnlinePlayback {
        let client = PikPakClient.shared
        let before = (try? await client.listFiles()).map { Set($0.map(\.id)) } ?? []
        let taskID = try await client.addOfflineTask(urlOrMagnet: source.magnet)

        for _ in 0..<60 {
            if let task = try? await client.offlineTask(id: taskID) {
                if task.isFailed {
                    throw OnlineSourceSearchError.provider(task.message ?? "PikPak could not prepare this torrent.")
                }
                if let fileID = task.fileID, !fileID.isEmpty {
                    let resolvedFile = try? await client.getFile(id: fileID)
                    if let resolved = resolvedFile {
                        if resolved.item.isVideo, let url = resolved.streamURL {
                            return ResolvedOnlinePlayback(
                                url: url, title: resolved.item.name, provider: Provider.pikpak.rawValue,
                                headers: client.directPlaybackHeaders()
                            )
                        }
                        if resolved.item.isFolder {
                            let folderVideo = await largestPikPakVideo(items: [resolved.item], client: client)
                            if let item = folderVideo {
                                let streamURL = try? await client.streamURL(forFileId: item.id)
                                if let url = streamURL {
                                    return ResolvedOnlinePlayback(
                                        url: url, title: item.name, provider: Provider.pikpak.rawValue,
                                        headers: client.directPlaybackHeaders()
                                    )
                                }
                            }
                        }
                    }
                }
            }

            let listedRoots = try? await client.listFiles()
            if let roots = listedRoots {
                let newRoots = roots.filter { !before.contains($0.id) || $0.id == taskID }
                let rootVideo = await largestPikPakVideo(items: newRoots, client: client)
                if let item = rootVideo {
                    let streamURL = try? await client.streamURL(forFileId: item.id)
                    if let url = streamURL {
                        return ResolvedOnlinePlayback(
                            url: url, title: item.name, provider: Provider.pikpak.rawValue,
                            headers: client.directPlaybackHeaders()
                        )
                    }
                }
            }
            try await Task.sleep(nanoseconds: 2_000_000_000)
        }
        throw OnlinePlaybackResolutionError.timedOut(Provider.pikpak.rawValue)
    }

    private func largestPikPakVideo(
        items: [PikPakFileItem],
        client: PikPakClient
    ) async -> PikPakFileItem? {
        var candidates = items.filter(\.isVideo)
        for folder in items.filter(\.isFolder).prefix(4) {
            let listedChildren = try? await client.listFiles(parentId: folder.id)
            if let children = listedChildren {
                candidates.append(contentsOf: children.filter(\.isVideo))
                for subfolder in children.filter(\.isFolder).prefix(4) {
                    let listedNested = try? await client.listFiles(parentId: subfolder.id)
                    if let nested = listedNested {
                        candidates.append(contentsOf: nested.filter(\.isVideo))
                    }
                }
            }
        }
        return candidates.max { $0.size < $1.size }
    }

    private func resolveTorBox(_ source: OnlineTorrentSource) async throws -> ResolvedOnlinePlayback {
        let client = TorBoxClient(apiKey: TorBoxKeyStore.load())
        let created = try await client.createTorrent(magnet: source.magnet)
        let magnetHash = URLComponents(string: source.magnet)?.queryItems?
            .first(where: { $0.name.lowercased() == "xt" })?.value?
            .replacingOccurrences(of: "urn:btih:", with: "", options: .caseInsensitive)
        let expectedHash = (created.hash ?? magnetHash)?.lowercased()

        for _ in 0..<60 {
            let torrents = try await client.torrents(bypassCache: true)
            let torrent = torrents.first { torrent in
                if let id = created.torrentId, torrent.id == id { return true }
                if let expectedHash { return torrent.hash?.lowercased() == expectedHash }
                return false
            }
            if let torrent, torrent.isReady,
               let file = torrent.videoFiles.max(by: { ($0.size ?? 0) < ($1.size ?? 0) }) {
                let url = try await client.downloadURL(torrentId: torrent.id, fileId: file.id)
                return ResolvedOnlinePlayback(
                    url: url, title: file.displayName, provider: Provider.torBox.rawValue, headers: nil
                )
            }
            try await Task.sleep(nanoseconds: 2_000_000_000)
        }
        throw OnlinePlaybackResolutionError.timedOut(Provider.torBox.rawValue)
    }

    private func resolveRealDebrid(_ source: OnlineTorrentSource) async throws -> ResolvedOnlinePlayback {
        let client = RealDebridClient(apiKey: RealDebridKeyStore.key)
        let resolved = try await client.resolve(magnet: source.magnet)
        return ResolvedOnlinePlayback(
            url: resolved.url, title: resolved.fileName ?? source.name,
            provider: Provider.realDebrid.rawValue, headers: nil
        )
    }

    private func resolveOffcloud(_ source: OnlineTorrentSource) async throws -> ResolvedOnlinePlayback {
        let client = OffcloudClient(apiKey: OffcloudKeyStore.load())
        if let cached = try await client.cachedFilesIfAvailable(for: source.magnet),
           let file = cached.filter(\.isVideo).max(by: { ($0.size ?? 0) < ($1.size ?? 0) }),
           let url = file.streamURL {
            return ResolvedOnlinePlayback(
                url: url, title: file.name, provider: Provider.offcloud.rawValue, headers: nil
            )
        }

        let transfer = try await client.create(url: source.magnet)
        for _ in 0..<60 {
            let current = (try await client.history()).first(where: { $0.requestId == transfer.requestId })
            if current?.isFailed == true { throw OnlinePlaybackResolutionError.noPlayableFile(Provider.offcloud.rawValue) }
            if current?.isDownloaded == true {
                let files: [OffcloudFile]
                do {
                    files = try await client.explore(requestId: transfer.requestId)
                } catch OffcloudError.badArchive {
                    files = try await client.cachedFilesIfAvailable(for: source.magnet) ?? []
                }
                if let file = files.filter(\.isVideo).max(by: { ($0.size ?? 0) < ($1.size ?? 0) }),
                   let url = file.streamURL {
                    return ResolvedOnlinePlayback(
                        url: url, title: file.name, provider: Provider.offcloud.rawValue, headers: nil
                    )
                }
            }
            try await Task.sleep(nanoseconds: 2_000_000_000)
        }
        throw OnlinePlaybackResolutionError.timedOut(Provider.offcloud.rawValue)
    }
}

private struct RealDebridClient: Sendable {
    private let apiKey: String
    private let baseURL = URL(string: "https://api.real-debrid.com/rest/1.0/")!

    struct Resolved: Sendable { let url: URL; let fileName: String? }

    init(apiKey: String) {
        self.apiKey = apiKey
    }

    func resolve(magnet: String) async throws -> Resolved {
        let cachedVariant = try await cachedVariant(for: magnet)
        let added: AddedTorrent = try await send(path: "torrents/addMagnet", method: "POST", form: ["magnet": magnet])
        try await sendEmpty(
            path: "torrents/selectFiles/\(added.id)",
            method: "POST",
            form: ["files": cachedVariant.fileIDs.map { String($0) }.joined(separator: ",")]
        )

        // Cached torrents normally become ready within a few seconds. Do not leave
        // the player behind an indefinite spinner if Real-Debrid cannot prepare it.
        for _ in 0..<20 {
            let info: TorrentInfo = try await send(path: "torrents/info/\(added.id)", method: "GET")
            if ["magnet_error", "error", "virus", "dead"].contains(info.status.lowercased()) {
                throw OnlinePlaybackResolutionError.noPlayableFile("Real-Debrid")
            }
            if info.status.lowercased() == "downloaded", !info.links.isEmpty {
                let selected = info.files.enumerated().filter { $0.element.selected == 1 }
                let selectedVideos = selected.filter { isVideoFile($0.element.path) }
                let playableFiles = selectedVideos.isEmpty ? selected : selectedVideos
                let largest = playableFiles.max { $0.element.bytes < $1.element.bytes }
                let linkIndex = largest.flatMap { match in
                    selected.firstIndex(where: { $0.offset == match.offset })
                } ?? 0
                let restricted = info.links[min(linkIndex, info.links.count - 1)]
                let result: UnrestrictedLink = try await send(
                    path: "unrestrict/link", method: "POST", form: ["link": restricted]
                )
                guard let url = URL(string: result.download) else {
                    throw OnlineSourceSearchError.invalidResponse
                }
                return Resolved(url: url, fileName: result.filename)
            }
            try await Task.sleep(nanoseconds: 750_000_000)
        }
        throw OnlinePlaybackResolutionError.timedOut("Real-Debrid")
    }

    private func cachedVariant(for magnet: String) async throws -> CachedVariant {
        guard let hash = infoHash(from: magnet) else {
            throw OnlineSourceSearchError.provider("The torrent link does not contain a valid info hash.")
        }

        let data = try await sendData(
            path: "torrents/instantAvailability/\(hash)",
            method: "GET"
        )
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hashEntry = root.first(where: { $0.key.caseInsensitiveCompare(hash) == .orderedSame })?.value
                as? [String: Any],
              let variants = hashEntry["rd"] as? [[String: Any]] else {
            throw OnlineSourceSearchError.provider(
                "This source is not cached on Real-Debrid. Choose another result."
            )
        }

        let parsed = variants.compactMap { variant -> CachedVariant? in
            let files = variant.compactMap { key, value -> CachedFile? in
                guard let id = Int(key), let details = value as? [String: Any] else { return nil }
                let filename = details["filename"] as? String ?? ""
                let filesize = (details["filesize"] as? NSNumber)?.int64Value ?? 0
                return CachedFile(id: id, filename: filename, filesize: filesize)
            }
            guard let largestVideo = files.filter({ isVideoFile($0.filename) })
                .max(by: { $0.filesize < $1.filesize }) else { return nil }

            // Real-Debrid requires all IDs from one cached variant to preserve
            // instant availability, even when the torrent includes sidecar files.
            return CachedVariant(
                fileIDs: files.map(\.id).sorted(),
                largestVideoBytes: largestVideo.filesize
            )
        }

        guard let best = parsed.max(by: { $0.largestVideoBytes < $1.largestVideoBytes }),
              !best.fileIDs.isEmpty else {
            throw OnlineSourceSearchError.provider(
                "Real-Debrid has no cached playable video for this result. Choose another result."
            )
        }
        return best
    }

    private func infoHash(from magnet: String) -> String? {
        URLComponents(string: magnet)?.queryItems?
            .first(where: { $0.name.caseInsensitiveCompare("xt") == .orderedSame })?.value?
            .replacingOccurrences(of: "urn:btih:", with: "", options: .caseInsensitive)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func isVideoFile(_ name: String) -> Bool {
        let videoExtensions: Set<String> = [
            "mp4", "mkv", "mov", "m4v", "avi", "webm", "ts", "m2ts", "mpg", "mpeg", "wmv", "flv"
        ]
        return videoExtensions.contains((name as NSString).pathExtension.lowercased())
    }

    private func send<T: Decodable>(
        path: String,
        method: String,
        form: [String: String]? = nil
    ) async throws -> T {
        let data = try await sendData(path: path, method: method, form: form)
        return try JSONDecoder().decode(T.self, from: data)
    }

    @discardableResult
    private func sendData(
        path: String,
        method: String,
        form: [String: String]? = nil
    ) async throws -> Data {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = method
        request.timeoutInterval = 35
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let form {
            var values = URLComponents()
            values.queryItems = form.map { URLQueryItem(name: $0.key, value: $0.value) }
            request.httpBody = values.percentEncodedQuery?.data(using: .utf8)
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await HighPriorityNetworkManager.shared.responsiveData(for: request)
        guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
            let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
            throw OnlineSourceSearchError.provider(
                message ?? "Real-Debrid request failed (HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0))."
            )
        }
        return data
    }

    private func sendEmpty(path: String, method: String, form: [String: String]) async throws {
        _ = try await sendData(path: path, method: method, form: form)
    }

    private struct CachedFile { let id: Int; let filename: String; let filesize: Int64 }
    private struct CachedVariant { let fileIDs: [Int]; let largestVideoBytes: Int64 }
    private struct AddedTorrent: Decodable { let id: String }
    private struct TorrentFile: Decodable { let id: Int; let path: String; let bytes: Int64; let selected: Int }
    private struct TorrentInfo: Decodable { let status: String; let files: [TorrentFile]; let links: [String] }
    private struct UnrestrictedLink: Decodable { let filename: String?; let download: String }
}

@MainActor
final class DirectTorrentPlaybackEngine {
    static let shared = DirectTorrentPlaybackEngine()

    private var session: lt_session_t?
    private var currentTorrent: lt_torrent_id = -1
    private var currentStream: lt_stream_id = -1
    private var currentDirectory: URL?

    private init() {}

    func start(magnet: String) async throws -> URL {
        stopCurrent()
        let session = try ensureSession()
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DirectTorrent", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        currentDirectory = base

        let torrentID = magnet.withCString { magnetPointer in
            base.path.withCString { pathPointer in
                lt_add_magnet(session, magnetPointer, pathPointer, 1)
            }
        }
        guard torrentID >= 0 else {
            throw OnlinePlaybackResolutionError.torrentEngine(lastError("Could not add magnet."))
        }
        currentTorrent = torrentID

        var metadataReady = false
        for _ in 0..<60 {
            var status = lt_torrent_status()
            if lt_get_status(session, torrentID, &status) != 0 {
                if status.state == -2 {
                    stopCurrent()
                    throw OnlinePlaybackResolutionError.torrentEngine(cString(status.error_msg) ?? lastError("Torrent failed."))
                }
                if status.has_metadata != 0 {
                    metadataReady = true
                    break
                }
            }
            do {
                try await Task.sleep(nanoseconds: 500_000_000)
            } catch {
                stopCurrent()
                throw error
            }
        }
        guard metadataReady else {
            stopCurrent()
            throw OnlinePlaybackResolutionError.timedOut("Direct Torrent")
        }

        let streamID = lt_start_stream(session, torrentID, -1, 192 * 1_024 * 1_024)
        guard streamID >= 0 else {
            stopCurrent()
            throw OnlinePlaybackResolutionError.torrentEngine(lastError("Could not start torrent stream."))
        }
        currentStream = streamID
        _ = lt_preload_stream(session, streamID, 16 * 1_024 * 1_024)

        var status = lt_stream_status()
        guard lt_get_stream_status(session, streamID, &status) != 0,
              let rawURL = cString(status.url),
              let url = URL(string: rawURL) else {
            stopCurrent()
            throw OnlinePlaybackResolutionError.torrentEngine(lastError("The torrent engine returned no stream URL."))
        }

        // Do not present a player pointed at an idle local HTTP server. The
        // native preload starts fetching the head/tail immediately; wait only
        // until it has a real peer, transfer, or its first contiguous piece.
        // This turns dead/stale tracker results into a clear error instead of
        // leaving AVPlayer/VLC on an endless spinner.
        var sawActivePeer = status.active_peers > 0
        var sawTransfer = status.download_rate > 0 || status.buffer_pieces > 0
        for _ in 0..<40 {
            if sawTransfer { break }
            do {
                try await Task.sleep(nanoseconds: 500_000_000)
            } catch {
                stopCurrent()
                throw error
            }
            guard lt_get_stream_status(session, streamID, &status) != 0 else {
                stopCurrent()
                throw OnlinePlaybackResolutionError.torrentEngine(lastError("The torrent stream stopped before playback."))
            }
            sawActivePeer = sawActivePeer || status.active_peers > 0
            sawTransfer = status.download_rate > 0 || status.buffer_pieces > 0
        }
        guard sawTransfer else {
            stopCurrent()
            let message = sawActivePeer
                ? "Torrent peers connected but sent no video data. Choose another result."
                : "No active torrent peers were found. Choose another result with working seeders."
            throw OnlinePlaybackResolutionError.torrentEngine(message)
        }
        return url
    }

    func stopCurrent() {
        guard let session else { return }
        if currentStream >= 0 {
            lt_stop_stream(session, currentStream)
            currentStream = -1
        }
        if currentTorrent >= 0 {
            lt_remove_torrent(session, currentTorrent, 1)
            currentTorrent = -1
        }
        if let currentDirectory {
            try? FileManager.default.removeItem(at: currentDirectory)
            self.currentDirectory = nil
        }
    }

    private func ensureSession() throws -> lt_session_t {
        if let session { return session }
        let created = "".withCString { lt_create_session($0, 0, 0) }
        guard let created else {
            throw OnlinePlaybackResolutionError.torrentEngine(lastError("Could not initialize torrent engine."))
        }
        session = created
        return created
    }

    private func lastError(_ fallback: String) -> String {
        guard let pointer = lt_last_error() else { return fallback }
        let value = String(cString: pointer)
        return value.isEmpty ? fallback : value
    }

    private func cString<T>(_ tuple: T) -> String? {
        var value = tuple
        return withUnsafePointer(to: &value) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: MemoryLayout<T>.size) {
                let result = String(cString: $0)
                return result.isEmpty ? nil : result
            }
        }
    }
}

@MainActor
extension AppViewModel {
    func resolveAndPlayOnlineSource(
        _ source: OnlineTorrentSource,
        linkId: UUID? = nil
    ) async throws -> String {
        isLoading = true
        defer { isLoading = false }
        let resolved = try await OnlinePlaybackResolver.shared.resolve(source)
        startPlayback(
            url: resolved.url,
            title: resolved.title,
            linkId: linkId,
            headers: resolved.headers
        )
        return resolved.provider
    }

    func resolveAndPlayMagnet(
        _ magnet: String,
        title: String? = nil,
        linkId: UUID? = nil
    ) async throws -> String {
        let trimmed = magnet.trimmingCharacters(in: .whitespacesAndNewlines)
        guard LinkResolver.classify(trimmed) == .magnet
                || LinkResolver.classify(trimmed) == .pikpakMagnet else {
            throw OnlineSourceSearchError.provider("The magnet link is invalid.")
        }

        let magnetName = URLComponents(string: trimmed)?.queryItems?
            .first(where: { $0.name.lowercased() == "dn" })?.value?
            .removingPercentEncoding
        let displayName = [title, magnetName]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { !$0.isEmpty }) ?? "Torrent video"
        let quality = OnlineStreamQuality.detect(hint: nil, fileName: displayName) ?? .p1080
        let source = OnlineTorrentSource(
            id: "manual|\(trimmed)",
            name: displayName,
            magnet: trimmed,
            quality: quality,
            seeders: 0,
            sizeBytes: 0,
            origin: .manual
        )
        return try await resolveAndPlayOnlineSource(source, linkId: linkId)
    }
}
