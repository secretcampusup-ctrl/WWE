import Foundation

enum TMDBSettings {
    private static let tokenKey = "tmdb.readAccessToken"
    static var readAccessToken: String {
        get { UserDefaults.standard.string(forKey: tokenKey) ?? "" }
        set { UserDefaults.standard.set(newValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: tokenKey) }
    }
    static var isConfigured: Bool { !readAccessToken.isEmpty }
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

    func details(for rawTitle: String) async -> TMDBTitleDetails? {
        guard TMDBSettings.isConfigured else { return nil }
        let query = Self.searchTitle(from: rawTitle)
        guard !query.isEmpty else { return nil }
        let cacheKey = query.lowercased()
        if let cached = detailsCache[cacheKey] { return cached }
        do {
            let search: SearchResponse = try await request("/3/search/multi", query: ["query": query, "include_adult": "false"])
            guard let match = search.results.first(where: { $0.mediaType == "movie" || $0.mediaType == "tv" }) else { return nil }
            let endpoint = "/3/\(match.mediaType)/\(match.id)"
            let payload: DetailPayload = try await request(endpoint, query: ["append_to_response": "credits,videos"])
            let trailers = payload.videos?.results ?? []
            let trailer = trailers.first { $0.site == "YouTube" && $0.type == "Trailer" && $0.official == true }
                ?? trailers.first { $0.site == "YouTube" && $0.type == "Trailer" }
            let details = TMDBTitleDetails(
                id: match.id,
                mediaType: match.mediaType,
                title: payload.title ?? payload.name ?? match.title ?? match.name ?? query,
                overview: payload.overview ?? "",
                posterPath: payload.posterPath,
                backdropPath: payload.backdropPath,
                releaseDate: payload.releaseDate ?? payload.firstAirDate,
                voteAverage: payload.voteAverage ?? 0,
                genres: payload.genres ?? [],
                cast: Array((payload.credits?.cast ?? []).prefix(20)),
                seasons: (payload.seasons ?? []).filter { $0.seasonNumber > 0 },
                trailerKey: trailer?.key
            )
            detailsCache[cacheKey] = details
            return details
        } catch {
            return nil
        }
    }

    static func searchTitle(from rawTitle: String) -> String {
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
        parts.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        var request = URLRequest(url: parts.url!)
        request.setValue("Bearer \(TMDBSettings.readAccessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await HighPriorityNetworkManager.shared.responsiveData(for: request)
        guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else { throw URLError(.badServerResponse) }
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
