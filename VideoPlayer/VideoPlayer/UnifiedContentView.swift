import SwiftUI
import UIKit
import Kingfisher
import UniformTypeIdentifiers

enum UnifiedMediaSection: String, CaseIterable, Identifiable {
    case movies = "Movies"
    case shows = "TV Shows"
    case unknown = "Others"
    var id: String { rawValue }
    var icon: String {
        switch self { case .movies: return "film.fill"; case .shows: return "tv.fill"; case .unknown: return "questionmark.folder.fill" }
    }
}

enum UnifiedSource: Codable {
    case webDAV(server: WebDAVServer, file: WebDAVFile)
    case offcloud(transfer: OffcloudTransfer, file: OffcloudFile)
    case torBox(torrent: TorBoxTorrent, file: TorBoxFile)
    case catalog(mediaType: String, tmdbID: Int)

    var isVisibleByFileSize: Bool {
        switch self {
        case let .webDAV(_, file): return VideoLibraryVisibility.allows(sizeBytes: file.size)
        case let .offcloud(_, file): return VideoLibraryVisibility.allows(sizeBytes: file.size)
        case let .torBox(_, file): return VideoLibraryVisibility.allows(sizeBytes: file.size)
        case .catalog: return true
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
    var manualMetadataProvider: String?
    /// False means the file was published immediately and its TMDB lookup is
    /// still queued in the background. Nil is reserved for legacy snapshots.
    var metadataLookupCompleted: Bool? = nil
    var episodes: [UnifiedEpisode] = []
    var posterURL: URL? {
        details?.posterURL
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

private struct UnifiedContentSnapshot: Codable, @unchecked Sendable {
    let movies: [UnifiedMediaEntry]
    let shows: [UnifiedMediaEntry]
    let unknown: [UnifiedMediaEntry]
    let sourceSignature: String?
    let metadataSignature: String?
}

func restoredCatalogEntry(from link: SavedVideoLink) -> UnifiedMediaEntry? {
    guard let identity = link.favoriteIdentity,
          identity.hasPrefix("catalog|tmdb|") else { return nil }
    let parts = identity.split(separator: "|").map(String.init)
    guard parts.count == 4,
          (parts[2] == "movie" || parts[2] == "tv"),
          let tmdbID = Int(parts[3]),
          let url = URL(string: "catalog://tmdb/\(parts[2])/\(tmdbID)") else { return nil }
    return UnifiedMediaEntry(
        id: identity,
        rawTitle: link.title,
        title: link.displayTitle,
        sourceLabel: "Orion Catalog",
        source: .catalog(mediaType: parts[2], tmdbID: tmdbID),
        streamURL: url,
        details: nil,
        metadataLookupCompleted: true
    )
}

/// JSON encoding and atomic disk writes can take multiple frames for a large
/// library. Serialize them on an actor that never occupies SwiftUI's executor.
private actor UnifiedContentSnapshotWriter {
    private var latestRevision = 0

    func persist(_ snapshot: UnifiedContentSnapshot, to url: URL, revision: Int) {
        guard revision > latestRevision else { return }
        latestRevision = revision
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        try? data.write(to: url, options: .atomic)
    }
}

private struct EpisodeMetadataBatch {
    let seriesEntryID: String
    let tmdbSeriesID: Int
    let season: Int
    let episodeNumbers: [Int]

    var identity: String {
        "\(tmdbSeriesID)|s\(season)|" + episodeNumbers.map(String.init).joined(separator: ",")
    }
}

private struct DetailsArtworkRequest: Sendable {
    let entryID: String
    let cacheKey: String
    let url: URL
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
    private var lastMetadataSignature = ""
    private var metadataEnrichmentTask: Task<Void, Never>?
    private var episodeEnrichmentTask: Task<Void, Never>?
    private var detailsArtworkTask: Task<Void, Never>?
    private var prioritizedEpisodeSeries: Set<String> = []
    private var prioritizedDetailsArtwork: Set<String> = []
    private var pendingForcedRefresh = false
    private let cloud = OffcloudViewModel()
    private let snapshotWriter = UnifiedContentSnapshotWriter()
    private var snapshotRevision = 0
    private var metadataGeneration = 0
    private var snapshotRestoreTask: Task<UnifiedContentSnapshot?, Never>?
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
        let url = Self.snapshotURL
        snapshotRestoreTask = Task.detached(priority: .userInitiated) {
            guard let data = try? Data(contentsOf: url) else { return nil }
            return try? JSONDecoder().decode(UnifiedContentSnapshot.self, from: data)
        }
    }

    private func restoreSnapshotIfNeeded() async {
        guard let task = snapshotRestoreTask else { return }
        if let snapshot = await task.value {
            movies = Self.removingUndersizedFiles(from: snapshot.movies)
            shows = Self.removingUndersizedFiles(from: snapshot.shows)
            unknown = Self.removingUndersizedFiles(from: snapshot.unknown)
            lastSourceSignature = snapshot.sourceSignature ?? ""
            lastMetadataSignature = snapshot.metadataSignature ?? Self.currentMetadataSignature()
            loaded = true
        }
        snapshotRestoreTask = nil
    }

    func load(vm: AppViewModel, force: Bool = false) async {
        await restoreSnapshotIfNeeded()
        if isLoading {
            // Pull-to-refresh or a newly added provider must never be discarded
            // just because an older scan is still finishing.
            if force { pendingForcedRefresh = true }
            return
        }
        if force {
            metadataEnrichmentTask?.cancel()
            metadataEnrichmentTask = nil
            metadataGeneration &+= 1
            episodeEnrichmentTask?.cancel()
            episodeEnrichmentTask = nil
            detailsArtworkTask?.cancel()
            detailsArtworkTask = nil
        }
        let metadataSignature = Self.currentMetadataSignature()
        let baseSourceSignature = vm.servers.map {
            $0.id.uuidString + $0.displayAddress + WebDAVContentSelectionStore.revision(for: $0.id)
        }.joined(separator: "|") + "|metadata:" + metadataSignature
        var sourceSignature = baseSourceSignature + "|torbox:\(TorBoxLibraryStore.revision)"
        // A loaded library is immutable until the user explicitly refreshes.
        // Saving a new WebDAV folder changes the selection revision immediately;
        // it must not trigger an automatic scan that temporarily replaces/empties
        // Home. The next manual refresh performs the append-only discovery pass.
        let hasInterruptedMetadataQueue = (movies + shows + unknown)
            .contains(where: { $0.metadataLookupCompleted == false })
        if loaded && !force && metadataEnrichmentTask != nil { return }
        if loaded && !force && !hasInterruptedMetadataQueue {
            if metadataEnrichmentTask == nil {
                _ = startEpisodeEnrichmentIfNeeded()
                startDetailsArtworkPrefetchIfNeeded()
            }
            return
        }
        isLoading = true
        status = "Scanning connected libraries…"
        defer {
            isLoading = false
            if pendingForcedRefresh {
                pendingForcedRefresh = false
                Task { @MainActor [weak self, weak vm] in
                    guard let self, let vm else { return }
                    await self.load(vm: vm, force: true)
                }
            }
        }

        // Settings and provider screens use their own OffcloudViewModel. Reload
        // the persisted account/files before every catalog scan so this shared
        // Home/Content model cannot keep an old in-memory provider snapshot.
        await cloud.reloadPersistedState()

        let existingLibraryEntries = movies + shows + unknown
        var raw: [UnifiedMediaEntry] = []
        for server in vm.servers {
            let files = await vm.contentLibraryFiles(server: server, forceRefresh: force)
            let client = WebDAVClient(server: server)
            for (index, file) in files.enumerated() {
                guard file.isVideo && !file.isDirectory else { continue }
                guard let url = client.streamURL(for: file) else { continue }
                raw.append(UnifiedMediaEntry(
                    id: "webdav|\(server.id.uuidString)|\(file.path)", rawTitle: file.name,
                    title: file.name, sourceLabel: server.name,
                    source: .webDAV(server: server, file: file), streamURL: url
                ))
                if index.isMultiple(of: 64) { await Task.yield() }
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
            var torrents = await Task.detached(priority: .utility) {
                TorBoxLibraryStore.load()
            }.value
            if force {
                do {
                    torrents = try await TorBoxClient(apiKey: torBoxKey).torrents(bypassCache: true)
                    let values = torrents
                    await Task.detached(priority: .utility) {
                        TorBoxLibraryStore.save(values)
                    }.value
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

        if loaded {
            // Every scan of an existing library is discovery-only. Preserve every
            // previously indexed WebDAV file and append newly scanned paths, even
            // when a selected folder is new, empty, slow, or temporarily times out.
            // Series aggregates are expanded back into their episode files first.
            let configuredServerIDs = Set(vm.servers.map(\.id))
            let preservedWebDAVEntries = existingLibraryEntries.flatMap { entry -> [UnifiedMediaEntry] in
                if !entry.episodes.isEmpty {
                    return entry.episodes.compactMap { episode in
                        guard case let .webDAV(server, file) = episode.source,
                              configuredServerIDs.contains(server.id) else { return nil }
                        return UnifiedMediaEntry(
                            id: episode.id,
                            // Episode enrichment may replace `episode.title` with
                            // the localized API name. Classification must continue
                            // using the original filename so SxxExx survives refresh.
                            rawTitle: file.name,
                            title: entry.title,
                            sourceLabel: entry.sourceLabel,
                            source: episode.source,
                            streamURL: episode.url,
                            details: entry.details,
                            manualMetadataProvider: entry.manualMetadataProvider,
                            metadataLookupCompleted: entry.metadataLookupCompleted
                        )
                    }
                }
                guard case let .webDAV(server, _) = entry.source,
                      configuredServerIDs.contains(server.id) else { return [] }
                return [entry]
            }
            var entriesByID = Dictionary(
                preservedWebDAVEntries.map { ($0.id, $0) },
                uniquingKeysWith: { existing, _ in existing }
            )
            for entry in raw where entriesByID[entry.id] == nil {
                entriesByID[entry.id] = entry
            }
            raw = Array(entriesByID.values)
        }

        guard !raw.isEmpty else {
            movies = []; shows = []; unknown = []; loaded = true
            lastSourceSignature = sourceSignature
            lastMetadataSignature = metadataSignature
            status = ""
            persistSnapshot()
            return
        }
        status = "Indexing new files…"

        let previousLibraryEntries = movies + shows + unknown
        let previousMetadataSignature = lastMetadataSignature
        let previousEntriesByID = Dictionary(
            previousLibraryEntries.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let previousMetadataByQuery = Dictionary(
            previousLibraryEntries.compactMap { entry in
                entry.details.map { (metadataGroupKey(for: entry), $0) }
            },
            uniquingKeysWith: { first, _ in first }
        )
        let previouslyScannedQueries = Set(
            previousLibraryEntries
                .filter { $0.metadataLookupCompleted != false }
                .map { metadataGroupKey(for: $0) }
        )

        // Match each cleaned title once. Episode packs can contain hundreds of files
        // that all resolve to the same show, so querying each file serially made the
        // Content screen appear to load forever.
        var representativeByKey: [String: UnifiedMediaEntry] = [:]
        for (index, entry) in raw.enumerated() {
            representativeByKey[metadataGroupKey(for: entry)] = entry
            if index.isMultiple(of: 48) { await Task.yield() }
        }
        // Old query groups are final. Only titles that have never appeared in
        // the persisted library enter the automatic lookup queue.
        let representatives = representativeByKey.filter { key, _ in
            previousMetadataByQuery[key] == nil && !previouslyScannedQueries.contains(key)
        }
        let pendingMetadataQueries = Set(representatives.keys)
        await publishClassifiedLibrary(
            raw: raw,
            metadataByQuery: previousMetadataByQuery,
            previousEntriesByID: previousEntriesByID,
            pendingMetadataQueries: pendingMetadataQueries,
            completedMetadataQueries: previouslyScannedQueries,
            metadataSignature: metadataSignature,
            previousMetadataSignature: previousMetadataSignature
        )

        // Discovery is complete at this point. Publish and return immediately;
        // TMDB classification continues independently in bounded background
        // batches, so refresh controls never wait for hundreds of API calls.
        loaded = true
        lastSourceSignature = sourceSignature
        lastMetadataSignature = metadataSignature
        status = ""
        persistSnapshot()
        metadataGeneration &+= 1
        startMetadataEnrichment(
            raw: raw,
            representatives: representatives,
            initialMetadata: previousMetadataByQuery,
            previousEntriesByID: previousEntriesByID,
            previouslyScannedQueries: previouslyScannedQueries,
            metadataSignature: metadataSignature,
            previousMetadataSignature: previousMetadataSignature,
            generation: metadataGeneration
        )
    }

    private func publishClassifiedLibrary(
        raw: [UnifiedMediaEntry],
        metadataByQuery: [String: TMDBTitleDetails],
        previousEntriesByID: [String: UnifiedMediaEntry],
        pendingMetadataQueries: Set<String>,
        completedMetadataQueries: Set<String>,
        metadataSignature: String,
        previousMetadataSignature: String
    ) async {
        var movieItems: [UnifiedMediaEntry] = []
        var showEpisodes: [String: [(UnifiedMediaEntry, UnifiedEpisode)]] = [:]
        var unknownItems: [UnifiedMediaEntry] = []
        let liveManualEntriesByID = Dictionary(
            (movies + shows + unknown)
                .filter { $0.manualMetadataProvider != nil }
                .map { ($0.id, $0) },
            uniquingKeysWith: { latest, _ in latest }
        )
        for (index, originalEntry) in raw.enumerated() {
            var entry = originalEntry
            let query = metadataGroupKey(for: entry)
            let preservedEntry = liveManualEntriesByID[entry.id] ?? previousEntriesByID[entry.id]
            entry.details = metadataByQuery[query]
            if completedMetadataQueries.contains(query) {
                entry.metadataLookupCompleted = true
            } else if pendingMetadataQueries.contains(query) {
                entry.metadataLookupCompleted = false
            } else if let previous = preservedEntry {
                entry.metadataLookupCompleted = previous.metadataLookupCompleted ?? true
            }
            if let previous = preservedEntry, previous.manualMetadataProvider != nil {
                entry.details = previous.details
                entry.manualMetadataProvider = previous.manualMetadataProvider
                entry.metadataLookupCompleted = true
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
                let ep = UnifiedEpisode(
                    id: entry.id,
                    title: entry.rawTitle,
                    season: season,
                    episode: episode,
                    source: entry.source,
                    url: entry.streamURL
                )
                showEpisodes[key, default: []].append((entry, ep))
            } else if entry.details != nil {
                movieItems.append(entry)
            } else {
                unknownItems.append(entry)
            }
            if index.isMultiple(of: 32) { await Task.yield() }
        }

        var showItems: [UnifiedMediaEntry] = []
        for (index, values) in showEpisodes.values.enumerated() {
            guard var first = values.first?.0 else { continue }
            first.title = first.details?.title ?? first.title
            first.episodes = values.map(\.1).sorted { lhs, rhs in
                lhs.season == rhs.season ? lhs.episode < rhs.episode : lhs.season < rhs.season
            }
            showItems.append(first)
            if index.isMultiple(of: 16) { await Task.yield() }
        }

        guard !Task.isCancelled else { return }
        movies = deduplicatedMovies(movieItems).sorted {
            $0.title.localizedStandardCompare($1.title) == .orderedAscending
        }
        shows = showItems.sorted {
            $0.title.localizedStandardCompare($1.title) == .orderedAscending
        }
        unknown = unknownItems.sorted {
            $0.title.localizedStandardCompare($1.title) == .orderedAscending
        }
    }

    private func startMetadataEnrichment(
        raw: [UnifiedMediaEntry],
        representatives: [String: UnifiedMediaEntry],
        initialMetadata: [String: TMDBTitleDetails],
        previousEntriesByID: [String: UnifiedMediaEntry],
        previouslyScannedQueries: Set<String>,
        metadataSignature: String,
        previousMetadataSignature: String,
        generation: Int
    ) {
        metadataEnrichmentTask?.cancel()
        guard !representatives.isEmpty else {
            metadataEnrichmentTask = nil
            _ = startEpisodeEnrichmentIfNeeded()
            startDetailsArtworkPrefetchIfNeeded()
            return
        }

        metadataEnrichmentTask = Task(priority: .utility) { [weak self] in
            guard let self else { return }
            var metadataByQuery = initialMetadata
            var pending = Set(representatives.keys)
            var completed = previouslyScannedQueries
            let work = representatives.sorted { $0.key < $1.key }
            var changesSincePublish = 0

            for (key, entry) in work {
                guard !Task.isCancelled, self.metadataGeneration == generation else { return }
                let details = await TMDBService.shared.detailsOriginalFirst(
                    for: self.metadataLookupTitle(for: entry),
                    preferredMediaType: self.preferredMediaType(for: entry)
                )
                guard !Task.isCancelled, self.metadataGeneration == generation else { return }
                if let details { metadataByQuery[key] = details }
                pending.remove(key)
                completed.insert(key)
                changesSincePublish += 1

                if changesSincePublish >= 24 {
                    await self.publishClassifiedLibrary(
                        raw: raw,
                        metadataByQuery: metadataByQuery,
                        previousEntriesByID: previousEntriesByID,
                        pendingMetadataQueries: pending,
                        completedMetadataQueries: completed,
                        metadataSignature: metadataSignature,
                        previousMetadataSignature: previousMetadataSignature
                    )
                    guard !Task.isCancelled, self.metadataGeneration == generation else { return }
                    self.persistSnapshot()
                    changesSincePublish = 0
                }
                // Be gentle on the connection without holding the refresh UI.
                try? await Task.sleep(nanoseconds: 120_000_000)
            }

            guard !Task.isCancelled, self.metadataGeneration == generation else { return }
            if changesSincePublish > 0 {
                await self.publishClassifiedLibrary(
                    raw: raw,
                    metadataByQuery: metadataByQuery,
                    previousEntriesByID: previousEntriesByID,
                    pendingMetadataQueries: pending,
                    completedMetadataQueries: completed,
                    metadataSignature: metadataSignature,
                    previousMetadataSignature: previousMetadataSignature
                )
                self.persistSnapshot()
            }
            guard !Task.isCancelled, self.metadataGeneration == generation else { return }
            self.metadataEnrichmentTask = nil
            _ = self.startEpisodeEnrichmentIfNeeded()
            self.startDetailsArtworkPrefetchIfNeeded()
        }
    }

    private func persistSnapshot() {
        let snapshot = UnifiedContentSnapshot(
            movies: movies,
            shows: shows,
            unknown: unknown,
            sourceSignature: lastSourceSignature,
            metadataSignature: lastMetadataSignature
        )
        snapshotRevision += 1
        let revision = snapshotRevision
        let writer = snapshotWriter
        let url = Self.snapshotURL
        Task(priority: .utility) {
            await writer.persist(snapshot, to: url, revision: revision)
        }
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
        case let .catalog(mediaType, tmdbID): sourcePath = "tmdb/\(mediaType)/\(tmdbID)"
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

    private static func currentMetadataSignature() -> String {
        "tmdb:" + stableSignature(TMDBSettings.readAccessToken)
            + "|matcher:release-v2"
    }

    func applyManualTMDB(_ details: TMDBTitleDetails, to entry: UnifiedMediaEntry) {
        guard var value = takeEntry(id: entry.id) else { return }
        value.details = details
        value.title = details.title
        value.manualMetadataProvider = "tmdb"
        value.metadataLookupCompleted = true
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
                VideoThumbnailLoader.cacheImageInBackground(image, forStableKeys: [
                    "unified-manual|\(entry.id)", "unified|\(entry.id)"
                ])
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

    func applyManualCover(_ image: UIImage, to entry: UnifiedMediaEntry) {
        VideoThumbnailLoader.cacheImageInBackground(image, forStableKeys: [
            "unified-manual|\(entry.id)", "unified|\(entry.id)"
        ])
    }

    private func takeEntry(id: String) -> UnifiedMediaEntry? {
        if let index = movies.firstIndex(where: { $0.id == id }) { return movies.remove(at: index) }
        if let index = shows.firstIndex(where: { $0.id == id }) { return shows.remove(at: index) }
        if let index = unknown.firstIndex(where: { $0.id == id }) { return unknown.remove(at: index) }
        return nil
    }

    /// Warms episode names, descriptions, and still artwork very gently. Only
    /// one season and one image are processed at a time so playback and normal
    /// browsing retain network priority.
    @discardableResult
    private func startEpisodeEnrichmentIfNeeded() -> Bool {
        guard episodeEnrichmentTask == nil else { return true }
        episodeEnrichmentTask = Task(priority: .utility) { [weak self] in
            guard let self else { return }
            // Let the newly published grids complete their first frame before
            // grouping a very large episode library.
            try? await Task.sleep(nanoseconds: 350_000_000)
            var pending = await self.episodeMetadataBatches()
            guard !pending.isEmpty, !Task.isCancelled else {
                self.episodeEnrichmentTask = nil
                return
            }
            while !pending.isEmpty, !Task.isCancelled {
                let preferredIndex = pending.firstIndex {
                    self.prioritizedEpisodeSeries.contains($0.seriesEntryID)
                } ?? pending.startIndex
                let batch = pending.remove(at: preferredIndex)
                await self.prefetchEpisodeBatch(batch)
                self.prioritizedEpisodeSeries.remove(batch.seriesEntryID)
                try? await Task.sleep(nanoseconds: 700_000_000)
            }
            guard !Task.isCancelled else { return }
            self.episodeEnrichmentTask = nil
            self.startDetailsArtworkPrefetchIfNeeded()
        }
        return true
    }

    func prioritizeEpisodeMetadata(for entry: UnifiedMediaEntry) {
        prioritizedDetailsArtwork.insert(entry.id)
        if entry.details?.isSeries == true, !entry.episodes.isEmpty {
            prioritizedEpisodeSeries.insert(entry.id)
            _ = startEpisodeEnrichmentIfNeeded()
        }
        startDetailsArtworkPrefetchIfNeeded()
    }

    /// Downloads the exact No-Language/English portrait consumed by Details,
    /// one item at a time and only after metadata enrichment has gone idle.
    private func startDetailsArtworkPrefetchIfNeeded() {
        guard detailsArtworkTask == nil else { return }
        detailsArtworkTask = Task(priority: .background) { [weak self] in
            guard let self else { return }
            // Give the visible library a moment to finish its own first render.
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            let requests = await self.detailsArtworkRequests()
            guard !requests.isEmpty, !Task.isCancelled else {
                self.detailsArtworkTask = nil
                return
            }
            var pending = requests
            while !pending.isEmpty, !Task.isCancelled {
                let preferredIndex = pending.firstIndex {
                    self.prioritizedDetailsArtwork.contains($0.entryID)
                } ?? pending.startIndex
                let request = pending.remove(at: preferredIndex)
                self.prioritizedDetailsArtwork.remove(request.entryID)
                await self.prefetchDetailsArtwork(request)
                try? await Task.sleep(nanoseconds: 1_200_000_000)
            }
            guard !Task.isCancelled else { return }
            self.detailsArtworkTask = nil
        }
    }

    private func detailsArtworkRequests() async -> [DetailsArtworkRequest] {
        var requests: [DetailsArtworkRequest] = []
        for (index, entry) in (movies + shows).enumerated() {
            guard let url = entry.details?.detailsPosterURL else { continue }
            let cacheKey = detailsArtworkCacheKey(for: entry)
            guard await VideoThumbnailLoader.cachedImageAsync(forStableKey: cacheKey) == nil else { continue }
            requests.append(DetailsArtworkRequest(entryID: entry.id, cacheKey: cacheKey, url: url))
            if index.isMultiple(of: 24) { await Task.yield() }
        }
        return requests
    }

    private func detailsArtworkCacheKey(for entry: UnifiedMediaEntry) -> String {
        let metadataKey: String
        if !entry.episodes.isEmpty, let details = entry.details {
            metadataKey = "series|tmdb|\(details.id)"
        } else {
            let normalizedTitle = VideoTitleFormatter.title(from: entry.title)
                .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
                .lowercased()
                .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            metadataKey = (entry.episodes.isEmpty ? "movie|" : "series|") + normalizedTitle
        }
        return VideoThumbnailLoader.tmdbDetailsPosterCacheKey(forMetadataIdentity: metadataKey)
    }

    private func prefetchDetailsArtwork(_ request: DetailsArtworkRequest) async {
        let ready = await Task.detached(priority: .background) {
            if VideoThumbnailLoader.cachedImage(forStableKey: request.cacheKey) != nil { return true }
            var urlRequest = URLRequest(url: request.url)
            urlRequest.networkServiceType = .background
            urlRequest.timeoutInterval = 45
            guard let (data, response) = try? await URLSession.shared.data(for: urlRequest),
                  let http = response as? HTTPURLResponse,
                  200..<300 ~= http.statusCode,
                  let image = UIImage(data: data),
                  !Task.isCancelled else { return false }
            VideoThumbnailLoader.cacheHighQualityImage(
                image,
                forStableKey: request.cacheKey,
                maximumBytes: ThumbnailPipeline.largeMaximumBytes
            )
            return true
        }.value
        if !ready {
            DiagnosticLogger.log("Details artwork prefetch failed: \(request.entryID)")
        }
    }

    private func episodeMetadataBatches() async -> [EpisodeMetadataBatch] {
        // v1 could mark a season complete when episode records existed but their
        // still artwork had never been resolved. Revisit each season once with
        // the repaired TMDB artwork pipeline; movie/series metadata stays intact.
        let completed = Set(UserDefaults.standard.stringArray(forKey: "unified.completedEpisodeMetadata.v2") ?? [])
        var result: [EpisodeMetadataBatch] = []
        for (index, entry) in shows.enumerated() {
            guard let seriesID = entry.details?.id else { continue }
            let batches = Dictionary(grouping: entry.episodes, by: \.season)
                .map { season, episodes in
                    EpisodeMetadataBatch(
                        seriesEntryID: entry.id,
                        tmdbSeriesID: seriesID,
                        season: season,
                        episodeNumbers: episodes.map(\.episode).sorted()
                    )
                }
                .filter { !completed.contains($0.identity) }
                .sorted { $0.season < $1.season }
            result.append(contentsOf: batches)
            if index.isMultiple(of: 12) { await Task.yield() }
        }
        return result
    }

    private func prefetchEpisodeBatch(_ batch: EpisodeMetadataBatch) async {
        let values = await TMDBService.shared.seasonEpisodeDetails(
            seriesID: batch.tmdbSeriesID,
            season: batch.season,
            episodeNumbers: batch.episodeNumbers
        )
        var completed = batch.episodeNumbers.allSatisfy { values[$0] != nil }
        for episode in batch.episodeNumbers {
            guard !Task.isCancelled,
                  let url = values[episode]?.imageURL else { continue }
            let cacheKey = "tmdb-remote|\(url.absoluteString)"
            let imageIsReady = await Task.detached(priority: .utility) {
                if VideoThumbnailLoader.cachedImage(forStableKey: cacheKey) != nil { return true }
                var request = URLRequest(url: url)
                request.networkServiceType = .background
                request.timeoutInterval = 30
                guard let (data, _) = try? await URLSession.shared.data(for: request),
                      let image = UIImage(data: data) else { return false }
                VideoThumbnailLoader.cacheImage(image, forStableKey: cacheKey)
                return true
            }.value
            if !imageIsReady { completed = false }
            try? await Task.sleep(nanoseconds: 450_000_000)
        }
        if completed {
            var completedBatches = Set(UserDefaults.standard.stringArray(forKey: "unified.completedEpisodeMetadata.v2") ?? [])
            completedBatches.insert(batch.identity)
            UserDefaults.standard.set(Array(completedBatches), forKey: "unified.completedEpisodeMetadata.v2")
        }
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
    case tmdb, cover
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

    private var posterCardWidth: CGFloat {
        max(88, floor((UIScreen.main.bounds.width - 52) / 3))
    }

    private var posterCardHeight: CGFloat { posterCardWidth * 1.5 }

    private var columns: [GridItem] {
        Array(repeating: GridItem(.fixed(posterCardWidth), spacing: 12, alignment: .top), count: 3)
    }

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
        Button {
            model.prioritizeEpisodeMetadata(for: entry)
            selected = entry
        } label: {
            VStack(alignment: .leading, spacing: 7) {
                ZStack {
                    RoundedRectangle(cornerRadius: 14).fill(Color.white.opacity(0.07))
                    UnifiedPosterArtwork(entry: entry, section: section)
                        .frame(width: posterCardWidth, height: posterCardHeight)
                        .clipped()
                }
                .frame(width: posterCardWidth, height: posterCardHeight)
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .stroke(Color.white.opacity(0.13), lineWidth: 0.8)
                )
                Text(entry.title)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(width: posterCardWidth, height: 16, alignment: .leading)
                Group {
                    if !entry.episodes.isEmpty {
                        Text("\(entry.episodes.count) episodes")
                            .font(.caption2)
                            .foregroundStyle(AppPalette.accent)
                    } else {
                        Color.clear
                    }
                }
                .frame(width: posterCardWidth, height: 13, alignment: .leading)
            }
            .frame(
                width: posterCardWidth,
                height: posterCardHeight + 43,
                alignment: .topLeading
            )
            .clipped()
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button {
                manualSearch = UnifiedManualSearchRequest(entry: entry, kind: .tmdb)
            } label: {
                Label("Search Movie / TV Metadata", systemImage: "film.stack")
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
            Text(section == .unknown ? "No Other Content" : "No \(section.rawValue)")
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
        UnifiedMediaDetailsHost(
            vm: vm,
            entry: entry,
            section: section,
            categoryEntries: currentEntries
        )
    }

    private func play(_ source: UnifiedSource) {
        switch source {
        case let .webDAV(server, file):
            Task { @MainActor in
                guard await vm.preparePlayback(file: file, server: server) else { return }
                showPlayer = true
            }
            return
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
        case .catalog:
            return
        }
        showPlayer = true
    }
}

/// Manual covers update the visible grid through the shared stable-poster event.
struct UnifiedPosterArtwork: View {
    let entry: UnifiedMediaEntry
    let section: UnifiedMediaSection
    @State private var cachedImage: UIImage?
    @State private var resolvedPosterURL: URL?
    /// Gates the first render so we commit to exactly one poster source.
    /// Without this, the manual-cache lookup below resolves a moment after
    /// KFImage has already started showing the network image, and swapping
    /// branches mid-appearance is what produced the zoom/pop-in flicker.
    @State private var hasCheckedCache = false

    private var cacheKey: String { "unified|\(entry.id)" }
    private var manualCacheKey: String { "unified-manual|\(entry.id)" }

    init(entry: UnifiedMediaEntry, section: UnifiedMediaSection) {
        self.entry = entry
        self.section = section
        _cachedImage = State(initialValue: nil)
    }

    var body: some View {
        Group {
            if !hasCheckedCache {
                ProgressView().tint(AppPalette.accent)
            } else if let cachedImage {
                Image(uiImage: cachedImage)
                    .resizable()
                    .scaledToFill()
            } else if let url = resolvedPosterURL {
                KFImage(url)
                    .placeholder { ProgressView().tint(AppPalette.accent) }
                    .cacheOriginalImage()
                    .onSuccess { result in
                        // Kingfisher's URL cache is disposable. Keep the library
                        // poster under the same persistent key every screen reads.
                        VideoThumbnailLoader.cacheImageInBackground(result.image, forStableKey: cacheKey)
                    }
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
            if let manual = await cachedPoster() {
                cachedImage = manual
                hasCheckedCache = true
                return
            }
            resolvedPosterURL = await noLanguagePosterURL()
            hasCheckedCache = true
        }
        .onReceive(NotificationCenter.default.publisher(for: VideoThumbnailLoader.stablePosterDidUpdateNotification)) { notification in
            guard let updatedKey = notification.object as? String,
                  updatedKey == manualCacheKey || updatedKey == cacheKey else { return }
            Task {
                cachedImage = await cachedPoster()
            }
        }
    }

    /// TMDB's list/discover endpoints only return the localized poster (often
    /// with burned-in title text), so `entry.details` from the catalog builder
    /// never carries a no-language poster. Resolve it once per title here —
    /// via the entry's known TMDB id when available, so no title search is
    /// needed — and fall back to the localized poster only if no
    /// language-free rendition exists for that title.
    private func noLanguagePosterURL() async -> URL? {
        if let existing = entry.details?.detailsPosterURL {
            return existing
        }
        if case let .catalog(mediaType, tmdbID) = entry.source {
            let details = await TMDBService.shared.details(
                mediaType: mediaType,
                tmdbID: tmdbID,
                fallbackTitle: entry.title
            )
            return details?.detailsPosterURL ?? entry.posterURL
        }
        return entry.posterURL
    }

    private func cachedPoster() async -> UIImage? {
        if let manual = await VideoThumbnailLoader.cachedImageAsync(forStableKey: manualCacheKey) {
            return manual
        }
        return nil
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
                ToolbarItem(placement: .topBarLeading) {
                    AppAnimatedBackButton(size: 36) { dismiss() }
                }
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
    let section: UnifiedMediaSection
    let categoryEntries: [UnifiedMediaEntry]
    @StateObject private var selection: UnifiedEpisodeSelection
    @State private var activeEntry: UnifiedMediaEntry
    @State private var showPlayer = false
    @State private var showOnlineSources = false
    @State private var presentOnlinePlayerAfterSourcesDismiss = false
    /// The source sheet is bypassed only for an explicit PikPak choice. The
    /// ID lets us ignore stale updates after changing episode or leaving.
    @State private var automaticPikPakTransferID: String?
    @State private var isSearchingAutomaticPikPakSource = false
    @State private var showPikPakQualityChooser = false
    @State private var pikPakQualityCandidates: [OnlineTorrentSource] = []
    @State private var pikPakQualityLookupMessage: String?
    @State private var presentPikPakPlayerAfterChooserDismiss = false
    @State private var pikPakPreparationError: String?

    init(
        vm: AppViewModel,
        entry: UnifiedMediaEntry,
        section: UnifiedMediaSection,
        categoryEntries: [UnifiedMediaEntry]
    ) {
        self.vm = vm
        self.section = section
        self.categoryEntries = categoryEntries
        var preparedEntry = entry
        if case let .catalog(mediaType, tmdbID) = entry.source,
           mediaType == "tv",
           let details = entry.details,
           !details.seasons.isEmpty {
            preparedEntry.episodes = Self.catalogEpisodes(
                entryID: entry.id,
                details: details,
                tmdbID: tmdbID
            )
        }
        _activeEntry = State(initialValue: preparedEntry)
        _selection = StateObject(wrappedValue: UnifiedEpisodeSelection(id: preparedEntry.episodes.first?.id))
    }

    private var selectedEpisode: UnifiedEpisode? {
        guard let selectedEpisodeID = selection.id else { return nil }
        return activeEntry.episodes.first { $0.id == selectedEpisodeID }
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
            },
            suggestionsTitle: suggestionsTitle,
            suggestions: suggestions,
            onSelectSuggestion: selectSuggestion
        )
        // Keep one Details hierarchy for the selected library item. Re-keying
        // the whole screen when cast/logo/runtime metadata arrived caused the
        // first open to rebuild and visibly jump from the temporary artwork to
        // the final poster. VideoDetailsView now adopts enrichment in place.
        .id(activeEntry.id)
        .task(id: activeEntry.id) {
            guard case let .catalog(mediaType, tmdbID) = activeEntry.source else { return }
            if let details = await TMDBService.shared.details(
                mediaType: mediaType,
                tmdbID: tmdbID,
                fallbackTitle: activeEntry.title
            ) {
                activeEntry.details = details
                if mediaType == "tv" {
                    let episodes = Self.catalogEpisodes(
                        entryID: activeEntry.id,
                        details: details,
                        tmdbID: tmdbID
                    )
                    activeEntry.episodes = episodes
                    if selection.id.map({ selectedID in
                        episodes.contains(where: { $0.id == selectedID })
                    }) != true {
                        selection.id = episodes.first?.id
                    }
                }
            }
        }
        .fullScreenCover(isPresented: $showPlayer) {
            if shouldShowPikPakPreparationPlayer {
                PikPakPreparationPlayerScreen(
                    title: currentDetailsItem.title,
                    message: activePikPakTransfer?.message,
                    errorMessage: pikPakPreparationError,
                    onClose: {
                        showPlayer = false
                        pikPakPreparationError = nil
                        automaticPikPakTransferID = nil
                        vm.cancelOnlinePlaybackPreparation()
                    }
                )
            } else {
                ResolvedPlayerScreen(
                    vm: vm,
                    episodeOptions: playerEpisodeOptions,
                    onSelectEpisode: switchPlayerEpisode
                )
            }
        }
        .sheet(
            isPresented: $showPikPakQualityChooser,
            onDismiss: {
                guard presentPikPakPlayerAfterChooserDismiss else { return }
                presentPikPakPlayerAfterChooserDismiss = false
                showPlayer = true
            }
        ) {
            PikPakQualityChoiceSheet(
                title: currentDetailsItem.title,
                isSearching: isSearchingAutomaticPikPakSource,
                sources: pikPakQualityCandidates,
                message: pikPakQualityLookupMessage,
                onSelect: selectPikPakQuality
            )
            .preferredColorScheme(.dark)
        }
        .fullScreenCover(
            isPresented: $showOnlineSources,
            onDismiss: {
                guard presentOnlinePlayerAfterSourcesDismiss else { return }
                presentOnlinePlayerAfterSourcesDismiss = false
                guard vm.ensurePreparedOnlinePlaybackIsActive() else {
                    DiagnosticLogger.log("[OnlinePlayback] presentation aborted because playback state is empty")
                    vm.errorMessage = "The stream was prepared, but the player did not receive its URL."
                    return
                }
                // onDismiss runs after the source cover has fully completed its
                // transition, so the player cover can no longer be torn down by
                // the outgoing cover's lifecycle.
                showPlayer = true
            }
        ) {
            ExperimentalOnlineSourcesView(
                vm: vm,
                entry: activeEntry,
                episode: selectedEpisode,
                onPlaybackReady: {
                    presentOnlinePlayerAfterSourcesDismiss = true
                    showOnlineSources = false
                }
            )
        }
        .onChange(of: vm.onlinePlaybackTransfer) { transfer in
            handleAutomaticPikPakTransfer(transfer)
        }
    }

    private var relatedEpisodes: [VideoEpisodeItem] {
        activeEntry.episodes.map {
            VideoEpisodeItem(id: $0.id, title: $0.title, season: $0.season, episode: $0.episode)
        }
    }

    private var activePikPakTransfer: OnlinePlaybackTransfer? {
        guard let automaticPikPakTransferID,
              vm.onlinePlaybackTransfer?.id == automaticPikPakTransferID else { return nil }
        return vm.onlinePlaybackTransfer
    }

    private var shouldShowPikPakPreparationPlayer: Bool {
        vm.nowPlayingURL == nil && (automaticPikPakTransferID != nil || pikPakPreparationError != nil)
    }

    private static func catalogEpisodes(
        entryID: String,
        details: TMDBTitleDetails,
        tmdbID: Int
    ) -> [UnifiedEpisode] {
        details.seasons
            .filter { $0.seasonNumber > 0 && $0.episodeCount > 0 }
            .sorted { $0.seasonNumber < $1.seasonNumber }
            .flatMap { season -> [UnifiedEpisode] in
                (1...season.episodeCount).compactMap { episodeNumber in
                    let episodeID = "\(entryID)|s\(season.seasonNumber)|e\(episodeNumber)"
                    guard let url = URL(
                        string: "catalog://tmdb/tv/\(tmdbID)/season/\(season.seasonNumber)/episode/\(episodeNumber)"
                    ) else { return nil }
                    return UnifiedEpisode(
                        id: episodeID,
                        title: String(
                            format: "%@ S%02dE%02d Episode %d",
                            details.title,
                            season.seasonNumber,
                            episodeNumber,
                            episodeNumber
                        ),
                        season: season.seasonNumber,
                        episode: episodeNumber,
                        source: .catalog(mediaType: "tv", tmdbID: tmdbID),
                        url: url
                    )
                }
            }
    }

    private var playerEpisodeOptions: [PlayerEpisodeOption] {
        activeEntry.episodes
            .sorted {
                $0.season == $1.season ? $0.episode < $1.episode : $0.season < $1.season
            }
            .map { episode in
                PlayerEpisodeOption(
                    id: episode.id,
                    title: "S\(episode.season) · E\(episode.episode)",
                    subtitle: VideoTitleFormatter.episodeTitle(from: episode.title)
                )
            }
    }

    private var currentDetailsItem: VideoDetailsItem {
        if let episode = selectedEpisode {
            return VideoDetailsItem(
                id: episode.id, title: episode.title, url: episode.url,
                httpHeaders: playbackHeaders(for: episode.source),
                // Every episode shares the series artwork/metadata identity. The
                // selected file and S/E label change, but story/rating/cast do not.
                posterCacheKey: "unified|\(activeEntry.id)",
                fileExtension: (episode.title as NSString).pathExtension.uppercased(),
                source: activeEntry.sourceLabel, relatedEpisodes: relatedEpisodes,
                seriesIdentity: "unified|\(activeEntry.id)",
                suppliedTMDBDetails: activeEntry.details,
                manualMetadataProvider: activeEntry.manualMetadataProvider
            )
        }
        return VideoDetailsItem(
            id: activeEntry.id, title: activeEntry.title, url: activeEntry.streamURL,
            httpHeaders: playbackHeaders(for: activeEntry.source),
            posterCacheKey: "unified|\(activeEntry.id)",
            fileExtension: (activeEntry.rawTitle as NSString).pathExtension.uppercased(),
            source: activeEntry.sourceLabel, relatedEpisodes: relatedEpisodes,
            seriesIdentity: "unified|\(activeEntry.id)",
            suppliedTMDBDetails: activeEntry.details,
            manualMetadataProvider: activeEntry.manualMetadataProvider
        )
    }

    private func playbackHeaders(for source: UnifiedSource) -> [String: String] {
        guard case let .webDAV(server, _) = source else { return [:] }
        return WebDAVClient(server: server).streamHeaders()
    }

    private func playCurrent() {
        // Keep the exact unified-library identity attached to playback so resume
        // history remains stable while the details screen is open.
        vm.preparePlaybackHistory(for: currentDetailsItem)
        let source = selectedEpisode?.source ?? activeEntry.source
        switch source {
        case let .webDAV(server, file):
            Task { @MainActor in
                guard await vm.preparePlayback(file: file, server: server) else { return }
                showPlayer = true
            }
            return
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
        case .catalog:
            if OnlinePlaybackProviderPreference.selected == .pikpak {
                pikPakQualityCandidates = []
                pikPakQualityLookupMessage = nil
                pikPakPreparationError = nil
                showPikPakQualityChooser = true
                Task { @MainActor in
                    await prepareAutomaticPikPakPlayback()
                }
            } else {
                showOnlineSources = true
            }
            return
        }
        showPlayer = true
    }

    /// Find three useful resolution choices before handing a magnet to PikPak.
    /// The player itself is presented as soon as the user chooses one; cloud
    /// preparation then continues inside the player instead of behind a blank
    /// details page.
    @MainActor
    private func prepareAutomaticPikPakPlayback() async {
        guard automaticPikPakTransferID == nil, !isSearchingAutomaticPikPakSource else { return }
        guard case let .catalog(mediaType, tmdbID) = activeEntry.source else { return }
        isSearchingAutomaticPikPakSource = true
        defer { isSearchingAutomaticPikPakSource = false }

        var imdbID = activeEntry.details?.imdbID
        if imdbID?.isEmpty != false {
            imdbID = await TMDBService.shared.externalIMDbID(mediaType: mediaType, tmdbID: tmdbID)
        }
        let context = OnlineSourceLookupContext(
            title: activeEntry.details?.title ?? activeEntry.title,
            year: activeEntry.details?.releaseDate.map { String($0.prefix(4)) },
            mediaType: mediaType,
            tmdbID: tmdbID,
            imdbID: imdbID,
            season: selectedEpisode?.season ?? (mediaType == "tv" ? 1 : nil),
            episode: selectedEpisode?.episode ?? (mediaType == "tv" ? 1 : nil)
        )
        do {
            let sources = try await OnlineSourceSearchService.shared.search(context)
            let choices = pikPakQualityChoices(from: sources)
            guard !choices.isEmpty else {
                pikPakQualityLookupMessage = "No supported torrent quality was found for this title."
                return
            }
            pikPakQualityCandidates = choices
        } catch {
            pikPakQualityLookupMessage = error.localizedDescription
        }
    }

    private func pikPakQualityChoices(from sources: [OnlineTorrentSource]) -> [OnlineTorrentSource] {
        let bestByQuality = Dictionary(grouping: sources, by: \.quality).compactMap { _, values in
            values.max { lhs, rhs in
                if lhs.seeders != rhs.seeders { return lhs.seeders < rhs.seeders }
                return lhs.sizeBytes < rhs.sizeBytes
            }
        }
        var selected: [OnlineTorrentSource] = []
        let preferredQualities: [OnlineStreamQuality] = [.p720, .p1080, .p2160]
        for quality in preferredQualities {
            if let source = bestByQuality.first(where: { $0.quality == quality }) {
                selected.append(source)
            }
        }
        for source in bestByQuality.sorted(by: { $0.quality > $1.quality }) where selected.count < 3 {
            guard !selected.contains(where: { $0.id == source.id }) else { continue }
            selected.append(source)
        }
        return selected.sorted { $0.quality < $1.quality }
    }

    @MainActor
    private func selectPikPakQuality(_ source: OnlineTorrentSource) {
        guard automaticPikPakTransferID == nil else { return }
        automaticPikPakTransferID = source.id
        vm.prepareOnlineSource(source, historyItem: currentDetailsItem)
        presentPikPakPlayerAfterChooserDismiss = true
        showPikPakQualityChooser = false
    }

    @MainActor
    private func handleAutomaticPikPakTransfer(_ transfer: OnlinePlaybackTransfer?) {
        guard let transfer,
              transfer.id == automaticPikPakTransferID else { return }
        switch transfer.phase {
        case .preparing, .downloading:
            break
        case .ready:
            automaticPikPakTransferID = nil
            pikPakPreparationError = nil
            guard vm.playPreparedOnlineSource() else {
                pikPakPreparationError = "The stream was prepared, but the player did not receive its URL."
                return
            }
        case .failed:
            automaticPikPakTransferID = nil
            pikPakPreparationError = transfer.message
        }
    }

    @MainActor
    private func switchPlayerEpisode(_ episodeID: String) {
        guard selection.id != episodeID,
              activeEntry.episodes.contains(where: { $0.id == episodeID }) else { return }
        vm.endPlaybackPresentation()
        selection.id = episodeID
        playCurrent()
    }

    private var suggestionsTitle: String {
        switch section {
        case .movies: return "Unwatched Movies"
        case .shows: return "Unwatched TV Shows"
        case .unknown: return "Unwatched Others"
        }
    }

    private var suggestions: [VideoDetailsSuggestion] {
        Array(categoryEntries.lazy
            .filter { $0.id != activeEntry.id && !hasBeenWatched($0) }
            .prefix(14))
            .map { entry in
                return VideoDetailsSuggestion(
                    id: entry.id,
                    title: entry.title,
                    posterCacheKey: "unified|\(entry.id)",
                    imageURL: entry.posterURL
                )
            }
    }

    private func hasBeenWatched(_ entry: UnifiedMediaEntry) -> Bool {
        if vm.playbackHistory[entry.id] != nil { return true }
        return entry.episodes.contains { vm.playbackHistory[$0.id] != nil }
    }

    private func selectSuggestion(_ id: String) {
        guard let next = categoryEntries.first(where: { $0.id == id }) else { return }
        activeEntry = next
        selection.id = next.episodes.first?.id
    }
}

private struct PikPakQualityChoiceSheet: View {
    let title: String
    let isSearching: Bool
    let sources: [OnlineTorrentSource]
    let message: String?
    let onSelect: (OnlineTorrentSource) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                AppTheme.bg.ignoresSafeArea()
                LinearGradient(
                    colors: [AppPalette.purple.opacity(0.28), .clear, Color.blue.opacity(0.14)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .ignoresSafeArea()

                VStack(alignment: .leading, spacing: 22) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("CHOOSE STREAM QUALITY")
                            .font(.system(size: 11, weight: .black))
                            .tracking(1.3)
                            .foregroundStyle(.white.opacity(0.58))
                        Text(VideoTitleFormatter.title(from: title))
                            .font(.system(size: 25, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                            .lineLimit(2)
                        Text("Your choice opens the player immediately. PikPak continues preparing the stream inside it.")
                            .font(.subheadline)
                            .foregroundStyle(.white.opacity(0.68))
                    }

                    if isSearching {
                        VStack(spacing: 18) {
                            PikPakOrbitLoader(size: 88)
                            Text("Finding the best available qualities…")
                                .font(.system(size: 15, weight: .semibold, design: .rounded))
                                .foregroundStyle(.white.opacity(0.78))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 34)
                    } else if sources.isEmpty {
                        ContentUnavailableView(
                            "No stream qualities found",
                            systemImage: "video.slash",
                            description: Text(message ?? "Try another title or search provider.")
                        )
                        .foregroundStyle(.white.opacity(0.78))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        VStack(spacing: 11) {
                            ForEach(sources) { source in
                                Button { onSelect(source) } label: {
                                    HStack(spacing: 15) {
                                        Text(source.quality.label)
                                            .font(.system(size: 18, weight: .black, design: .rounded))
                                            .foregroundStyle(.black)
                                            .frame(width: 70, height: 58)
                                            .background(AppPalette.gradient, in: RoundedRectangle(cornerRadius: 17, style: .continuous))
                                        VStack(alignment: .leading, spacing: 5) {
                                            Text(source.quality == .p2160 ? "Maximum detail" : source.quality == .p1080 ? "Balanced playback" : "Fast start")
                                                .font(.system(size: 15, weight: .bold))
                                                .foregroundStyle(.white)
                                            Label("\(source.seeders) seeders · \(source.sizeLabel)", systemImage: "bolt.fill")
                                                .font(.caption)
                                                .foregroundStyle(.white.opacity(0.62))
                                        }
                                        Spacer()
                                        Image(systemName: "arrow.right.circle.fill")
                                            .font(.title2)
                                            .foregroundStyle(.white.opacity(0.84))
                                    }
                                    .padding(12)
                                    .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                                    .overlay(RoundedRectangle(cornerRadius: 22).stroke(Color.white.opacity(0.12), lineWidth: 1))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(20)
            }
            .navigationTitle("PikPak")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    AppAnimatedBackButton(size: 36) { dismiss() }
                }
            }
        }
    }
}

private struct PikPakPreparationPlayerScreen: View {
    let title: String
    let message: String?
    let errorMessage: String?
    let onClose: () -> Void

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            RadialGradient(
                colors: [AppPalette.purple.opacity(0.42), Color.blue.opacity(0.13), .clear],
                center: .center,
                startRadius: 8,
                endRadius: 330
            )
            .ignoresSafeArea()

            VStack(spacing: 22) {
                Spacer()
                PikPakOrbitLoader(size: 132)
                VStack(spacing: 9) {
                    Text(errorMessage == nil ? "Preparing your stream" : "Couldn’t prepare the stream")
                        .font(.system(size: 23, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                    Text(VideoTitleFormatter.title(from: title))
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.white.opacity(0.64))
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                    Text(errorMessage ?? message ?? "PikPak is connecting to the selected quality. You can stay here while it finishes.")
                        .font(.footnote)
                        .foregroundStyle(errorMessage == nil ? .white.opacity(0.56) : .orange.opacity(0.9))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }
                Spacer()
                Button(errorMessage == nil ? "Cancel" : "Back") { onClose() }
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 52)
                    .background(Color.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .padding(.horizontal, 28)
                    .padding(.bottom, 35)
            }
        }
        .preferredColorScheme(.dark)
    }
}

private struct PikPakOrbitLoader: View {
    var size: CGFloat
    @State private var isAnimating = false

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.white.opacity(0.08), lineWidth: max(3, size * 0.035))
            Circle()
                .trim(from: 0.08, to: 0.73)
                .stroke(AppPalette.gradient, style: StrokeStyle(lineWidth: max(4, size * 0.05), lineCap: .round))
                .rotationEffect(.degrees(isAnimating ? 360 : 0))
            Circle()
                .trim(from: 0.12, to: 0.35)
                .stroke(Color.white.opacity(0.76), style: StrokeStyle(lineWidth: max(2, size * 0.022), lineCap: .round))
                .rotationEffect(.degrees(isAnimating ? -420 : 0))
            Image(systemName: "play.fill")
                .font(.system(size: size * 0.27, weight: .black))
                .foregroundStyle(.white)
                .offset(x: size * 0.035)
                .scaleEffect(isAnimating ? 1.08 : 0.92)
        }
        .frame(width: size, height: size)
        .shadow(color: AppPalette.purple.opacity(0.6), radius: 22)
        .onAppear {
            withAnimation(.linear(duration: 2.15).repeatForever(autoreverses: false)) {
                isAnimating = true
            }
        }
    }
}

private struct ExperimentalOnlineSourcesView: View {
    @ObservedObject var vm: AppViewModel
    let entry: UnifiedMediaEntry
    let episode: UnifiedEpisode?
    let onPlaybackReady: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var sources: [OnlineTorrentSource] = []
    @State private var isSearching = true
    @State private var resolvingID: String?
    @State private var message: String?

    private var configuredProviders: [String] {
        var values: [String] = []
        if !RealDebridKeyStore.key.isEmpty { values.append("Real-Debrid") }
        if !TorBoxKeyStore.load().isEmpty { values.append("TorBox") }
        if PikPakClient.shared.loadAccount() != nil { values.append("PikPak") }
        if !OffcloudKeyStore.load().isEmpty { values.append("Offcloud") }
        return values
    }

    private var activeProviders: [String] {
        let preference = OnlinePlaybackProviderPreference.selected
        switch preference {
        case .automatic: return configuredProviders
        case .directTorrent: return []
        default: return [preference.title]
        }
    }

    private var sourceSearchLabel: String {
        let count = OnlineSearchProviderSelection.selected.count
        return count == 1 ? "Searching 1 provider…" : "Searching \(count) providers…"
    }

    private var fastestID: String? {
        sources.max {
            if $0.seeders != $1.seeders { return $0.seeders < $1.seeders }
            if $0.sizeBytes == 0 { return true }
            if $1.sizeBytes == 0 { return false }
            return $0.sizeBytes > $1.sizeBytes
        }?.id
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(entry.title)
                            .font(.title2.bold())
                            .foregroundStyle(.white)
                        Text(episodeLabel ?? "Streaming Sources")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    providerStrip

                    if let transfer = currentTransfer {
                        transferStatusCard(transfer)
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }

                    if isSearching {
                        VStack(spacing: 13) {
                            ProgressView().tint(AppPalette.purple)
                            Text(sourceSearchLabel)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 55)
                    } else if sources.isEmpty {
                        statusCard(
                            title: "No matching sources",
                            subtitle: message ?? "No 720p, 1080p, 1440p, or 4K torrent was found.",
                            icon: "magnifyingglass",
                            tint: .orange
                        )
                    } else {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("TOP SOURCES BY QUALITY")
                                .font(.caption.bold())
                                .tracking(0.8)
                                .foregroundStyle(.secondary)
                            ForEach(sources.sorted(by: { $0.quality < $1.quality })) { source in
                                sourceCard(source)
                            }
                        }
                    }

                    if let message, !sources.isEmpty {
                        Text(message)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 4)
                    }
                }
                .padding(18)
                .padding(.bottom, 70)
            }
            .background(AppTheme.bg.ignoresSafeArea())
            .navigationTitle("Sources")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    AppAnimatedBackButton(size: 36) { dismiss() }
                }
            }
            .task { await loadSources() }
            .onChange(of: vm.onlinePlaybackTransfer) { transfer in
                handleTransferChange(transfer)
            }
        }
        .preferredColorScheme(.dark)
    }

    private var episodeLabel: String? {
        guard let episode else { return nil }
        return String(format: "Season %d · Episode %d", episode.season, episode.episode)
    }

    private var playbackHistoryItem: VideoDetailsItem {
        let activeEpisode = episode
        let title = activeEpisode?.title ?? entry.title
        return VideoDetailsItem(
            id: activeEpisode?.id ?? entry.id,
            title: title,
            url: activeEpisode?.url ?? entry.streamURL,
            posterCacheKey: "unified|\(entry.id)",
            fileExtension: (title as NSString).pathExtension.uppercased(),
            source: entry.sourceLabel,
            relatedEpisodes: entry.episodes.map {
                VideoEpisodeItem(id: $0.id, title: $0.title, season: $0.season, episode: $0.episode)
            },
            seriesIdentity: "unified|\(entry.id)",
            suppliedTMDBDetails: entry.details
        )
    }

    private var providerStrip: some View {
        HStack(spacing: 11) {
            Image(systemName: activeProviders.isEmpty ? "bolt.horizontal.circle.fill" : "icloud.and.arrow.up.fill")
                .font(.title3)
                .foregroundStyle(activeProviders.isEmpty ? AppPalette.purple : .green)
            VStack(alignment: .leading, spacing: 3) {
                Text(activeProviders.isEmpty ? "Direct Torrent Player" : activeProviders.joined(separator: " · "))
                    .font(.headline)
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(activeProviders.isEmpty
                     ? "No cloud service is enabled. Playback uses the built-in torrent engine."
                     : "The magnet is added automatically, then the prepared video starts.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(15)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 18))
    }

    private func sourceCard(_ source: OnlineTorrentSource) -> some View {
        let isFastest = fastestID == source.id
        let isResolving = resolvingID == source.id
        return Button {
            guard resolvingID == nil else { return }
            resolve(source)
        } label: {
            HStack(spacing: 14) {
                VStack(spacing: 2) {
                    Text(source.quality.label)
                        .font(.headline.bold())
                        .foregroundStyle(isFastest ? .black : .white)
                    if isFastest {
                        Text("FASTEST")
                            .font(.system(size: 8, weight: .black))
                            .tracking(0.5)
                            .foregroundStyle(.black.opacity(0.72))
                    }
                }
                .frame(width: 70, height: 58)
                .background(
                    isFastest ? AnyShapeStyle(AppPalette.gradient) : AnyShapeStyle(Color.white.opacity(0.08)),
                    in: RoundedRectangle(cornerRadius: 14)
                )

                VStack(alignment: .leading, spacing: 5) {
                    Text(isFastest ? "Fastest Link · \(source.quality.label)" : source.name)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                    HStack(spacing: 7) {
                        Text(source.origin.rawValue)
                        Text("·")
                        Label("\(source.seeders)", systemImage: "arrow.up.circle.fill")
                        Text("·")
                        Text(source.sizeLabel)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                }
                Spacer(minLength: 4)
                if isResolving {
                    VStack(spacing: 4) {
                        Image(systemName: currentTransfer?.phase == .downloading
                              ? "arrow.down.circle.fill" : "hourglass")
                            .font(.headline)
                        Text(currentTransfer?.phase == .downloading ? "Downloading" : "Preparing")
                            .font(.system(size: 9, weight: .bold))
                    }
                    .foregroundStyle(currentTransfer?.phase == .downloading ? AppPalette.accent : .white)
                } else {
                    Image(systemName: "play.fill")
                        .font(.headline)
                        .foregroundStyle(.white)
                        .frame(width: 38, height: 38)
                        .background(Color.white.opacity(0.1), in: Circle())
                }
            }
            .padding(12)
            .background(Color.white.opacity(isResolving ? 0.095 : 0.055), in: RoundedRectangle(cornerRadius: 20))
            .overlay {
                RoundedRectangle(cornerRadius: 20)
                    .stroke(isFastest ? AppPalette.purple.opacity(0.75) : Color.white.opacity(0.055), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .disabled(resolvingID != nil)
    }

    @MainActor
    private func loadSources() async {
        guard case let .catalog(mediaType, tmdbID) = entry.source else {
            isSearching = false
            message = "Online lookup is available for catalog titles only."
            return
        }
        isSearching = true
        sources = []
        message = nil
        var imdbID = entry.details?.imdbID
        if imdbID?.isEmpty != false {
            imdbID = await TMDBService.shared.externalIMDbID(mediaType: mediaType, tmdbID: tmdbID)
        }
        let year = entry.details?.releaseDate.map { String($0.prefix(4)) }
        let context = OnlineSourceLookupContext(
            title: entry.details?.title ?? entry.title,
            year: year,
            mediaType: mediaType,
            tmdbID: tmdbID,
            imdbID: imdbID,
            season: episode?.season ?? (mediaType == "tv" ? 1 : nil),
            episode: episode?.episode ?? (mediaType == "tv" ? 1 : nil)
        )
        do {
            sources = try await OnlineSourceSearchService.shared.search(context)
            if sources.isEmpty {
                message = "No supported quality was returned by the selected search provider."
            }
        } catch {
            message = error.localizedDescription
            sources = []
        }
        isSearching = false
    }

    private func resolve(_ source: OnlineTorrentSource) {
        resolvingID = source.id
        message = nil
        vm.prepareOnlineSource(source, historyItem: playbackHistoryItem)
    }

    private var currentTransfer: OnlinePlaybackTransfer? {
        guard let resolvingID,
              vm.onlinePlaybackTransfer?.id == resolvingID else { return nil }
        return vm.onlinePlaybackTransfer
    }

    private func handleTransferChange(_ transfer: OnlinePlaybackTransfer?) {
        guard let resolvingID,
              let transfer,
              transfer.id == resolvingID else { return }
        switch transfer.phase {
        case .preparing, .downloading:
            message = nil
        case .ready:
            if vm.playPreparedOnlineSource() {
                self.resolvingID = nil
                onPlaybackReady()
            }
        case .failed:
            message = transfer.message
            self.resolvingID = nil
        }
    }

    private func transferStatusCard(_ transfer: OnlinePlaybackTransfer) -> some View {
        let isDownloading = transfer.phase == .downloading
        return HStack(spacing: 14) {
            Image(systemName: isDownloading ? "arrow.down.circle.fill" : "hourglass")
                .font(.system(size: 23, weight: .semibold))
                .foregroundStyle(isDownloading ? AppPalette.accent : .white)
                .frame(width: 48, height: 48)
                .background(
                    (isDownloading ? AppPalette.accent : Color.white).opacity(0.12),
                    in: RoundedRectangle(cornerRadius: 15, style: .continuous)
                )
            VStack(alignment: .leading, spacing: 4) {
                Text(isDownloading ? "Downloading" : "Preparing stream")
                    .font(.headline)
                    .foregroundStyle(.white)
                Text(isDownloading
                     ? "Real-Debrid is downloading this file. You can leave this page and keep browsing."
                     : "Checking whether this file is already available…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(15)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            LinearGradient(
                colors: [AppPalette.purple.opacity(isDownloading ? 0.2 : 0.08), Color.white.opacity(0.045)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: 20, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(AppPalette.accent.opacity(isDownloading ? 0.4 : 0.13), lineWidth: 1)
        }
        .animation(.easeInOut(duration: 0.22), value: transfer.phase)
    }

    private func statusCard(title: String, subtitle: String, icon: String, tint: Color) -> some View {
        HStack(spacing: 13) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(tint)
                .frame(width: 46, height: 46)
                .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 14))
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline).foregroundStyle(.white)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 20))
    }
}

struct UnifiedSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var vm: AppViewModel
    var showsDoneButton = true
    @State private var destination: SettingsDestination?

    private enum SettingsDestination: String, Identifiable {
        case streaming, servers, downloads, subtitles, directLinks
        var id: String { rawValue }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    VStack(alignment: .leading, spacing: 7) {
                        Image(systemName: "gearshape.2.fill")
                            .font(.system(size: 34, weight: .semibold))
                            .foregroundStyle(AppPalette.gradient)
                        Text("Control Center")
                            .font(.system(size: 28, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                        Text("Manage your sources, subtitles, downloads, and direct links.")
                            .font(.subheadline)
                            .foregroundStyle(.white.opacity(0.5))
                    }

                    VStack(spacing: 12) {
                        settingsRow("Streaming", "Online platform, Orion and Real-Debrid", "play.tv.fill", .streaming)
                        settingsRow("Servers", "WebDAV, PikPak, Offcloud and TorBox accounts", "server.rack", .servers)
                        settingsRow("Downloads", "Current downloads and downloaded videos", "arrow.down.circle.fill", .downloads)
                        settingsRow("Subtitles", "Language, appearance and automatic search", "captions.bubble.fill", .subtitles)
                        settingsRow("Direct Links", "Add PikPak or any direct video link", "link.badge.plus", .directLinks)
                    }
                }
                .padding(.horizontal, 18)
                .padding(.top, 18)
                .padding(.bottom, 120)
            }
            .background(
                LinearGradient(
                    colors: [AppTheme.bg, AppPalette.accent.opacity(0.08), AppTheme.bg],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .ignoresSafeArea()
            )
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if showsDoneButton {
                    ToolbarItem(placement: .topBarLeading) {
                        AppAnimatedBackButton(size: 36) { dismiss() }
                    }
                }
            }
            .fullScreenCover(item: $destination) { item in destinationView(item) }
        }.preferredColorScheme(.dark)
    }

    private func settingsRow(_ title: String, _ subtitle: String, _ icon: String, _ target: SettingsDestination) -> some View {
        Button { destination = target } label: {
            HStack(spacing: 13) {
                Image(systemName: icon)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(AppPalette.gradient)
                    .frame(width: 46, height: 46)
                    .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.headline).foregroundStyle(.white)
                    Text(subtitle).font(.caption).foregroundStyle(.white.opacity(0.48)).lineLimit(2)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.caption.bold())
                    .foregroundStyle(.white.opacity(0.35))
            }
            .padding(14)
            .background(Color.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .stroke(Color.white.opacity(0.08), lineWidth: 0.8)
            )
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder private func destinationView(_ item: SettingsDestination) -> some View {
        switch item {
        case .streaming: StreamingPlatformSettingsView()
        case .servers: ServerAccountsSettingsView(vm: vm)
        case .downloads: DownloadManagerView()
        case .subtitles: SubtitleSettingsView()
        case .directLinks: DirectLinksSettingsView(vm: vm)
        }
    }
}

private struct StreamingPlatformSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("online_platform_experimental_enabled_v1") private var platformEnabled = true
    @AppStorage("online_playback_provider_preference_v1") private var playbackProvider =
        OnlinePlaybackProviderPreference.automatic.rawValue
    @State private var orionUserKey = ""
    @State private var orionAppKey = ""
    @State private var realDebridKey = ""
    @State private var stremioAddonURL = ""
    @State private var selectedSearchProviders = OnlineSearchProviderSelection.selected
    @State private var status = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    streamingHero
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 12, trailing: 0))
                }
                Section("Online Platform") {
                    Toggle("Enable Experimental Home", isOn: $platformEnabled)
                    Text("TMDB powers the catalogue. Your existing Content library and Resume Playback remain independent.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Playback Provider") {
                    Picker("Use", selection: $playbackProvider) {
                        ForEach(OnlinePlaybackProviderPreference.allCases) { provider in
                            Text(provider.title).tag(provider.rawValue)
                        }
                    }
                    Text("Playback uses only the provider selected here. Automatic tries configured services in order, starting with Real-Debrid.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Search Providers") {
                    Text("Choose one or more providers. Their results are combined, so you see more links for each quality.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ForEach(OnlineSearchProviderSelection.available) { provider in
                        Button { toggleSearchProvider(provider) } label: {
                            HStack(spacing: 12) {
                                Image(systemName: searchProviderIcon(provider))
                                    .font(.headline)
                                    .foregroundStyle(selectedSearchProviders.contains(provider) ? .white : AppPalette.accent)
                                    .frame(width: 34, height: 34)
                                    .background(selectedSearchProviders.contains(provider) ? AnyShapeStyle(AppPalette.gradient) : AnyShapeStyle(Color.white.opacity(0.08)), in: Circle())
                                Text(provider.title).foregroundStyle(.primary)
                                Spacer()
                                Image(systemName: selectedSearchProviders.contains(provider) ? "checkmark.circle.fill" : "circle")
                                    .font(.title3)
                                    .foregroundStyle(selectedSearchProviders.contains(provider) ? AppPalette.accent : .secondary)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }

                Section("Orion") {
                    SecureField("User API Key", text: $orionUserKey)
                        .textContentType(.password)
                    SecureField("Custom App API Key", text: $orionAppKey)
                        .textContentType(.password)
                    Text("Both values are stored in the iPhone Keychain. Never reuse another application's App Key.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Save Orion Credentials") { saveOrion() }
                        .disabled(orionUserKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                  && orionAppKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    if !OrionCredentialStore.userKey.isEmpty || !OrionCredentialStore.appKey.isEmpty {
                        Button("Remove Orion Credentials", role: .destructive) {
                            OrionCredentialStore.clear()
                            orionUserKey = ""
                            orionAppKey = ""
                            status = "Orion credentials removed"
                        }
                    }
                }

                Section("Real-Debrid") {
                    SecureField("API Token", text: $realDebridKey)
                        .textContentType(.password)
                    Text("Real-Debrid is contacted only when this token is configured.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Save Real-Debrid Token") {
                        let key = realDebridKey.trimmingCharacters(in: .whitespacesAndNewlines)
                        status = RealDebridKeyStore.save(key) ? "Real-Debrid token saved" : "Could not save token"
                    }
                    .disabled(realDebridKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    if !RealDebridKeyStore.key.isEmpty {
                        Button("Remove Real-Debrid Token", role: .destructive) {
                            _ = RealDebridKeyStore.clear()
                            realDebridKey = ""
                            status = "Real-Debrid token removed"
                        }
                    }
                }

                Section("Manual Stremio Add-on") {
                    SecureField("https://…/manifest.json", text: $stremioAddonURL)
                        .textContentType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Text("Paste a Stremio-compatible manifest URL here. If it contains a debrid token, it is stored securely in the iPhone Keychain. The add-on is searched first, alongside the existing Orion or Pirate Bay search.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Save Add-on URL") { saveStremioAddon() }
                        .disabled(stremioAddonURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    if StremioAddonStore.isConfigured {
                        Button("Remove Add-on URL", role: .destructive) {
                            _ = StremioAddonStore.clear()
                            stremioAddonURL = ""
                            status = "Manual add-on removed"
                        }
                    }
                }

                if !status.isEmpty {
                    Section("Status") { Text(status).font(.footnote).foregroundStyle(.secondary) }
                }
            }
            .scrollContentBackground(.hidden)
            .background(
                LinearGradient(colors: [AppTheme.bg, AppPalette.purple.opacity(0.18), AppTheme.bg], startPoint: .topLeading, endPoint: .bottomTrailing)
                    .ignoresSafeArea()
            )
            .navigationTitle("Streaming")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    AppAnimatedBackButton(size: 36) { dismiss() }
                }
            }
            .onAppear {
                orionUserKey = OrionCredentialStore.userKey
                orionAppKey = OrionCredentialStore.appKey
                realDebridKey = RealDebridKeyStore.key
                stremioAddonURL = StremioAddonStore.manifestURL
                selectedSearchProviders = OnlineSearchProviderSelection.selected
            }
        }
        .preferredColorScheme(.dark)
    }

    private func saveOrion() {
        let user = orionUserKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let app = orionAppKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if OrionCredentialStore.save(userKey: user, appKey: app) {
            status = OrionCredentialStore.isReady
                ? "Orion is ready"
                : "User key saved · Custom App Key is still required"
        } else {
            status = "Could not save Orion credentials"
        }
    }

    private func saveStremioAddon() {
        let value = stremioAddonURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: value), url.scheme?.lowercased() == "https",
              url.path.lowercased().hasSuffix("/manifest.json") else {
            status = "Enter a valid HTTPS URL ending in /manifest.json"
            return
        }
        status = StremioAddonStore.save(value) ? "Manual add-on saved" : "Could not save add-on URL"
    }

    private var streamingHero: some View {
        HStack(spacing: 14) {
            Image(systemName: "dot.radiowaves.left.and.right")
                .font(.system(size: 25, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 58, height: 58)
                .background(AppPalette.gradient, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            VStack(alignment: .leading, spacing: 4) {
                Text("Streaming Studio").font(.title3.bold()).foregroundStyle(.white)
                Text("Search, sources and playback in one place")
                    .font(.caption).foregroundStyle(.white.opacity(0.65))
            }
            Spacer()
        }
        .padding(16)
        .background(Color.white.opacity(0.075), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).stroke(Color.white.opacity(0.12), lineWidth: 1))
    }

    private func toggleSearchProvider(_ provider: OnlineSearchProviderPreference) {
        if selectedSearchProviders.contains(provider) {
            guard selectedSearchProviders.count > 1 else {
                status = "Keep at least one search provider enabled"
                return
            }
            selectedSearchProviders.remove(provider)
        } else {
            selectedSearchProviders.insert(provider)
        }
        OnlineSearchProviderSelection.selected = selectedSearchProviders
    }

    private func searchProviderIcon(_ provider: OnlineSearchProviderPreference) -> String {
        switch provider {
        case .stremioAddon: return "puzzlepiece.extension.fill"
        case .orion: return "sparkles"
        case .pirateBay: return "sailboat.fill"
        case .nyaa: return "tv.inset.filled"
        case .automatic: return "wand.and.stars"
        }
    }
}

private struct ServerAccountsSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var vm: AppViewModel
    @StateObject private var cloud = OffcloudViewModel()
    @State private var offcloudKey = ""
    @State private var torBoxKey = ""
    @State private var torBoxStatus = ""
    @State private var isSavingTorBox = false
    @State private var destination: ServerDestination?

    private enum ServerDestination: String, Identifiable {
        case webdav, pikpak, offcloud, torbox
        var id: String { rawValue }
    }

    var body: some View {
        NavigationStack {
            List {
                Section("Servers") {
                    serverRow("WebDAV", "PikPak, NAS and other WebDAV servers", "externaldrive.connected.to.line.below", .webdav)
                    serverRow("PikPak", "Import a secure rclone session for Discover", "bolt.horizontal.cloud.fill", .pikpak)
                    serverRow("Offcloud", "Offcloud account and cloud transfers", "cloud.fill", .offcloud)
                    serverRow("TorBox", "TorBox account and torrent library", "shippingbox.fill", .torbox)
                }
            }
            .navigationTitle("Servers")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    AppAnimatedBackButton(size: 36) { dismiss() }
                }
            }
            .fullScreenCover(item: $destination) { destinationView($0) }
            .onAppear {
                offcloudKey = cloud.apiKey
                torBoxKey = TorBoxKeyStore.load()
            }
        }
        .preferredColorScheme(.dark)
    }

    private func serverRow(_ title: String, _ subtitle: String, _ icon: String, _ target: ServerDestination) -> some View {
        Button { destination = target } label: {
            HStack(spacing: 13) {
                Image(systemName: icon).frame(width: 28).foregroundStyle(AppPalette.gradient)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).foregroundStyle(.primary)
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
            }
            .padding(.vertical, 3)
        }
    }

    @ViewBuilder private func destinationView(_ item: ServerDestination) -> some View {
        switch item {
        case .webdav:
            WebDAVSettingsView(vm: vm)
        case .pikpak:
            PikPakAccountSettingsView(vm: vm)
        case .offcloud:
            NavigationStack {
                Form {
                    Section("Offcloud API") {
                        SecureField("API Key", text: $offcloudKey).textContentType(.password)
                        Text("The key is stored securely in the iPhone Keychain.").font(.caption).foregroundStyle(.secondary)
                    }
                    Section {
                        Button("Save API Key") {
                            cloud.saveKey(offcloudKey)
                            destination = nil
                        }
                        .disabled(offcloudKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        if cloud.hasKey {
                            Button("Remove API Key", role: .destructive) {
                                cloud.clearKey()
                                offcloudKey = ""
                            }
                        }
                    }
                }
                .navigationTitle("Offcloud Settings")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        AppAnimatedBackButton(size: 36) { destination = nil }
                    }
                }
            }
            .preferredColorScheme(.dark)
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
                        Button { saveTorBoxAccount() } label: {
                            if isSavingTorBox { HStack { ProgressView(); Text("Connecting…") } }
                            else { Text("Save and Sync TorBox") }
                        }
                        .disabled(isSavingTorBox || torBoxKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        if !TorBoxKeyStore.load().isEmpty {
                            Button("Remove TorBox Account", role: .destructive) {
                                _ = TorBoxKeyStore.delete()
                                TorBoxLibraryStore.clear()
                                torBoxKey = ""
                                torBoxStatus = ""
                            }
                        }
                    }
                }
                .navigationTitle("TorBox Settings")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        AppAnimatedBackButton(size: 36) { destination = nil }
                    }
                }
            }
            .preferredColorScheme(.dark)
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

private struct PikPakAccountSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var vm: AppViewModel
    @State private var showRcloneImporter = false
    @State private var showRcloneRemotePicker = false
    @State private var rcloneRemotes: [PikPakRcloneRemote] = []
    @State private var isConnecting = false
    @State private var status = ""

    private var isConnected: Bool {
        vm.pikpakAccount != nil || PikPakClient.shared.loadAccount() != nil
    }

    private var connectedAccountName: String? {
        (vm.pikpakAccount ?? PikPakClient.shared.loadAccount())?.displayName
    }

    private var allowedConfigurationTypes: [UTType] {
        var types: [UTType] = [.plainText, .data]
        if let conf = UTType(filenameExtension: "conf") { types.insert(conf, at: 0) }
        return types
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("PikPak Session") {
                    HStack(spacing: 12) {
                        Image(systemName: isConnected ? "checkmark.circle.fill" : "person.crop.circle.badge.questionmark")
                            .font(.title2)
                            .foregroundStyle(isConnected ? Color.green : AppPalette.accent)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(isConnected ? "Connected" : "Not Connected")
                                .font(.headline)
                            Text(isConnected
                                 ? "\(connectedAccountName ?? "PikPak") · Session stored in Keychain."
                                 : "Import the rclone.conf created on your computer.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                }

                Section("Import from rclone") {
                    Button {
                        showRcloneImporter = true
                    } label: {
                        HStack(spacing: 10) {
                            if isConnecting { ProgressView() }
                            else { Image(systemName: "doc.badge.arrow.up.fill") }
                            Text(isConnecting ? "Checking PikPak Session…" : "Import rclone.conf")
                        }
                    }
                    .disabled(isConnecting)

                    Text("Move rclone.conf to iCloud Drive or On My iPhone, then select it here. The token is read locally and is never displayed.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if !status.isEmpty {
                    Section("Status") {
                        Text(status)
                            .font(.footnote)
                            .foregroundStyle(status.hasPrefix("Connected") ? Color.green : Color.secondary)
                    }
                }

                if isConnected {
                    Section {
                        Button("Disconnect PikPak", role: .destructive) {
                            vm.pikpakLogout()
                            status = ""
                        }
                    }
                }
            }
            .navigationTitle("PikPak Account")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    AppAnimatedBackButton(size: 36) { dismiss() }
                }
            }
            .fileImporter(
                isPresented: $showRcloneImporter,
                allowedContentTypes: allowedConfigurationTypes,
                allowsMultipleSelection: false,
                onCompletion: importRcloneConfiguration
            )
            .confirmationDialog(
                "Choose PikPak Account",
                isPresented: $showRcloneRemotePicker,
                titleVisibility: .visible
            ) {
                ForEach(rcloneRemotes) { remote in
                    Button(remote.name) { connect(to: remote) }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Select the rclone remote that belongs to your Premium account.")
            }
        }
        .preferredColorScheme(.dark)
    }

    private func importRcloneConfiguration(_ result: Result<[URL], Error>) {
        switch result {
        case let .failure(error):
            status = error.localizedDescription
        case let .success(urls):
            guard let url = urls.first else { return }
            let didAccess = url.startAccessingSecurityScopedResource()
            defer { if didAccess { url.stopAccessingSecurityScopedResource() } }

            do {
                let data = try Data(contentsOf: url)
                guard let configuration = String(data: data, encoding: .utf8),
                      !configuration.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw PikPakError.invalidCredentials
                }
                let remotes = PikPakClient.shared.rcloneRemotes(from: configuration)
                guard !remotes.isEmpty else { throw PikPakError.invalidCredentials }
                if remotes.count == 1, let remote = remotes.first {
                    connect(to: remote)
                } else {
                    rcloneRemotes = remotes
                    status = "Choose which PikPak account to connect."
                    showRcloneRemotePicker = true
                }
            } catch {
                status = error.localizedDescription
            }
        }
    }

    private func connect(to remote: PikPakRcloneRemote) {
        isConnecting = true
        status = "Checking \(remote.name)…"
        Task { @MainActor in
            if let error = await vm.pikpakLoginWithPersonalAccessToken(
                remote.configuration,
                label: remote.name
            ) {
                status = error
            } else {
                status = "Connected · \(remote.name)"
            }
            isConnecting = false
        }
    }
}

private struct DirectLinksSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var vm: AppViewModel
    @State private var link = ""
    @State private var message: String?
    @State private var isResolving = false
    @State private var showPlayer = false
    @State private var showDownloads = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Add Link") {
                    TextField("PikPak or direct video URL", text: $link, axis: .vertical)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)

                    Button {
                        if let value = UIPasteboard.general.string?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
                            link = value
                            message = nil
                        } else {
                            message = "Clipboard is empty"
                        }
                    } label: {
                        Label("Paste", systemImage: "doc.on.clipboard")
                    }

                    Button { saveLink() } label: {
                        Label("Add to Library", systemImage: "plus.circle.fill")
                    }
                    .disabled(!hasLink || isResolving)

                    HStack(spacing: 10) {
                        Button { watchLink() } label: {
                            Label("Watch", systemImage: "play.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)

                        Button { downloadLink() } label: {
                            Label("Download", systemImage: "arrow.down.circle.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                    }
                    .disabled(!hasLink || isResolving)

                    if isResolving {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text("Resolving link…")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                if let message {
                    Section { Text(message).font(.footnote).foregroundStyle(.secondary) }
                }

                Section {
                    Text("Supports direct HTTP video streams, HLS, PikPak direct/share links, and magnet links.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Direct Links")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    AppAnimatedBackButton(size: 36) { dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
        .fullScreenCover(isPresented: $showPlayer) {
            ResolvedPlayerScreen(vm: vm)
        }
        .fullScreenCover(isPresented: $showDownloads) {
            DownloadManagerView()
        }
    }

    private var hasLink: Bool {
        !link.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func saveLink() {
        let raw = link.trimmingCharacters(in: .whitespacesAndNewlines)
        let kind = LinkResolver.classify(raw)
        let saved: SavedVideoLink?

        switch kind {
        case .magnet, .pikpakMagnet:
            saved = vm.saveDirectLink(raw, source: .direct, title: "Magnet link")
        case .pikpakShare:
            saved = vm.saveDirectLink(raw, source: .pikpak, title: "PikPak Share")
        case .pikpakDirect:
            saved = vm.saveDirectLink(
                raw,
                resolvedStream: LinkResolver.resolvePikPakDirectStream(raw),
                source: .pikpak,
                title: LinkResolver.pikpakDirectDisplayTitle(raw)
            )
        default:
            saved = vm.saveDirectLink(raw)
        }

        if saved != nil {
            link = ""
            message = "Link added to the library"
        } else {
            message = "Invalid link. Use a direct URL, PikPak link, HLS, or magnet."
        }
    }

    private func watchLink() {
        let raw = link.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return }
        isResolving = true
        message = nil

        Task {
            let error = await vm.openUserLink(raw)
            await MainActor.run {
                isResolving = false
                if let error {
                    message = error
                } else if vm.nowPlayingURL != nil {
                    showPlayer = true
                } else {
                    message = "Could not resolve this link for playback."
                }
            }
        }
    }

    private func downloadLink() {
        let raw = link.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return }
        isResolving = true
        message = nil

        Task {
            let error = await vm.openUserLink(raw)
            await MainActor.run {
                isResolving = false
                guard error == nil, let streamURL = vm.nowPlayingURL else {
                    message = error ?? "Could not resolve this link for download."
                    return
                }

                let resolvedTitle = vm.nowPlaying?.name ?? VideoTitleFormatter.title(from: streamURL.lastPathComponent)
                let title = resolvedTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Video" : resolvedTitle
                let fileName = streamURL.lastPathComponent.isEmpty ? "\(title).mp4" : streamURL.lastPathComponent
                VideoDownloadManager.shared.startDownload(
                    url: streamURL,
                    stableKey: "direct-link|\(raw)",
                    title: title,
                    suggestedFileName: fileName,
                    headers: vm.nowPlayingHeaders ?? [:]
                )
                message = "Download started"
                showDownloads = true
            }
        }
    }
}
