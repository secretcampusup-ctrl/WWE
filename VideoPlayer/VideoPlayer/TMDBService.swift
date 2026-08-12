import Foundation

enum TMDBSettings {
    private static let tokenKey = "tmdb.readAccessToken"
    static var readAccessToken: String {
        get {
            if let stored = SecureCredentialStore.string(for: AppCredentialKeys.tmdb) { return stored }
            // One-time migration from older builds.
            guard let legacy = UserDefaults.standard.string(forKey: tokenKey), !legacy.isEmpty else { return "" }
            let value = normalize(legacy)
            if SecureCredentialStore.set(value, for: AppCredentialKeys.tmdb) {
                UserDefaults.standard.removeObject(forKey: tokenKey)
            }
            return value
        }
        set {
            let value = normalize(newValue)
            if SecureCredentialStore.set(value, for: AppCredentialKeys.tmdb) {
                UserDefaults.standard.removeObject(forKey: tokenKey)
            }
        }
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

struct TMDBTitleDetails: Identifiable, Codable {
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
    let runtimeMinutes: Int?
    let productionCountries: [String]?
    let certification: String?
    let director: TMDBCrewMember?
    let logoPath: String?

    var isSeries: Bool { mediaType == "tv" }
    var posterURL: URL? {
        guard let posterPath else { return nil }
        return URL(string: "https://image.tmdb.org/t/p/w342\(posterPath)")
    }

    var imageURL: URL? {
        guard let path = backdropPath ?? posterPath else { return nil }
        return URL(string: "https://image.tmdb.org/t/p/w1280\(path)")
    }
    var logoURL: URL? {
        guard let logoPath else { return nil }
        return URL(string: "https://image.tmdb.org/t/p/w500\(logoPath)")
    }
}

struct TMDBGenre: Codable, Identifiable { let id: Int; let name: String }
struct TMDBCastMember: Codable, Identifiable {
    let id: Int
    let name: String
    let character: String
    let profilePath: String?
    var imageURL: URL? { profilePath.flatMap { URL(string: "https://image.tmdb.org/t/p/w342\($0)") } }
}
struct TMDBCrewMember: Codable, Identifiable {
    let id: Int
    let name: String
    let job: String
    let profilePath: String?
    var imageURL: URL? { profilePath.flatMap { URL(string: "https://image.tmdb.org/t/p/w342\($0)") } }
}
struct TMDBSeason: Codable, Identifiable {
    let id: Int
    let name: String
    let seasonNumber: Int
    let episodeCount: Int
    let posterPath: String?
}


struct TMDBEpisodeDetails: Codable {
    let name: String
    let overview: String
    let stillPath: String?
    var imageURL: URL? { stillPath.flatMap { URL(string: "https://image.tmdb.org/t/p/w780\($0)") } }
}
actor TMDBService {
    static let shared = TMDBService()
    private var detailsCache: [String: TMDBTitleDetails]
    private var episodeCache: [String: TMDBEpisodeDetails]
    private let cacheURL: URL
    private let decoder: JSONDecoder = {
        let value = JSONDecoder()
        value.keyDecodingStrategy = .convertFromSnakeCase
        return value
    }()

    init() {
        let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TMDBMetadata", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        cacheURL = directory.appendingPathComponent("metadata-v4.json")
        if let data = try? Data(contentsOf: cacheURL),
           let payload = try? JSONDecoder().decode(TMDBPersistentCache.self, from: data) {
            detailsCache = payload.details
            episodeCache = payload.episodes
        } else {
            detailsCache = [:]
            episodeCache = [:]
        }
    }

    private func persistCache() {
        let payload = TMDBPersistentCache(details: detailsCache, episodes: episodeCache)
        guard let data = try? JSONEncoder().encode(payload) else { return }
        try? data.write(to: cacheURL, options: .atomic)
    }

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
        let preferred = VideoTitleFormatter.episodeComponents(from: rawTitle) == nil ? nil : "tv"
        return await detailsForQuery(Self.searchTitle(from: rawTitle), preferredMediaType: preferred)
    }

    func detailsOriginalFirst(for rawTitle: String, preferredMediaType: String? = nil) async -> TMDBTitleDetails? {
        guard TMDBSettings.isConfigured else { return nil }
        let original = Self.originalSearchTitle(from: rawTitle)
        let filtered = Self.searchTitle(from: rawTitle)
        var attempted = Set<String>()
        for query in [original, filtered] where !query.isEmpty {
            let key = query.lowercased()
            guard attempted.insert(key).inserted else { continue }
            if let result = await detailsForQuery(query, preferredMediaType: preferredMediaType) { return result }
        }
        return nil
    }

    /// Cache-only lookup used during app launch. It never performs a network request.
    func cachedDetailsOriginalFirst(for rawTitle: String, preferredMediaType: String? = nil) -> TMDBTitleDetails? {
        let original = Self.originalSearchTitle(from: rawTitle)
        let filtered = Self.searchTitle(from: rawTitle)
        var attempted = Set<String>()
        for query in [original, filtered] where !query.isEmpty {
            let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines)
            guard attempted.insert(normalized.lowercased()).inserted else { continue }
            let key = normalized.lowercased() + "|" + (preferredMediaType ?? "any")
            if let cached = detailsCache[key] { return cached }
        }
        return nil
    }

    private func detailsForQuery(_ query: String, preferredMediaType: String? = nil) async -> TMDBTitleDetails? {
        guard TMDBSettings.isConfigured else { return nil }
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedQuery.isEmpty else { return nil }
        let cacheKey = normalizedQuery.lowercased() + "|" + (preferredMediaType ?? "any")
        if let cached = detailsCache[cacheKey] { return cached }
        let candidates = await searchCandidates(for: normalizedQuery)
        guard let match = Self.bestMatch(in: candidates, query: normalizedQuery, preferredMediaType: preferredMediaType) else { return nil }
        do {
            let endpoint = "/3/\(match.mediaType)/\(match.id)"
            let payload: DetailPayload = try await request(endpoint, query: [
                "append_to_response": "credits,videos,release_dates,images",
                "include_image_language": "en,null"
            ])
            let trailers = payload.videos?.results ?? []
            let trailer = trailers.first { $0.site == "YouTube" && $0.type == "Trailer" && $0.official == true }
                ?? trailers.first { $0.site == "YouTube" && $0.type == "Trailer" }
            let certification = payload.releaseDates?.results
                .first(where: { $0.iso31661 == "US" })?.releaseDates
                .first(where: { !$0.certification.isEmpty })?.certification
                ?? payload.releaseDates?.results.flatMap(\.releaseDates)
                    .first(where: { !$0.certification.isEmpty })?.certification
            let details = TMDBTitleDetails(
                id: match.id, mediaType: match.mediaType,
                title: payload.title ?? payload.name ?? match.title ?? match.name ?? normalizedQuery,
                overview: payload.overview ?? "", posterPath: payload.posterPath,
                backdropPath: payload.backdropPath, releaseDate: payload.releaseDate ?? payload.firstAirDate,
                voteAverage: payload.voteAverage ?? 0, genres: payload.genres ?? [],
                cast: Array((payload.credits?.cast ?? []).prefix(20)),
                seasons: (payload.seasons ?? []).filter { $0.seasonNumber > 0 }, trailerKey: trailer?.key,
                runtimeMinutes: payload.runtime,
                productionCountries: payload.productionCountries?.map(\.name),
                certification: certification,
                director: payload.credits?.crew.first(where: { $0.job == "Director" }),
                logoPath: payload.images?.logos.first(where: { $0.iso6391 == "en" })?.filePath
                    ?? payload.images?.logos.first?.filePath
            )
            detailsCache[cacheKey] = details
            persistCache()
            return details
        } catch { return nil }
    }

    private func searchCandidates(for rawQuery: String) async -> [SearchResult] {
        var values: [SearchResult] = []

        // Multi-search is fastest when TMDB accepts the release-style query.
        if let response: SearchResponse = try? await request(
            "/3/search/multi",
            query: ["query": rawQuery, "include_adult": "false"]
        ) {
            values.append(contentsOf: response.results.filter { $0.mediaType == "movie" || $0.mediaType == "tv" })
        }

        // Dedicated movie/TV searches are the reliable fallback. They receive a
        // clean title and the year separately, which resolves filenames such as
        // `Gran Torino - 2008.mkv` and `Sinners (2025) (2160p...).mkv`.
        let parsed = Self.canonicalTitleAndYear(from: rawQuery)
        guard !parsed.title.isEmpty else { return values }
        var movieQuery = ["query": parsed.title, "include_adult": "false"]
        var tvQuery = ["query": parsed.title, "include_adult": "false"]
        if let year = parsed.year {
            movieQuery["year"] = year
            tvQuery["first_air_date_year"] = year
        }
        if let response: TypedTitleSearchResponse = try? await request("/3/search/movie", query: movieQuery) {
            values.append(contentsOf: response.results.map {
                SearchResult(id: $0.id, mediaType: "movie", title: $0.title, name: $0.name)
            })
        }
        if let response: TypedTitleSearchResponse = try? await request("/3/search/tv", query: tvQuery) {
            values.append(contentsOf: response.results.map {
                SearchResult(id: $0.id, mediaType: "tv", title: $0.title, name: $0.name)
            })
        }
        var seen = Set<String>()
        return values.filter { seen.insert("\($0.mediaType)|\($0.id)").inserted }
    }

    private static func canonicalTitleAndYear(from raw: String) -> (title: String, year: String?) {
        var value = searchTitle(from: raw)
        let yearPattern = #"(?<!\d)((?:19|20)\d{2})(?!\d)"#
        var year: String?
        if let regex = try? NSRegularExpression(pattern: yearPattern),
           let match = regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)),
           let range = Range(match.range(at: 1), in: value) {
            year = String(value[range])
            value.removeSubrange(range)
        }
        value = value.replacingOccurrences(of: #"[\[\](){}._-]+"#, with: " ", options: .regularExpression)
        value = value.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (value, year)
    }

    private static func originalSearchTitle(from rawTitle: String) -> String {
        var value = rawTitle.removingPercentEncoding ?? rawTitle
        value = (value as NSString).deletingPathExtension
        value = value.replacingOccurrences(of: ".", with: " ").replacingOccurrences(of: "_", with: " ")
        return value.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func bestMatch(in results: [SearchResult], query: String, preferredMediaType: String?) -> SearchResult? {
        guard !results.isEmpty else { return nil }
        let preferredResults: [SearchResult]
        if let preferredMediaType {
            let matches = results.filter { $0.mediaType == preferredMediaType }
            preferredResults = matches.isEmpty ? results : matches
        } else {
            preferredResults = results
        }
        let queryTokens = titleTokens(searchTitle(from: query))
        guard !queryTokens.isEmpty else { return nil }
        let ranked = preferredResults.map { result -> (SearchResult, Double) in
            let title = result.title ?? result.name ?? ""
            let resultTokens = titleTokens(title)
            let overlap = queryTokens.intersection(resultTokens).count
            let denominator = max(1, min(queryTokens.count, resultTokens.count))
            return (result, Double(overlap) / Double(denominator))
        }.sorted { $0.1 > $1.1 }
        guard let best = ranked.first, best.1 >= 0.34 else { return nil }
        return best.0
    }

    private static func titleTokens(_ value: String) -> Set<String> {
        let stop: Set<String> = ["the", "a", "an", "and", "of", "in", "to", "movie", "season", "complete"]
        let words = value.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted)
        return Set(words.filter { $0.count > 1 && !stop.contains($0) && Int($0) == nil })
    }
    // Temporarily disabled for metadata matching tests. Keep the full filter
    // implementation below so it can be restored by flipping this flag only.
    private static let releaseKeywordFilteringEnabled = true

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
        let cacheKey = "\(series.id)|s\(season)|e\(episode)"
        if let cached = episodeCache[cacheKey] { return cached }
        do {
            let payload: EpisodePayload = try await request("/3/tv/\(series.id)/season/\(season)/episode/\(episode)", query: [:])
            let details = TMDBEpisodeDetails(name: payload.name ?? "Episode \(episode)", overview: payload.overview ?? "", stillPath: payload.stillPath)
            episodeCache[cacheKey] = details
            persistCache()
            return details
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
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw TMDBRequestError(message: "TMDB returned no HTTP response.") }
        guard 200..<300 ~= http.statusCode else {
            let payload = try? decoder.decode(TMDBErrorPayload.self, from: data)
            throw TMDBRequestError(message: payload?.statusMessage ?? "TMDB request failed (HTTP \(http.statusCode)).")
        }
        return try decoder.decode(T.self, from: data)
    }
}

private struct TMDBPersistentCache: Codable {
    let details: [String: TMDBTitleDetails]
    let episodes: [String: TMDBEpisodeDetails]
}

private struct SearchResponse: Decodable { let results: [SearchResult] }
private struct TypedTitleSearchResponse: Decodable { let results: [TypedTitleSearchResult] }
private struct TypedTitleSearchResult: Decodable {
    let id: Int
    let title: String?
    let name: String?
}

private struct SearchResult: Decodable {
    let id: Int; let mediaType: String; let title: String?; let name: String?
}
private struct DetailPayload: Decodable {
    let title: String?; let name: String?; let overview: String?
    let posterPath: String?; let backdropPath: String?
    let releaseDate: String?; let firstAirDate: String?; let voteAverage: Double?; let runtime: Int?
    let genres: [TMDBGenre]?; let seasons: [TMDBSeason]?
    let credits: Credits?; let videos: Videos?; let productionCountries: [ProductionCountry]?
    let releaseDates: ReleaseDatesResponse?; let images: TMDBImagesPayload?
}
private struct Credits: Decodable { let cast: [TMDBCastMember]; let crew: [TMDBCrewMember] }
private struct ProductionCountry: Decodable { let name: String }
private struct ReleaseDatesResponse: Decodable { let results: [ReleaseDatesCountry] }
private struct ReleaseDatesCountry: Decodable { let iso31661: String; let releaseDates: [ReleaseDateEntry] }
private struct ReleaseDateEntry: Decodable { let certification: String }
private struct TMDBImagesPayload: Decodable { let logos: [TMDBLogoPayload] }
private struct TMDBLogoPayload: Decodable { let filePath: String; let iso6391: String? }
private struct Videos: Decodable { let results: [Video] }
private struct Video: Decodable { let key: String; let site: String; let type: String; let official: Bool? }

private struct EpisodePayload: Decodable { let name: String?; let overview: String?; let stillPath: String? }


private struct AuthenticationPayload: Decodable { let success: Bool }
private struct TMDBErrorPayload: Decodable { let statusMessage: String? }
private struct TMDBRequestError: Error { let message: String }
