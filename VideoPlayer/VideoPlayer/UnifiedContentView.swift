import SwiftUI
import UIKit
import Kingfisher

enum UnifiedMediaSection: String, CaseIterable, Identifiable {
    case movies = "Movies"
    case shows = "TV Shows"
    case unknown = "Unknown"
    var id: String { rawValue }
    var icon: String {
        switch self { case .movies: return "film.fill"; case .shows: return "tv.fill"; case .unknown: return "questionmark.folder.fill" }
    }
}

enum UnifiedSource: Codable {
    case webDAV(server: WebDAVServer, file: WebDAVFile)
    case offcloud(transfer: OffcloudTransfer, file: OffcloudFile)
    case torBox(torrent: TorBoxTorrent, file: TorBoxFile)

    var isVisibleByFileSize: Bool {
        switch self {
        case let .webDAV(_, file): return VideoLibraryVisibility.allows(sizeBytes: file.size)
        case let .offcloud(_, file): return VideoLibraryVisibility.allows(sizeBytes: file.size)
        case let .torBox(_, file): return VideoLibraryVisibility.allows(sizeBytes: file.size)
        }
    }
}

struct UnifiedMediaEntry: Identifiable, Codable {
    let id: String
    let rawTitle: String
    var title: String
    let sourceLabel: String
    let source: UnifiedSource
    let streamURL: URL
    var details: TMDBTitleDetails?
    var adultScene: ThePornDBScene?
    var manualMetadataProvider: String?
    /// Nil means an older snapshot or not searched yet. True prevents an
    /// unmatched filename from generating the same API request every launch.
    var adultLookupCompleted: Bool?
    var episodes: [UnifiedEpisode] = []
    var posterURL: URL? {
        if let url = details?.posterURL { return url }
        if let raw = adultScene?.bestImage { return URL(string: raw) }
        return nil
    }
}

struct UnifiedEpisode: Identifiable, Codable {
    let id: String
    let title: String
    let season: Int
    let episode: Int
    let source: UnifiedSource
    let url: URL
}

private struct UnifiedContentSnapshot: Codable {
    let movies: [UnifiedMediaEntry]
    let shows: [UnifiedMediaEntry]
    let unknown: [UnifiedMediaEntry]
    let sourceSignature: String?
}

@MainActor
final class UnifiedContentModel: ObservableObject {
    @Published var movies: [UnifiedMediaEntry] = []
    @Published var shows: [UnifiedMediaEntry] = []
    @Published var unknown: [UnifiedMediaEntry] = []
    @Published var isLoading = false
    @Published var status = ""
    private var loaded = false
    private var lastSourceSignature = ""
    private var adultEnrichmentTask: Task<Void, Never>?
    private let cloud = OffcloudViewModel()
    private static var snapshotURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let directory = base.appendingPathComponent("UnifiedContent", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableDirectory = directory
        try? mutableDirectory.setResourceValues(values)
        return directory.appendingPathComponent("snapshot-v1.json")
    }

    init() {
        if let data = try? Data(contentsOf: Self.snapshotURL),
           let snapshot = try? JSONDecoder().decode(UnifiedContentSnapshot.self, from: data) {
            movies = Self.removingUndersizedFiles(from: snapshot.movies)
            shows = Self.removingUndersizedFiles(from: snapshot.shows)
            unknown = Self.removingUndersizedFiles(from: snapshot.unknown)
            // Older snapshots could mark metadata complete before a stable
            // poster was actually stored. Requeue only those blank cards.
            for index in unknown.indices where
                VideoThumbnailLoader.cachedImage(forStableKey: "unified-adult|\(unknown[index].id)") == nil {
                unknown[index].adultLookupCompleted = nil
            }
            lastSourceSignature = snapshot.sourceSignature ?? ""
            loaded = true
        }
    }

    func load(vm: AppViewModel, force: Bool = false) async {
        if force {
            // A refresh replaces the previous scan. Never let an older adult
            // enrichment pass continue mutating the same array in parallel.
            adultEnrichmentTask?.cancel()
            adultEnrichmentTask = nil
        }
        let metadataMatcherRevision = "release-v2-adult-v1"
        let baseSourceSignature = vm.servers.map {
            $0.id.uuidString + $0.displayAddress + WebDAVContentSelectionStore.revision(for: $0.id)
        }.joined(separator: "|") + "|tmdb:" + Self.stableSignature(TMDBSettings.readAccessToken)
            + "|tpdb:" + Self.stableSignature(ThePornDBSettings.apiKey)
            + "|matcher:" + metadataMatcherRevision
        var sourceSignature = baseSourceSignature + "|torbox:\(TorBoxLibraryStore.revision)"
        let shouldFetchMetadata = force || sourceSignature != lastSourceSignature
        // A cached library is immutable until the user explicitly refreshes.
        if loaded && !force && sourceSignature == lastSourceSignature {
            if ThePornDBSettings.hasValidAPIKey,
               unknown.contains(where: { $0.adultLookupCompleted != true }) {
                startAdultEnrichmentIfNeeded()
            }
            return
        }
        guard !isLoading else { return }
        isLoading = true
        status = "Scanning connected libraries…"
        defer { isLoading = false }

        var raw: [UnifiedMediaEntry] = []
        for server in vm.servers {
            let files = await vm.contentLibraryFiles(server: server, forceRefresh: force)
            let client = WebDAVClient(server: server)
            for file in files where file.isVideo && !file.isDirectory {
                guard let url = client.streamURL(for: file) else { continue }
                raw.append(UnifiedMediaEntry(
                    id: "webdav|\(server.id.uuidString)|\(file.path)", rawTitle: file.name,
                    title: file.name, sourceLabel: server.name,
                    source: .webDAV(server: server, file: file), streamURL: url
                ))
            }
        }

        if cloud.hasKey {
            // Startup uses the persisted Offcloud history/files only. Network refresh
            // happens exclusively from pull-to-refresh or the refresh button.
            if force { await cloud.refreshAll() }
            for transfer in cloud.transfers where transfer.isDownloaded {
                for file in cloud.cachedVideoFiles(for: transfer) {
                    guard let url = file.streamURL else { continue }
                    raw.append(UnifiedMediaEntry(
                        id: "offcloud|\(transfer.requestId)|\(file.id)", rawTitle: file.name,
                        title: file.name, sourceLabel: "Offcloud",
                        source: .offcloud(transfer: transfer, file: file), streamURL: url
                    ))
                }
            }
        }

        let torBoxKey = TorBoxKeyStore.load()
        if !torBoxKey.isEmpty {
            var torrents = TorBoxLibraryStore.load()
            if force {
                do {
                    torrents = try await TorBoxClient(apiKey: torBoxKey).torrents(bypassCache: true)
                    TorBoxLibraryStore.save(torrents)
                    sourceSignature = baseSourceSignature + "|torbox:\(TorBoxLibraryStore.revision)"
                } catch {
                    status = error.localizedDescription
                }
            }
            for torrent in torrents where torrent.isReady {
                for file in torrent.videoFiles {
                    guard let url = URL(string: "torbox://torrent/\(torrent.id)/file/\(file.id)") else { continue }
                    raw.append(UnifiedMediaEntry(
                        id: "torbox|\(torrent.id)|\(file.id)", rawTitle: file.displayName,
                        title: file.displayName, sourceLabel: "TorBox",
                        source: .torBox(torrent: torrent, file: file), streamURL: url
                    ))
                }
            }
        }

        guard !raw.isEmpty else {
            movies = []; shows = []; unknown = []; loaded = true
            lastSourceSignature = sourceSignature; status = ""
            persistSnapshot()
            return
        }
        status = "Scanning files with TMDB…"

        // Match each cleaned title once. Episode packs can contain hundreds of files
        // that all resolve to the same show, so querying each file serially made the
        // Content screen appear to load forever.
        var representativeByKey: [String: UnifiedMediaEntry] = [:]
        for entry in raw { representativeByKey[metadataGroupKey(for: entry)] = entry }
        let representatives = Array(representativeByKey)
        var metadataByQuery: [String: TMDBTitleDetails] = [:]
        await withTaskGroup(of: (String, TMDBTitleDetails?).self) { group in
            var iterator = representatives.makeIterator()
            for _ in 0..<min(8, representatives.count) {
                guard let (key, entry) = iterator.next() else { break }
                let lookupTitle = metadataLookupTitle(for: entry)
                let preferredType = preferredMediaType(for: entry)
                group.addTask {
                    let details: TMDBTitleDetails?
                    if shouldFetchMetadata {
                        details = await TMDBService.shared.detailsOriginalFirst(for: lookupTitle, preferredMediaType: preferredType)
                    } else {
                        details = await TMDBService.shared.cachedDetailsOriginalFirst(for: lookupTitle, preferredMediaType: preferredType)
                    }
                    return (key, details)
                }
            }
            while let (key, details) = await group.next() {
                if let details { metadataByQuery[key] = details }
                if let (nextKey, nextEntry) = iterator.next() {
                    let lookupTitle = metadataLookupTitle(for: nextEntry)
                    let preferredType = preferredMediaType(for: nextEntry)
                    group.addTask {
                        let details: TMDBTitleDetails?
                        if shouldFetchMetadata {
                            details = await TMDBService.shared.detailsOriginalFirst(for: lookupTitle, preferredMediaType: preferredType)
                        } else {
                            details = await TMDBService.shared.cachedDetailsOriginalFirst(for: lookupTitle, preferredMediaType: preferredType)
                        }
                        return (nextKey, details)
                    }
                }
            }
        }

        // Keep completed adult matches while refreshing provider file lists.
        // Otherwise every manual refresh discarded the posters and immediately
        // launched the same large batch of ThePornDB requests again.
        let previousEntriesByID = Dictionary(
            (movies + shows + unknown).map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var movieItems: [UnifiedMediaEntry] = []
        var showEpisodes: [String: [(UnifiedMediaEntry, UnifiedEpisode)]] = [:]
        var unknownItems: [UnifiedMediaEntry] = []
        for var entry in raw {
            let query = metadataGroupKey(for: entry)
            entry.details = metadataByQuery[query]
            if let previous = previousEntriesByID[entry.id], previous.manualMetadataProvider != nil {
                entry.details = previous.details
                entry.adultScene = previous.adultScene
                entry.manualMetadataProvider = previous.manualMetadataProvider
                entry.title = previous.title
            }
            if let canonicalTitle = entry.details?.title, !canonicalTitle.isEmpty {
                entry.title = canonicalTitle
            }
            if let details = entry.details, details.isSeries {
                let parts = VideoTitleFormatter.episodeComponents(from: entry.rawTitle)
                let season = parts?.season ?? 1
                let episode = parts?.episode ?? 1
                let key = "tmdb|\(details.id)"
                let ep = UnifiedEpisode(id: entry.id, title: entry.rawTitle, season: season, episode: episode, source: entry.source, url: entry.streamURL)
                showEpisodes[key, default: []].append((entry, ep))
            } else if entry.details != nil {
                movieItems.append(entry)
            } else {
                if let previous = previousEntriesByID[entry.id] {
                    entry.adultScene = previous.adultScene
                    entry.adultLookupCompleted = previous.adultLookupCompleted
                    if previous.adultScene != nil { entry.title = previous.title }
                    // A previous metadata lookup may have completed while its
                    // image download failed. Manual refresh must retry those
                    // entries instead of preserving a permanently blank card.
                    let adultPosterKey = "unified-adult|\(entry.id)"
                    if force, VideoThumbnailLoader.cachedImage(forStableKey: adultPosterKey) == nil {
                        entry.adultLookupCompleted = nil
                    }
                }
                unknownItems.append(entry)
            }
        }

        var showItems: [UnifiedMediaEntry] = []
        for values in showEpisodes.values {
            guard var first = values.first?.0 else { continue }
            first.title = first.details?.title ?? first.title
            first.episodes = values.map(\.1).sorted { lhs, rhs in
                lhs.season == rhs.season ? lhs.episode < rhs.episode : lhs.season < rhs.season
            }
            showItems.append(first)
        }

        movies = deduplicatedMovies(movieItems).sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        shows = showItems.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        unknown = unknownItems.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }

        // Adult fallback runs after the usable Content screen has finished loading.
        // It also runs on the first normal scan; results are persisted below by
        // enrichUnknownWithAdultMetadata and are not requested again next launch.
        if ThePornDBSettings.hasValidAPIKey && !unknownItems.isEmpty {
            startAdultEnrichmentIfNeeded()
        }
        loaded = true
        lastSourceSignature = sourceSignature
        status = ""
        persistSnapshot()
    }

    private func persistSnapshot() {
        let snapshot = UnifiedContentSnapshot(movies: movies, shows: shows, unknown: unknown, sourceSignature: lastSourceSignature)
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        try? data.write(to: Self.snapshotURL, options: .atomic)
    }

    /// Swift's built-in `hashValue` changes between launches. A deterministic
    /// one-way signature lets us detect credential changes without persisting
    /// the TMDB token itself or forcing a full metadata rescan every launch.
    private static func stableSignature(_ value: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in value.utf8 { hash = (hash ^ UInt64(byte)) &* 1_099_511_628_211 }
        return String(hash, radix: 16)
    }

    private func preferredMediaType(for entry: UnifiedMediaEntry) -> String {
        if VideoTitleFormatter.episodeComponents(from: entry.rawTitle) != nil { return "tv" }
        let value = entry.rawTitle.lowercased()
        if value.range(of: #"\bseason[ ._-]*\d{1,3}\b"#, options: .regularExpression) != nil { return "tv" }
        return "movie"
    }

    private func metadataGroupKey(for entry: UnifiedMediaEntry) -> String {
        let cleaned = TMDBService.searchTitle(from: metadataLookupTitle(for: entry)).lowercased()
        if VideoTitleFormatter.episodeComponents(from: entry.rawTitle) != nil { return "episode|" + cleaned }
        return "file|" + entry.rawTitle.lowercased()
    }

    private func metadataLookupTitle(for entry: UnifiedMediaEntry) -> String {
        let cleanedFile = TMDBService.searchTitle(from: entry.rawTitle)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let genericEpisode = cleanedFile.isEmpty || cleanedFile.range(
            of: #"^(?:s\d{1,3}(?:e\d{1,3})?|e(?:pisode)?\s*\d{1,4}|\d{1,4})$"#,
            options: [.regularExpression, .caseInsensitive]
        ) != nil
        guard genericEpisode else { return entry.rawTitle }

        let sourcePath: String
        switch entry.source {
        case let .webDAV(_, file): sourcePath = file.path
        case let .offcloud(_, file): sourcePath = file.path ?? file.name
        case let .torBox(torrent, file): sourcePath = (torrent.name.map { $0 + "/" } ?? "") + (file.name ?? file.displayName)
        }
        let genericFolders: Set<String> = [
            "movie", "movies", "film", "films", "tv", "tv show", "tv shows", "series",
            "show", "shows", "video", "videos", "media", "downloads", "my pack", "pikpak",
            "offcloud", "english movies", "korean drama", "asian drama", "drama", "anime"
        ]
        let parents = sourcePath.replacingOccurrences(of: "\\", with: "/")
            .split(separator: "/").dropLast().reversed().map(String.init)
        for folder in parents {
            let cleaned = TMDBService.searchTitle(from: folder).trimmingCharacters(in: .whitespacesAndNewlines)
            let lower = cleaned.lowercased()
            let seasonOnly = lower.range(of: #"^(?:season\s*)?\d{1,3}$"#, options: .regularExpression) != nil
            if cleaned.count > 1, !genericFolders.contains(lower), !seasonOnly { return folder }
        }
        return entry.rawTitle
    }

    private func enrichUnknownWithAdultMetadata() async {
        var items = unknown
        // Process up to 200 still-pending entries per pass. Filtering the indices
        // first ensures libraries larger than 200 continue on later launches.
        let pendingIndices = Array(items.indices.filter { items[$0].adultLookupCompleted != true }.prefix(200))
        for index in pendingIndices {
            guard !Task.isCancelled else { return }
            // Match VideoDetailsView exactly. The former TMDB release-name
            // cleaner produced a different query for adult filenames, which is
            // why opening Details found a cover while Content refresh did not.
            let query = VideoTitleFormatter.title(from: items[index].title)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !query.isEmpty else {
                items[index].adultLookupCompleted = true
                continue
            }
            if let response = try? await ThePornDBAPIService.shared.searchScenes(query: query, limit: 5) {
                guard !Task.isCancelled else { return }
                items[index].adultLookupCompleted = true
                if let scene = bestAdultMatch(response.list, query: query) ?? response.list.first {
                    items[index].adultScene = scene
                    items[index].title = scene.title ?? items[index].title
                    let posterKey = "unified|\(items[index].id)"
                    let adultPosterKey = "unified-adult|\(items[index].id)"
                    if VideoThumbnailLoader.cachedImage(forStableKey: adultPosterKey) == nil,
                       let imageURL = scene.bestImage {
                        await ThumbnailLoadGate.shared.acquire()
                        let cover = try? await ThePornDBAPIService.shared.downloadImage(from: imageURL)
                        await ThumbnailLoadGate.shared.release()
                        guard !Task.isCancelled else { return }
                        if let cover {
                            VideoThumbnailLoader.cacheImage(cover, forStableKey: adultPosterKey)
                            VideoThumbnailLoader.cacheImage(cover, forStableKey: posterKey)
                            VideoThumbnailLoader.cacheImage(
                                cover,
                                forStableKey: VideoThumbnailLoader.canonicalPosterCacheKey(for: items[index].rawTitle)
                            )
                        }
                    }
                } else if let metadata = await VideoThumbnailLoader.fetchThePornDBMetadata(for: query) {
                    guard !Task.isCancelled else { return }
                    // No scene: use the shared performer fallback. Cache its image
                    // under the same stable key consumed by the Unknown poster grid.
                    items[index].title = metadata.title ?? items[index].title
                    if let cover = metadata.coverImage {
                        VideoThumbnailLoader.cacheImage(cover, forStableKey: "unified-adult|\(items[index].id)")
                        VideoThumbnailLoader.cacheImage(cover, forStableKey: "unified|\(items[index].id)")
                    }
                }
                unknown = items
                if index.isMultiple(of: 10) { persistSnapshot() }
            }
        }
        unknown = items.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        persistSnapshot()
    }

    func applyManualTMDB(_ details: TMDBTitleDetails, to entry: UnifiedMediaEntry) {
        guard var value = takeEntry(id: entry.id) else { return }
        value.details = details
        value.adultScene = nil
        value.title = details.title
        value.manualMetadataProvider = "tmdb"
        if details.isSeries {
            shows.append(value)
            shows.sort { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        } else {
            value.episodes = []
            movies.append(value)
            movies.sort { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        }
        persistSnapshot()
        if let posterURL = details.posterURL {
            Task {
                guard let (data, _) = try? await HighPriorityNetworkManager.shared.responsiveData(from: posterURL),
                      let image = UIImage(data: data) else { return }
                VideoThumbnailLoader.cacheImage(image, forStableKey: "unified-manual|\(entry.id)")
                VideoThumbnailLoader.cacheImage(image, forStableKey: "unified|\(entry.id)")
            }
        }
    }

    private static func removingUndersizedFiles(from entries: [UnifiedMediaEntry]) -> [UnifiedMediaEntry] {
        entries.compactMap { original in
            var entry = original
            entry.episodes.removeAll { !$0.source.isVisibleByFileSize }
            guard entry.source.isVisibleByFileSize || !entry.episodes.isEmpty else { return nil }
            return entry
        }
    }

    func applyManualAdult(_ scene: ThePornDBScene, image: UIImage, to entry: UnifiedMediaEntry) {
        guard var value = takeEntry(id: entry.id) else { return }
        value.details = nil
        value.adultScene = scene
        value.title = scene.title ?? value.title
        value.adultLookupCompleted = true
        value.manualMetadataProvider = "theporndb"
        value.episodes = []
        unknown.append(value)
        unknown.sort { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        persistSnapshot()
        VideoThumbnailLoader.cacheImage(image, forStableKey: "unified-manual|\(entry.id)")
        VideoThumbnailLoader.cacheImage(image, forStableKey: "unified-adult|\(entry.id)")
        VideoThumbnailLoader.cacheImage(image, forStableKey: "unified|\(entry.id)")
    }

    func applyManualCover(_ image: UIImage, to entry: UnifiedMediaEntry) {
        VideoThumbnailLoader.cacheImage(image, forStableKey: "unified-manual|\(entry.id)")
        VideoThumbnailLoader.cacheImage(image, forStableKey: "unified|\(entry.id)")
    }

    private func takeEntry(id: String) -> UnifiedMediaEntry? {
        if let index = movies.firstIndex(where: { $0.id == id }) { return movies.remove(at: index) }
        if let index = shows.firstIndex(where: { $0.id == id }) { return shows.remove(at: index) }
        if let index = unknown.firstIndex(where: { $0.id == id }) { return unknown.remove(at: index) }
        return nil
    }

    private func startAdultEnrichmentIfNeeded() {
        guard ThePornDBSettings.hasValidAPIKey,
              unknown.contains(where: { $0.adultLookupCompleted != true }),
              adultEnrichmentTask == nil else { return }
        adultEnrichmentTask = Task { [weak self] in
            guard let self else { return }
            await self.enrichUnknownWithAdultMetadata()
            guard !Task.isCancelled else { return }
            self.adultEnrichmentTask = nil
        }
    }

    private func bestAdultMatch(_ scenes: [ThePornDBScene], query: String) -> ThePornDBScene? {
        let queryTokens = metadataTokens(query)
        guard !queryTokens.isEmpty else { return nil }
        return scenes.map { scene -> (ThePornDBScene, Double) in
            let tokens = metadataTokens(scene.title ?? "")
            let overlap = queryTokens.intersection(tokens).count
            return (scene, Double(overlap) / Double(max(1, min(queryTokens.count, tokens.count))))
        }.filter { $0.1 >= 0.5 }.max { $0.1 < $1.1 }?.0
    }

    private func metadataTokens(_ value: String) -> Set<String> {
        Set(value.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count > 2 && Int($0) == nil })
    }

    private func deduplicatedMovies(_ entries: [UnifiedMediaEntry]) -> [UnifiedMediaEntry] {
        var seen = Set<String>()
        return entries.filter { entry in
            let key = entry.details.map { "tmdb|\($0.id)" } ?? entry.id
            return seen.insert(key).inserted
        }
    }
}

private enum UnifiedManualSearchKind {
    case tmdb, adult, cover
}

private struct UnifiedManualSearchRequest: Identifiable {
    let id = UUID()
    let entry: UnifiedMediaEntry
    let kind: UnifiedManualSearchKind
}

struct UnifiedContentView: View {
    @ObservedObject var vm: AppViewModel
    @ObservedObject var model: UnifiedContentModel
    var isActive: Bool
    @State private var section: UnifiedMediaSection = .movies
    @State private var selected: UnifiedMediaEntry?
    @State private var showPlayer = false
    @State private var manualSearch: UnifiedManualSearchRequest?
    @Namespace private var selectionAnimation

    private let columns = Array(
        repeating: GridItem(.flexible(), spacing: 12, alignment: .top),
        count: 3
    )

    var body: some View {
        NavigationStack {
            ZStack {
                AppTheme.bg.ignoresSafeArea()
                ScrollView {
                    VStack(spacing: 16) {
                        sectionPicker
                        if model.isLoading && currentEntries.isEmpty {
                            VStack(spacing: 14) {
                                ProgressView().tint(AppPalette.accent).scaleEffect(1.15)
                                Text(model.status).font(.subheadline).foregroundStyle(.secondary)
                            }.frame(maxWidth: .infinity).padding(.top, 90)
                        } else if currentEntries.isEmpty {
                            emptyState
                        } else {
                            LazyVGrid(columns: columns, spacing: 18) { ForEach(currentEntries) { posterCard($0) } }
                        }
                    }.padding(.horizontal, 14).padding(.bottom, 110)
                }
                .scrollIndicators(.hidden)
                .refreshable { await model.load(vm: vm, force: true) }
            }
            .navigationTitle("Content")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { Task { await model.load(vm: vm, force: true) } } label: { Image(systemName: "arrow.clockwise") }
                }
            }
            .task(id: contentRefreshID) { if isActive { await model.load(vm: vm, force: false) } }
            .fullScreenCover(item: $selected) { entry in detailsHost(entry) }
            .fullScreenCover(isPresented: $showPlayer) { ResolvedPlayerScreen(vm: vm) }
            .sheet(item: $manualSearch) { request in
                manualSearchSheet(request)
            }
        }
    }

    private var contentRefreshID: String {
        "\(isActive)|" + vm.servers.map {
            $0.id.uuidString + $0.displayAddress + WebDAVContentSelectionStore.revision(for: $0.id)
        }.joined(separator: "|") + "|torbox:\(TorBoxLibraryStore.revision)"
    }

    private var currentEntries: [UnifiedMediaEntry] {
        switch section { case .movies: return model.movies; case .shows: return model.shows; case .unknown: return model.unknown }
    }

    private var sectionPicker: some View {
        HStack(spacing: 6) {
            ForEach(UnifiedMediaSection.allCases) { value in
                Button {
                    withAnimation(.spring(response: 0.34, dampingFraction: 0.84)) { section = value }
                } label: {
                    Label(value.rawValue, systemImage: value.icon)
                        .font(.system(size: 12, weight: .bold)).lineLimit(1)
                        .foregroundStyle(section == value ? .white : .secondary)
                        .frame(maxWidth: .infinity).padding(.vertical, 10)
                        .background {
                            if section == value {
                                Capsule().fill(AppPalette.gradient).matchedGeometryEffect(id: "content-section", in: selectionAnimation)
                            }
                        }
                }.buttonStyle(.plain)
            }
        }.padding(5).background(.ultraThinMaterial, in: Capsule())
    }

    private func posterCard(_ entry: UnifiedMediaEntry) -> some View {
        Button { selected = entry } label: {
            VStack(alignment: .leading, spacing: 7) {
                ZStack {
                    RoundedRectangle(cornerRadius: 14).fill(Color.white.opacity(0.07))
                    UnifiedPosterArtwork(entry: entry, section: section)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .clipped()
                }
                .aspectRatio(2/3, contentMode: .fit)
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 14))
                Text(entry.title)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if !entry.episodes.isEmpty { Text("\(entry.episodes.count) episodes").font(.caption2).foregroundStyle(AppPalette.accent) }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button {
                manualSearch = UnifiedManualSearchRequest(entry: entry, kind: .tmdb)
            } label: {
                Label("Search Movie / TV Metadata", systemImage: "film.stack")
            }
            Button {
                manualSearch = UnifiedManualSearchRequest(entry: entry, kind: .adult)
            } label: {
                Label("Search Adult Metadata", systemImage: "person.crop.rectangle.stack")
            }
            Button {
                manualSearch = UnifiedManualSearchRequest(entry: entry, kind: .cover)
            } label: {
                Label("Search Cover Only", systemImage: "photo.on.rectangle.angled")
            }
        }
    }

    @ViewBuilder
    private func manualSearchSheet(_ request: UnifiedManualSearchRequest) -> some View {
        switch request.kind {
        case .tmdb:
            UnifiedTMDBManualSearchView(initialQuery: VideoTitleFormatter.title(from: request.entry.title)) { details in
                model.applyManualTMDB(details, to: request.entry)
                manualSearch = nil
            }
        case .adult:
            ThePornDBSearchView(
                initialQuery: VideoTitleFormatter.title(from: request.entry.title),
                initialMode: .scenes,
                onPickScene: { scene, image in
                    model.applyManualAdult(scene, image: image, to: request.entry)
                    manualSearch = nil
                }
            ) { image in
                model.applyManualCover(image, to: request.entry)
                manualSearch = nil
            }
        case .cover:
            YandexImageSearchView(initialQuery: VideoTitleFormatter.title(from: request.entry.title)) { image in
                model.applyManualCover(image, to: request.entry)
                manualSearch = nil
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: section.icon)
                .font(.system(size: 42, weight: .semibold))
                .foregroundStyle(AppPalette.gradient)
            Text(section == .unknown ? "No Unknown Content" : "No \(section.rawValue)")
                .font(.title3.weight(.bold))
            Text("Pull to refresh after adding WebDAV, Offcloud, or TorBox in Home settings.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 30)
        .padding(.top, 70)
    }

    @ViewBuilder private func detailsHost(_ entry: UnifiedMediaEntry) -> some View {
        UnifiedMediaDetailsHost(vm: vm, entry: entry)
    }

    private func play(_ source: UnifiedSource) {
        switch source {
        case let .webDAV(server, file): vm.play(file: file, server: server)
        case let .offcloud(_, file):
            guard let url = file.streamURL else { return }
            if let saved = vm.saveDirectLink(url.absoluteString, resolvedStream: url, source: .offcloud, title: file.name) {
                vm.playSavedLink(saved)
            } else {
                _ = vm.playOnlineURL(url.absoluteString)
            }
        case let .torBox(torrent, file):
            Task { @MainActor in
                guard await vm.playTorBoxFile(torrentId: torrent.id, file: file) else { return }
                showPlayer = true
            }
            return
        }
        showPlayer = true
    }
}

/// Unknown posters can arrive either from the background ThePornDB refresh or
/// from VideoDetailsView. This view observes the shared stable-poster event so
/// the visible grid updates immediately without requiring a tab/page reload.
struct UnifiedPosterArtwork: View {
    let entry: UnifiedMediaEntry
    let section: UnifiedMediaSection
    @State private var cachedImage: UIImage?

    private var cacheKey: String { "unified|\(entry.id)" }
    private var adultCacheKey: String { "unified-adult|\(entry.id)" }
    private var manualCacheKey: String { "unified-manual|\(entry.id)" }

    init(entry: UnifiedMediaEntry, section: UnifiedMediaSection) {
        self.entry = entry
        self.section = section
        _cachedImage = State(initialValue: nil)
    }

    var body: some View {
        Group {
            if let cachedImage {
                Image(uiImage: cachedImage)
                    .resizable()
                    .scaledToFill()
            } else if let url = entry.posterURL {
                KFImage(url)
                    .placeholder { ProgressView().tint(AppPalette.accent) }
                    .cacheOriginalImage()
                    .fade(duration: 0.12)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "film.fill")
                    .font(.title)
                    .foregroundStyle(AppPalette.gradient)
            }
        }
        .task(id: "\(section.rawValue)|\(manualCacheKey)") {
            if section == .unknown { await loadVisiblePosterIfNeeded() }
            else {
                cachedImage = await cachedPoster(includeAdult: false)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: VideoThumbnailLoader.stablePosterDidUpdateNotification)) { notification in
            guard let updatedKey = notification.object as? String,
                  updatedKey == manualCacheKey || updatedKey == adultCacheKey || updatedKey == cacheKey else { return }
            Task {
                cachedImage = await cachedPoster(includeAdult: section == .unknown)
            }
        }
    }

    private func cachedPoster(includeAdult: Bool) async -> UIImage? {
        if let manual = await VideoThumbnailLoader.cachedImageAsync(forStableKey: manualCacheKey) {
            return manual
        }
        if includeAdult,
           let adult = await VideoThumbnailLoader.cachedImageAsync(forStableKey: adultCacheKey) {
            return adult
        }
        // `unified|…` was previously shared with the wide details backdrop.
        // Grid cards must use only a manual/adult cover or the vertical API poster.
        return nil
    }

    private func loadVisiblePosterIfNeeded() async {
        if let existing = await cachedPoster(includeAdult: true) {
            cachedImage = existing
            return
        }

        let query = VideoTitleFormatter.title(from: entry.title)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, ThePornDBSettings.hasValidAPIKey else {
            return
        }

        // LazyVGrid creates this task only for visible/near-visible cards. The
        // shared gate bounds all screens together and the second cache check
        // avoids work if the model refresh completed while this card waited.
        await ThumbnailLoadGate.shared.acquire()
        if let existing = await VideoThumbnailLoader.cachedImageAsync(forStableKey: adultCacheKey) {
            await ThumbnailLoadGate.shared.release()
            cachedImage = existing
            return
        }
        let cover = await VideoThumbnailLoader.fetchThePornDBMetadata(for: query)?.coverImage
        await ThumbnailLoadGate.shared.release()

        guard !Task.isCancelled else { return }
        if let cover {
            VideoThumbnailLoader.cacheImageInBackground(cover, forStableKey: adultCacheKey)
            VideoThumbnailLoader.cacheImageInBackground(cover, forStableKey: cacheKey)
            VideoThumbnailLoader.cacheImageInBackground(
                cover,
                forStableKey: VideoThumbnailLoader.canonicalPosterCacheKey(for: entry.title)
            )
            cachedImage = cover
        } else {
            cachedImage = nil
        }
    }
}

private struct UnifiedTMDBManualSearchView: View {
    let onApply: (TMDBTitleDetails) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var query: String
    @State private var mediaType: String? = nil
    @State private var result: TMDBTitleDetails?
    @State private var isSearching = false
    @State private var message: String?
    @State private var searchTask: Task<Void, Never>?

    init(initialQuery: String, onApply: @escaping (TMDBTitleDetails) -> Void) {
        self.onApply = onApply
        _query = State(initialValue: initialQuery)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 14) {
                Picker("Type", selection: $mediaType) {
                    Text("Any").tag(nil as String?)
                    Text("Movie").tag("movie" as String?)
                    Text("TV Show").tag("tv" as String?)
                }
                .pickerStyle(.segmented)

                HStack(spacing: 10) {
                    TextField("Movie or TV title", text: $query)
                        .textInputAutocapitalization(.words)
                        .submitLabel(.search)
                        .onSubmit(search)
                        .padding(.horizontal, 13)
                        .frame(height: 44)
                        .background(AppTheme.card, in: RoundedRectangle(cornerRadius: 12))
                    Button(action: search) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 15, weight: .bold))
                            .frame(width: 44, height: 44)
                            .foregroundStyle(.white)
                            .background(AppPalette.gradient, in: RoundedRectangle(cornerRadius: 12))
                    }
                    .buttonStyle(.plain)
                }

                if isSearching {
                    ProgressView("Searching TMDB…")
                        .tint(AppPalette.accent)
                        .frame(maxHeight: .infinity)
                } else if let result {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 13) {
                            HStack(alignment: .top, spacing: 13) {
                                KFImage(result.posterURL)
                                    .placeholder { Color.white.opacity(0.06) }
                                    .resizable()
                                    .scaledToFill()
                                    .frame(width: 105, height: 157)
                                    .clipShape(RoundedRectangle(cornerRadius: 12))
                                VStack(alignment: .leading, spacing: 7) {
                                    Text(result.title).font(.headline)
                                    Text(result.isSeries ? "TV Show" : "Movie")
                                        .font(.caption.bold()).foregroundStyle(AppPalette.accent)
                                    if let date = result.releaseDate { Text(date).font(.caption).foregroundStyle(.secondary) }
                                    if result.voteAverage > 0 {
                                        Label(String(format: "%.1f", result.voteAverage), systemImage: "star.fill")
                                            .font(.caption.bold()).foregroundStyle(.yellow)
                                    }
                                }
                            }
                            if !result.overview.isEmpty {
                                Text(result.overview).font(.subheadline).foregroundStyle(.white.opacity(0.75))
                            }
                            Button {
                                onApply(result)
                                dismiss()
                            } label: {
                                Label("Apply Metadata", systemImage: "checkmark.circle.fill")
                                    .font(.headline).frame(maxWidth: .infinity).padding(.vertical, 13)
                                    .foregroundStyle(.white).background(AppPalette.gradient, in: RoundedRectangle(cornerRadius: 13))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                } else {
                    VStack(spacing: 12) {
                        Image(systemName: "film.stack")
                            .font(.system(size: 42, weight: .medium))
                            .foregroundStyle(AppPalette.gradient)
                        Text("Search TMDB").font(.title3.bold())
                        Text(message ?? "Enter the correct title, then apply the matching metadata.")
                            .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .padding(16)
            .background(AppTheme.bg.ignoresSafeArea())
            .navigationTitle("Manual Metadata")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Cancel") { dismiss() } }
            }
            .onDisappear { searchTask?.cancel() }
        }
        .preferredColorScheme(.dark)
    }

    private func search() {
        let value = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        searchTask?.cancel()
        isSearching = true
        result = nil
        message = nil
        searchTask = Task {
            let found = await TMDBService.shared.detailsOriginalFirst(for: value, preferredMediaType: mediaType)
            guard !Task.isCancelled else { return }
            result = found
            message = found == nil ? "No matching result was found." : nil
            isSearching = false
        }
    }
}

@MainActor private final class UnifiedEpisodeSelection: ObservableObject {
    @Published var id: String?
    init(id: String? = nil) { self.id = id }
}

struct UnifiedMediaDetailsHost: View {
    @ObservedObject var vm: AppViewModel
    let entry: UnifiedMediaEntry
    @StateObject private var selection: UnifiedEpisodeSelection
    @State private var showPlayer = false

    init(vm: AppViewModel, entry: UnifiedMediaEntry) {
        self.vm = vm
        self.entry = entry
        _selection = StateObject(wrappedValue: UnifiedEpisodeSelection(id: entry.episodes.first?.id))
    }

    private var selectedEpisode: UnifiedEpisode? {
        guard let selectedEpisodeID = selection.id else { return nil }
        return entry.episodes.first { $0.id == selectedEpisodeID }
    }

    var body: some View {
        VideoDetailsView(
            vm: vm,
            item: currentDetailsItem,
            onPlay: playCurrent,
            dismissOnPlay: false,
            onSelectEpisode: { episodeID in
                guard selection.id != episodeID else { return }
                selection.id = episodeID
            }
        )
        .fullScreenCover(isPresented: $showPlayer) { ResolvedPlayerScreen(vm: vm) }
    }

    private var relatedEpisodes: [VideoEpisodeItem] {
        entry.episodes.map {
            VideoEpisodeItem(id: $0.id, title: $0.title, season: $0.season, episode: $0.episode)
        }
    }

    private var currentDetailsItem: VideoDetailsItem {
        if let episode = selectedEpisode {
            return VideoDetailsItem(
                id: episode.id, title: episode.title, url: episode.url,
                httpHeaders: playbackHeaders(for: episode.source),
                // Every episode shares the series artwork/metadata identity. The
                // selected file and S/E label change, but story/rating/cast do not.
                posterCacheKey: "unified|\(entry.id)",
                fileExtension: (episode.title as NSString).pathExtension.uppercased(),
                source: entry.sourceLabel, relatedEpisodes: relatedEpisodes,
                suppliedTMDBDetails: entry.details,
                suppliedAdultMetadata: suppliedAdultMetadata,
                manualMetadataProvider: entry.manualMetadataProvider
            )
        }
        return VideoDetailsItem(
            id: entry.id, title: entry.title, url: entry.streamURL,
            httpHeaders: playbackHeaders(for: entry.source),
            posterCacheKey: "unified|\(entry.id)",
            fileExtension: (entry.rawTitle as NSString).pathExtension.uppercased(),
            source: entry.sourceLabel, relatedEpisodes: relatedEpisodes,
            suppliedTMDBDetails: entry.details,
            suppliedAdultMetadata: suppliedAdultMetadata,
            manualMetadataProvider: entry.manualMetadataProvider
        )
    }

    private func playbackHeaders(for source: UnifiedSource) -> [String: String] {
        guard case let .webDAV(server, _) = source else { return [:] }
        return WebDAVClient(server: server).streamHeaders()
    }

    private var suppliedAdultMetadata: VideoThumbnailLoader.ThePornDBMetadata? {
        guard let scene = entry.adultScene else { return nil }
        let cover = VideoThumbnailLoader.cachedImage(forStableKey: "unified-manual|\(entry.id)")
            ?? VideoThumbnailLoader.cachedImage(forStableKey: "unified-adult|\(entry.id)")
            ?? VideoThumbnailLoader.cachedImage(forStableKey: "unified|\(entry.id)")
        return VideoThumbnailLoader.ThePornDBMetadata(
            source: .scene,
            title: scene.title,
            performers: (scene.performers ?? []).compactMap(\.name),
            tags: scene.tagNames,
            date: scene.date,
            siteName: scene.site,
            coverImage: cover
        )
    }

    private func playCurrent() {
        let source = selectedEpisode?.source ?? entry.source
        switch source {
        case let .webDAV(server, file): vm.play(file: file, server: server)
        case let .offcloud(_, file):
            guard let url = file.streamURL else { return }
            if let saved = vm.saveDirectLink(url.absoluteString, resolvedStream: url, source: .offcloud, title: file.name) {
                vm.playSavedLink(saved)
            } else { _ = vm.playOnlineURL(url.absoluteString) }
        case let .torBox(torrent, file):
            Task { @MainActor in
                guard await vm.playTorBoxFile(torrentId: torrent.id, file: file) else { return }
                showPlayer = true
            }
            return
        }
        showPlayer = true
    }
}

struct UnifiedSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var vm: AppViewModel
    @StateObject private var cloud = OffcloudViewModel()
    @State private var offcloudKey = ""
    @State private var torBoxKey = ""
    @State private var torBoxStatus = ""
    @State private var isSavingTorBox = false
    @State private var destination: SettingsDestination?

    private enum SettingsDestination: String, Identifiable {
        case webdav, offcloud, torbox, tmdb, adult
        var id: String { rawValue }
    }

    var body: some View {
        NavigationStack {
            List {
                Section("Cloud Sources") {
                    settingsRow("WebDAV", "Connect PikPak or another WebDAV server", "externaldrive.connected.to.line.below", .webdav)
                    settingsRow("Offcloud", "Add or update the Offcloud API key", "cloud.fill", .offcloud)
                    settingsRow("TorBox", "Connect your TorBox account and library", "shippingbox.fill", .torbox)
                }
                Section("Metadata") {
                    settingsRow("TMDB", "Movies and TV metadata — first priority", "film.stack.fill", .tmdb)
                    settingsRow("ThePornDB", "Temporarily paused — TMDB only mode", "pause.circle.fill", .adult)
                }
                Section {
                    Text("TMDB is currently the only active metadata provider. Original file names are sent without release-keyword filtering. Unmatched files remain in Unknown.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Settings")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .sheet(item: $destination) { item in destinationView(item) }
            .onAppear { offcloudKey = cloud.apiKey; torBoxKey = TorBoxKeyStore.load() }
        }.preferredColorScheme(.dark)
    }

    private func settingsRow(_ title: String, _ subtitle: String, _ icon: String, _ target: SettingsDestination) -> some View {
        Button { destination = target } label: {
            HStack(spacing: 13) {
                Image(systemName: icon).frame(width: 28).foregroundStyle(AppPalette.gradient)
                VStack(alignment: .leading, spacing: 3) { Text(title).foregroundStyle(.primary); Text(subtitle).font(.caption).foregroundStyle(.secondary) }
                Spacer(); Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
            }.padding(.vertical, 3)
        }
    }

    @ViewBuilder private func destinationView(_ item: SettingsDestination) -> some View {
        switch item {
        case .webdav: WebDAVSettingsView(vm: vm)
        case .tmdb: TMDBSettingsView()
        case .adult: ThePornDBSettingsView()
        case .torbox:
            NavigationStack {
                Form {
                    Section("TorBox Account") {
                        SecureField("API Key", text: $torBoxKey).textContentType(.password)
                        Text("The key is verified with TorBox and stored securely in the iPhone Keychain.").font(.caption).foregroundStyle(.secondary)
                    }
                    if !torBoxStatus.isEmpty {
                        Section { Text(torBoxStatus).font(.footnote).foregroundStyle(.secondary) }
                    }
                    Section {
                        Button {
                            saveTorBoxAccount()
                        } label: {
                            if isSavingTorBox { HStack { ProgressView(); Text("Connecting…") } }
                            else { Text("Save and Sync TorBox") }
                        }
                        .disabled(isSavingTorBox || torBoxKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        if !TorBoxKeyStore.load().isEmpty {
                            Button("Remove TorBox Account", role: .destructive) {
                                _ = TorBoxKeyStore.delete(); TorBoxLibraryStore.clear(); torBoxKey = ""; torBoxStatus = ""
                            }
                        }
                    }
                }.navigationTitle("TorBox Settings").navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { destination = nil } } }
            }.preferredColorScheme(.dark)
        case .offcloud:
            NavigationStack {
                Form {
                    Section("Offcloud API") {
                        SecureField("API Key", text: $offcloudKey).textContentType(.password)
                        Text("The key is stored securely in the iPhone Keychain.").font(.caption).foregroundStyle(.secondary)
                    }
                    Section {
                        Button("Save API Key") { cloud.saveKey(offcloudKey); destination = nil }.disabled(offcloudKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        if cloud.hasKey { Button("Remove API Key", role: .destructive) { cloud.clearKey(); offcloudKey = "" } }
                    }
                }.navigationTitle("Offcloud Settings").navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { destination = nil } } }
            }.preferredColorScheme(.dark)
        }
    }

    private func saveTorBoxAccount() {
        let key = torBoxKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        isSavingTorBox = true
        torBoxStatus = "Checking account…"
        Task { @MainActor in
            do {
                let client = TorBoxClient(apiKey: key)
                try await client.validate()
                let torrents = try await client.torrents(bypassCache: true)
                guard TorBoxKeyStore.save(key) else { throw TorBoxError.invalidResponse }
                TorBoxLibraryStore.save(torrents)
                torBoxStatus = "Connected · \(torrents.count) torrents synced"
                isSavingTorBox = false
                try? await Task.sleep(nanoseconds: 700_000_000)
                destination = nil
            } catch {
                torBoxStatus = error.localizedDescription
                isSavingTorBox = false
            }
        }
    }
}
