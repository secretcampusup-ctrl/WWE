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
        case stremioAddon = "Manual Add-on"
        case nyaa = "Nyaa"
    }

    let id: String
    let name: String
    let magnet: String
    /// Some debrid-backed add-ons return an already playable HTTPS URL.
    let directURL: URL?
    let quality: OnlineStreamQuality
    let seeders: Int
    let sizeBytes: Int64
    let origin: Origin
    let requestedSeason: Int?
    let requestedEpisode: Int?

    init(
        id: String,
        name: String,
        magnet: String,
        directURL: URL? = nil,
        quality: OnlineStreamQuality,
        seeders: Int,
        sizeBytes: Int64,
        origin: Origin,
        requestedSeason: Int? = nil,
        requestedEpisode: Int? = nil
    ) {
        self.id = id
        self.name = name
        self.magnet = magnet
        self.directURL = directURL
        self.quality = quality
        self.seeders = seeders
        self.sizeBytes = sizeBytes
        self.origin = origin
        self.requestedSeason = requestedSeason
        self.requestedEpisode = requestedEpisode
    }

    var sizeLabel: String {
        guard sizeBytes > 0 else { return "Unknown size" }
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: sizeBytes)
    }

    var requestsSpecificEpisode: Bool {
        requestedSeason != nil && requestedEpisode != nil
    }

    func matchesRequestedEpisode(fileName: String) -> Bool {
        guard let requestedSeason, let requestedEpisode else { return true }
        guard let found = parsedEpisode(in: fileName) else { return false }
        return found.season == requestedSeason && found.episode == requestedEpisode
    }

    func hasRecognizableEpisodeTag(fileName: String) -> Bool {
        parsedEpisode(in: fileName) != nil
    }

    private func parsedEpisode(in fileName: String) -> (season: Int, episode: Int)? {
        let patterns = [
            #"(?i)\bS(\d{1,3})[ ._-]*E(\d{1,3})\b"#,
            #"(?i)\b(\d{1,3})x(\d{1,3})\b"#
        ]
        for pattern in patterns {
            guard let expression = try? NSRegularExpression(pattern: pattern),
                  let match = expression.firstMatch(
                    in: fileName,
                    range: NSRange(fileName.startIndex..<fileName.endIndex, in: fileName)
                  ),
                  let seasonRange = Range(match.range(at: 1), in: fileName),
                  let episodeRange = Range(match.range(at: 2), in: fileName),
                  let season = Int(fileName[seasonRange]),
                  let episode = Int(fileName[episodeRange]) else { continue }
            return (season, episode)
        }
        let episodeOnlyPattern = #"(?i)\b(?:E|EP|Episode)[ ._-]?(\d{1,3})\b"#
        if let requestedSeason,
           let expression = try? NSRegularExpression(pattern: episodeOnlyPattern),
           let match = expression.firstMatch(
            in: fileName,
            range: NSRange(fileName.startIndex..<fileName.endIndex, in: fileName)
           ),
           let episodeRange = Range(match.range(at: 1), in: fileName),
           let episode = Int(fileName[episodeRange]) {
            return (requestedSeason, episode)
        }
        return nil
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
        var raw: [OnlineTorrentSource] = []
        var errors: [Error] = []
        let providers = OnlineSearchProviderSelection.selected
        guard !providers.isEmpty else {
            throw OnlineSourceSearchError.provider("Choose at least one search provider in Settings.")
        }
        for provider in OnlineSearchProviderSelection.available where providers.contains(provider) {
            do {
                switch provider {
                case .stremioAddon:
                    guard StremioAddonStore.isConfigured, let imdb = context.imdbID, !imdb.isEmpty else { continue }
                    raw += try await searchStremioAddon(context, imdbID: imdb)
                case .orion:
                    guard OrionCredentialStore.isReady, let imdb = context.imdbID, !imdb.isEmpty else { continue }
                    raw += try await searchOrion(context, imdbID: imdb)
                case .pirateBay:
                    raw += try await searchPirateBay(context)
                case .nyaa:
                    raw += try await searchNyaa(context)
                case .automatic:
                    continue
                }
            } catch {
                errors.append(error)
            }
        }
        if raw.isEmpty, let error = errors.first { throw error }
        return bestPerQuality(eligibleSources(raw))
    }

    /// Loads streams from a manually configured Stremio-compatible manifest URL.
    private func searchStremioAddon(_ context: OnlineSourceLookupContext, imdbID: String) async throws -> [OnlineTorrentSource] {
        let manifest = StremioAddonStore.manifestURL
        guard let manifestURL = URL(string: manifest), manifestURL.scheme?.lowercased() == "https" else {
            throw OnlineSourceSearchError.provider("Enter a valid HTTPS add-on manifest URL.")
        }
        let suffix = "/manifest.json"
        guard manifestURL.absoluteString.lowercased().hasSuffix(suffix) else {
            throw OnlineSourceSearchError.provider("The add-on URL must end with /manifest.json.")
        }
        let contentID: String
        if context.mediaType == "tv" {
            contentID = "\(imdbID):\(context.season ?? 1):\(context.episode ?? 1)"
        } else {
            contentID = imdbID
        }
        let base = String(manifestURL.absoluteString.dropLast(suffix.count))
        guard let url = URL(string: "\(base)/stream/\(context.mediaType)/\(contentID).json") else {
            throw OnlineSourceSearchError.invalidResponse
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 35
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await HighPriorityNetworkManager.shared.responsiveData(for: request)
        guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode,
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let streams = root["streams"] as? [[String: Any]] else {
            throw OnlineSourceSearchError.invalidResponse
        }
        return streams.enumerated().compactMap { index, stream in
            let name = (stream["title"] as? String)?.replacingOccurrences(of: "\n", with: " · ")
                ?? (stream["name"] as? String) ?? context.fallbackQuery
            let rawURL = stream["url"] as? String
            let directURL = rawURL.flatMap { URL(string: $0) }.flatMap {
                $0.scheme?.lowercased().hasPrefix("http") == true ? $0 : nil
            }
            let magnet: String
            if let rawURL, rawURL.lowercased().hasPrefix("magnet:?") {
                magnet = rawURL
            } else if let hash = stream["infoHash"] as? String, !hash.isEmpty {
                magnet = Self.magnet(infoHash: hash, name: name)
            } else if directURL != nil {
                magnet = ""
            } else {
                return nil
            }
            guard let quality = OnlineStreamQuality.detect(hint: name, fileName: name) else { return nil }
            let seeders = Self.intValue(stream["seeders"] ?? stream["seeds"])
            let size = Self.byteSize(from: stream["size"] ?? stream["sizeBytes"])
            return OnlineTorrentSource(
                id: "addon|\(index)|\(stream["infoHash"] as? String ?? name)", name: name,
                magnet: magnet, directURL: directURL, quality: quality, seeders: seeders, sizeBytes: size,
                origin: .stremioAddon,
                requestedSeason: context.mediaType == "tv" ? context.season : nil,
                requestedEpisode: context.mediaType == "tv" ? context.episode : nil
            )
        }
    }

    private func eligibleSources(_ values: [OnlineTorrentSource]) -> [OnlineTorrentSource] {
        values.filter { source in
            source.origin == .nyaa || source.sizeBytes == 0 || source.sizeBytes >= minimumVisibleSize
        }
    }

    private func bestPerQuality(_ eligible: [OnlineTorrentSource]) -> [OnlineTorrentSource] {
        OnlineStreamQuality.allCases.flatMap { quality in
            Array(rankedSources(for: quality, in: eligible).prefix(3))
        }
    }

    private func rankedSources(
        for quality: OnlineStreamQuality,
        in eligible: [OnlineTorrentSource]
    ) -> [OnlineTorrentSource] {
        let qualitySources = eligible.filter { $0.quality == quality }
        let exactEpisodes = qualitySources.filter {
            $0.requestsSpecificEpisode && $0.matchesRequestedEpisode(fileName: $0.name)
        }
        let candidates = exactEpisodes.isEmpty ? qualitySources : exactEpisodes
        return candidates.sorted {
            if $0.seeders != $1.seeders { return $0.seeders > $1.seeders }
            if $0.sizeBytes == 0 { return false }
            if $1.sizeBytes == 0 { return true }
            return $0.sizeBytes < $1.sizeBytes
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
            if context.mediaType == "tv",
               let found = Self.episodeIdentity(in: name),
               (found.season != (context.season ?? 1) || found.episode != (context.episode ?? 1)) {
                return nil
            }
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
                origin: .orion,
                requestedSeason: context.mediaType == "tv" ? context.season : nil,
                requestedEpisode: context.mediaType == "tv" ? context.episode : nil
            )
        }
    }

    private func searchPirateBay(_ context: OnlineSourceLookupContext) async throws -> [OnlineTorrentSource] {
        var queries: [String] = []
        if let imdbID = context.imdbID, !imdbID.isEmpty {
            if context.mediaType == "tv" {
                queries.append("\(imdbID) " + String(
                    format: "S%02dE%02d",
                    context.season ?? 1,
                    context.episode ?? 1
                ))
            } else {
                queries.append(imdbID)
            }
        }
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
                if context.mediaType == "tv",
                   let found = Self.episodeIdentity(in: value.name),
                   (found.season != (context.season ?? 1) || found.episode != (context.episode ?? 1)) {
                    continue
                }
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
                    origin: .pirateBay,
                    requestedSeason: context.mediaType == "tv" ? context.season : nil,
                    requestedEpisode: context.mediaType == "tv" ? context.episode : nil
                ))
            }
            if Set(combined.map(\.quality)).count == OnlineStreamQuality.allCases.count { break }
        }
        return combined
    }

    private func searchNyaa(_ context: OnlineSourceLookupContext) async throws -> [OnlineTorrentSource] {
        var components = URLComponents(string: "https://nyaa.media/")!
        components.queryItems = [
            URLQueryItem(name: "f", value: "0"),
            URLQueryItem(name: "c", value: "0_0"),
            URLQueryItem(name: "q", value: context.fallbackQuery)
        ]
        var request = URLRequest(url: components.url!)
        request.timeoutInterval = 35
        request.setValue("text/html", forHTTPHeaderField: "Accept")
        let (data, response) = try await HighPriorityNetworkManager.shared.responsiveData(for: request)
        guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode,
              let html = String(data: data, encoding: .utf8) else { throw OnlineSourceSearchError.invalidResponse }

        let rowPattern = #"<tr class=\"(?:default|success|danger|warning)\">(.*?)</tr>"#
        let rows = Self.matches(rowPattern, in: html, capture: 1, options: [.dotMatchesLineSeparators])
        return rows.compactMap { row in
            guard let magnet = Self.matches(#"href=\"(magnet:\?[^\"]+)\""#, in: row, capture: 1).first else { return nil }
            let nameHTML = Self.matches(#"href=\"(?:https?://nyaa\.media)?/view/[^\"]+\"[^>]*>(.*?)</a>"#, in: row, capture: 1, options: [.dotMatchesLineSeparators]).first ?? ""
            let name = Self.decodeHTML(nameHTML).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, let quality = OnlineStreamQuality.detect(hint: nil, fileName: name) else { return nil }
            if context.mediaType == "tv", let found = Self.episodeIdentity(in: name),
               (found.season != (context.season ?? 1) || found.episode != (context.episode ?? 1)) { return nil }
            let sizeText = Self.matches(#"([0-9]+(?:\.[0-9]+)?\s*(?:KiB|MiB|GiB|TiB))"#, in: row).first
            let numericCells = Self.matches(#"<td class=\"text-center\">\s*([0-9]+)\s*</td>"#, in: row, capture: 1)
            let seeders = numericCells.suffix(3).first.flatMap { Int($0) } ?? 0
            return OnlineTorrentSource(
                id: "nyaa|\(Self.infoHash(from: Self.decodeHTML(magnet)) ?? name)", name: name,
                magnet: Self.decodeHTML(magnet), quality: quality, seeders: seeders,
                sizeBytes: Self.byteSize(from: sizeText), origin: .nyaa,
                requestedSeason: context.mediaType == "tv" ? context.season : nil,
                requestedEpisode: context.mediaType == "tv" ? context.episode : nil
            )
        }
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

    private static func episodeIdentity(in value: String) -> (season: Int, episode: Int)? {
        let patterns = [
            #"(?i)\bS(\d{1,3})[ ._-]*E(\d{1,3})\b"#,
            #"(?i)\b(\d{1,3})x(\d{1,3})\b"#
        ]
        for pattern in patterns {
            guard let expression = try? NSRegularExpression(pattern: pattern),
                  let match = expression.firstMatch(
                    in: value,
                    range: NSRange(value.startIndex..<value.endIndex, in: value)
                  ),
                  let seasonRange = Range(match.range(at: 1), in: value),
                  let episodeRange = Range(match.range(at: 2), in: value),
                  let season = Int(value[seasonRange]),
                  let episode = Int(value[episodeRange]) else { continue }
            return (season, episode)
        }
        return nil
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

    private static func byteSize(from value: Any?) -> Int64 {
        if let number = value as? NSNumber { return number.int64Value }
        if let text = value as? String {
            let normalized = text.lowercased().replacingOccurrences(of: ",", with: ".")
            guard let match = try? NSRegularExpression(pattern: #"([0-9]+(?:\.[0-9]+)?)\s*(gb|mb|kb|b)?"#)
                .firstMatch(in: normalized, range: NSRange(normalized.startIndex..., in: normalized)),
                  let numberRange = Range(match.range(at: 1), in: normalized), let number = Double(normalized[numberRange]) else { return 0 }
            let unit = match.range(at: 2).location == NSNotFound ? "b" : String(normalized[Range(match.range(at: 2), in: normalized)!])
            let multiplier: Double = unit == "gb" ? 1_073_741_824 : unit == "mb" ? 1_048_576 : unit == "kb" ? 1_024 : 1
            return Int64(number * multiplier)
        }
        return 0
    }

    private static func matches(
        _ pattern: String, in text: String, capture: Int = 0,
        options: NSRegularExpression.Options = []
    ) -> [String] {
        guard let expression = try? NSRegularExpression(pattern: pattern, options: options) else { return [] }
        return expression.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
            guard $0.numberOfRanges > capture, let range = Range($0.range(at: capture), in: text) else { return nil }
            return String(text[range])
        }
    }

    private static func decodeHTML(_ value: String) -> String {
        value.replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
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
    let requiredDownload: Bool

    init(
        url: URL,
        title: String,
        provider: String,
        headers: [String: String]?,
        requiredDownload: Bool = false
    ) {
        self.url = url
        self.title = title
        self.provider = provider
        self.headers = headers
        self.requiredDownload = requiredDownload
    }
}

struct DirectTorrentPlayback: Sendable {
    let url: URL
    /// The native engine's actual selected file, including its container
    /// extension. The localhost stream URL ends in a numeric file index, so
    /// the player cannot otherwise distinguish MP4 (AVPlayer) from MKV (VLC).
    let fileName: String
}

struct OnlinePlaybackProgress: Sendable {
    enum Phase: Sendable {
        case preparing
        case downloading
    }

    let provider: String
    let phase: Phase
}

typealias OnlinePlaybackProgressHandler = @Sendable (OnlinePlaybackProgress) -> Void

struct OnlinePlaybackTransfer: Identifiable, Equatable {
    enum Phase: Equatable {
        case preparing
        case downloading
        case ready
        case failed
    }

    let id: String
    let title: String
    let provider: String
    let phase: Phase
    let message: String
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

    func resolve(
        _ source: OnlineTorrentSource,
        onProgress: @escaping OnlinePlaybackProgressHandler = { _ in }
    ) async throws -> ResolvedOnlinePlayback {
        if let url = source.directURL {
            return ResolvedOnlinePlayback(url: url, title: source.name, provider: source.origin.rawValue, headers: nil)
        }
        let preference = OnlinePlaybackProviderPreference.selected
        if preference == .directTorrent {
            return try await resolveDirectTorrent(source)
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
            return try await resolveDirectTorrent(source)
        }

        var failures: [String] = []
        for provider in providers {
            do {
                onProgress(.init(provider: provider.rawValue, phase: .preparing))
                switch provider {
                case .pikpak: return try await resolvePikPak(source)
                case .torBox: return try await resolveTorBox(source)
                case .realDebrid: return try await resolveRealDebrid(source, onProgress: onProgress)
                case .offcloud: return try await resolveOffcloud(source)
                }
            } catch {
                if error is CancellationError || Task.isCancelled { throw CancellationError() }
                failures.append("\(provider.rawValue): \(error.localizedDescription)")
            }
        }
        throw OnlinePlaybackResolutionError.allProvidersFailed(failures.joined(separator: "\n"))
    }

    private func resolveDirectTorrent(_ source: OnlineTorrentSource) async throws -> ResolvedOnlinePlayback {
        if source.requestsSpecificEpisode,
           !source.matchesRequestedEpisode(fileName: source.name) {
            throw OnlineSourceSearchError.provider(
                "Direct Torrent cannot safely choose the requested episode from this season pack. Choose an episode-specific source or a cloud provider."
            )
        }
        let playback = try await DirectTorrentPlaybackEngine.shared.start(magnet: source.magnet)
        return ResolvedOnlinePlayback(
            url: playback.url,
            title: playback.fileName,
            provider: "Direct Torrent",
            headers: nil
        )
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
                            let hasWrongEpisode = source.requestsSpecificEpisode
                                && source.hasRecognizableEpisodeTag(fileName: resolved.item.name)
                                && !source.matchesRequestedEpisode(fileName: resolved.item.name)
                            if hasWrongEpisode {
                                throw OnlineSourceSearchError.provider(
                                    "PikPak returned a different episode than the one selected."
                                )
                            }
                            return ResolvedOnlinePlayback(
                                url: url, title: resolved.item.name, provider: Provider.pikpak.rawValue,
                                headers: client.directPlaybackHeaders()
                            )
                        }
                        if resolved.item.isFolder {
                            let folderVideo = await largestPikPakVideo(
                                items: [resolved.item],
                                client: client,
                                source: source
                            )
                            if let item = folderVideo {
                                let streamURL = try? await client.streamURL(forFileId: item.id)
                                if let url = streamURL {
                                    return ResolvedOnlinePlayback(
                                        url: url, title: item.name, provider: Provider.pikpak.rawValue,
                                        headers: client.directPlaybackHeaders()
                                    )
                                }
                            } else if source.requestsSpecificEpisode {
                                throw OnlineSourceSearchError.provider(
                                    "PikPak prepared the torrent, but it does not contain the requested episode."
                                )
                            }
                        }
                    }
                }
            }

            let listedRoots = try? await client.listFiles()
            if let roots = listedRoots {
                let newRoots = roots.filter { !before.contains($0.id) || $0.id == taskID }
                let rootVideo = await largestPikPakVideo(items: newRoots, client: client, source: source)
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
        client: PikPakClient,
        source: OnlineTorrentSource
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
        if source.requestsSpecificEpisode {
            let matching = candidates.filter { source.matchesRequestedEpisode(fileName: $0.name) }
            if let file = matching.max(by: { $0.size < $1.size }) { return file }
            if candidates.count == 1,
               !source.hasRecognizableEpisodeTag(fileName: candidates[0].name) {
                return candidates[0]
            }
            return nil
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
            if let torrent, torrent.isReady {
                guard let file = selectedTorBoxFile(from: torrent.videoFiles, source: source) else {
                    throw OnlineSourceSearchError.provider(
                        "TorBox prepared the torrent, but it does not contain the requested episode."
                    )
                }
                let url = try await client.downloadURL(torrentId: torrent.id, fileId: file.id)
                return ResolvedOnlinePlayback(
                    url: url, title: file.displayName, provider: Provider.torBox.rawValue, headers: nil
                )
            }
            try await Task.sleep(nanoseconds: 2_000_000_000)
        }
        throw OnlinePlaybackResolutionError.timedOut(Provider.torBox.rawValue)
    }

    private func selectedTorBoxFile(
        from files: [TorBoxFile],
        source: OnlineTorrentSource
    ) -> TorBoxFile? {
        if source.requestsSpecificEpisode {
            let matching = files.filter { source.matchesRequestedEpisode(fileName: $0.displayName) }
            if let file = matching.max(by: { ($0.size ?? 0) < ($1.size ?? 0) }) { return file }
            if files.count == 1,
               !source.hasRecognizableEpisodeTag(fileName: files[0].displayName) {
                return files[0]
            }
            return nil
        }
        return files.max(by: { ($0.size ?? 0) < ($1.size ?? 0) })
    }

    private func resolveRealDebrid(
        _ source: OnlineTorrentSource,
        onProgress: @escaping OnlinePlaybackProgressHandler
    ) async throws -> ResolvedOnlinePlayback {
        let client = RealDebridClient(apiKey: RealDebridKeyStore.key)
        let resolved = try await client.resolve(
            magnet: source.magnet,
            requestedSeason: source.requestedSeason,
            requestedEpisode: source.requestedEpisode,
            onProgress: onProgress
        )
        return ResolvedOnlinePlayback(
            url: resolved.url, title: resolved.fileName ?? source.name,
            provider: Provider.realDebrid.rawValue, headers: nil,
            requiredDownload: resolved.requiredDownload
        )
    }

    private func resolveOffcloud(_ source: OnlineTorrentSource) async throws -> ResolvedOnlinePlayback {
        let client = OffcloudClient(apiKey: OffcloudKeyStore.load())
        if let cached = try await client.cachedFilesIfAvailable(for: source.magnet) {
            let cachedVideos = cached.filter(\.isVideo)
            if let file = selectedOffcloudFile(from: cachedVideos, source: source),
               let url = file.streamURL {
                return ResolvedOnlinePlayback(
                    url: url, title: file.name, provider: Provider.offcloud.rawValue, headers: nil
                )
            }
            if source.requestsSpecificEpisode, !cachedVideos.isEmpty {
                throw OnlineSourceSearchError.provider(
                    "Offcloud cache does not contain the requested episode."
                )
            }
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
                let videoFiles = files.filter(\.isVideo)
                if let file = selectedOffcloudFile(from: videoFiles, source: source),
                   let url = file.streamURL {
                    return ResolvedOnlinePlayback(
                        url: url, title: file.name, provider: Provider.offcloud.rawValue, headers: nil
                    )
                }
                if source.requestsSpecificEpisode, !videoFiles.isEmpty {
                    throw OnlineSourceSearchError.provider(
                        "Offcloud prepared the torrent, but it does not contain the requested episode."
                    )
                }
            }
            try await Task.sleep(nanoseconds: 2_000_000_000)
        }
        throw OnlinePlaybackResolutionError.timedOut(Provider.offcloud.rawValue)
    }

    private func selectedOffcloudFile(
        from files: [OffcloudFile],
        source: OnlineTorrentSource
    ) -> OffcloudFile? {
        if source.requestsSpecificEpisode {
            let matching = files.filter { source.matchesRequestedEpisode(fileName: $0.name) }
            if let file = matching.max(by: { ($0.size ?? 0) < ($1.size ?? 0) }) { return file }
            if files.count == 1,
               !source.hasRecognizableEpisodeTag(fileName: files[0].name) {
                return files[0]
            }
            return nil
        }
        return files.max(by: { ($0.size ?? 0) < ($1.size ?? 0) })
    }
}

private struct RealDebridClient: Sendable {
    private let apiKey: String
    private let baseURL = URL(string: "https://api.real-debrid.com/rest/1.0/")!

    struct Resolved: Sendable {
        let url: URL
        let fileName: String?
        let requiredDownload: Bool
    }

    init(apiKey: String) {
        self.apiKey = apiKey
    }

    func resolve(
        magnet: String,
        requestedSeason: Int?,
        requestedEpisode: Int?,
        onProgress: @escaping OnlinePlaybackProgressHandler
    ) async throws -> Resolved {
        onProgress(.init(provider: "Real-Debrid", phase: .preparing))

        // Reuse an already-downloaded item from the account before adding the
        // same magnet again. Besides being faster, this avoids waiting on a new
        // duplicate while the Real-Debrid website already shows the file ready.
        if let existing = try? await existingDownloadedResolution(
            magnet: magnet,
            requestedSeason: requestedSeason,
            requestedEpisode: requestedEpisode
        ) {
            return existing
        }

        let added: AddedTorrent = try await send(path: "torrents/addMagnet", method: "POST", form: ["magnet": magnet])

        var availableFiles: [TorrentFile] = []
        for _ in 0..<30 {
            let info: TorrentInfo = try await send(path: "torrents/info/\(added.id)", method: "GET")
            try validate(status: info.status)
            availableFiles = info.files ?? []
            if !availableFiles.isEmpty { break }
            try await Task.sleep(nanoseconds: 500_000_000)
        }

        let videoFiles = availableFiles.filter { isVideoFile($0.path) }
        let candidates = videoFiles.isEmpty ? availableFiles : videoFiles
        guard let selectedFile = bestFile(
            in: candidates,
            requestedSeason: requestedSeason,
            requestedEpisode: requestedEpisode
        ) else {
            throw OnlineSourceSearchError.provider(
                "The selected torrent does not contain the requested episode. Choose another source."
            )
        }
        try await sendEmpty(
            path: "torrents/selectFiles/\(added.id)",
            method: "POST",
            form: ["files": String(selectedFile.id)]
        )

        // Cached files become ready almost immediately. Uncached torrents keep
        // preparing in the app-wide transfer task so leaving this screen never
        // cancels their Real-Debrid download.
        var requiredDownload = false
        for _ in 0..<450 {
            let info: TorrentInfo = try await send(path: "torrents/info/\(added.id)", method: "GET")
            try validate(status: info.status)
            let normalizedStatus = info.status.lowercased()
            if normalizedStatus == "queued" || normalizedStatus == "downloading" {
                requiredDownload = true
                onProgress(.init(provider: "Real-Debrid", phase: .downloading))
            }
            if normalizedStatus == "downloaded" {
                guard let resolved = try await downloadedResolution(
                    from: info,
                    requestedSeason: requestedSeason,
                    requestedEpisode: requestedEpisode,
                    requiredDownload: requiredDownload
                ) else {
                    throw OnlineSourceSearchError.provider(
                        "Real-Debrid finished the torrent but did not return the selected video link."
                    )
                }
                return resolved
            }
            try await Task.sleep(nanoseconds: 2_000_000_000)
        }
        throw OnlinePlaybackResolutionError.timedOut("Real-Debrid")
    }

    private func existingDownloadedResolution(
        magnet: String,
        requestedSeason: Int?,
        requestedEpisode: Int?
    ) async throws -> Resolved? {
        guard let requestedHash = infoHash(from: magnet) else { return nil }
        let torrents: [TorrentSummary] = try await send(path: "torrents", method: "GET")
        let matching = torrents.filter {
            $0.status.lowercased() == "downloaded"
                && $0.hash.caseInsensitiveCompare(requestedHash) == .orderedSame
        }

        for torrent in matching {
            let info: TorrentInfo = try await send(path: "torrents/info/\(torrent.id)", method: "GET")
            if let resolved = try await downloadedResolution(
                from: info,
                requestedSeason: requestedSeason,
                requestedEpisode: requestedEpisode,
                requiredDownload: false
            ) {
                return resolved
            }
        }
        return nil
    }

    private func downloadedResolution(
        from info: TorrentInfo,
        requestedSeason: Int?,
        requestedEpisode: Int?,
        requiredDownload: Bool
    ) async throws -> Resolved? {
        let links = info.links ?? []
        let selectedFiles = (info.files ?? []).filter { $0.selected == 1 }
        let selectedVideos = selectedFiles.filter { isVideoFile($0.path) }
        let candidates = selectedVideos.isEmpty ? selectedFiles : selectedVideos
        guard !links.isEmpty,
              let file = bestFile(
                in: candidates,
                requestedSeason: requestedSeason,
                requestedEpisode: requestedEpisode
              ),
              let linkIndex = selectedFiles.firstIndex(where: { $0.id == file.id }),
              links.indices.contains(linkIndex) else {
            return nil
        }

        let result: UnrestrictedLink = try await send(
            path: "unrestrict/link",
            method: "POST",
            form: ["link": links[linkIndex]]
        )
        try validateEpisode(
            fileName: result.filename,
            requestedSeason: requestedSeason,
            requestedEpisode: requestedEpisode
        )
        guard let url = URL(string: result.download) else {
            throw OnlineSourceSearchError.invalidResponse
        }
        return Resolved(
            url: url,
            fileName: result.filename ?? file.path,
            requiredDownload: requiredDownload
        )
    }

    private func validateEpisode(
        fileName: String?,
        requestedSeason: Int?,
        requestedEpisode: Int?
    ) throws {
        guard let requestedSeason,
              let requestedEpisode,
              let fileName else { return }
        let expected = "s\(requestedSeason)e\(requestedEpisode)"
        let fullIdentity = episodeIdentity(in: fileName)
        let episodeOnly = episodeOnlyNumber(in: fileName)
        let hasRecognizableIdentity = fullIdentity != nil || episodeOnly != nil
        let matches = fullIdentity == expected
            || (fullIdentity == nil && episodeOnly == requestedEpisode)
        if hasRecognizableIdentity && !matches {
            throw OnlineSourceSearchError.provider(
                "Real-Debrid returned a different episode than the one selected."
            )
        }
    }

    private func infoHash(from magnet: String) -> String? {
        guard let value = URLComponents(string: magnet)?.queryItems?
            .first(where: { $0.name.caseInsensitiveCompare("xt") == .orderedSame })?.value,
              let hash = value.split(separator: ":").last else { return nil }
        return String(hash).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func validate(status: String) throws {
        if ["magnet_error", "error", "virus", "dead"].contains(status.lowercased()) {
            throw OnlinePlaybackResolutionError.noPlayableFile("Real-Debrid")
        }
    }

    private func bestFile(
        in files: [TorrentFile],
        requestedSeason: Int?,
        requestedEpisode: Int?
    ) -> TorrentFile? {
        if let requestedSeason, let requestedEpisode {
            let identity = "s\(requestedSeason)e\(requestedEpisode)"
            if let matchingEpisode = files.filter({ file in
                episodeIdentity(in: file.path) == identity
                    || (episodeIdentity(in: file.path) == nil
                        && episodeOnlyNumber(in: file.path) == requestedEpisode)
            })
                .max(by: { $0.bytes < $1.bytes }) {
                return matchingEpisode
            }
            // A single-file torrent returned for an episode query is safe even
            // when the release name does not include a conventional SxxExx tag.
            if files.count == 1,
               episodeIdentity(in: files[0].path) == nil,
               episodeOnlyNumber(in: files[0].path) == nil {
                return files[0]
            }
            return nil
        }
        return files.max(by: { $0.bytes < $1.bytes })
    }

    private func episodeIdentity(in value: String) -> String? {
        let patterns = [
            #"(?i)\bS(\d{1,3})[ ._-]*E(\d{1,3})\b"#,
            #"(?i)\b(\d{1,3})x(\d{1,3})\b"#
        ]
        for pattern in patterns {
            guard let expression = try? NSRegularExpression(pattern: pattern),
                  let match = expression.firstMatch(
                    in: value,
                    range: NSRange(value.startIndex..<value.endIndex, in: value)
                  ),
                  let seasonRange = Range(match.range(at: 1), in: value),
                  let episodeRange = Range(match.range(at: 2), in: value),
                  let season = Int(value[seasonRange]),
                  let episode = Int(value[episodeRange]) else { continue }
            return "s\(season)e\(episode)"
        }
        return nil
    }

    private func episodeOnlyNumber(in value: String) -> Int? {
        let pattern = #"(?i)\b(?:E|EP|Episode)[ ._-]?(\d{1,3})\b"#
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(
                in: value,
                range: NSRange(value.startIndex..<value.endIndex, in: value)
              ),
              let episodeRange = Range(match.range(at: 1), in: value) else { return nil }
        return Int(value[episodeRange])
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

    private struct AddedTorrent: Decodable { let id: String }
    private struct TorrentSummary: Decodable {
        let id: String
        let hash: String
        let status: String
    }
    private struct TorrentFile: Decodable { let id: Int; let path: String; let bytes: Int64; let selected: Int }
    private struct TorrentInfo: Decodable {
        let status: String
        let files: [TorrentFile]?
        let links: [String]?
    }
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

    func start(magnet: String) async throws -> DirectTorrentPlayback {
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

        let selectedFile = try preferredVideoFile(session: session, torrentID: torrentID)
        let streamID = lt_start_stream(
            session,
            torrentID,
            selectedFile.index,
            192 * 1_024 * 1_024
        )
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
        return DirectTorrentPlayback(url: url, fileName: selectedFile.name)
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

    private func preferredVideoFile(
        session: lt_session_t,
        torrentID: lt_torrent_id
    ) throws -> (index: Int32, name: String) {
        let fileCount = lt_get_file_count(session, torrentID)
        guard fileCount > 0 else {
            stopCurrent()
            throw OnlinePlaybackResolutionError.noPlayableFile("Direct Torrent")
        }

        var files = Array(repeating: lt_file_info(), count: Int(fileCount))
        let loadedCount = files.withUnsafeMutableBufferPointer { buffer in
            lt_get_files(session, torrentID, buffer.baseAddress, fileCount)
        }
        guard loadedCount > 0,
              let selected = files.prefix(Int(loadedCount))
                .filter({ $0.is_streamable != 0 })
                .max(by: { $0.size < $1.size }) else {
            stopCurrent()
            throw OnlinePlaybackResolutionError.noPlayableFile("Direct Torrent")
        }

        let name = cString(selected.name)
            ?? cString(selected.path)
            ?? "Torrent video"
        return (selected.index, name)
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
