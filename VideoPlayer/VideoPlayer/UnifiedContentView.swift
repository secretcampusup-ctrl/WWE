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
    var adultScene: ThePornDBScene?
    var manualMetadataProvider: String?
    /// False means the file was published immediately and its TMDB lookup is
    /// still queued in the background. Nil is reserved for legacy snapshots.
    var metadataLookupCompleted: Bool? = nil
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
        metadataLookupCompleted: true,
        adultLookupCompleted: true
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
    private var adultEnrichmentTask: Task<Void, Never>?
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
            // A refresh replaces the previous scan. Never let an older adult
            // enrichment pass continue mutating the same array in parallel.
            adultEnrichmentTask?.cancel()
            adultEnrichmentTask = nil
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
                if !startEpisodeEnrichmentIfNeeded() { _ = startAdultEnrichmentIfNeeded() }
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
                            adultScene: entry.adultScene,
                            manualMetadataProvider: entry.manualMetadataProvider,
                            metadataLookupCompleted: entry.metadataLookupCompleted,
                            adultLookupCompleted: entry.adultLookupCompleted
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
        // Keep completed adult matches while refreshing provider file lists.
        // Otherwise every refresh would discard posters and repeat the same API
        // requests while the TMDB queue runs in the background.
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
                entry.adultScene = previous.adultScene
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
                if let previous = preservedEntry {
                    let retryPreservedIdentifier = previous.manualMetadataProvider == nil
                        && metadataSignature != previousMetadataSignature
                        && VideoTitleFormatter.catalogIdentifier(from: entry.rawTitle) != nil
                    if retryPreservedIdentifier {
                        entry.adultScene = nil
                        entry.adultLookupCompleted = false
                    } else {
                        entry.adultScene = previous.adultScene
                        entry.adultLookupCompleted = previous.adultLookupCompleted
                        if previous.adultScene != nil { entry.title = previous.title }
                    }
                }
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
            if !startEpisodeEnrichmentIfNeeded() { _ = startAdultEnrichmentIfNeeded() }
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
            if !self.startEpisodeEnrichmentIfNeeded() { _ = self.startAdultEnrichmentIfNeeded() }
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

    private func enrichUnknownWithAdultMetadata() async {
        var items = unknown
        var changedSincePublish = 0
        // Process up to 200 still-pending entries per pass. Filtering the indices
        // first ensures libraries larger than 200 continue on later launches.
        let pendingIndices = Array(items.indices.filter {
            items[$0].metadataLookupCompleted != false
                && items[$0].adultLookupCompleted != true
        }.prefix(200))
        for index in pendingIndices {
            guard !Task.isCancelled else { return }
            // Match VideoDetailsView exactly. The former TMDB release-name
            // cleaner produced a different query for adult filenames, which is
            // why opening Details found a cover while Content refresh did not.
            let query = VideoTitleFormatter.title(from: items[index].title)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !query.isEmpty else {
                items[index].adultLookupCompleted = true
                changedSincePublish += 1
                continue
            }
            let isJavCode = VideoTitleFormatter.catalogIdentifier(from: query) != nil
            let response = isJavCode
                ? try? await ThePornDBAPIService.shared.searchJav(query: query, limit: 5)
                : try? await ThePornDBAPIService.shared.searchScenes(query: query, limit: 5)
            if let response {
                guard !Task.isCancelled else { return }
                items[index].adultLookupCompleted = true
                changedSincePublish += 1
                if let scene = bestAdultMatch(response.list, query: query) ?? response.list.first {
                    items[index].adultScene = scene
                    items[index].title = scene.title ?? items[index].title
                    let posterKey = "unified|\(items[index].id)"
                    let adultPosterKey = "unified-adult|\(items[index].id)"
                    let existingPoster = await VideoThumbnailLoader.cachedImageAsync(forStableKey: adultPosterKey)
                    if existingPoster == nil, let imageURL = scene.bestImage {
                        await ThumbnailLoadGate.shared.acquire()
                        let cover = try? await ThePornDBAPIService.shared.downloadImage(from: imageURL)
                        await ThumbnailLoadGate.shared.release()
                        guard !Task.isCancelled else { return }
                        if let cover {
                            VideoThumbnailLoader.cacheImageInBackground(cover, forStableKeys: [
                                adultPosterKey,
                                posterKey,
                                VideoThumbnailLoader.canonicalPosterCacheKey(for: items[index].rawTitle)
                            ])
                        }
                    }
                } else if let metadata = await VideoThumbnailLoader.fetchThePornDBMetadata(for: query) {
                    guard !Task.isCancelled else { return }
                    // No scene: use the shared performer fallback. Cache its image
                    // under the same stable key consumed by the Unknown poster grid.
                    items[index].title = metadata.title ?? items[index].title
                    if let cover = metadata.coverImage {
                        VideoThumbnailLoader.cacheImageInBackground(cover, forStableKeys: [
                            "unified-adult|\(items[index].id)",
                            "unified|\(items[index].id)"
                        ])
                    }
                }
                // Publishing a 500+ item array for every metadata response makes
                // SwiftUI re-diff the visible grids while the user is scrolling.
                // Commit a bounded batch instead, then yield a frame.
                if changedSincePublish >= 24 {
                    unknown = items
                    persistSnapshot()
                    changedSincePublish = 0
                    await Task.yield()
                }
            }
            try? await Task.sleep(nanoseconds: 80_000_000)
        }
        unknown = items.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        persistSnapshot()
    }

    private static func currentMetadataSignature() -> String {
        "tmdb:" + stableSignature(TMDBSettings.readAccessToken)
            + "|tpdb:" + stableSignature(ThePornDBSettings.apiKey)
            + "|matcher:release-v2-adult-v3-jav-details-poster-v1"
    }

    func applyManualTMDB(_ details: TMDBTitleDetails, to entry: UnifiedMediaEntry) {
        guard var value = takeEntry(id: entry.id) else { return }
        value.details = details
        value.adultScene = nil
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

    func applyManualAdult(_ scene: ThePornDBScene, image: UIImage, to entry: UnifiedMediaEntry) {
        guard var value = takeEntry(id: entry.id) else { return }
        value.details = nil
        value.adultScene = scene
        value.title = scene.title ?? value.title
        value.adultLookupCompleted = true
        value.manualMetadataProvider = "theporndb"
        value.metadataLookupCompleted = true
        value.episodes = []
        unknown.append(value)
        unknown.sort { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        persistSnapshot()
        VideoThumbnailLoader.cacheImageInBackground(image, forStableKeys: [
            "unified-manual|\(entry.id)",
            "unified-adult|\(entry.id)",
            "unified|\(entry.id)"
        ])
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

    @discardableResult
    private func startAdultEnrichmentIfNeeded() -> Bool {
        guard ThePornDBSettings.hasValidAPIKey,
              unknown.contains(where: {
                  $0.metadataLookupCompleted != false && $0.adultLookupCompleted != true
              }),
              adultEnrichmentTask == nil else { return adultEnrichmentTask != nil }
        adultEnrichmentTask = Task { [weak self] in
            guard let self else { return }
            await self.enrichUnknownWithAdultMetadata()
            guard !Task.isCancelled else { return }
            self.adultEnrichmentTask = nil
            self.startDetailsArtworkPrefetchIfNeeded()
        }
        return true
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
                _ = self.startAdultEnrichmentIfNeeded()
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
            if !self.startAdultEnrichmentIfNeeded() {
                self.startDetailsArtworkPrefetchIfNeeded()
            }
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

        // A completed lookup is final. Scrolling or refreshing must not turn an
        // old unmatched item into another provider request.
        guard entry.adultLookupCompleted != true else { return }

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

    init(
        vm: AppViewModel,
        entry: UnifiedMediaEntry,
        section: UnifiedMediaSection,
        categoryEntries: [UnifiedMediaEntry]
    ) {
        self.vm = vm
        self.section = section
        self.categoryEntries = categoryEntries
        _activeEntry = State(initialValue: entry)
        _selection = StateObject(wrappedValue: UnifiedEpisodeSelection(id: entry.episodes.first?.id))
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
        .id(
            "\(activeEntry.id)|\(activeEntry.details?.cast.count ?? 0)"
                + "|\(activeEntry.details?.runtimeMinutes ?? -1)"
                + "|\(activeEntry.details?.logoPath ?? "")"
        )
        .task(id: activeEntry.id) {
            guard case let .catalog(mediaType, _) = activeEntry.source else { return }
            if let details = await TMDBService.shared.detailsOriginalFirst(
                for: activeEntry.title,
                preferredMediaType: mediaType
            ) {
                activeEntry.details = details
            }
        }
        .fullScreenCover(isPresented: $showPlayer) {
            ResolvedPlayerScreen(
                vm: vm,
                episodeOptions: playerEpisodeOptions,
                onSelectEpisode: switchPlayerEpisode
            )
        }
        .fullScreenCover(isPresented: $showOnlineSources) {
            ExperimentalOnlineSourcesView(entry: activeEntry)
        }
    }

    private var relatedEpisodes: [VideoEpisodeItem] {
        activeEntry.episodes.map {
            VideoEpisodeItem(id: $0.id, title: $0.title, season: $0.season, episode: $0.episode)
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
                suppliedAdultMetadata: suppliedAdultMetadata,
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
            suppliedAdultMetadata: suppliedAdultMetadata,
            manualMetadataProvider: activeEntry.manualMetadataProvider
        )
    }

    private func playbackHeaders(for source: UnifiedSource) -> [String: String] {
        guard case let .webDAV(server, _) = source else { return [:] }
        return WebDAVClient(server: server).streamHeaders()
    }

    private var suppliedAdultMetadata: VideoThumbnailLoader.ThePornDBMetadata? {
        guard let scene = activeEntry.adultScene else { return nil }
        return VideoThumbnailLoader.ThePornDBMetadata(
            source: .scene,
            title: scene.title,
            performers: (scene.performers ?? []).compactMap(\.name),
            tags: scene.tagNames,
            date: scene.date,
            siteName: scene.site,
            // VideoDetailsView resolves the same stable poster keys
            // asynchronously. Never decode disk images while constructing a
            // navigation destination.
            coverImage: nil
        )
    }

    private func playCurrent() {
        // Keep the exact unified-library identity attached to playback. Adult/JAV
        // metadata can change the displayed title while the details screen is open,
        // so relying on title/source reconstruction made some Others entries miss
        // Resume Playback even though their progress tick was received.
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
            showOnlineSources = true
            return
        }
        showPlayer = true
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

private struct ExperimentalOnlineSourcesView: View {
    let entry: UnifiedMediaEntry
    @Environment(\.dismiss) private var dismiss

    private var activeProviders: [String] {
        var values: [String] = []
        if !TorBoxKeyStore.load().isEmpty { values.append("TorBox") }
        if !RealDebridKeyStore.key.isEmpty { values.append("Real-Debrid") }
        if !OffcloudKeyStore.load().isEmpty { values.append("Offcloud") }
        if PikPakClient.shared.loadAccount() != nil { values.append("PikPak") }
        return values
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(entry.title)
                            .font(.title2.bold())
                            .foregroundStyle(.white)
                        Text("Streaming Sources · Experimental")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    statusCard(
                        title: OrionCredentialStore.isReady ? "Orion Ready" : "Orion App Key Required",
                        subtitle: OrionCredentialStore.isReady
                            ? "This title is ready for an automatic Orion lookup."
                            : "Add a regenerated User API Key and your Custom App API Key in Settings.",
                        icon: OrionCredentialStore.isReady ? "checkmark.seal.fill" : "key.fill",
                        tint: OrionCredentialStore.isReady ? .green : .orange
                    )

                    VStack(alignment: .leading, spacing: 12) {
                        Text("ACTIVE PLAYBACK SERVICES")
                            .font(.caption.bold())
                            .tracking(0.8)
                            .foregroundStyle(.secondary)
                        if activeProviders.isEmpty {
                            Text("No playback service is connected. The app will never contact an unconfigured provider.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(activeProviders, id: \.self) { provider in
                                Label(provider, systemImage: "checkmark.circle.fill")
                                    .font(.headline)
                                    .foregroundStyle(.white)
                            }
                        }
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 20))

                    Text("Orion searches only after a title is opened. Home browsing never consumes Orion requests.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 4)
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
        }
        .preferredColorScheme(.dark)
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
    @State private var orionUserKey = ""
    @State private var orionAppKey = ""
    @State private var realDebridKey = ""
    @State private var status = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Online Platform") {
                    Toggle("Enable Experimental Home", isOn: $platformEnabled)
                    Text("TMDB powers the catalogue. Your existing Content library and Resume Playback remain independent.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
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

                if !status.isEmpty {
                    Section("Status") { Text(status).font(.footnote).foregroundStyle(.secondary) }
                }
            }
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
            saved = vm.saveDirectLink(raw, source: .pikpak, title: "Magnet link")
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
