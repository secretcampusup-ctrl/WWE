import Foundation

enum TMDBSettings {
    private static let tokenKey = "tmdb.readAccessToken"
    static var readAccessToken: String {
        get { UserDefaults.standard.string(forKey: tokenKey) ?? "" }
        set { UserDefaults.standard.set(normalize(newValue), forKey: tokenKey) }
    }
    static var isConfigured: Bool { !readAccessToken.isEmpty }

    /// Accept pasted v4 Read Access Tokens, values prefixed with "Bearer", and
    /// legacy 32-character v3 API keys. Also removes invisible/punctuation
    /// characters commonly copied with the credential on iOS.
    static func normalize(_ raw: String) -> String {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.lowercased().hasPrefix("bearer ") { value = String(value.dropFirst(7)) }
        value = value.trimmingCharacters(in: CharacterSet(charactersIn: " \t\r\n\"'؟?،,;"))
        return value.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) }.map(String.init).joined()
    }

    static var usesV3APIKey: Bool {
        let value = readAccessToken
        return value.count == 32 && value.allSatisfy { $0.isHexDigit }
    }
}

struct TMDBTitleDetails: Identifiable, Decodable {
    let id: Int
    let mediaType: String
    let title: String
    let overview: String
    let posterPath: String?
    let backdropPath: String?
    let releaseDate: String?
    let voteAverage: Double
    let genres: [TMDBGenre]
    let cast: [TMDBCastMember]
    let seasons: [TMDBSeason]
    let trailerKey: String?

    var isSeries: Bool { mediaType == "tv" }
    var posterURL: URL? {
        guard let posterPath else { return nil }
        return URL(string: "https://image.tmdb.org/t/p/w342\(posterPath)")
    }

    var imageURL: URL? {
        guard let path = backdropPath ?? posterPath else { return nil }
        return URL(string: "https://image.tmdb.org/t/p/w1280\(path)")
    }
}

struct TMDBGenre: Decodable, Identifiable { let id: Int; let name: String }
struct TMDBCastMember: Decodable, Identifiable {
    let id: Int
    let name: String
    let character: String
    let profilePath: String?
    var imageURL: URL? { profilePath.flatMap { URL(string: "https://image.tmdb.org/t/p/w342\($0)") } }
}
struct TMDBSeason: Decodable, Identifiable {
    let id: Int
    let name: String
    let seasonNumber: Int
    let episodeCount: Int
    let posterPath: String?
}


struct TMDBEpisodeDetails {
    let name: String
    let overview: String
    let stillPath: String?
    var imageURL: URL? { stillPath.flatMap { URL(string: "https://image.tmdb.org/t/p/w780\($0)") } }
}
actor TMDBService {
    static let shared = TMDBService()
    private var detailsCache: [String: TMDBTitleDetails] = [:]
    private let decoder: JSONDecoder = {
        let value = JSONDecoder()
        value.keyDecodingStrategy = .convertFromSnakeCase
        return value
    }()

    /// Returns nil on success, otherwise a precise user-facing TMDB error.
    func testConnection() async -> String? {
        guard TMDBSettings.isConfigured else { return "Enter a TMDB Read Access Token or API key." }
        do {
            let _: AuthenticationPayload = try await request("/3/authentication", query: [:])
            return nil
        } catch let error as TMDBRequestError {
            return error.message
        } catch {
            return "Connection failed: \(error.localizedDescription)"
        }
    }

    func details(for rawTitle: String) async -> TMDBTitleDetails? {
        await detailsForQuery(Self.searchTitle(from: rawTitle))
    }

    func detailsOriginalFirst(for rawTitle: String) async -> TMDBTitleDetails? {
        guard TMDBSettings.isConfigured else { return nil }
        let original = Self.originalSearchTitle(from: rawTitle)
        let filtered = Self.searchTitle(from: rawTitle)
        var attempted = Set<String>()
        for query in [original, filtered] where !query.isEmpty {
            let key = query.lowercased()
            guard attempted.insert(key).inserted else { continue }
            if let result = await detailsForQuery(query) { return result }
        }
        return nil
    }

    private func detailsForQuery(_ query: String) async -> TMDBTitleDetails? {
        guard TMDBSettings.isConfigured else { return nil }
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedQuery.isEmpty else { return nil }
        let cacheKey = normalizedQuery.lowercased()
        if let cached = detailsCache[cacheKey] { return cached }
        do {
            let search: SearchResponse = try await request("/3/search/multi", query: ["query": normalizedQuery, "include_adult": "false"])
            let candidates = search.results.filter { $0.mediaType == "movie" || $0.mediaType == "tv" }
            guard let match = Self.bestMatch(in: candidates, query: normalizedQuery) else { return nil }
            let endpoint = "/3/\(match.mediaType)/\(match.id)"
            let payload: DetailPayload = try await request(endpoint, query: ["append_to_response": "credits,videos"])
            let trailers = payload.videos?.results ?? []
            let trailer = trailers.first { $0.site == "YouTube" && $0.type == "Trailer" && $0.official == true }
                ?? trailers.first { $0.site == "YouTube" && $0.type == "Trailer" }
            let details = TMDBTitleDetails(
                id: match.id, mediaType: match.mediaType,
                title: payload.title ?? payload.name ?? match.title ?? match.name ?? normalizedQuery,
                overview: payload.overview ?? "", posterPath: payload.posterPath,
                backdropPath: payload.backdropPath, releaseDate: payload.releaseDate ?? payload.firstAirDate,
                voteAverage: payload.voteAverage ?? 0, genres: payload.genres ?? [],
                cast: Array((payload.credits?.cast ?? []).prefix(20)),
                seasons: (payload.seasons ?? []).filter { $0.seasonNumber > 0 }, trailerKey: trailer?.key
            )
            detailsCache[cacheKey] = details
            return details
        } catch { return nil }
    }

    private static func originalSearchTitle(from rawTitle: String) -> String {
        var value = rawTitle.removingPercentEncoding ?? rawTitle
        value = (value as NSString).deletingPathExtension
        value = value.replacingOccurrences(of: ".", with: " ").replacingOccurrences(of: "_", with: " ")
        return value.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func bestMatch(in results: [SearchResult], query: String) -> SearchResult? {
        guard !results.isEmpty else { return nil }
        let queryTokens = titleTokens(searchTitle(from: query))
        guard !queryTokens.isEmpty else { return nil }
        let ranked = results.map { result -> (SearchResult, Double) in
            let title = result.title ?? result.name ?? ""
            let resultTokens = titleTokens(title)
            let overlap = queryTokens.intersection(resultTokens).count
            let denominator = max(1, min(queryTokens.count, resultTokens.count))
            return (result, Double(overlap) / Double(denominator))
        }.sorted { $0.1 > $1.1 }
        guard let best = ranked.first, best.1 >= 0.45 else { return nil }
        return best.0
    }

    private static func titleTokens(_ value: String) -> Set<String> {
        let stop: Set<String> = ["the", "a", "an", "and", "of", "in", "to", "movie", "season", "complete"]
        let words = value.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted)
        return Set(words.filter { $0.count > 1 && !stop.contains($0) && Int($0) == nil })
    }
    // Temporarily disabled for metadata matching tests. Keep the full filter
    // implementation below so it can be restored by flipping this flag only.
    private static let releaseKeywordFilteringEnabled = false

    static func searchTitle(from rawTitle: String) -> String {
        if !releaseKeywordFilteringEnabled {
            return originalSearchTitle(from: rawTitle)
        }
        var value = (rawTitle.removingPercentEncoding ?? rawTitle)
            .replacingOccurrences(of: ".", with: " ")
            .replacingOccurrences(of: "_", with: " ")
        value = value.replacingOccurrences(
            of: #"(?i)\b(?:Season\s*\d{1,3}|S\d{1,3}(?:\s*E\d{1,3})?|COMPLETE|4320p|2160p|1440p|1080p|720p|480p|8K|4K|UHD|FHD|HDR|DV|HDTV|WEB[ -]?DL|WEBRIP|BLURAY|REMUX|x264|x265|H264|H265|HEVC)\b.*$"#,
            with: "",
            options: .regularExpression
        )
        value = value.replacingOccurrences(of: #"(?i)\b(?:MP4|MKV|AVI|MOV)\b.*$"#, with: "", options: .regularExpression)
        value = value.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? VideoTitleFormatter.title(from: rawTitle) : value
    }
    func episodeDetails(seriesTitle: String, season: Int, episode: Int) async -> TMDBEpisodeDetails? {
        guard let series = await details(for: seriesTitle), series.isSeries else { return nil }
        do {
            let payload: EpisodePayload = try await request("/3/tv/\(series.id)/season/\(season)/episode/\(episode)", query: [:])
            return TMDBEpisodeDetails(name: payload.name ?? "Episode \(episode)", overview: payload.overview ?? "", stillPath: payload.stillPath)
        } catch { return nil }
    }
    private func request<T: Decodable>(_ path: String, query: [String: String]) async throws -> T {
        var parts = URLComponents(string: "https://api.themoviedb.org\(path)")!
        var requestQuery = query
        if TMDBSettings.usesV3APIKey { requestQuery["api_key"] = TMDBSettings.readAccessToken }
        parts.queryItems = requestQuery.map { URLQueryItem(name: $0.key, value: $0.value) }
        var request = URLRequest(url: parts.url!)
        if !TMDBSettings.usesV3APIKey {
            request.setValue("Bearer \(TMDBSettings.readAccessToken)", forHTTPHeaderField: "Authorization")
        }
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 25
        let (data, response) = try await HighPriorityNetworkManager.shared.responsiveData(for: request)
        guard let http = response as? HTTPURLResponse else { throw TMDBRequestError(message: "TMDB returned no HTTP response.") }
        guard 200..<300 ~= http.statusCode else {
            let payload = try? decoder.decode(TMDBErrorPayload.self, from: data)
            throw TMDBRequestError(message: payload?.statusMessage ?? "TMDB request failed (HTTP \(http.statusCode)).")
        }
        return try decoder.decode(T.self, from: data)
    }
}

private struct SearchResponse: Decodable { let results: [SearchResult] }
private struct SearchResult: Decodable {
    let id: Int; let mediaType: String; let title: String?; let name: String?
}
private struct DetailPayload: Decodable {
    let title: String?; let name: String?; let overview: String?
    let posterPath: String?; let backdropPath: String?
    let releaseDate: String?; let firstAirDate: String?; let voteAverage: Double?
    let genres: [TMDBGenre]?; let seasons: [TMDBSeason]?
    let credits: Credits?; let videos: Videos?
}
private struct Credits: Decodable { let cast: [TMDBCastMember] }
private struct Videos: Decodable { let results: [Video] }
private struct Video: Decodable { let key: String; let site: String; let type: String; let official: Bool? }

private struct EpisodePayload: Decodable { let name: String?; let overview: String?; let stillPath: String? }


private struct AuthenticationPayload: Decodable { let success: Bool }
private struct TMDBErrorPayload: Decodable { let statusMessage: String? }
private struct TMDBRequestError: Error { let message: String }
