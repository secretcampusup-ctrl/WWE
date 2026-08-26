import Foundation
import Combine
import UIKit

/// قائمة تشغيل يُنشئها المستخدم — تحتفظ فقط بمعرّفات الفيديوهات
/// الموجودة أصلاً بالمكتبة (savedLinks) حتى لا يتكرر تخزين البيانات
struct VideoPlaylist: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String
    var linkIDs: [UUID]
    var dateCreated: Date

    init(id: UUID = UUID(), name: String, linkIDs: [UUID] = [], dateCreated: Date = Date()) {
        self.id = id
        self.name = name
        self.linkIDs = linkIDs
        self.dateCreated = dateCreated
    }
}

struct PlaybackHistoryEntry: Identifiable, Codable, Equatable {
    let id: String
    var title: String
    var source: String
    var posterCacheKey: String?
    var positionSeconds: Double
    var durationSeconds: Double
    var watchedAt: Date

    var hasResumePoint: Bool {
        positionSeconds > 3
            && (durationSeconds <= 0
                || (positionSeconds < durationSeconds * 0.95 && durationSeconds - positionSeconds > 5))
    }
}

/// Serializes library snapshots away from the main thread. Revisions prevent
/// an older, slower task from overwriting a newer favorite state.
private actor SavedLinksPersistenceWriter {
    private var latestRevision = 0

    func persist(_ links: [SavedVideoLink], key: String, revision: Int) {
        guard revision > latestRevision else { return }
        latestRevision = revision
        guard let data = try? JSONEncoder().encode(links) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}

/// Playlist JSON can grow considerably with a large library. Encoding it and
/// forcing UserDefaults to synchronize on the MainActor made the first tap feel
/// ignored. Revisions keep this background writer ordered without blocking UI.
private actor PlaylistsPersistenceWriter {
    private var latestRevision = 0

    func persist(_ playlists: [VideoPlaylist], key: String, revision: Int) {
        guard revision > latestRevision else { return }
        latestRevision = revision
        guard let data = try? JSONEncoder().encode(playlists) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}

@MainActor
class AppViewModel: ObservableObject {
    @Published var servers: [WebDAVServer] = []
    @Published var currentFiles: [WebDAVFile] = []
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var currentPath: [String] = []
    @Published var selectedServer: WebDAVServer?
    @Published var nowPlaying: WebDAVFile?
    @Published var nowPlayingURL: URL?
    /// Extra HTTP headers for the current stream (WebDAV Basic Auth, etc.).
    @Published var nowPlayingHeaders: [String: String]?
    /// Library entry currently playing (for resume + badges).
    @Published var nowPlayingLinkId: UUID?
    @Published var nowPlayingResumeAt: Double = 0
    @Published var nowPlayingSubtitleContext: SubtitleMediaContext?
    /// App-wide online preparation state. It intentionally lives on the view
    /// model rather than the source sheet so an uncached debrid transfer keeps
    /// running while the user browses other sections.
    @Published private(set) var onlinePlaybackTransfer: OnlinePlaybackTransfer?
    private var onlinePlaybackPreparationTask: Task<Void, Never>?
    private var preparedOnlinePlayback: ResolvedOnlinePlayback?
    /// The library identity belongs to the title/episode selected before a
    /// provider resolves its temporary stream URL. Keep it beside that
    /// preparation so every provider reaches the same playback-history path.
    private var preparedOnlinePlaybackHistoryItem: VideoDetailsItem?
    /// Library of auto-saved links (newest first).
    @Published var savedLinks: [SavedVideoLink] = []
    /// Small local-only resume history. It never stores stream URLs and never
    /// starts metadata, artwork, or provider requests.
    @Published private(set) var playbackHistory: [String: PlaybackHistoryEntry] = [:]

    var recentPlaybackHistory: [PlaybackHistoryEntry] {
        Array(playbackHistory.values.sorted { $0.watchedAt > $1.watchedAt }.prefix(12))
    }

    /// Videos explicitly pinned by the user, newest favorites first.
    var favoriteLinks: [SavedVideoLink] {
        savedLinks
            .filter { $0.isFavorite && $0.isVisibleInLibrary }
            .sorted { $0.dateAdded > $1.dateAdded }
    }

    var visibleSavedLinks: [SavedVideoLink] {
        savedLinks.filter(\.isVisibleInLibrary)
    }

    /// قوائم التشغيل التي أنشأها المستخدم، الأحدث أولاً
    @Published var playlists: [VideoPlaylist] = []

    /// PikPak session state (optional - login UI removed; used only for share/magnet if still signed in)
    @Published var pikpakAccount: PikPakAccount?
    @Published var pikpakFiles: [PikPakFileItem] = []
    @Published var pikpakPath: [(id: String, name: String)] = []
    private var pikpakFilesCache: [String: [PikPakFileItem]] = [:]
    private var pikpakNativeDirectoryCache: [String: [PikPakFileItem]] = [:]
    private var pikpakWebDAVFileIDCache: [String: String] =
        UserDefaults.standard.dictionary(forKey: "pikpak_webdav_file_ids_v1") as? [String: String] ?? [:]
    @Published var pikpakStatus: String?

    private let serversKey = "saved_servers"
    private let linksKey = "saved_video_links_v2"
    private let playlistsKey = "video_playlists_v1"
    private let pikPakCachePrefix = "pikpak_webdav_cache_v1_"
    private let playbackHistoryKey = "playback_history_v1"
    private let savedLinksPersistenceWriter = SavedLinksPersistenceWriter()
    private var savedLinksPersistenceRevision = 0
    private let playlistsPersistenceWriter = PlaylistsPersistenceWriter()
    private var playlistsPersistenceRevision = 0
    private var pendingHistoryItem: (id: String, title: String, source: String, posterCacheKey: String?)?
    private var pendingHistoryProgress: (position: Double, duration: Double)?

    init() {
        loadServers()
        loadSavedLinks()
        loadPlaylists()
        loadPlaybackHistory()
        pikpakAccount = PikPakClient.shared.loadAccount()
    }

    private func loadPlaybackHistory() {
        guard let data = UserDefaults.standard.data(forKey: playbackHistoryKey),
              let values = try? JSONDecoder().decode([PlaybackHistoryEntry].self, from: data) else { return }
        playbackHistory = Dictionary(uniqueKeysWithValues: values.map { ($0.id, $0) })
    }

    private func persistPlaybackHistory() {
        let values = playbackHistory.values
            .sorted { $0.watchedAt > $1.watchedAt }
            .prefix(100)
        guard let data = try? JSONEncoder().encode(Array(values)) else { return }
        UserDefaults.standard.set(data, forKey: playbackHistoryKey)
    }

    func preparePlaybackHistory(for item: VideoDetailsItem) {
        pendingHistoryItem = (
            item.id,
            item.title,
            item.source,
            item.posterCacheKey ?? VideoThumbnailLoader.canonicalPosterCacheKey(for: item.title)
        )
        pendingHistoryProgress = nil
        let episode = item.relatedEpisodes.first(where: { $0.id == item.id })
        let parsedEpisode = VideoTitleFormatter.episodeComponents(from: item.title)
        if let details = item.suppliedTMDBDetails {
            nowPlayingSubtitleContext = SubtitleMediaContext(
                title: details.title,
                tmdbID: details.id,
                mediaType: details.mediaType,
                season: episode?.season ?? parsedEpisode?.season,
                episode: episode?.episode ?? parsedEpisode?.episode
            )
        } else {
            nowPlayingSubtitleContext = nil
        }
    }

    func playbackHistoryEntry(for item: VideoDetailsItem) -> PlaybackHistoryEntry? {
        playbackHistory[item.id]
    }

    /// Commits once when the player closes. Calling it again is harmless.
    func finishPlaybackHistory() {
        guard let item = pendingHistoryItem else { return }
        defer {
            pendingHistoryItem = nil
            pendingHistoryProgress = nil
        }
        guard let progress = pendingHistoryProgress, progress.position > 3 else { return }

        let nearEnd = progress.duration > 0
            && (progress.position >= progress.duration * 0.95 || progress.duration - progress.position < 5)
        let entry = PlaybackHistoryEntry(
            id: item.id,
            title: item.title,
            source: item.source,
            posterCacheKey: item.posterCacheKey,
            positionSeconds: nearEnd ? 0 : progress.position,
            durationSeconds: progress.duration,
            watchedAt: Date()
        )
        playbackHistory[item.id] = entry
        persistPlaybackHistory()
    }

    // MARK: - Persistence: servers

    func loadServers() {
        guard let data = UserDefaults.standard.data(forKey: serversKey),
              let decoded = try? JSONDecoder().decode([WebDAVServer].self, from: data) else { return }
        servers = decoded
    }

    func saveServers() {
        if let data = try? JSONEncoder().encode(servers) {
            UserDefaults.standard.set(data, forKey: serversKey)
            UserDefaults.standard.synchronize()
        }
    }

    func addServer(_ server: WebDAVServer) {
        servers.append(server)
        saveServers()
    }

    func updateServer(_ server: WebDAVServer) {
        if let idx = servers.firstIndex(where: { $0.id == server.id }) {
            servers[idx] = server
            saveServers()
        }
    }

    func deleteServer(at offsets: IndexSet) {
        servers.remove(atOffsets: offsets)
        saveServers()
    }

    func deleteServer(_ server: WebDAVServer) {
        servers.removeAll { $0.id == server.id }
        saveServers()
    }

    // MARK: - Persistence: links

    func loadSavedLinks() {
        // Prefer v2; fall back to v1 key for upgrades
        let data = UserDefaults.standard.data(forKey: linksKey)
            ?? UserDefaults.standard.data(forKey: "saved_video_links")
        guard let data,
              let decoded = try? JSONDecoder().decode([SavedVideoLink].self, from: data) else {
            savedLinks = []
            return
        }
        var migrated = decoded
        var didMigrate = false
        for index in migrated.indices {
            guard let reference = Self.torBoxReference(from: migrated[index].urlString)
                    ?? Self.torBoxReference(from: migrated[index].resolvedStreamURL) else { continue }
            if migrated[index].source != .torbox
                || migrated[index].torBoxTorrentId != reference.torrentId
                || migrated[index].torBoxFileId != reference.fileId
                || migrated[index].resolvedStreamURL != nil {
                migrated[index].source = .torbox
                migrated[index].torBoxTorrentId = reference.torrentId
                migrated[index].torBoxFileId = reference.fileId
                // This is an internal reference, never a playable stream URL.
                migrated[index].resolvedStreamURL = nil
                didMigrate = true
            }
        }
        savedLinks = migrated.sorted { ($0.lastPlayed ?? $0.dateAdded) > ($1.lastPlayed ?? $1.dateAdded) }
        if didMigrate { persistSavedLinksImmediately() }
    }

    func persistSavedLinksImmediately() {
        savedLinksPersistenceRevision += 1
        let revision = savedLinksPersistenceRevision
        let snapshot = savedLinks
        let key = linksKey
        let writer = savedLinksPersistenceWriter
        Task(priority: .utility) {
            await writer.persist(snapshot, key: key, revision: revision)
        }
    }

    func isFavorite(_ item: VideoDetailsItem) -> Bool {
        savedLinks.first(where: { matches($0, item: item) })?.isFavorite == true
    }

    @discardableResult
    func toggleFavorite(_ item: VideoDetailsItem) -> Bool {
        if let index = savedLinks.firstIndex(where: { matches($0, item: item) }) {
            var updated = savedLinks[index]
            updated.isFavorite.toggle()
            updated.favoriteIdentity = item.id
            upgradeProviderReference(&updated, from: item)
            savedLinks[index] = updated
            let result = updated.isFavorite
            savedLinks = savedLinks
            persistSavedLinksImmediately()
            if result { cachePoster(for: item, savedID: updated.id) }
            return result
        }

        let source = providerSource(for: item)
        let torBox = Self.torBoxReference(from: item.url.absoluteString)
        let link = SavedVideoLink(
            urlString: item.url.absoluteString,
            resolvedStreamURL: source == .torbox ? nil : item.url.absoluteString,
            title: item.title,
            dateAdded: Date(),
            lastPlayed: nil,
            source: source,
            torBoxTorrentId: torBox?.torrentId,
            torBoxFileId: torBox?.fileId,
            durationSeconds: item.durationSeconds,
            videoWidth: item.videoWidth,
            videoHeight: item.videoHeight,
            fileSizeBytes: item.fileSizeBytes,
            isFavorite: true,
            favoriteIdentity: item.id
        )
        savedLinks.insert(link, at: 0)
        persistSavedLinksImmediately()
        cachePoster(for: item, savedID: link.id)
        return true
    }

    private func cachePoster(for item: VideoDetailsItem, savedID: UUID) {
        // Poster lookup, resize and WebP disk writes are intentionally detached
        // from the heart button. The favorite state has already been published
        // and persisted before this work begins.
        let title = item.title
        let itemID = item.id
        let customImage = item.customPosterImage
        let customPosterFileName = item.customPosterFileName
        let posterCacheKey = item.posterCacheKey
        DispatchQueue.global(qos: .utility).async {
            let canonicalKey = VideoThumbnailLoader.canonicalPosterCacheKey(for: title)
            let image = customImage
                ?? customPosterFileName.flatMap { VideoThumbnailLoader.loadCustomPoster(fileName: $0) }
                ?? posterCacheKey.flatMap { VideoThumbnailLoader.cachedImage(forStableKey: $0) }
                ?? VideoThumbnailLoader.cachedImage(forStableKey: canonicalKey)
            guard let image else { return }
            VideoThumbnailLoader.cacheImage(image, forStableKey: "saved|\(savedID.uuidString)")
            VideoThumbnailLoader.cacheImage(image, forStableKey: itemID)
            VideoThumbnailLoader.cacheImage(image, forStableKey: canonicalKey)
            if let posterCacheKey { VideoThumbnailLoader.cacheImage(image, forStableKey: posterCacheKey) }
        }
    }
    private func matches(_ link: SavedVideoLink, item: VideoDetailsItem) -> Bool {
        let target = item.url.absoluteString
        return link.favoriteIdentity == item.id
            || link.urlString == target
            || link.resolvedStreamURL == target
            || link.url?.absoluteString == target
    }

    /// يرجع مدخل المكتبة المطابق للفيديو، أو ينشئ واحداً جديداً إن لم يكن محفوظاً بعد
    /// (يُستخدم من المفضلة وقوائم التشغيل معاً حتى لا يتكرر منطق الإنشاء)
    @discardableResult
    private func resolvedLink(for item: VideoDetailsItem) -> SavedVideoLink {
        if let existing = savedLinks.first(where: { matches($0, item: item) }) {
            return existing
        }

        let source = providerSource(for: item)
        let torBox = Self.torBoxReference(from: item.url.absoluteString)
        let link = SavedVideoLink(
            urlString: item.url.absoluteString,
            resolvedStreamURL: source == .torbox ? nil : item.url.absoluteString,
            title: item.title,
            dateAdded: Date(),
            lastPlayed: nil,
            source: source,
            torBoxTorrentId: torBox?.torrentId,
            torBoxFileId: torBox?.fileId,
            durationSeconds: item.durationSeconds,
            videoWidth: item.videoWidth,
            videoHeight: item.videoHeight,
            fileSizeBytes: item.fileSizeBytes,
            isFavorite: false,
            favoriteIdentity: item.id
        )
        savedLinks.insert(link, at: 0)
        cachePoster(for: item, savedID: link.id)
        persistSavedLinksImmediately()
        return link
    }

    // MARK: - Persistence: playlists

    func loadPlaylists() {
        guard let data = UserDefaults.standard.data(forKey: playlistsKey),
              let decoded = try? JSONDecoder().decode([VideoPlaylist].self, from: data) else {
            playlists = []
            return
        }
        playlists = decoded.sorted { $0.dateCreated > $1.dateCreated }
    }

    func persistPlaylistsImmediately() {
        playlistsPersistenceRevision += 1
        let revision = playlistsPersistenceRevision
        let snapshot = playlists
        let key = playlistsKey
        let writer = playlistsPersistenceWriter
        Task(priority: .utility) {
            await writer.persist(snapshot, key: key, revision: revision)
        }
    }

    /// فيديوهات قائمة تشغيل معيّنة، بترتيب الإضافة (الأحدث أولاً)
    func links(in playlist: VideoPlaylist) -> [SavedVideoLink] {
        playlist.linkIDs.compactMap { id in
            savedLinks.first(where: { $0.id == id && $0.isVisibleInLibrary })
        }
    }

    @discardableResult
    func createPlaylist(name: String) -> VideoPlaylist {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let playlist = VideoPlaylist(name: trimmed.isEmpty ? "New Playlist" : trimmed)
        playlists.insert(playlist, at: 0)
        persistPlaylistsImmediately()
        return playlist
    }

    func renamePlaylist(_ playlist: VideoPlaylist, to newName: String) {
        let title = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, let idx = playlists.firstIndex(where: { $0.id == playlist.id }) else { return }
        playlists[idx].name = title
        persistPlaylistsImmediately()
    }

    func deletePlaylist(_ playlist: VideoPlaylist) {
        playlists.removeAll { $0.id == playlist.id }
        persistPlaylistsImmediately()
    }

    func isInPlaylist(_ item: VideoDetailsItem, playlist: VideoPlaylist) -> Bool {
        guard let link = savedLinks.first(where: { matches($0, item: item) }) else { return false }
        return playlist.linkIDs.contains(link.id)
    }

    /// يضيف الفيديو لقائمة التشغيل أو يزيله منها، وينشئ مدخلاً بالمكتبة له تلقائياً إذا لم يكن محفوظاً
    @discardableResult
    func togglePlaylistMembership(_ item: VideoDetailsItem, playlist: VideoPlaylist) -> Bool {
        guard let idx = playlists.firstIndex(where: { $0.id == playlist.id }) else { return false }
        let link = resolvedLink(for: item)
        let isIncluded: Bool
        if let pos = playlists[idx].linkIDs.firstIndex(of: link.id) {
            playlists[idx].linkIDs.remove(at: pos)
            isIncluded = false
        } else {
            playlists[idx].linkIDs.insert(link.id, at: 0)
            isIncluded = true
        }
        // Publish the completed state before persistence begins so the checkmark
        // changes on this same tap even inside a reused List row.
        playlists = playlists
        persistPlaylistsImmediately()
        return isIncluded
    }

    func removeLink(_ link: SavedVideoLink, from playlist: VideoPlaylist) {
        guard let idx = playlists.firstIndex(where: { $0.id == playlist.id }) else { return }
        playlists[idx].linkIDs.removeAll { $0 == link.id }
        persistPlaylistsImmediately()
    }

    // MARK: - Link normalize (all stream formats)

    func normalizedURL(from raw: String) -> URL? {
        LinkResolver.normalizeToURL(raw)
    }

    /// Saves any accepted stream/share link immediately.
    @discardableResult
    func saveDirectLink(_ raw: String, resolvedStream: URL? = nil, source: SavedVideoLink.LinkSource? = nil, title: String? = nil, pikpakFileId: String? = nil, poster: String? = nil, fileSizeBytes: Int64? = nil, posterCacheKey: String? = nil) -> SavedVideoLink? {
        let kind = LinkResolver.classify(raw)
        // Keep the original magnet. Playback resolves it through whichever
        // debrid/cloud provider is configured, or through the direct engine.
        if kind == .magnet || kind == .pikpakMagnet {
            let title = title ?? "Magnet download"
            if let idx = savedLinks.firstIndex(where: { $0.urlString == raw.trimmingCharacters(in: .whitespacesAndNewlines) }) {
                savedLinks[idx].lastPlayed = Date()
                if let source { savedLinks[idx].source = source }
                persistSavedLinksImmediately()
                return savedLinks[idx]
            }
            let link = SavedVideoLink(
                urlString: raw.trimmingCharacters(in: .whitespacesAndNewlines),
                resolvedStreamURL: resolvedStream?.absoluteString,
                title: title,
                dateAdded: Date(),
                lastPlayed: Date(),
                source: source ?? .direct,
                pikpakFileId: pikpakFileId,
                remotePosterURL: poster
            )
            savedLinks.insert(link, at: 0)
            persistSavedLinksImmediately()
            return link
        }

        guard let url = LinkResolver.normalizeToURL(raw) else { return nil }

        let resolvedSource: SavedVideoLink.LinkSource = {
            if let source { return source }
            switch kind {
            case .hls: return .hls
            case .pikpakShare, .pikpakMagnet, .pikpakDirect: return .pikpak
            default: return .direct
            }
        }()

        let display = title ?? LinkResolver.displayTitle(for: url)
        let key = url.absoluteString

        if let idx = savedLinks.firstIndex(where: {
            $0.urlString == key || $0.urlString == raw.trimmingCharacters(in: .whitespacesAndNewlines)
                || ($0.pikpakFileId != nil && $0.pikpakFileId == pikpakFileId)
        }) {
            var existing = savedLinks.remove(at: idx)
            existing.lastPlayed = Date()
            if let resolvedStream { existing.resolvedStreamURL = resolvedStream.absoluteString }
            if let pikpakFileId, !pikpakFileId.isEmpty {
                existing.pikpakFileId = pikpakFileId
                existing.source = .pikpak
            } else if existing.source == .direct, resolvedSource != .direct {
                existing.source = resolvedSource
            }
            if existing.title.isEmpty { existing.title = display }
            if let poster { existing.remotePosterURL = poster }
            if let fileSizeBytes, fileSizeBytes > 0 { existing.fileSizeBytes = fileSizeBytes }
            if let posterCacheKey { existing.favoriteIdentity = posterCacheKey }
            savedLinks.insert(existing, at: 0)
            copyProviderPosterIfAvailable(from: posterCacheKey, to: existing.id)
            persistSavedLinksImmediately()
            return existing
        }

        let link = SavedVideoLink(
            urlString: key,
            resolvedStreamURL: resolvedStream?.absoluteString,
            title: display,
            dateAdded: Date(),
            lastPlayed: Date(),
            source: resolvedSource,
            pikpakFileId: pikpakFileId,
            remotePosterURL: poster,
            fileSizeBytes: fileSizeBytes,
            favoriteIdentity: posterCacheKey
        )
        savedLinks.insert(link, at: 0)
        copyProviderPosterIfAvailable(from: posterCacheKey, to: link.id)
        persistSavedLinksImmediately()
        if link.fileSizeBytes == nil { fetchFileSize(for: link) }
        return link
    }


    private func copyProviderPosterIfAvailable(from providerKey: String?, to savedID: UUID) {
        guard let providerKey else { return }
        DispatchQueue.global(qos: .utility).async {
            guard let poster = VideoThumbnailLoader.cachedImage(forStableKey: providerKey) else { return }
            VideoThumbnailLoader.cacheImage(poster, forStableKey: "saved|\(savedID.uuidString)")
        }
    }
    private func refreshMissingFileSizes() {
        for link in savedLinks where link.fileSizeBytes == nil {
            fetchFileSize(for: link)
        }
    }

    private func fetchFileSize(for link: SavedVideoLink) {
        guard link.fileSizeBytes == nil, let url = link.url else { return }
        Task {
            func size(from response: URLResponse) -> Int64? {
                guard let http = response as? HTTPURLResponse else { return nil }
                if let length = http.value(forHTTPHeaderField: "Content-Length"), let bytes = Int64(length), bytes > 0 { return bytes }
                if let range = http.value(forHTTPHeaderField: "Content-Range"), let total = range.split(separator: "/").last, let bytes = Int64(total), bytes > 0 { return bytes }
                return nil
            }
            var head = URLRequest(url: url)
            head.httpMethod = "HEAD"
            head.timeoutInterval = 12
            var discovered = (try? await HighPriorityNetworkManager.shared.videoData(for: head)).flatMap { size(from: $0.1) }
            if discovered == nil {
                var range = URLRequest(url: url)
                range.setValue("bytes=0-0", forHTTPHeaderField: "Range")
                range.timeoutInterval = 12
                discovered = (try? await HighPriorityNetworkManager.shared.videoData(for: range)).flatMap { size(from: $0.1) }
            }
            guard let bytes = discovered, let index = savedLinks.firstIndex(where: { $0.id == link.id }) else { return }
            savedLinks[index].fileSizeBytes = bytes
            persistSavedLinksImmediately()
        }
    }
    func deleteSavedLink(_ link: SavedVideoLink) {
        BackgroundVideoCacheManager.shared.removeCachedVideo(
            remoteURL: link.url,
            stableKey: link.id.uuidString,
            suggestedFileName: link.title
        )
        savedLinks.removeAll { $0.id == link.id }
        if let url = link.url {
            VideoThumbnailLoader.deleteCache(for: url)
        }
        if let name = link.thumbnailFileName {
            VideoThumbnailLoader.deleteCustomPoster(fileName: name)
        }
        persistSavedLinksImmediately()
    }

    func renameSavedLink(_ link: SavedVideoLink, to newTitle: String) {
        let title = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        if let idx = savedLinks.firstIndex(where: { $0.id == link.id }) {
            savedLinks[idx].title = title
            persistSavedLinksImmediately()
        }
    }

    func setCustomThumbnail(_ image: UIImage, for link: SavedVideoLink) {
        let linkID = link.id
        let favoriteIdentity = link.favoriteIdentity
        DispatchQueue.global(qos: .userInitiated).async {
            guard let fileName = VideoThumbnailLoader.saveCustomPoster(image, for: linkID) else { return }
            Task { @MainActor [weak self] in
                guard let self,
                      let idx = self.savedLinks.firstIndex(where: { $0.id == linkID }) else { return }
                if let old = self.savedLinks[idx].thumbnailFileName, old != fileName {
                    VideoThumbnailLoader.deleteCustomPoster(fileName: old)
                }
                self.savedLinks[idx].thumbnailFileName = fileName
                let keys = Set(["saved|\(linkID.uuidString)", favoriteIdentity].compactMap { $0 })
                VideoThumbnailLoader.cacheImageInBackground(image, forStableKeys: Array(keys))
                self.savedLinks = self.savedLinks
                self.persistSavedLinksImmediately()
            }
        }
    }

    func clearCustomThumbnail(for link: SavedVideoLink) {
        guard let idx = savedLinks.firstIndex(where: { $0.id == link.id }) else { return }
        if let old = savedLinks[idx].thumbnailFileName {
            VideoThumbnailLoader.deleteCustomPoster(fileName: old)
        }
        savedLinks[idx].thumbnailFileName = nil
        let keys = Set(["saved|\(link.id.uuidString)", link.favoriteIdentity].compactMap { $0 })
        for key in keys { VideoThumbnailLoader.removeCachedImage(forStableKey: key) }
        savedLinks = savedLinks
        persistSavedLinksImmediately()
    }

    func playSavedLink(_ link: SavedVideoLink) {
        Task {
            await playSavedLinkAsync(link)
        }
    }

    func playSavedLinkAsync(_ link: SavedVideoLink) async {
        let savedKind = LinkResolver.classify(link.urlString)
        if savedKind == .magnet || savedKind == .pikpakMagnet {
            do {
                let provider = try await resolveAndPlayMagnet(
                    link.urlString,
                    title: link.title,
                    linkId: link.id
                )
                pikpakStatus = "Playing through \(provider)"
            } catch {
                errorMessage = error.localizedDescription
            }
            return
        }

        // A TorBox favorite stores only stable torrent/file IDs. Resolve a fresh
        // signed CDN URL for every play instead of sending `torbox://` to AVPlayer.
        if link.source == .torbox
            || Self.torBoxReference(from: link.urlString) != nil
            || Self.torBoxReference(from: link.resolvedStreamURL) != nil {
            let reference = torBoxReference(for: link)
            guard let reference else {
                errorMessage = "This TorBox favorite is missing its file reference. Remove it and add it again."
                return
            }
            let key = TorBoxKeyStore.load()
            guard !key.isEmpty else {
                errorMessage = TorBoxError.missingKey.localizedDescription
                return
            }
            isLoading = true
            defer { isLoading = false }
            do {
                let stream = try await TorBoxClient(apiKey: key).downloadURL(
                    torrentId: reference.torrentId,
                    fileId: reference.fileId
                )
                startPlayback(url: stream, title: link.title, linkId: link.id)
            } catch {
                errorMessage = error.localizedDescription
            }
            return
        }

        // Account/file entries must resolve a fresh signed URL before consulting
        // the persisted fallback. Reusing yesterday's CDN signature is a common
        // cause of VLC/AVPlayer reporting that the media cannot be opened.
        if link.source == .pikpak, let fileId = link.pikpakFileId {
            isLoading = true
            defer { isLoading = false }
            do {
                let stream = try await PikPakClient.shared.streamURL(forFileId: fileId)
                startPlayback(url: stream, title: link.title, linkId: link.id, headers: PikPakClient.shared.directPlaybackHeaders())
                if let idx = savedLinks.firstIndex(where: { $0.id == link.id }) {
                    savedLinks[idx].resolvedStreamURL = stream.absoluteString
                    persistSavedLinksImmediately()
                }
                return
            } catch {
                // A pasted direct link may still be usable as the final fallback.
            }
        }

        // A stable DAV-origin entry must refresh its signed redirect below on
        // every play. Only genuinely pasted/native direct links may reuse the
        // tokenized URL here; otherwise an old CDN signature can bypass DAV
        // refresh and become both slow and eventually unplayable.
        let hasConfiguredWebDAVOrigin: Bool = {
            guard let host = link.originalURL?.host?.lowercased() else { return false }
            return servers.contains { $0.baseURL?.host?.lowercased() == host }
        }()
        if !hasConfiguredWebDAVOrigin
            && (LinkResolver.isPikPakDirectDownload(link.urlString)
                || (link.source == .pikpak
                    && LinkResolver.isPikPakDirectDownload(link.resolvedStreamURL ?? ""))) {
            if let stream = LinkResolver.resolvePikPakDirectStream(link.resolvedStreamURL ?? link.urlString)
                ?? LinkResolver.resolvePikPakDirectStream(link.urlString) {
                startPlayback(
                    url: stream,
                    title: link.title,
                    linkId: link.id,
                    headers: PikPakClient.shared.directPlaybackHeaders()
                )
                return
            }
        }

        // PikPak share original - try resolve again
        if link.source == .pikpak, LinkResolver.isPikPakShareURL(link.urlString) {
            isLoading = true
            defer { isLoading = false }
            do {
                try await resolveAndPlayPikPakShare(link.urlString)
                // attach link id after resolve
                nowPlayingLinkId = link.id
                if link.hasResumePoint {
                    nowPlayingResumeAt = link.resumePositionSeconds ?? 0
                }
                return
            } catch {
                errorMessage = error.localizedDescription
            }
        }

        guard let url = link.url else {
            errorMessage = "No playable URL for this item"
            return
        }

        // Existing library/hero entries may still carry an expired PikPak CDN
        // URL in `resolvedStreamURL`. Identify their DAV server from the stable
        // original URL, then upgrade them to a native PikPak file reference.
        let providerURL = link.originalURL ?? url
        if let host = providerURL.host?.lowercased(),
           let server = servers.first(where: { $0.baseURL?.host?.lowercased() == host }) {
            let webDAVFile = WebDAVFile(
                name: link.title,
                path: providerURL.path,
                isDirectory: false,
                size: link.fileSizeBytes,
                contentType: nil
            )
            if isPikPakDAVServer(server), pikpakAccount != nil {
                let client = WebDAVClient(server: server)
                do {
                    if let native = try await nativePikPakPlayback(for: webDAVFile, client: client) {
                        if let index = savedLinks.firstIndex(where: { $0.id == link.id }) {
                            savedLinks[index].source = .pikpak
                            savedLinks[index].pikpakFileId = native.file.id
                            savedLinks[index].resolvedStreamURL = native.stream.absoluteString
                            persistSavedLinksImmediately()
                        }
                        startPlayback(
                            url: native.stream,
                            title: link.title,
                            linkId: link.id,
                            headers: PikPakClient.shared.directPlaybackHeaders()
                        )
                        return
                    }
                } catch {
                    DiagnosticLogger.log("[PlaybackRoute] saved-entry webdav-fallback reason=\(error.localizedDescription)")
                }
            }

            // A PikPak DAV media URL is only a gateway. Resolve its cross-host
            // redirect first and hand the signed CDN URL to the player, exactly
            // like a direct link pasted in Settings. Keeping playback on
            // dav.mypikpak.com makes every range request traverse WebDAV and is
            // dramatically slower for large MP4/MKV files.
            if isPikPakDAVServer(server) {
                let client = WebDAVClient(server: server)
                if let directURL = await client.resolvedStreamURL(for: webDAVFile),
                   isResolvedPikPakCDNURL(directURL, comparedWith: providerURL) {
                    if let index = savedLinks.firstIndex(where: { $0.id == link.id }) {
                        // Keep urlString as the stable DAV reference. The signed
                        // URL is refreshed again on every play before it expires.
                        savedLinks[index].source = .webdav
                        savedLinks[index].resolvedStreamURL = directURL.absoluteString
                        persistSavedLinksImmediately()
                    }
                    DiagnosticLogger.log("[PlaybackRoute] provider=pikpak-dav-cdn saved-entry=true")
                    startPlayback(
                        url: directURL,
                        title: link.title,
                        linkId: link.id,
                        headers: PikPakClient.shared.directPlaybackHeaders()
                    )
                    return
                }
            }
            startPlayback(
                url: providerURL,
                title: link.title,
                linkId: link.id,
                headers: WebDAVClient(server: server).streamHeaders()
            )
            return
        }
        startPlayback(url: url, title: link.title, linkId: link.id)
    }

    private func providerSource(for item: VideoDetailsItem) -> SavedVideoLink.LinkSource {
        let label = item.source.lowercased()
        if item.url.scheme?.lowercased() == "torbox" || label.contains("torbox") { return .torbox }
        if label.contains("offcloud") { return .offcloud }
        if label.contains("pikpak") || label.contains("webdav") || !item.httpHeaders.isEmpty { return .webdav }
        if let host = item.url.host?.lowercased(),
           servers.contains(where: { $0.baseURL?.host?.lowercased() == host }) { return .webdav }
        if item.url.pathExtension.lowercased() == "m3u8" { return .hls }
        return .direct
    }

    private func upgradeProviderReference(_ link: inout SavedVideoLink, from item: VideoDetailsItem) {
        let source = providerSource(for: item)
        if let reference = Self.torBoxReference(from: item.url.absoluteString) {
            link.source = .torbox
            link.urlString = item.url.absoluteString
            link.resolvedStreamURL = nil
            link.torBoxTorrentId = reference.torrentId
            link.torBoxFileId = reference.fileId
        } else if link.source == .direct, source != .direct {
            // Repair old favorites that were saved before provider detection,
            // without downgrading an existing PikPak/Offcloud source identity.
            link.source = source
        }
    }

    private func torBoxReference(for link: SavedVideoLink) -> (torrentId: Int, fileId: Int)? {
        if let torrentId = link.torBoxTorrentId, let fileId = link.torBoxFileId {
            return (torrentId, fileId)
        }
        return Self.torBoxReference(from: link.urlString)
            ?? Self.torBoxReference(from: link.resolvedStreamURL)
    }

    private static func torBoxReference(from raw: String?) -> (torrentId: Int, fileId: Int)? {
        guard let raw, let url = URL(string: raw), url.scheme?.lowercased() == "torbox" else { return nil }
        let parts = ([url.host].compactMap { $0 } + url.pathComponents.filter { $0 != "/" })
            .map { $0.lowercased() }
        guard let torrentMarker = parts.firstIndex(of: "torrent"),
              let fileMarker = parts.firstIndex(of: "file"),
              parts.indices.contains(torrentMarker + 1),
              parts.indices.contains(fileMarker + 1),
              let torrentId = Int(parts[torrentMarker + 1]),
              let fileId = Int(parts[fileMarker + 1]) else { return nil }
        return (torrentId, fileId)
    }

    func startPlayback(
        url: URL,
        title: String,
        linkId: UUID? = nil,
        headers: [String: String]? = nil
    ) {
        // Prefer matching library entry for resume
        let matchedId = linkId ?? savedLinks.first(where: {
            $0.url?.absoluteString == url.absoluteString
                || $0.resolvedStreamURL == url.absoluteString
                || $0.urlString == url.absoluteString
        })?.id

        var resume: Double = 0
        if let matchedId, let link = savedLinks.first(where: { $0.id == matchedId }), link.hasResumePoint {
            resume = link.resumePositionSeconds ?? 0
        }
        if resume <= 3,
           let historyID = pendingHistoryItem?.id,
           let history = playbackHistory[historyID], history.hasResumePoint {
            resume = history.positionSeconds
        }

        // Playback must own the only active network request. Starting the hidden
        // full-file background cache here created a second priority-1 transfer for
        // the same PikPak URL, splitting bandwidth and triggering CDN throttling.
        let playbackURL = url

        nowPlayingLinkId = matchedId
        nowPlayingResumeAt = resume
        nowPlayingHeaders = playbackURL.isFileURL ? nil : headers
        nowPlaying = WebDAVFile(
            // Preserve the original extension for player routing. PikPak signed
            // CDN URLs usually have no path extension, so removing `.mkv` here
            // incorrectly routed Matroska files into AVPlayer instead of VLC.
            // VideoPlayerView formats this raw name only when displaying the title.
            name: title,
            path: playbackURL.absoluteString,
            isDirectory: false,
            contentType: "video"
        )
        nowPlayingURL = playbackURL
        DiagnosticLogger.log(
            "[PlaybackState] launch ready extension=\((title as NSString).pathExtension.lowercased()) hasHeaders=\(headers?.isEmpty == false)"
        )

    }

    /// Returns the native PikPak reference for the currently presented item.
    /// A signed URL fallback also covers old direct-link favourites whose file
    /// id has not yet been persisted locally.
    func pikPakFileID(for linkID: UUID?, playbackURL: URL?) -> String? {
        if let linkID,
           let fileID = savedLinks.first(where: { $0.id == linkID })?.pikpakFileId,
           !fileID.isEmpty {
            return fileID
        }
        return playbackURL.flatMap { PikPakClient.shared.fileID(fromPlaybackURL: $0) }
    }

    /// Replaces only the expiring CDN rendition and preserves the active
    /// library/history identity. ResolvedPlayerScreen re-creates the engine
    /// with this URL and seeks back to the sampled playback second.
    func switchPikPakQuality(to streamURL: URL, resumeAt: Double) {
        guard nowPlaying != nil else { return }
        nowPlayingURL = streamURL
        nowPlayingResumeAt = max(0, resumeAt)
        nowPlayingHeaders = PikPakClient.shared.directPlaybackHeaders()
        DiagnosticLogger.log("[PikPakPlayback] quality switch resume=\(Int(max(0, resumeAt))) host=\(streamURL.host ?? \"unknown\")")
    }

    /// Persist exact playback position + detected resolution for resume / badges.
    func updatePlaybackProgress(
        seconds: Double,
        duration: Double,
        width: Int,
        height: Int,
        linkId: UUID? = nil,
        streamURL: URL? = nil
    ) {
        if pendingHistoryItem != nil, seconds.isFinite, duration.isFinite, seconds >= 0 {
            // Memory only while playback is active. The disk write happens once
            // in finishPlaybackHistory(), after the final AVPlayer/VLC tick.
            pendingHistoryProgress = (seconds, max(0, duration))
        }
        let id = linkId ?? nowPlayingLinkId
        var idx = id.flatMap { lid in savedLinks.firstIndex(where: { $0.id == lid }) }
        if idx == nil, let streamURL {
            idx = savedLinks.firstIndex(where: {
                $0.url?.absoluteString == streamURL.absoluteString
                    || $0.resolvedStreamURL == streamURL.absoluteString
                    || $0.urlString == streamURL.absoluteString
            })
        }
        guard let idx else { return }

        if duration > 0 {
            savedLinks[idx].durationSeconds = duration
        }
        if width > 0 { savedLinks[idx].videoWidth = width }
        if height > 0 { savedLinks[idx].videoHeight = height }

        // Near end or finished -> clear resume so next open starts from beginning
        if duration > 0, seconds >= duration * 0.95 || (duration - seconds) < 5 {
            savedLinks[idx].resumePositionSeconds = nil
        } else if seconds > 3 {
            savedLinks[idx].resumePositionSeconds = seconds
        }
        persistSavedLinksImmediately()
    }

    func resumeSeconds(for link: SavedVideoLink) -> Double {
        link.hasResumePoint ? (link.resumePositionSeconds ?? 0) : 0
    }

    // MARK: - WebDAV

    func connect(to server: WebDAVServer) async {
        isLoading = true
        errorMessage = nil
        let client = WebDAVClient(server: server)
        do {
            try await client.testConnection()
            if let idx = servers.firstIndex(where: { $0.id == server.id }) {
                servers[idx].isConnected = true
                saveServers()
            }
            selectedServer = server
            currentPath = []
            await browse(server: server, path: "")
        } catch {
            errorMessage = error.localizedDescription
            if let idx = servers.firstIndex(where: { $0.id == server.id }) {
                servers[idx].isConnected = false
                saveServers()
            }
        }
        isLoading = false
    }

    func browse(server: WebDAVServer, path: String) async {
        isLoading = true
        errorMessage = nil
        let client = WebDAVClient(server: server)
        do {
            let files = try await client.listFiles(at: path)
            currentFiles = files
                .filter { $0.isDirectory || VideoLibraryVisibility.allows(sizeBytes: $0.size) }
                .sorted { a, b in
                    if a.isDirectory != b.isDirectory { return a.isDirectory }
                    return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
                }
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    /// Returns the last successful PikPak listing immediately, without network work.
    func cachedPikPakFiles(server: WebDAVServer, path: String, flattenFolders: Bool, extractSmallFolders: Bool = false) -> [WebDAVFile]? {
        guard let data = UserDefaults.standard.data(forKey: pikPakCacheKey(server: server, path: path, flattenFolders: flattenFolders, extractSmallFolders: extractSmallFolders)) else {
            return nil
        }
        return (try? JSONDecoder().decode([WebDAVFile].self, from: data))?.filter {
            $0.isDirectory || VideoLibraryVisibility.allows(sizeBytes: $0.size)
        }
    }

    private func savePikPakFilesToCache(_ files: [WebDAVFile], server: WebDAVServer, path: String, flattenFolders: Bool, extractSmallFolders: Bool) {
        let key = pikPakCacheKey(
            server: server,
            path: path,
            flattenFolders: flattenFolders,
            extractSmallFolders: extractSmallFolders
        )
        DispatchQueue.global(qos: .utility).async {
            guard let data = try? JSONEncoder().encode(files) else { return }
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    private func pikPakCacheKey(server: WebDAVServer, path: String, flattenFolders: Bool, extractSmallFolders: Bool) -> String {
        let raw = "\(server.host.lowercased())|\(server.port)|\(server.path)|\(path)|\(flattenFolders)|\(extractSmallFolders)"
        return pikPakCachePrefix + raw.data(using: .utf8)!.base64EncodedString()
    }
    /// Loads one folder normally, or gathers only videos from its nested folders.
    /// This is used exclusively by the PikPak tab.
    func pikPakFiles(server: WebDAVServer, path: String, flattenFolders: Bool, extractSmallFolders: Bool = false, forceRefresh: Bool = false) async -> [WebDAVFile] {
        isLoading = true
        errorMessage = nil
        let client = WebDAVClient(server: server)
        defer { isLoading = false }

        do {
            let files: [WebDAVFile]
            if flattenFolders {
                files = try await collectPikPakVideos(client: client, startingAt: path, forceRefresh: forceRefresh)
            } else if extractSmallFolders {
                files = try await listPikPakFolderWithSmallFoldersExtracted(client: client, path: path, forceRefresh: forceRefresh)
            } else {
                files = try await client.listFiles(at: path, forceRefresh: forceRefresh)
            }
            let sortedFiles = files
                .filter { $0.isDirectory || VideoLibraryVisibility.allows(sizeBytes: $0.size) }
                .sorted {
                    if flattenFolders { return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
                    if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
                    return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
                }
            savePikPakFilesToCache(sortedFiles, server: server, path: path, flattenFolders: flattenFolders, extractSmallFolders: extractSmallFolders)
            return sortedFiles
        } catch {
            errorMessage = error.localizedDescription
            return []
        }
    }

    /// Shows large child folders, but extracts video files from small child folders.
    private func listPikPakFolderWithSmallFoldersExtracted(client: WebDAVClient, path: String, forceRefresh: Bool = false) async throws -> [WebDAVFile] {
        let directFiles = try await client.listFiles(at: path, forceRefresh: forceRefresh)
        var result = directFiles.filter { !$0.isDirectory }

        for folder in directFiles where folder.isDirectory {
            let childVideos = try await collectPikPakVideos(client: client, startingAt: folder.path, maximumFiles: 4, forceRefresh: forceRefresh)
            if childVideos.count <= 3 {
                result.append(contentsOf: childVideos)
            } else {
                result.append(folder)
            }
        }
        return result
    }
    private func collectPikPakVideos(client: WebDAVClient, startingAt path: String, maximumFiles: Int = 1_000, forceRefresh: Bool = false) async throws -> [WebDAVFile] {
        var pendingPaths = [path]
        var visited = Set<String>()
        var videos: [WebDAVFile] = []
        while !pendingPaths.isEmpty && videos.count < maximumFiles {
            var batch: [String] = []
            while batch.count < 12, let nextPath = pendingPaths.popLast() {
                let normalizedPath = nextPath.trimmingCharacters(in: .whitespacesAndNewlines)
                if visited.insert(normalizedPath).inserted { batch.append(nextPath) }
            }
            guard !batch.isEmpty else { continue }
            let listings = await withTaskGroup(of: [WebDAVFile].self) { group in
                for folderPath in batch {
                    group.addTask {
                        (try? await client.listFiles(at: folderPath, forceRefresh: forceRefresh)) ?? []
                    }
                }
                var result: [[WebDAVFile]] = []
                for await files in group { result.append(files) }
                return result
            }
            for contents in listings {
                for item in contents {
                    if Task.isCancelled { return videos }
                    if item.isDirectory {
                        pendingPaths.append(item.path)
                    } else if item.isVideo, videos.count < maximumFiles {
                        videos.append(item)
                    }
                }
            }
        }
        return videos
    }
    /// Library discovery does not touch published view-model state. Keep the
    /// recursive traversal, de-duplication, sorting and index serialization off
    /// the main actor so large WebDAV folders cannot interrupt scrolling.
    nonisolated func contentLibraryFiles(server: WebDAVServer, forceRefresh: Bool = false) async -> [WebDAVFile] {
        let configuredRoots = WebDAVContentSelectionStore.selectedPaths(for: server.id)
        let roots = configuredRoots.map(WebDAVContentSelectionStore.minimalRoots) ?? [""]
        guard !roots.isEmpty else { return [] }
        let revision = WebDAVContentSelectionStore.revision(for: server.id)
        let persistedIndex = WebDAVContentIndexStore.load(serverID: server.id, revision: revision)
        if !forceRefresh, let persistedIndex {
            return persistedIndex.filter(\.isVideo)
        }
        let cachedIndex = persistedIndex ?? []
        var collected: [WebDAVFile] = []
        await withTaskGroup(of: [WebDAVFile].self) { group in
            for root in roots {
                group.addTask {
                    (try? await Self.collectContentVideos(
                        server: server,
                        startingAt: root,
                        maximumFiles: 5_000,
                        forceRefresh: forceRefresh
                    )) ?? []
                }
            }
            for await files in group { collected.append(contentsOf: files) }
        }
        // Manual refresh is append-only. Keep the persisted WebDAV index in
        // place and merge newly discovered paths into it. A slow/partial folder
        // response must never blank the library or force old metadata to load
        // again. Folder selection changes use a new revision and therefore
        // still start with the newly selected scope.
        var filesByPath = Dictionary(
            cachedIndex.filter(\.isVideo).map { ($0.path, $0) },
            uniquingKeysWith: { existing, _ in existing }
        )
        for file in collected where file.isVideo {
            filesByPath[file.path] = file
        }
        let result = filesByPath.values.sorted {
            $0.path.localizedStandardCompare($1.path) == .orderedAscending
        }
        WebDAVContentIndexStore.save(result, serverID: server.id, revision: revision)
        return result
    }

    /// A content-only traversal deliberately separated from the @MainActor
    /// browser helpers. Each selected root owns its client, avoiding shared
    /// mutable authentication state while roots are scanned concurrently.
    nonisolated private static func collectContentVideos(
        server: WebDAVServer,
        startingAt path: String,
        maximumFiles: Int,
        forceRefresh: Bool
    ) async throws -> [WebDAVFile] {
        let client = WebDAVClient(server: server)
        var pendingPaths = [path]
        var visited = Set<String>()
        var videos: [WebDAVFile] = []

        while !pendingPaths.isEmpty && videos.count < maximumFiles {
            var batch: [String] = []
            while batch.count < 8, let nextPath = pendingPaths.popLast() {
                let normalized = nextPath.trimmingCharacters(in: .whitespacesAndNewlines)
                if visited.insert(normalized).inserted { batch.append(nextPath) }
            }
            guard !batch.isEmpty else { continue }

            let listings = await withTaskGroup(of: [WebDAVFile].self) { group in
                for folderPath in batch {
                    group.addTask {
                        (try? await client.listFiles(at: folderPath, forceRefresh: forceRefresh)) ?? []
                    }
                }
                var result: [[WebDAVFile]] = []
                result.reserveCapacity(batch.count)
                for await files in group { result.append(files) }
                return result
            }

            for contents in listings {
                for item in contents {
                    if Task.isCancelled { return videos }
                    if item.isDirectory {
                        pendingPaths.append(item.path)
                    } else if item.isVideo, videos.count < maximumFiles {
                        videos.append(item)
                    }
                }
            }
            // Cooperatively yield between directory batches. This matters on
            // older iPhones when a DAV response contains hundreds of children.
            await Task.yield()
        }
        return videos
    }

    func searchPikPakVideos(server: WebDAVServer, query: String) async -> [WebDAVFile] {
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        do {
            let client = WebDAVClient(server: server)
            let videos = try await collectPikPakVideos(
                client: client,
                startingAt: "",
                maximumFiles: 5_000,
                forceRefresh: false
            )
            guard !Task.isCancelled else { return [] }
            let matches = normalized.isEmpty ? videos : videos.filter {
                $0.name.lowercased().contains(normalized)
                    || $0.displayName.lowercased().contains(normalized)
                    || $0.path.lowercased().contains(normalized)
            }
            return matches.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        } catch {
            if !Task.isCancelled { errorMessage = error.localizedDescription }
            return []
        }
    }

    func openFolder(_ folder: WebDAVFile, server: WebDAVServer) async {
        currentPath.append(folder.name)
        await browse(server: server, path: folder.path)
    }

    func goBack(server: WebDAVServer) async {
        guard !currentPath.isEmpty else { return }
        currentPath.removeLast()
        let path = currentPath.isEmpty ? "" : "/" + currentPath.joined(separator: "/")
        await browse(server: server, path: path)
    }

    /// Prepare a fresh playback URL. PikPak DAV entries are converted to their
    /// signed CDN redirect first; ordinary DAV servers stay on their authenticated
    /// URL. The redirect resolver stops before reading the media body, so it does
    /// not compete with the player for bandwidth.
    @discardableResult
    func preparePlayback(file: WebDAVFile, server: WebDAVServer) async -> Bool {
        let client = WebDAVClient(server: server)
        guard let url = client.streamURL(for: file) else {
            errorMessage = "Could not build stream URL for this file"
            return false
        }
        errorMessage = nil
        // Never leave the previous video mounted while the next player is shown.
        nowPlaying = nil
        nowPlayingURL = nil
        nowPlayingHeaders = nil

        // When the same PikPak account is connected natively, translate the DAV
        // path to its stable file ID and request a fresh original CDN URL. This
        // makes Media playback use the same fast route as a pasted direct link.
        if isPikPakDAVServer(server), pikpakAccount != nil {
            do {
                if let native = try await nativePikPakPlayback(for: file, client: client) {
                    DiagnosticLogger.log("[PlaybackRoute] provider=pikpak-native file=\(file.name)")
                    let saved = saveDirectLink(
                        url.absoluteString,
                        resolvedStream: native.stream,
                        source: .pikpak,
                        title: file.name,
                        pikpakFileId: native.file.id,
                        poster: native.file.thumbnailLink,
                        fileSizeBytes: file.size ?? native.file.size
                    )
                    startPlayback(
                        url: native.stream,
                        title: file.name,
                        linkId: saved?.id,
                        headers: PikPakClient.shared.directPlaybackHeaders()
                    )
                    return nowPlayingURL != nil
                }
                DiagnosticLogger.log("[PlaybackRoute] provider=webdav-fallback reason=no-native-match file=\(file.name)")
            } catch {
                DiagnosticLogger.log("[PlaybackRoute] provider=webdav-fallback reason=\(error.localizedDescription) file=\(file.name)")
            }
        }

        var playbackURL = url
        var playbackHeaders = client.streamHeaders()
        if isPikPakDAVServer(server),
           let directURL = await client.resolvedStreamURL(for: file),
           isResolvedPikPakCDNURL(directURL, comparedWith: url) {
            playbackURL = directURL
            playbackHeaders = PikPakClient.shared.directPlaybackHeaders()
            DiagnosticLogger.log("[PlaybackRoute] provider=pikpak-dav-cdn file=\(file.name)")
        }

        let saved = saveDirectLink(
            url.absoluteString,
            resolvedStream: playbackURL,
            source: .webdav,
            title: file.name,
            fileSizeBytes: file.size
        )
        startPlayback(
            url: playbackURL,
            title: file.name,
            linkId: saved?.id,
            headers: playbackHeaders
        )
        return nowPlayingURL != nil
    }

    private func isPikPakDAVServer(_ server: WebDAVServer) -> Bool {
        let host = (server.baseURL?.host ?? server.host).lowercased()
        return host == "dav.mypikpak.com" || host.hasSuffix(".mypikpak.com")
    }

    private func isResolvedPikPakCDNURL(_ candidate: URL, comparedWith webDAVURL: URL) -> Bool {
        if LinkResolver.isPikPakDirectDownload(candidate.absoluteString) { return true }
        guard let candidateHost = candidate.host?.lowercased(),
              let davHost = webDAVURL.host?.lowercased() else { return false }
        return candidateHost != davHost
    }

    private func nativePikPakPlayback(
        for webDAVFile: WebDAVFile,
        client: WebDAVClient
    ) async throws -> (file: PikPakFileItem, stream: URL)? {
        guard let file = try await nativePikPakFile(for: webDAVFile, client: client) else {
            return nil
        }
        do {
            return (file, try await PikPakClient.shared.streamURL(forFileId: file.id))
        } catch {
            // A cached file ID may become stale after a move/re-upload. Remove it,
            // rebuild the folder path once, and still complete this same tap.
            invalidateNativePikPakFileCache(for: webDAVFile, client: client)
            pikpakNativeDirectoryCache.removeAll()
            guard let refreshed = try await nativePikPakFile(for: webDAVFile, client: client) else {
                throw error
            }
            return (refreshed, try await PikPakClient.shared.streamURL(forFileId: refreshed.id))
        }
    }

    private func nativePikPakFile(
        for webDAVFile: WebDAVFile,
        client: WebDAVClient
    ) async throws -> PikPakFileItem? {
        let cacheKey = nativePikPakCacheKey(for: webDAVFile, client: client)
        if let cachedID = pikpakWebDAVFileIDCache[cacheKey] {
            return PikPakFileItem(
                id: cachedID,
                name: webDAVFile.name,
                kind: "drive#file",
                size: webDAVFile.size ?? 0,
                mimeType: webDAVFile.contentType,
                parentId: nil,
                thumbnailLink: nil,
                webContentLink: nil,
                phase: nil
            )
        }

        let rawComponents = client.relativePathComponents(for: webDAVFile)
        guard !rawComponents.isEmpty else { return nil }
        var children = try await nativePikPakChildren(parentID: "")

        // Some DAV servers prefix hrefs with `dav`/`webdav`. Begin at the first
        // component that actually exists in the connected PikPak drive root.
        guard let start = rawComponents.firstIndex(where: { component in
            children.contains { namesMatch($0.name, component) }
        }) else { return nil }

        let components = Array(rawComponents[start...])
        for (offset, component) in components.enumerated() {
            let isLast = offset == components.count - 1
            let matches = children.filter {
                namesMatch($0.name, component) && (isLast ? !$0.isFolder : $0.isFolder)
            }
            guard !matches.isEmpty else { return nil }

            if isLast {
                cacheNativePikPakSiblings(children, webDAVComponents: rawComponents)
                let resolved = matches.first(where: {
                    guard let expectedSize = webDAVFile.size, expectedSize > 0 else { return false }
                    return $0.size == expectedSize
                }) ?? matches[0]
                pikpakWebDAVFileIDCache[cacheKey] = resolved.id
                persistNativePikPakFileIDCache()
                return resolved
            }

            children = try await nativePikPakChildren(parentID: matches[0].id)
        }
        return nil
    }

    private func nativePikPakChildren(parentID: String) async throws -> [PikPakFileItem] {
        if let cached = pikpakNativeDirectoryCache[parentID] { return cached }
        let files = try await PikPakClient.shared.listFiles(parentId: parentID)
        pikpakNativeDirectoryCache[parentID] = files
        return files
    }

    private func namesMatch(_ lhs: String, _ rhs: String) -> Bool {
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]
        return lhs.precomposedStringWithCanonicalMapping
            .compare(rhs.precomposedStringWithCanonicalMapping, options: options) == .orderedSame
    }

    private func nativePikPakCacheKey(for file: WebDAVFile, client: WebDAVClient) -> String {
        let account = pikpakAccount?.userId ?? pikpakAccount?.displayName ?? "pikpak"
        let path = client.relativePathComponents(for: file).joined(separator: "/")
        return "\(account)|\(path)|\(file.size ?? 0)"
    }

    private func cacheNativePikPakSiblings(
        _ children: [PikPakFileItem],
        webDAVComponents: [String]
    ) {
        guard !webDAVComponents.isEmpty else { return }
        let account = pikpakAccount?.userId ?? pikpakAccount?.displayName ?? "pikpak"
        let directory = webDAVComponents.dropLast()
        for child in children where !child.isFolder {
            let path = (Array(directory) + [child.name]).joined(separator: "/")
            pikpakWebDAVFileIDCache["\(account)|\(path)|\(child.size)"] = child.id
        }
        persistNativePikPakFileIDCache()
    }

    private func invalidateNativePikPakFileCache(for file: WebDAVFile, client: WebDAVClient) {
        pikpakWebDAVFileIDCache.removeValue(forKey: nativePikPakCacheKey(for: file, client: client))
        persistNativePikPakFileIDCache()
    }

    private func persistNativePikPakFileIDCache() {
        UserDefaults.standard.set(pikpakWebDAVFileIDCache, forKey: "pikpak_webdav_file_ids_v1")
    }

    /// Compatibility entry point for callers that do not present a player.
    func play(file: WebDAVFile, server: WebDAVServer) {
        Task { [weak self] in
            _ = await self?.preparePlayback(file: file, server: server)
        }
    }

    /// Releases the presented playback state without touching metadata/API work.
    /// This prevents a dismissed player from being reconstructed with its stale URL.
    func endPlaybackPresentation() {
        DiagnosticLogger.log("[PlaybackState] end presentation hadURL=\(nowPlayingURL != nil) hadFile=\(nowPlaying != nil)")
        finishPlaybackHistory()
        if nowPlayingURL?.host == "127.0.0.1" || nowPlayingURL?.host == "localhost" {
            DirectTorrentPlaybackEngine.shared.stopCurrent()
        }
        nowPlayingURL = nil
        nowPlayingHeaders = nil
        nowPlayingResumeAt = 0
        nowPlayingLinkId = nil
        nowPlayingSubtitleContext = nil
        nowPlaying = nil
        preparedOnlinePlayback = nil
        preparedOnlinePlaybackHistoryItem = nil
    }

    /// TorBox CDN links are generated on demand and expire, so they must never
    /// be persisted in the library. Resolve immediately before presentation.
    @MainActor
    func playTorBoxFile(torrentId: Int, file: TorBoxFile) async -> Bool {
        let key = TorBoxKeyStore.load()
        guard !key.isEmpty else {
            errorMessage = TorBoxError.missingKey.localizedDescription
            return false
        }
        isLoading = true
        defer { isLoading = false }
        do {
            let url = try await TorBoxClient(apiKey: key).downloadURL(torrentId: torrentId, fileId: file.id)
            startPlayback(url: url, title: file.displayName)
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    // MARK: - Open any link (direct / HLS / PikPak share / magnet via PikPak)

    /// Save first immediately, then play or resolve.
    /// Returns error message or nil on success (playback URL prepared or async resolve started).
    func openUserLink(_ raw: String) async -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "Paste a link first" }

        let kind = LinkResolver.classify(trimmed)

        switch kind {
        case .pikpakDirect:
            // Tokenized CDN/download URLs (fid, g, sign, userid, category=original, ...)
            guard let stream = LinkResolver.resolvePikPakDirectStream(trimmed) else {
                return "Could not parse PikPak direct link"
            }
            let title = LinkResolver.pikpakDirectDisplayTitle(trimmed)
            _ = saveDirectLink(trimmed, resolvedStream: stream, source: .pikpak, title: title)
            startPlayback(
                url: stream,
                title: title,
                headers: PikPakClient.shared.directPlaybackHeaders()
            )
            return nil

        case .pikpakShare:
            _ = saveDirectLink(trimmed, source: .pikpak, title: "PikPak Share")
            do {
                try await resolveAndPlayPikPakShare(trimmed)
                return nil
            } catch {
                return error.localizedDescription
            }

        case .magnet, .pikpakMagnet:
            let magnetTitle = URLComponents(string: trimmed)?.queryItems?
                .first(where: { $0.name.lowercased() == "dn" })?.value?
                .removingPercentEncoding ?? "Magnet video"
            let saved = saveDirectLink(trimmed, source: .direct, title: magnetTitle)
            do {
                let provider = try await resolveAndPlayMagnet(
                    trimmed,
                    title: magnetTitle,
                    linkId: saved?.id
                )
                pikpakStatus = "Playing through \(provider)"
                return nil
            } catch {
                return error.localizedDescription
            }

        case .hls, .dash, .directStream, .unknown:
            // Also catch PikPak-looking links that slipped classification
            if LinkResolver.isPikPakDirectDownload(trimmed),
               let stream = LinkResolver.resolvePikPakDirectStream(trimmed) {
                let title = LinkResolver.pikpakDirectDisplayTitle(trimmed)
                _ = saveDirectLink(trimmed, resolvedStream: stream, source: .pikpak, title: title)
                startPlayback(
                    url: stream,
                    title: title,
                    headers: PikPakClient.shared.directPlaybackHeaders()
                )
                return nil
            }
            guard let url = LinkResolver.normalizeToURL(trimmed) else {
                return "Invalid link. Use http(s), m3u8, PikPak share/direct, or magnet."
            }
            let source: SavedVideoLink.LinkSource = (kind == .hls) ? .hls : .direct
            _ = saveDirectLink(trimmed, resolvedStream: url, source: source)
            startPlayback(url: url, title: LinkResolver.displayTitle(for: url))
            return nil

        case .webdav:
            guard let url = LinkResolver.normalizeToURL(trimmed) else {
                return "Invalid WebDAV URL"
            }
            _ = saveDirectLink(trimmed, resolvedStream: url, source: .webdav)
            startPlayback(url: url, title: LinkResolver.displayTitle(for: url))
            return nil
        }
    }

    /// Sync save+play for simple direct URLs (used by buttons).
    @discardableResult
    func playOnlineURL(_ raw: String) -> Bool {
        let kind = LinkResolver.classify(raw)
        if kind == .pikpakDirect, let stream = LinkResolver.resolvePikPakDirectStream(raw) {
            let title = LinkResolver.pikpakDirectDisplayTitle(raw)
            _ = saveDirectLink(raw, resolvedStream: stream, source: .pikpak, title: title)
            startPlayback(
                url: stream,
                title: title,
                headers: PikPakClient.shared.directPlaybackHeaders()
            )
            return true
        }
        if kind == .directStream || kind == .hls || kind == .dash || kind == .unknown {
            guard let url = LinkResolver.normalizeToURL(raw) else { return false }
            let source: SavedVideoLink.LinkSource = (kind == .hls) ? .hls : .direct
            _ = saveDirectLink(raw, resolvedStream: url, source: source)
            startPlayback(url: url, title: LinkResolver.displayTitle(for: url))
            return true
        }
        return false
    }

    // MARK: - PikPak

    func pikpakLogin(email: String, password: String, captchaToken: String = "") async -> String? {
        isLoading = true
        defer { isLoading = false }
        do {
            let acc = try await PikPakClient.shared.login(email: email, password: password, captchaToken: captchaToken)
            pikpakAccount = acc
            pikpakNativeDirectoryCache.removeAll()
            try await refreshPikPakFiles()
            return nil
        } catch {
            return error.localizedDescription
        }
    }
    func pikpakLoginWithPersonalAccessToken(_ token: String, label: String = "PikPak") async -> String? {
        isLoading = true
        defer { isLoading = false }
        do {
            let acc = try await PikPakClient.shared.loginWithPersonalAccessToken(token, label: label)
            pikpakAccount = acc
            pikpakNativeDirectoryCache.removeAll()
            try await refreshPikPakFiles()
            return nil
        } catch {
            return error.localizedDescription
        }
    }
    func pikpakLogout() {
        PikPakClient.shared.logout()
        pikpakAccount = nil
        pikpakFiles = []
        pikpakPath = []
        pikpakFilesCache.removeAll()
        pikpakNativeDirectoryCache.removeAll()
        pikpakWebDAVFileIDCache.removeAll()
        UserDefaults.standard.removeObject(forKey: "pikpak_webdav_file_ids_v1")
    }

    func refreshPikPakFiles(parentId: String? = nil, force: Bool = false) async throws {
        let pid = parentId ?? pikpakPath.last?.id ?? ""
        if !force, let cached = pikpakFilesCache[pid] {
            pikpakFiles = cached.filter { $0.isFolder || VideoLibraryVisibility.allows(sizeBytes: $0.size) }
            return
        }
        isLoading = true
        defer { isLoading = false }
        let files = try await PikPakClient.shared.listFiles(parentId: pid)
        let sorted = files
            .filter { $0.isFolder || VideoLibraryVisibility.allows(sizeBytes: $0.size) }
            .sorted { a, b in
                if a.isFolder != b.isFolder { return a.isFolder }
                return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
            }
        pikpakFilesCache[pid] = sorted
        pikpakFiles = sorted
    }

    func openPikPakFolder(_ folder: PikPakFileItem) async {
        pikpakPath.append((folder.id, folder.name))
        do {
            try await refreshPikPakFiles(parentId: folder.id)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func pikpakGoBack() async {
        if !pikpakPath.isEmpty { pikpakPath.removeLast() }
        do {
            try await refreshPikPakFiles()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func playPikPakFile(_ file: PikPakFileItem) async -> String? {
        isLoading = true
        defer { isLoading = false }
        do {
            let stream = try await PikPakClient.shared.streamURL(forFileId: file.id)
            _ = saveDirectLink(
                stream.absoluteString,
                resolvedStream: stream,
                source: .pikpak,
                title: file.name,
                pikpakFileId: file.id,
                poster: file.thumbnailLink,
                fileSizeBytes: file.size
            )
            startPlayback(url: stream, title: file.name, headers: PikPakClient.shared.directPlaybackHeaders())
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    func resolveAndPlayPikPakShare(_ link: String, password: String? = nil) async throws {
        isLoading = true
        defer { isLoading = false }
        let result = try await PikPakClient.shared.resolveShare(link: link, password: password)
        // Prefer first video file
        let videos = result.files.filter(\.isVideo)
        let target = videos.first ?? result.files.first(where: { !$0.isFolder })
        guard let file = target else {
            throw PikPakError.noStreamURL
        }
        let stream = try await PikPakClient.shared.streamURLFromShare(
            shareId: result.shareId,
            fileId: file.id,
            passToken: result.passToken
        )
        _ = saveDirectLink(
            link,
            resolvedStream: stream,
            source: .pikpak,
            title: file.name,
            pikpakFileId: file.id,
            poster: file.thumbnailLink,
            fileSizeBytes: file.size
        )
        startPlayback(url: stream, title: file.name, headers: PikPakClient.shared.directPlaybackHeaders())
    }

    func addMagnetToPikPak(_ magnet: String) async -> String? {
        isLoading = true
        defer { isLoading = false }
        do {
            _ = try await PikPakClient.shared.addOfflineTask(urlOrMagnet: magnet)
            _ = saveDirectLink(magnet, source: .pikpak, title: "Magnet task")
            // PikPak may accept the offline task before its new file becomes
            // listable. The transfer succeeded even if this immediate refresh
            // races the server, so refresh opportunistically without turning a
            // successful add into an error toast.
            try? await refreshPikPakFiles(force: true)
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}

extension AppViewModel {
    /// Starts resolving without toggling the app's blocking `isLoading` state.
    /// The task is owned by AppViewModel, so dismissing the source sheet does
    /// not cancel an uncached Real-Debrid transfer.
    func prepareOnlineSource(
        _ source: OnlineTorrentSource,
        historyItem: VideoDetailsItem? = nil
    ) {
        onlinePlaybackPreparationTask?.cancel()
        preparedOnlinePlayback = nil
        preparedOnlinePlaybackHistoryItem = nil
        DiagnosticLogger.log("[OnlinePlayback] begin quality=\(source.quality.label) provider=\(OnlinePlaybackProviderPreference.selected.title)")

        let transferID = source.id
        onlinePlaybackTransfer = OnlinePlaybackTransfer(
            id: transferID,
            title: source.name,
            provider: OnlinePlaybackProviderPreference.selected.title,
            phase: .preparing,
            message: "Preparing stream…"
        )

        onlinePlaybackPreparationTask = Task { [weak self] in
            guard let self else { return }
            do {
                let resolved = try await OnlinePlaybackResolver.shared.resolve(source) { [weak self] progress in
                    Task { @MainActor [weak self] in
                        guard let self,
                              let current = self.onlinePlaybackTransfer,
                              current.id == transferID,
                              current.phase != .ready,
                              current.phase != .failed else { return }

                        // Progress callbacks cross from the resolver actor back
                        // to MainActor. A queued "preparing" callback can arrive
                        // after a faster cached result. Never let an older phase
                        // overwrite downloading (or the terminal states above).
                        if current.phase == .downloading,
                           progress.phase == .preparing {
                            return
                        }
                        if current.phase == .downloading,
                           progress.phase == .downloading {
                            return
                        }
                        if current.phase == .preparing,
                           progress.phase == .preparing,
                           current.provider == progress.provider {
                            return
                        }
                        switch progress.phase {
                        case .preparing:
                            DiagnosticLogger.log("[OnlinePlayback] preparing provider=\(progress.provider)")
                            self.onlinePlaybackTransfer = OnlinePlaybackTransfer(
                                id: transferID,
                                title: source.name,
                                provider: progress.provider,
                                phase: .preparing,
                                message: "Preparing stream…"
                            )
                        case .downloading:
                            DiagnosticLogger.log("[OnlinePlayback] downloading provider=\(progress.provider)")
                            self.onlinePlaybackTransfer = OnlinePlaybackTransfer(
                                id: transferID,
                                title: source.name,
                                provider: progress.provider,
                                phase: .downloading,
                                message: "Downloading… You can keep browsing."
                            )
                        }
                    }
                }
                try Task.checkCancellation()
                guard self.onlinePlaybackTransfer?.id == transferID else { return }
                self.preparedOnlinePlayback = resolved
                self.preparedOnlinePlaybackHistoryItem = historyItem
                DiagnosticLogger.log("[OnlinePlayback] ready provider=\(resolved.provider) requiredDownload=\(resolved.requiredDownload)")
                self.onlinePlaybackTransfer = OnlinePlaybackTransfer(
                    id: transferID,
                    title: resolved.title,
                    provider: resolved.provider,
                    phase: .ready,
                    message: resolved.requiredDownload ? "Download complete · Ready to play" : "Ready to play"
                )
            } catch is CancellationError {
                return
            } catch {
                guard self.onlinePlaybackTransfer?.id == transferID else { return }
                DiagnosticLogger.log("[OnlinePlayback] failed error=\(error.localizedDescription)")
                self.onlinePlaybackTransfer = OnlinePlaybackTransfer(
                    id: transferID,
                    title: source.name,
                    provider: OnlinePlaybackProviderPreference.selected.title,
                    phase: .failed,
                    message: error.localizedDescription
                )
            }
        }
    }

    @discardableResult
    func playPreparedOnlineSource() -> Bool {
        guard let resolved = preparedOnlinePlayback else { return false }
        DiagnosticLogger.log("[OnlinePlayback] opening player provider=\(resolved.provider)")
        if nowPlayingURL != resolved.url || nowPlaying == nil {
            if let historyItem = preparedOnlinePlaybackHistoryItem {
                // Resolve URLs are temporary and provider-specific. Record the
                // stable media identity immediately before presentation so the
                // same title appears in Resume Playback regardless of whether
                // it was opened through Orion, an add-on, PikPak, TorBox, or
                // direct torrent playback.
                preparePlaybackHistory(for: historyItem)
            }
            startPlayback(
                url: resolved.url,
                title: resolved.title,
                linkId: resolved.pikpakFileID.flatMap {
                    saveDirectLink(
                        resolved.url.absoluteString,
                        resolvedStream: resolved.url,
                        source: .pikpak,
                        title: resolved.title,
                        pikpakFileId: $0
                    )?.id
                },
                headers: resolved.headers
            )
        }
        // Keep the resolved payload until the player actually closes. The
        // source sheet and player are adjacent full-screen covers; retaining
        // this lets onDismiss restore playback state if SwiftUI clears it while
        // finishing the outgoing cover transition.
        onlinePlaybackPreparationTask = nil
        onlinePlaybackTransfer = nil
        return true
    }

    func ensurePreparedOnlinePlaybackIsActive() -> Bool {
        if nowPlayingURL != nil, nowPlaying != nil { return true }
        guard preparedOnlinePlayback != nil else { return false }
        DiagnosticLogger.log("[OnlinePlayback] restoring prepared player state after cover transition")
        return playPreparedOnlineSource()
    }

    func clearFinishedOnlineTransfer() {
        guard let phase = onlinePlaybackTransfer?.phase,
              phase == .ready || phase == .failed else { return }
        preparedOnlinePlayback = nil
        preparedOnlinePlaybackHistoryItem = nil
        onlinePlaybackPreparationTask = nil
        onlinePlaybackTransfer = nil
    }
}
