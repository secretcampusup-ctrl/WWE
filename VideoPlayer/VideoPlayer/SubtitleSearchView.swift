import SwiftUI

struct DownloadedSubtitle: Sendable {
    let data: Data
    let fileName: String
}

struct SubtitleSearchResult: Identifiable, Sendable {
    let id = UUID()
    let title: String
    let language: String
    let format: String
    let hearingImpaired: Bool
    let season: Int?
    let episode: Int?
    let directURL: URL?
    let nID: String?
}

private enum SubtitleSearchError: LocalizedError {
    case invalidResponse
    case service(String)
    case archiveOnly
    case timedOut
    case unreadableSubtitle

    var errorDescription: String? {
        switch self {
        case .invalidResponse: return "SubDL returned an unreadable response."
        case .service(let message): return message
        case .archiveOnly: return "This result contains multiple files. Choose a single-file result."
        case .timedOut: return "The subtitle server took too long. Please try another result."
        case .unreadableSubtitle: return "This download is not a supported subtitle file. Please choose another result."
        }
    }
}

enum SubDLSubtitleService {
    private static let apiKey = "CGMzti6MNc_uoiaFivlTimZC5X-8ne4B"

    static func search(
        query: String,
        mediaTitle: String,
        mediaContext: SubtitleMediaContext? = nil,
        languageCode: String?
    ) async throws -> [SubtitleSearchResult] {
        guard var components = URLComponents(string: "https://api.subdl.com/api/v2/subtitles/search") else {
            throw SubtitleSearchError.invalidResponse
        }
        var items = [
            URLQueryItem(name: "unpack", value: "1"),
            URLQueryItem(name: "subs_per_page", value: "30")
        ]
        let usesMetadata = mediaContext.map {
            normalizedIdentity(query) == normalizedIdentity($0.title)
        } ?? false
        let parsedEpisode = VideoTitleFormatter.episodeComponents(from: mediaTitle)
        let requestedSeason = usesMetadata ? mediaContext?.season : parsedEpisode?.season
        let requestedEpisode = usesMetadata ? mediaContext?.episode : parsedEpisode?.episode
        if usesMetadata, let context = mediaContext, let tmdbID = context.tmdbID {
            items.append(URLQueryItem(name: "tmdb_id", value: String(tmdbID)))
            items.append(URLQueryItem(name: "type", value: context.mediaType == "tv" || context.isEpisode ? "tv" : "movie"))
        } else {
            items.append(URLQueryItem(name: "film_name", value: query))
        }
        if let languageCode { items.append(URLQueryItem(name: "languages", value: languageCode)) }
        if let season = requestedSeason, let episode = requestedEpisode {
            if !usesMetadata || mediaContext?.tmdbID == nil {
                items.append(URLQueryItem(name: "type", value: "tv"))
            }
            items.append(URLQueryItem(name: "season", value: String(season)))
            items.append(URLQueryItem(name: "episode", value: String(episode)))
        }
        components.queryItems = items
        guard let url = components.url else { throw SubtitleSearchError.invalidResponse }

        var request = URLRequest(url: url)
        request.timeoutInterval = 25
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await AppNetworkSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw SubtitleSearchError.invalidResponse }
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        if !(200...299).contains(http.statusCode) {
            let message = (object?["error"] as? String)
                ?? (object?["message"] as? String)
                ?? "Subtitle search failed (\(http.statusCode))."
            throw SubtitleSearchError.service(message)
        }
        guard let object else { throw SubtitleSearchError.invalidResponse }
        if let status = object["status"] as? Bool, !status {
            throw SubtitleSearchError.service((object["error"] as? String) ?? "No subtitles found.")
        }

        let subtitles = object["subtitles"] as? [[String: Any]] ?? []
        let flattened = subtitles.flatMap { subtitle -> [SubtitleSearchResult] in
            if let files = subtitle["unpack_files"] as? [[String: Any]], !files.isEmpty {
                return files.compactMap { result(from: $0, parent: subtitle) }
            }
            return result(from: subtitle, parent: nil).map { [$0] } ?? []
        }
        if let requestedEpisode {
            let exact = flattened.filter { result in
                guard result.episode == requestedEpisode else { return false }
                guard let requestedSeason, let resultSeason = result.season, resultSeason > 0 else { return true }
                return resultSeason == requestedSeason
            }
            return exact
        }
        return flattened
    }

    static func download(_ result: SubtitleSearchResult) async throws -> DownloadedSubtitle {
        let url: URL
        if let nID = result.nID,
                  let encoded = nID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
                  let generated = URL(string: "https://api.subdl.com/api/v2/subtitles/\(encoded)/download?format=file") {
            url = generated
        } else if let directURL = result.directURL {
            url = directURL
        } else {
            throw SubtitleSearchError.invalidResponse
        }

        var request = URLRequest(url: url)
        // SubDL occasionally leaves a download response open instead of failing.
        // Keep this short and enforce a separate wall-clock timeout below so the
        // result row can never spin indefinitely.
        request.timeoutInterval = 18
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await dataWithDeadline(for: request, seconds: 22)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode), !data.isEmpty else {
            throw SubtitleSearchError.invalidResponse
        }
        if data.starts(with: [0x50, 0x4B]) { throw SubtitleSearchError.archiveOnly }

        // The provider can sometimes return a successful HTML error page. Do
        // not close the picker or pretend that it was applied in that case.
        if let text = String(data: data.prefix(512), encoding: .utf8) {
            let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if normalized.hasPrefix("<!doctype html") || normalized.hasPrefix("<html") {
                throw SubtitleSearchError.unreadableSubtitle
            }
        }

        let responseName = http.suggestedFilename?.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallbackName = result.title.hasSuffix(".\(result.format)")
            ? result.title
            : "\(result.title).\(result.format.isEmpty ? "srt" : result.format)"
        let fileName = (responseName?.isEmpty == false ? responseName : nil) ?? fallbackName
        return DownloadedSubtitle(data: data, fileName: fileName)
    }

    private static func dataWithDeadline(
        for request: URLRequest,
        seconds: UInt64
    ) async throws -> (Data, URLResponse) {
        try await withThrowingTaskGroup(of: (Data, URLResponse).self) { group in
            group.addTask {
                try await AppNetworkSession.shared.data(for: request)
            }
            group.addTask {
                try await Task.sleep(nanoseconds: seconds * 1_000_000_000)
                throw SubtitleSearchError.timedOut
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else {
                throw SubtitleSearchError.invalidResponse
            }
            return first
        }
    }

    static func automaticDownload(
        mediaTitle: String,
        mediaContext: SubtitleMediaContext?
    ) async throws -> DownloadedSubtitle? {
        let languageCodes = SubtitlePreferences.searchLanguageCodes
        let metadataIdentity = mediaContext.map {
            "tmdb:\($0.tmdbID ?? 0)|\($0.mediaType ?? "")|s\($0.season ?? 0)e\($0.episode ?? 0)"
        } ?? mediaTitle
        let cacheKey = metadataIdentity + "|" + languageCodes.joined(separator: ",")
        if let cached = AutomaticSubtitleCache.load(key: cacheKey) { return cached }
        let results = try await search(
            query: mediaContext?.title ?? VideoTitleFormatter.title(from: mediaTitle),
            mediaTitle: mediaTitle,
            mediaContext: mediaContext,
            languageCode: languageCodes.joined(separator: ",")
        )
        guard !results.isEmpty else { return nil }

        let preferredCode = SubtitlePreferences.preferredLanguageCode.lowercased()
        let preferred = results.filter {
            SubtitlePreferences.languageMatches(
                code: $0.language,
                title: $0.language,
                preferredCode: preferredCode
            )
        }
        let ordered = preferred + results.filter { candidate in
            !preferred.contains(where: { $0.id == candidate.id })
        }

        var lastError: Error?
        for result in ordered.prefix(5) {
            do {
                let subtitle = try await download(result)
                AutomaticSubtitleCache.save(subtitle, key: cacheKey)
                return subtitle
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = error
            }
        }
        if let lastError { throw lastError }
        return nil
    }

    private static func result(from value: [String: Any], parent: [String: Any]?) -> SubtitleSearchResult? {
        let rawURL = string(value["download_url"])
            ?? string(value["file_url"])
            ?? string(value["url"])
            ?? string(parent?["download_url"])
            ?? string(parent?["file_url"])
            ?? string(parent?["url"])
        let directURL: URL? = rawURL.flatMap { raw in
            if let absolute = URL(string: raw), absolute.scheme != nil { return absolute }
            return URL(string: "https://dl.subdl.com\(raw.hasPrefix("/") ? raw : "/\(raw)")")
        }
        let nID = string(value["n_id"])
            ?? string(value["nId"])
            ?? string(value["subtitle_id"])
            ?? string(parent?["n_id"])
            ?? string(parent?["nId"])
            ?? string(parent?["subtitle_id"])
        guard directURL != nil || nID != nil else { return nil }
        let title = string(value["release_name"])
            ?? string(value["name"])
            ?? string(parent?["release_name"])
            ?? "Subtitle"
        let language = string(value["language"])
            ?? string(value["lang"])
            ?? string(parent?["language"])
            ?? string(parent?["lang"])
            ?? "Unknown"
        let format = string(value["format"])
            ?? (title as NSString).pathExtension.lowercased()
        let normalizedFormat = format.lowercased()
        guard ["srt", "vtt", "ass", "ssa"].contains(normalizedFormat) else { return nil }
        let childSeason = integer(value["season"])
        let childEpisode = integer(value["episode"])
        let parentSeason = integer(parent?["season"])
        let parentEpisode = integer(parent?["episode"])
        let hearingImpaired = (value["hi"] as? Bool) ?? (parent?["hi"] as? Bool) ?? false
        return SubtitleSearchResult(
            title: title,
            language: language,
            format: normalizedFormat,
            hearingImpaired: hearingImpaired,
            season: (childSeason ?? 0) > 0 ? childSeason : parentSeason,
            episode: (childEpisode ?? 0) > 0 ? childEpisode : parentEpisode,
            directURL: directURL,
            nID: nID
        )
    }

    private static func string(_ value: Any?) -> String? {
        if let value = value as? String, !value.isEmpty { return value }
        if let value = value as? NSNumber { return value.stringValue }
        return nil
    }

    private static func integer(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        if let value = value as? String { return Int(value) }
        return nil
    }

    private static func normalizedIdentity(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private enum AutomaticSubtitleCache {
    static func load(key: String) -> DownloadedSubtitle? {
        let urls = cacheURLs(for: key)
        guard let data = try? Data(contentsOf: urls.data),
              !data.isEmpty,
              let nameData = try? Data(contentsOf: urls.name),
              let fileName = String(data: nameData, encoding: .utf8),
              !fileName.isEmpty else { return nil }
        return DownloadedSubtitle(data: data, fileName: fileName)
    }

    static func save(_ subtitle: DownloadedSubtitle, key: String) {
        let urls = cacheURLs(for: key)
        try? FileManager.default.createDirectory(
            at: urls.data.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? subtitle.data.write(to: urls.data, options: .atomic)
        try? Data(subtitle.fileName.utf8).write(to: urls.name, options: .atomic)
    }

    private static func cacheURLs(for key: String) -> (data: URL, name: URL) {
        let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AutomaticSubtitles", isDirectory: true)
        let identifier = stableIdentifier(key.lowercased())
        return (
            root.appendingPathComponent(identifier + ".subtitle"),
            root.appendingPathComponent(identifier + ".name")
        )
    }

    private static func stableIdentifier(_ value: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(hash, radix: 16)
    }
}

struct SubtitleSearchView: View {
    private struct SearchLanguage: Identifiable {
        let code: String
        let title: String
        var id: String { code }
    }

    @Environment(\.dismiss) private var dismiss
    let mediaTitle: String
    let mediaContext: SubtitleMediaContext?
    /// Returns `true` only after the player parsed and applied the subtitle.
    let onSubtitleSelected: (DownloadedSubtitle) -> Bool

    @State private var query: String
    @State private var language = "CONFIGURED"
    @State private var results: [SubtitleSearchResult] = []
    @State private var isSearching = false
    @State private var downloadingID: UUID?
    @State private var errorMessage: String?

    private var languages: [SearchLanguage] {
        [
            SearchLanguage(code: "CONFIGURED", title: "Preferred Languages"),
            SearchLanguage(code: "ALL", title: "All Languages")
        ] + SubtitleLanguageOption.supported.map { SearchLanguage(code: $0.code, title: $0.title) }
    }

    init(
        mediaTitle: String,
        mediaContext: SubtitleMediaContext? = nil,
        onSubtitleSelected: @escaping (DownloadedSubtitle) -> Bool
    ) {
        self.mediaTitle = mediaTitle
        self.mediaContext = mediaContext
        self.onSubtitleSelected = onSubtitleSelected
        _query = State(initialValue: mediaContext?.title ?? VideoTitleFormatter.title(from: mediaTitle))
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                LinearGradient(
                    colors: [AppPalette.accent.opacity(0.18), .clear, Color.blue.opacity(0.07)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ).ignoresSafeArea()

                ScrollView(showsIndicators: false) {
                    VStack(spacing: 14) {
                        searchCard
                        content
                    }
                    .padding(18)
                    .padding(.bottom, 30)
                }
            }
            .navigationTitle("Find Subtitles")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    AppAnimatedBackButton(size: 36) { dismiss() }
                }
            }
            .toolbarColorScheme(.dark, for: .navigationBar)
        }
        .preferredColorScheme(.dark)
    }

    private var searchCard: some View {
        VStack(spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundStyle(.white.opacity(0.5))
                TextField("Movie or episode name", text: $query)
                    .textInputAutocapitalization(.words)
                    .autocorrectionDisabled()
                    .submitLabel(.search)
                    .onSubmit { performSearch() }
                if !query.isEmpty {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .foregroundStyle(.white.opacity(0.35))
                }
            }
            .padding(.horizontal, 14).frame(height: 48)
            .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 15))

            if let context = mediaContext {
                HStack(spacing: 7) {
                    Image(systemName: "checkmark.seal.fill").foregroundStyle(AppPalette.accent)
                    Text("TMDB · \(context.title)")
                    if let season = context.season, let episode = context.episode {
                        Text("· S\(season) E\(episode)")
                    }
                    Spacer(minLength: 0)
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white.opacity(0.62))
                .lineLimit(1)
            }

            HStack(spacing: 10) {
                Menu {
                    ForEach(languages) { option in
                        Button(option.title) { language = option.code }
                    }
                } label: {
                    Label(languages.first(where: { $0.code == language })?.title ?? "Language", systemImage: "globe")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(maxWidth: .infinity).frame(height: 44)
                        .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 13))
                }
                Button(action: performSearch) {
                    Group {
                        if isSearching { ProgressView().tint(.white) }
                        else { Label("Search", systemImage: "magnifyingglass") }
                    }
                    .font(.system(size: 14, weight: .bold))
                    .frame(maxWidth: .infinity).frame(height: 44)
                    .background(AppPalette.diagonalGradient, in: RoundedRectangle(cornerRadius: 13))
                }
                .disabled(isSearching || query.trimmingCharacters(in: .whitespacesAndNewlines).count < 2)
            }
        }
        .padding(16)
        .background(Color.white.opacity(0.065), in: RoundedRectangle(cornerRadius: 21, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 21).stroke(Color.white.opacity(0.08)))
    }

    @ViewBuilder private var content: some View {
        if let errorMessage {
            VStack(spacing: 9) {
                Image(systemName: "exclamationmark.triangle.fill").font(.title2).foregroundStyle(.yellow)
                Text(errorMessage).multilineTextAlignment(.center).foregroundStyle(.white.opacity(0.72))
            }
            .frame(maxWidth: .infinity).padding(.vertical, 30)
        } else if results.isEmpty, !isSearching {
            VStack(spacing: 10) {
                Image(systemName: "captions.bubble").font(.system(size: 34)).foregroundStyle(AppPalette.accent)
                Text("Search by title, then choose a subtitle to use it immediately.")
                    .font(.subheadline).multilineTextAlignment(.center).foregroundStyle(.white.opacity(0.52))
            }
            .frame(maxWidth: .infinity).padding(.vertical, 36)
        } else {
            LazyVStack(spacing: 10) {
                ForEach(results) { result in resultRow(result) }
            }
        }
    }

    private func resultRow(_ result: SubtitleSearchResult) -> some View {
        Button { download(result) } label: {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12).fill(AppPalette.accent.opacity(0.18))
                    Image(systemName: "captions.bubble.fill").foregroundStyle(AppPalette.accent)
                }.frame(width: 46, height: 46)
                VStack(alignment: .leading, spacing: 4) {
                    Text(result.title).font(.system(size: 14, weight: .semibold)).lineLimit(2)
                    HStack(spacing: 7) {
                        Text(result.language.uppercased())
                        Text(result.format.uppercased())
                        if result.hearingImpaired { Text("HI") }
                    }.font(.caption2.bold()).foregroundStyle(.white.opacity(0.45))
                }
                Spacer()
                if downloadingID == result.id { ProgressView().tint(.white) }
                else { Image(systemName: "arrow.down.circle.fill").font(.title3).foregroundStyle(AppPalette.accent) }
            }
            .foregroundStyle(.white).padding(13)
            .background(Color.white.opacity(0.065), in: RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(Color.white.opacity(0.07)))
        }
        .buttonStyle(.plain)
        .disabled(downloadingID != nil)
    }

    private func performSearch() {
        let cleaned = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleaned.count >= 2, !isSearching else { return }
        isSearching = true
        errorMessage = nil
        Task {
            do {
                results = try await SubDLSubtitleService.search(
                    query: cleaned,
                    mediaTitle: mediaTitle,
                    mediaContext: mediaContext,
                    languageCode: searchLanguageCode
                )
                if results.isEmpty { errorMessage = "No subtitles found for this search." }
            } catch {
                errorMessage = error.localizedDescription
            }
            isSearching = false
        }
    }

    private var searchLanguageCode: String? {
        if language == "ALL" { return nil }
        if language == "CONFIGURED" {
            return SubtitlePreferences.searchLanguageCodes.joined(separator: ",")
        }
        return language
    }

    private func download(_ result: SubtitleSearchResult) {
        guard downloadingID == nil else { return }
        downloadingID = result.id
        errorMessage = nil
        Task {
            do {
                let subtitle = try await SubDLSubtitleService.download(result)
                guard onSubtitleSelected(subtitle) else {
                    throw SubtitleSearchError.unreadableSubtitle
                }
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
            }
            downloadingID = nil
        }
    }
}
