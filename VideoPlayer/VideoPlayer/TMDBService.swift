import Foundation

enum TMDBSettings {
    private static let bundledReadAccessToken = "eyJhbGciOiJIUzI1NiJ9.eyJhdWQiOiI2M2E3NDZkM2FjZTJlZjVhNDM4Y2FiNjE5N2FkYTVmNCIsIm5iZiI6MTU1NDUzMzM4MC42MTc5OTk4LCJzdWIiOiI1Y2E4NGMwNDkyNTE0MTU2NjJmZDVhZjYiLCJzY29wZXMiOlsiYXBpX3JlYWQiXSwidmVyc2lvbiI6MX0.HgIosk-aOvM9xzyiL0WVCmAK3p5p47Ym4cqnU-qlBRE"
    static var readAccessToken: String {
        get { bundledReadAccessToken }
        set { }
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
    let imdbID: String?
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
    let noLanguageBackdropPath: String?
    let noLanguagePosterPath: String?
    let detailsPosterPath: String?

    var isSeries: Bool { mediaType == "tv" }
    var posterURL: URL? {
        guard let posterPath else { return nil }
        return URL(string: "https://image.tmdb.org/t/p/w342\(posterPath)")
    }

    var imageURL: URL? {
        guard let path = backdropPath ?? posterPath else { return nil }
        return URL(string: "https://image.tmdb.org/t/p/w1280\(path)")
    }
    var detailsBackdropURL: URL? {
        guard let path = noLanguageBackdropPath ?? backdropPath else { return nil }
        // w1280 covers a 3x iPhone width. `/original` backdrops are often 4–10 MB.
        return URL(string: "https://image.tmdb.org/t/p/w1280\(path)")
    }
    var compactBackdropURL: URL? {
        guard let path = noLanguageBackdropPath ?? backdropPath ?? posterPath else { return nil }
        return URL(string: "https://image.tmdb.org/t/p/w780\(path)")
    }
    var detailsPosterURL: URL? {
        // `noLanguagePosterPath` only exists after a full title-details fetch
        // (Details screen). Falling back to `detailsPosterPath` lets list/grid
        // posters (Home sections) render instantly from data already returned
        // by the discover/list feed, instead of blocking on a heavy per-title
        // details request just to resolve a poster URL.
        guard let path = noLanguagePosterPath ?? detailsPosterPath else { return nil }
        return URL(string: "https://image.tmdb.org/t/p/w780\(path)")
    }
    var heroPosterURL: URL? {
        // Prefer language-free poster, then the standard details poster.
        // `/original` keeps Hero sharp; PersistentHeroArtwork still downsamples
        // to screen size so scrolling stays smooth.
        guard let path = noLanguagePosterPath ?? detailsPosterPath ?? posterPath else { return nil }
        return URL(string: "https://image.tmdb.org/t/p/original\(path)")
    }
    var logoURL: URL? {
        guard let logoPath else { return nil }
        // Hero title logos benefit from the sharpest TMDB render available.
        return URL(string: "https://image.tmdb.org/t/p/original\(logoPath)")
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
    /// Episode cards are ~160pt on phone — w300 is sharp enough and far faster
    /// than w780 which was overkill for these thumbnails.
    var imageURL: URL? { stillPath.flatMap { URL(string: "https://image.tmdb.org/t/p/w300\($0)") } }
}
actor TMDBService {
    static let shared = TMDBService()
    private var detailsCache: [String: TMDBTitleDetails]
    private var episodeCache: [String: TMDBEpisodeDetails]
    private var completedSeasonCache: Set<String>
    private let cacheURL: URL
    private let decoder: JSONDecoder = {
        let value = JSONDecoder()
        value.keyDecodingStrategy = .convertFromSnakeCase
        return value
    }()

    init() {
        let fileManager = FileManager.default
        let directory = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PersistentMetadata/TMDB", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var resourceValues = URLResourceValues()
        resourceValues.isExcludedFromBackup = true
        var mutableDirectory = directory
        try? mutableDirectory.setResourceValues(resourceValues)
        cacheURL = directory.appendingPathComponent("metadata-v6.json")

        // Versions before persistent metadata stored this file in Library/Caches,
        // which iOS is allowed to purge at any time. Migrate it once so an update
        // does not throw away metadata the user already downloaded.
        let legacyURL = fileManager.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TMDBMetadata/metadata-v6.json")
        if !fileManager.fileExists(atPath: cacheURL.path),
           fileManager.fileExists(atPath: legacyURL.path) {
            try? fileManager.copyItem(at: legacyURL, to: cacheURL)
        }
        if let data = try? Data(contentsOf: cacheURL),
           let payload = try? JSONDecoder().decode(TMDBPersistentCache.self, from: data) {
            detailsCache = payload.details
            episodeCache = payload.episodes
            completedSeasonCache = payload.completedSeasons ?? []
        } else {
            detailsCache = [:]
            episodeCache = [:]
            completedSeasonCache = []
        }
    }

    private func persistCache() {
        let payload = TMDBPersistentCache(
            details: detailsCache,
            episodes: episodeCache,
            completedSeasons: completedSeasonCache
        )
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
        let canonical = Self.canonicalTitleAndYear(from: filtered).title
        var attempted = Set<String>()
        // Release names are often rejected when they still contain group/audio
        // tags. Try the clean query first, then title-only, and keep the raw
        // filename solely as a last resort for genuinely unusual movie names.
        for query in [filtered, canonical, original] where !query.isEmpty {
            let key = query.lowercased()
            guard attempted.insert(key).inserted else { continue }
            if let result = await detailsForQuery(query, preferredMediaType: preferredMediaType) { return result }
        }
        return nil
    }

    /// Fast path for Home / Media library scans.
    /// Multi-search for identity + poster, then one light details hit for
    /// genres (Home Genres section). Cast / logos still load on Details open.
    func libraryQuickDetails(for rawTitle: String, preferredMediaType: String? = nil) async -> TMDBTitleDetails? {
        guard TMDBSettings.isConfigured else { return nil }
        if let cached = cachedDetailsOriginalFirst(for: rawTitle, preferredMediaType: preferredMediaType),
           !cached.genres.isEmpty {
            return cached
        }
        let filtered = Self.searchTitle(from: rawTitle)
        let canonical = Self.canonicalTitleAndYear(from: filtered)
        let query = canonical.title.isEmpty ? filtered : canonical.title
        guard !query.isEmpty else { return nil }

        var candidates = await quickSearchCandidates(for: query, year: canonical.year)
        if candidates.isEmpty, query != filtered, !filtered.isEmpty {
            candidates = await quickSearchCandidates(for: filtered, year: canonical.year)
        }
        guard let match = Self.bestMatch(in: candidates, query: query, preferredMediaType: preferredMediaType)
                ?? candidates.first else { return nil }

        // Light details (no credits/images append) → genres for Home sections.
        if let rich = await lightTitleDetails(
            mediaType: match.mediaType,
            tmdbID: match.id,
            fallbackTitle: match.title ?? match.name ?? query,
            fallbackPoster: match.posterPath,
            fallbackBackdrop: match.backdropPath,
            fallbackOverview: match.overview,
            fallbackRelease: match.releaseDate ?? match.firstAirDate,
            fallbackVote: match.voteAverage
        ) {
            let base = query.lowercased()
            detailsCache[base + "|" + (preferredMediaType ?? "any")] = rich
            detailsCache[base + "|" + match.mediaType] = rich
            detailsCache[base + "|any"] = rich
            detailsCache["tmdb|\(match.mediaType)|\(match.id)"] = rich
            persistCache()
            return rich
        }

        let title = match.title ?? match.name ?? query
        let details = TMDBTitleDetails(
            id: match.id,
            mediaType: match.mediaType,
            imdbID: nil,
            title: title,
            overview: match.overview ?? "",
            posterPath: match.posterPath,
            backdropPath: match.backdropPath,
            releaseDate: match.releaseDate ?? match.firstAirDate,
            voteAverage: match.voteAverage ?? 0,
            genres: [],
            cast: [],
            seasons: [],
            trailerKey: nil,
            runtimeMinutes: nil,
            productionCountries: nil,
            certification: nil,
            director: nil,
            logoPath: nil,
            noLanguageBackdropPath: match.backdropPath,
            noLanguagePosterPath: match.posterPath,
            detailsPosterPath: match.posterPath
        )
        let base = query.lowercased()
        detailsCache[base + "|" + (preferredMediaType ?? "any")] = details
        detailsCache[base + "|" + match.mediaType] = details
        detailsCache[base + "|any"] = details
        detailsCache["tmdb|\(match.mediaType)|\(match.id)"] = details
        persistCache()
        return details
    }

    /// Basic title payload without credits/videos/images — enough for genres,
    /// rating, and release date used by Home category rows.
    private func lightTitleDetails(
        mediaType: String,
        tmdbID: Int,
        fallbackTitle: String,
        fallbackPoster: String?,
        fallbackBackdrop: String?,
        fallbackOverview: String?,
        fallbackRelease: String?,
        fallbackVote: Double?
    ) async -> TMDBTitleDetails? {
        guard mediaType == "movie" || mediaType == "tv" else { return nil }
        struct LightPayload: Decodable {
            let title: String?
            let name: String?
            let overview: String?
            let posterPath: String?
            let backdropPath: String?
            let releaseDate: String?
            let firstAirDate: String?
            let voteAverage: Double?
            let genres: [TMDBGenre]?
            let runtime: Int?
            let productionCountries: [ProductionCountry]?
        }
        guard let payload: LightPayload = try? await request("/3/\(mediaType)/\(tmdbID)", query: [:]) else {
            return nil
        }
        return TMDBTitleDetails(
            id: tmdbID,
            mediaType: mediaType,
            imdbID: nil,
            title: payload.title ?? payload.name ?? fallbackTitle,
            overview: payload.overview ?? fallbackOverview ?? "",
            posterPath: payload.posterPath ?? fallbackPoster,
            backdropPath: payload.backdropPath ?? fallbackBackdrop,
            releaseDate: payload.releaseDate ?? payload.firstAirDate ?? fallbackRelease,
            voteAverage: payload.voteAverage ?? fallbackVote ?? 0,
            genres: payload.genres ?? [],
            cast: [],
            seasons: [],
            trailerKey: nil,
            runtimeMinutes: payload.runtime,
            productionCountries: payload.productionCountries?.map(\.name),
            certification: nil,
            director: nil,
            logoPath: nil,
            noLanguageBackdropPath: payload.backdropPath ?? fallbackBackdrop,
            noLanguagePosterPath: payload.posterPath ?? fallbackPoster,
            detailsPosterPath: payload.posterPath ?? fallbackPoster
        )
    }

    private func quickSearchCandidates(for query: String, year: String?) async -> [SearchResult] {
        // Single multi-search — mirrors how the Search tab gets posters instantly.
        var params: [String: String] = ["query": query, "include_adult": "false"]
        if let year { params["year"] = year }
        guard let response: SearchResponse = try? await request("/3/search/multi", query: params) else {
            return []
        }
        return response.results.filter { $0.mediaType == "movie" || $0.mediaType == "tv" }
    }

    /// Loads a catalogue title by its stable TMDB identity. Home already owns
    /// this ID, so TV seasons must not depend on a second fuzzy title search.
    func details(mediaType: String, tmdbID: Int, fallbackTitle: String) async -> TMDBTitleDetails? {
        guard TMDBSettings.isConfigured,
              mediaType == "movie" || mediaType == "tv" else { return nil }
        let identityKey = "tmdb|\(mediaType)|\(tmdbID)"
        if let cached = detailsCache[identityKey] { return cached }
        if let cached = detailsCache.values.first(where: {
            $0.id == tmdbID && $0.mediaType == mediaType && (mediaType != "tv" || !$0.seasons.isEmpty)
        }) {
            detailsCache[identityKey] = cached
            return cached
        }

        do {
            let payload: DetailPayload = try await request("/3/\(mediaType)/\(tmdbID)", query: [
                "append_to_response": "credits,videos,release_dates,images,external_ids",
                "include_image_language": "en,null"
            ])
            let details = makeTitleDetails(
                payload: payload,
                id: tmdbID,
                mediaType: mediaType,
                fallbackTitle: fallbackTitle
            )
            detailsCache[identityKey] = details
            let fallbackKey = fallbackTitle.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if !fallbackKey.isEmpty {
                detailsCache[fallbackKey + "|" + mediaType] = details
                detailsCache[fallbackKey + "|any"] = details
            }
            persistCache()
            return details
        } catch {
            return nil
        }
    }

    /// Resolves the stable IMDb identifier used by Orion/torrent providers.
    /// This is intentionally separate from title search so older persistent
    /// metadata snapshots (created before `external_ids` was cached) still work.
    func externalIMDbID(mediaType: String, tmdbID: Int) async -> String? {
        guard TMDBSettings.isConfigured,
              mediaType == "movie" || mediaType == "tv" else { return nil }
        struct ExternalIDsPayload: Decodable { let imdbId: String? }
        let payload: ExternalIDsPayload? = try? await request(
            "/3/\(mediaType)/\(tmdbID)/external_ids",
            query: [:]
        )
        return payload?.imdbId?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Cache-only lookup used during app launch. It never performs a network request.
    func cachedDetailsOriginalFirst(for rawTitle: String, preferredMediaType: String? = nil) -> TMDBTitleDetails? {
        let original = Self.originalSearchTitle(from: rawTitle)
        let filtered = Self.searchTitle(from: rawTitle)
        let canonical = Self.canonicalTitleAndYear(from: filtered).title
        var attempted = Set<String>()
        for query in [filtered, canonical, original] where !query.isEmpty {
            let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines)
            guard attempted.insert(normalized.lowercased()).inserted else { continue }
            if let cached = cachedDetails(for: normalized, preferredMediaType: preferredMediaType) { return cached }
        }
        return nil
    }

    private func detailsForQuery(_ query: String, preferredMediaType: String? = nil) async -> TMDBTitleDetails? {
        guard TMDBSettings.isConfigured else { return nil }
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedQuery.isEmpty else { return nil }
        let cacheKey = normalizedQuery.lowercased() + "|" + (preferredMediaType ?? "any")
        if let cached = cachedDetails(for: normalizedQuery, preferredMediaType: preferredMediaType) {
            // Save the alias so subsequent reads are a direct dictionary hit.
            if detailsCache[cacheKey] == nil {
                detailsCache[cacheKey] = cached
                persistCache()
            }
            return cached
        }
        let candidates = await searchCandidates(for: normalizedQuery)
        guard let match = Self.bestMatch(in: candidates, query: normalizedQuery, preferredMediaType: preferredMediaType) else { return nil }
        do {
            let endpoint = "/3/\(match.mediaType)/\(match.id)"
            let payload: DetailPayload = try await request(endpoint, query: [
                "append_to_response": "credits,videos,release_dates,images,external_ids",
                "include_image_language": "en,null"
            ])
            let details = makeTitleDetails(
                payload: payload,
                id: match.id,
                mediaType: match.mediaType,
                fallbackTitle: match.title ?? match.name ?? normalizedQuery
            )
            // One successful response is shared by the Content scan and Details
            // screen even when one requested `movie`/`tv` and the other `any`.
            let base = normalizedQuery.lowercased()
            detailsCache[cacheKey] = details
            detailsCache[base + "|" + details.mediaType] = details
            detailsCache[base + "|any"] = details
            persistCache()
            return details
        } catch { return nil }
    }

    private func makeTitleDetails(
        payload: DetailPayload,
        id: Int,
        mediaType: String,
        fallbackTitle: String
    ) -> TMDBTitleDetails {
        let trailers = payload.videos?.results ?? []
        let trailer = trailers.first { $0.site == "YouTube" && $0.type == "Trailer" && $0.official == true }
            ?? trailers.first { $0.site == "YouTube" && $0.type == "Trailer" }
        let certification = payload.releaseDates?.results
            .first(where: { $0.iso31661 == "US" })?.releaseDates
            .first(where: { !$0.certification.isEmpty })?.certification
            ?? payload.releaseDates?.results.flatMap(\.releaseDates)
                .first(where: { !$0.certification.isEmpty })?.certification
        let noLanguagePosterPath = payload.images?.posters?
            .filter { $0.iso6391 == nil }
            .max { $0.qualityScore < $1.qualityScore }?.filePath
        let englishPosterPath = payload.images?.posters?
            .filter { $0.iso6391 == "en" }
            .max { $0.qualityScore < $1.qualityScore }?.filePath
        return TMDBTitleDetails(
            id: id,
            mediaType: mediaType,
            imdbID: payload.externalIds?.imdbId,
            title: payload.title ?? payload.name ?? fallbackTitle,
            overview: payload.overview ?? "",
            posterPath: payload.posterPath,
            backdropPath: payload.backdropPath,
            releaseDate: payload.releaseDate ?? payload.firstAirDate,
            voteAverage: payload.voteAverage ?? 0,
            genres: payload.genres ?? [],
            cast: Array((payload.credits?.cast ?? []).prefix(20)),
            seasons: (payload.seasons ?? []).filter { $0.seasonNumber > 0 },
            trailerKey: trailer?.key,
            runtimeMinutes: payload.runtime,
            productionCountries: payload.productionCountries?.map(\.name),
            certification: certification,
            director: payload.credits?.crew.first(where: { $0.job == "Director" }),
            logoPath: payload.images?.logos.first(where: { $0.iso6391 == "en" })?.filePath
                ?? payload.images?.logos.first?.filePath,
            noLanguageBackdropPath: payload.images?.backdrops?.first(where: { $0.iso6391 == nil })?.filePath,
            noLanguagePosterPath: noLanguagePosterPath,
            detailsPosterPath: noLanguagePosterPath ?? englishPosterPath ?? payload.posterPath
        )
    }

    private func cachedDetails(for query: String, preferredMediaType: String?) -> TMDBTitleDetails? {
        let base = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !base.isEmpty else { return nil }
        if let preferredMediaType {
            if let exact = detailsCache[base + "|" + preferredMediaType] { return exact }
            if let any = detailsCache[base + "|any"], any.mediaType == preferredMediaType { return any }
            return nil
        }
        return detailsCache[base + "|any"]
            ?? detailsCache[base + "|movie"]
            ?? detailsCache[base + "|tv"]
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
                SearchResult(
                    id: $0.id, mediaType: "movie", title: $0.title, name: $0.name,
                    posterPath: $0.posterPath, backdropPath: $0.backdropPath,
                    releaseDate: $0.releaseDate, firstAirDate: $0.firstAirDate,
                    voteAverage: $0.voteAverage, overview: $0.overview
                )
            })
        }
        if let response: TypedTitleSearchResponse = try? await request("/3/search/tv", query: tvQuery) {
            values.append(contentsOf: response.results.map {
                SearchResult(
                    id: $0.id, mediaType: "tv", title: $0.title, name: $0.name,
                    posterPath: $0.posterPath, backdropPath: $0.backdropPath,
                    releaseDate: $0.releaseDate, firstAirDate: $0.firstAirDate,
                    voteAverage: $0.voteAverage, overview: $0.overview
                )
            })
        }
        var seen = Set<String>()
        return values.filter { seen.insert("\($0.mediaType)|\($0.id)").inserted }
    }

    private static func canonicalTitleAndYear(from raw: String) -> (title: String, year: String?) {
        var value = searchTitle(from: raw)
        let yearPattern = #"(?<!\d)((?:19|20)\d{2})(?!\d)"#
        var year: String?
        if let regex = try? NSRegularExpression(pattern: yearPattern) {
            let matches = regex.matches(in: value, range: NSRange(value.startIndex..., in: value))
            let latestPlausibleYear = Calendar.current.component(.year, from: Date()) + 2
            // Use the last plausible year. This preserves title numbers in names
            // such as `Blade Runner 2049 (2017)` and `2001 A Space Odyssey (1968)`.
            if let match = matches.reversed().first(where: { match in
                guard let range = Range(match.range(at: 1), in: value),
                      let number = Int(value[range]) else { return false }
                return number <= latestPlausibleYear
            }), let range = Range(match.range(at: 1), in: value) {
                year = String(value[range])
                value.removeSubrange(range)
            }
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
        // Edition/repack markers normally sit immediately before resolution or
        // source tags. They are not part of the TMDB title and must be the cutoff.
        value = value.replacingOccurrences(
            of: #"(?i)\b(?:Season\s*\d{1,3}|S\d{1,3}(?:\s*E\d{1,3})?|COMPLETE|PROPER|REPACK|RERIP|INTERNAL|EXTENDED|UNRATED|REMASTERED|DIRECTORS?[ ._-]*CUT|THEATRICAL|LIMITED|4320p|2160p|1440p|1080p|720p|480p|8K|4K|UHD|FHD|HDR10\+?|HDR|DOLBY[ ._-]*VISION|DV|HDTV|WEB[ ._-]?(?:DL|RIP)|BLU[ ._-]?RAY|BDRIP|BRRIP|REMUX|x264|x265|H[ ._-]?264|H[ ._-]?265|HEVC|AV1|DDP?\d(?:\.\d)?|DTS(?:[ ._-]?HD)?|TRUEHD|ATMOS)\b.*$"#,
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
        return await episodeDetails(seriesID: series.id, season: season, episode: episode)
    }

    func episodeDetails(seriesID: Int, season: Int, episode: Int) async -> TMDBEpisodeDetails? {
        let cacheKey = "\(seriesID)|s\(season)|e\(episode)"
        if let cached = episodeCache[cacheKey] { return cached }
        do {
            let payload: EpisodePayload = try await request("/3/tv/\(seriesID)/season/\(season)/episode/\(episode)", query: [:])
            let details = TMDBEpisodeDetails(name: payload.name ?? "Episode \(episode)", overview: payload.overview ?? "", stillPath: payload.stillPath)
            episodeCache[cacheKey] = details
            persistCache()
            return details
        } catch { return nil }
    }

    /// Loads the complete season with one TMDB request instead of issuing one
    /// request per visible episode card. Existing disk-cached entries are reused.
    func seasonEpisodeDetails(
        seriesID: Int,
        season: Int,
        episodeNumbers: [Int]
    ) async -> [Int: TMDBEpisodeDetails] {
        let requestedNumbers = Set(episodeNumbers)
        guard !requestedNumbers.isEmpty else { return [:] }
        let seasonKey = "\(seriesID)|s\(season)"

        func cachedResults() -> [Int: TMDBEpisodeDetails] {
            Dictionary(uniqueKeysWithValues: requestedNumbers.compactMap { episode in
                let key = "\(seriesID)|s\(season)|e\(episode)"
                return episodeCache[key].map { (episode, $0) }
            })
        }

        var cacheChanged = false
        let cached = cachedResults()

        // A season marked complete by older builds may contain episode names but
        // no still_path. Do not treat that poisoned entry as finished artwork.
        // The bulk season request is only needed when an episode record itself is
        // missing; missing artwork is repaired below through the images endpoint.
        let hasEveryEpisodeRecord = requestedNumbers.allSatisfy { cached[$0] != nil }
        if !completedSeasonCache.contains(seasonKey) || !hasEveryEpisodeRecord {
            do {
                let payload: SeasonEpisodesPayload = try await request(
                    "/3/tv/\(seriesID)/season/\(season)",
                    query: [:]
                )
                for episode in payload.episodes where requestedNumbers.contains(episode.episodeNumber) {
                    let details = TMDBEpisodeDetails(
                        name: episode.name ?? "Episode \(episode.episodeNumber)",
                        overview: episode.overview ?? "",
                        stillPath: episode.stillPath
                    )
                    episodeCache["\(seriesID)|s\(season)|e\(episode.episodeNumber)"] = details
                }
                completedSeasonCache.insert(seasonKey)
                cacheChanged = true
            } catch {
                // Keep any disk-cached episode records usable during a temporary
                // TMDB/network failure. Missing records will be retried next time.
            }
        }

        // Prefer the single season payload. Per-episode /images calls were
        // serial and made library episode rows feel permanently stuck loading.
        let results = cachedResults()
        if cacheChanged { persistCache() }
        return results
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

// MARK: - Online platform catalogue

struct TMDBCatalogItem: Identifiable, Codable, Hashable {
    let id: Int
    let mediaType: String?
    let title: String?
    let name: String?
    let overview: String?
    let posterPath: String?
    let backdropPath: String?
    let releaseDate: String?
    let firstAirDate: String?
    let voteAverage: Double?
    let popularity: Double?
    let genreIds: [Int]?

    var resolvedMediaType: String { mediaType == "tv" ? "tv" : "movie" }
    var displayTitle: String { title ?? name ?? "Untitled" }
    var displayDate: String? { releaseDate ?? firstAirDate }
}

struct TMDBOnlineCatalogSnapshot: Codable {
    let refreshedAt: Date
    let trending: [TMDBCatalogItem]
    let newMovies: [TMDBCatalogItem]
    let popularMovies: [TMDBCatalogItem]
    let popularKoreanMovies: [TMDBCatalogItem]
    let airingTV: [TMDBCatalogItem]
    let newEpisodes: [TMDBCatalogItem]
    let recentKoreanDramas: [TMDBCatalogItem]
    let topRated: [TMDBCatalogItem]
    let movieGenres: [Int: String]
    let tvGenres: [Int: String]

    static let empty = TMDBOnlineCatalogSnapshot(
        refreshedAt: .distantPast,
        trending: [],
        newMovies: [],
        popularMovies: [],
        popularKoreanMovies: [],
        airingTV: [],
        newEpisodes: [],
        recentKoreanDramas: [],
        topRated: [],
        movieGenres: [:],
        tvGenres: [:]
    )

    var isEmpty: Bool {
        trending.isEmpty && newMovies.isEmpty && popularMovies.isEmpty && popularKoreanMovies.isEmpty
            && airingTV.isEmpty && newEpisodes.isEmpty && recentKoreanDramas.isEmpty && topRated.isEmpty
    }

    var isStale: Bool { Date().timeIntervalSince(refreshedAt) > 6 * 60 * 60 }
}

/// Independent, disk-backed catalogue for the experimental streaming platform.
/// Restoring this snapshot never waits for the network, so Home remains filled
/// while a six-hour refresh quietly replaces it in the background.
actor TMDBOnlineCatalogService {
    static let shared = TMDBOnlineCatalogService()

    private var snapshot: TMDBOnlineCatalogSnapshot
    private let cacheURL: URL
    private let decoder: JSONDecoder = {
        let value = JSONDecoder()
        value.keyDecodingStrategy = .convertFromSnakeCase
        return value
    }()

    init() {
        let fileManager = FileManager.default
        let directory = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PersistentMetadata/OnlineCatalog", isDirectory: true)
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        // v2 replaces the theatrical "now playing" feed with actual digital
        // releases. Do not briefly restore the old cinema-only Home cache.
        cacheURL = directory.appendingPathComponent("tmdb-online-v2.json")
        if let data = try? Data(contentsOf: cacheURL),
           let saved = try? JSONDecoder().decode(TMDBOnlineCatalogSnapshot.self, from: data) {
            snapshot = saved
        } else {
            snapshot = .empty
        }
    }

    func cachedSnapshot() -> TMDBOnlineCatalogSnapshot { snapshot }

    func search(_ rawQuery: String) async throws -> [TMDBCatalogItem] {
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard query.count >= 2, TMDBSettings.isConfigured else { return [] }
        let payload: TMDBCatalogListPayload = try await request(
            "/3/search/multi",
            query: [
                "query": query,
                "language": "en-US",
                "page": "1",
                "include_adult": "false"
            ]
        )
        return Self.deduplicated(
            payload.results.filter { $0.mediaType == "movie" || $0.mediaType == "tv" }
        )
    }

    func refresh(force: Bool = false) async throws -> TMDBOnlineCatalogSnapshot {
        guard TMDBSettings.isConfigured else { return snapshot }
        if !force, !snapshot.isEmpty, !snapshot.isStale { return snapshot }

        let dateFormatter = DateFormatter()
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        dateFormatter.timeZone = TimeZone(secondsFromGMT: 0)
        dateFormatter.dateFormat = "yyyy-MM-dd"
        let today = Date()
        let digitalWindowStart = Calendar.current.date(byAdding: .day, value: -90, to: today) ?? today

        async let trendingResponse = list("/3/trending/all/day", fallbackMediaType: nil)
        // TMDB release type 4 is Digital. This deliberately replaces the
        // theatre-only now_playing list, so Home never promotes a title before
        // its digital release is available.
        async let newMoviesResponse = list(
            "/3/discover/movie",
            fallbackMediaType: "movie",
            extra: [
                "region": "US",
                "with_release_type": "4",
                "release_date.gte": dateFormatter.string(from: digitalWindowStart),
                "release_date.lte": dateFormatter.string(from: today),
                "sort_by": "release_date.desc",
                "include_adult": "false",
                "include_video": "false"
            ]
        )
        async let popularMoviesResponse = list("/3/movie/popular", fallbackMediaType: "movie", extra: ["region": "US"])
        // Korean movies/dramas use `discover`, since the curated `/popular` and
        // `/on_the_air` endpoints don't accept an origin-country filter.
        async let popularKoreanMoviesResponse = list(
            "/3/discover/movie",
            fallbackMediaType: "movie",
            extra: [
                "with_origin_country": "KR",
                "sort_by": "popularity.desc",
                "include_adult": "false"
            ]
        )
        async let airingTVResponse = list("/3/tv/on_the_air", fallbackMediaType: "tv")
        async let newEpisodesResponse = list("/3/tv/airing_today", fallbackMediaType: "tv")
        async let recentKoreanDramaResponse = list(
            "/3/discover/tv",
            fallbackMediaType: "tv",
            extra: [
                "with_origin_country": "KR",
                "sort_by": "first_air_date.desc",
                "first_air_date.lte": dateFormatter.string(from: today)
            ]
        )
        async let topMoviesResponse = list("/3/movie/top_rated", fallbackMediaType: "movie", extra: ["region": "US"])
        async let topTVResponse = list("/3/tv/top_rated", fallbackMediaType: "tv")
        async let movieGenresResponse = genres("movie")
        async let tvGenresResponse = genres("tv")

        let trendingValues = try await trendingResponse
        let trending = trendingValues.filter { $0.mediaType == "movie" || $0.mediaType == "tv" }
        let topMovies = try await topMoviesResponse
        let topTV = try await topTVResponse
        let topRated = Self.deduplicated(topMovies + topTV)
            .sorted { ($0.voteAverage ?? 0) > ($1.voteAverage ?? 0) }

        let refreshed = TMDBOnlineCatalogSnapshot(
            refreshedAt: Date(),
            trending: trending,
            newMovies: try await newMoviesResponse,
            popularMovies: try await popularMoviesResponse,
            popularKoreanMovies: try await popularKoreanMoviesResponse,
            airingTV: try await airingTVResponse,
            newEpisodes: try await newEpisodesResponse,
            recentKoreanDramas: try await recentKoreanDramaResponse,
            topRated: topRated,
            movieGenres: try await movieGenresResponse,
            tvGenres: try await tvGenresResponse
        )
        snapshot = refreshed
        if let data = try? JSONEncoder().encode(refreshed) {
            try? data.write(to: cacheURL, options: .atomic)
        }
        return refreshed
    }

    private func list(
        _ path: String,
        fallbackMediaType: String?,
        extra: [String: String] = [:]
    ) async throws -> [TMDBCatalogItem] {
        var query = ["language": "en-US", "page": "1"]
        extra.forEach { query[$0.key] = $0.value }
        let payload: TMDBCatalogListPayload = try await request(path, query: query)
        return payload.results.map { item in
            guard item.mediaType == nil, let fallbackMediaType else { return item }
            return TMDBCatalogItem(
                id: item.id,
                mediaType: fallbackMediaType,
                title: item.title,
                name: item.name,
                overview: item.overview,
                posterPath: item.posterPath,
                backdropPath: item.backdropPath,
                releaseDate: item.releaseDate,
                firstAirDate: item.firstAirDate,
                voteAverage: item.voteAverage,
                popularity: item.popularity,
                genreIds: item.genreIds
            )
        }
    }

    private func genres(_ mediaType: String) async throws -> [Int: String] {
        let payload: TMDBCatalogGenrePayload = try await request(
            "/3/genre/\(mediaType)/list",
            query: ["language": "en-US"]
        )
        return Dictionary(uniqueKeysWithValues: payload.genres.map { ($0.id, $0.name) })
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
        guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
            throw URLError(.badServerResponse)
        }
        return try decoder.decode(T.self, from: data)
    }

    private static func deduplicated(_ items: [TMDBCatalogItem]) -> [TMDBCatalogItem] {
        var seen = Set<String>()
        return items.filter { seen.insert("\($0.resolvedMediaType)|\($0.id)").inserted }
    }
}

private struct TMDBCatalogListPayload: Decodable { let results: [TMDBCatalogItem] }
private struct TMDBCatalogGenrePayload: Decodable { let genres: [TMDBGenre] }

private struct TMDBPersistentCache: Codable {
    let details: [String: TMDBTitleDetails]
    let episodes: [String: TMDBEpisodeDetails]
    let completedSeasons: Set<String>?
}

private struct SearchResponse: Decodable { let results: [SearchResult] }
private struct TypedTitleSearchResponse: Decodable { let results: [TypedTitleSearchResult] }
private struct TypedTitleSearchResult: Decodable {
    let id: Int
    let title: String?
    let name: String?
    let posterPath: String?
    let backdropPath: String?
    let releaseDate: String?
    let firstAirDate: String?
    let voteAverage: Double?
    let overview: String?
}

private struct SearchResult: Decodable {
    let id: Int
    let mediaType: String
    let title: String?
    let name: String?
    let posterPath: String?
    let backdropPath: String?
    let releaseDate: String?
    let firstAirDate: String?
    let voteAverage: Double?
    let overview: String?
}
private struct DetailPayload: Decodable {
    let title: String?; let name: String?; let overview: String?
    let posterPath: String?; let backdropPath: String?
    let releaseDate: String?; let firstAirDate: String?; let voteAverage: Double?; let runtime: Int?
    let genres: [TMDBGenre]?; let seasons: [TMDBSeason]?
    let credits: Credits?; let videos: Videos?; let productionCountries: [ProductionCountry]?
    let releaseDates: ReleaseDatesResponse?; let images: TMDBImagesPayload?
    let externalIds: TMDBExternalIDsPayload?
}
private struct TMDBExternalIDsPayload: Decodable { let imdbId: String? }
private struct Credits: Decodable { let cast: [TMDBCastMember]; let crew: [TMDBCrewMember] }
private struct ProductionCountry: Decodable { let name: String }
private struct ReleaseDatesResponse: Decodable { let results: [ReleaseDatesCountry] }
private struct ReleaseDatesCountry: Decodable { let iso31661: String; let releaseDates: [ReleaseDateEntry] }
private struct ReleaseDateEntry: Decodable { let certification: String }
private struct TMDBImagesPayload: Decodable {
    let logos: [TMDBLogoPayload]
    let backdrops: [TMDBBackdropPayload]?
    let posters: [TMDBBackdropPayload]?
}
private struct TMDBLogoPayload: Decodable { let filePath: String; let iso6391: String? }
private struct TMDBBackdropPayload: Decodable {
    let filePath: String
    let iso6391: String?
    let voteAverage: Double?
    let voteCount: Int?
    let width: Int?
    let height: Int?

    var qualityScore: Double {
        let rating = (voteAverage ?? 0) * 1_000_000
        let votes = Double(voteCount ?? 0) * 1_000
        let pixels = Double(width ?? 0) * Double(height ?? 0) / 1_000_000
        return rating + votes + pixels
    }
}
private struct Videos: Decodable { let results: [Video] }
private struct Video: Decodable { let key: String; let site: String; let type: String; let official: Bool? }

private struct EpisodePayload: Decodable { let name: String?; let overview: String?; let stillPath: String? }
private struct SeasonEpisodesPayload: Decodable { let episodes: [SeasonEpisodePayload] }
private struct SeasonEpisodePayload: Decodable {
    let episodeNumber: Int
    let name: String?
    let overview: String?
    let stillPath: String?
}
private struct EpisodeImagesPayload: Decodable { let stills: [EpisodeImagePayload] }
private struct EpisodeImagePayload: Decodable { let filePath: String }


private struct AuthenticationPayload: Decodable { let success: Bool }
private struct TMDBErrorPayload: Decodable { let statusMessage: String? }
private struct TMDBRequestError: Error { let message: String }
