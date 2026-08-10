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
    /// Captured for the current playback so hidden tab views cannot steal a one-shot VR flag.
    @Published private(set) var nowPlayingForceVR = false
    private var nextPlaybackForceVR = false

    func requestNextPlaybackInVR() {
        nextPlaybackForceVR = true
    }

    /// Library of auto-saved links (newest first).
    @Published var savedLinks: [SavedVideoLink] = []

    /// Recently played (subset of library sorted by lastPlayed).
    var recentLinks: [SavedVideoLink] {
        savedLinks
            .filter { $0.lastPlayed != nil }
            .sorted { ($0.lastPlayed ?? .distantPast) > ($1.lastPlayed ?? .distantPast) }
    }

    /// Videos explicitly pinned by the user, newest favorites first.
    var favoriteLinks: [SavedVideoLink] {
        savedLinks
            .filter(\.isFavorite)
            .sorted { $0.dateAdded > $1.dateAdded }
    }

    /// قوائم التشغيل التي أنشأها المستخدم، الأحدث أولاً
    @Published var playlists: [VideoPlaylist] = []

    /// PikPak session state (optional - login UI removed; used only for share/magnet if still signed in)
    @Published var pikpakAccount: PikPakAccount?
    @Published var pikpakFiles: [PikPakFileItem] = []
    @Published var pikpakPath: [(id: String, name: String)] = []
    private var pikpakFilesCache: [String: [PikPakFileItem]] = [:]
    @Published var pikpakStatus: String?

    private let serversKey = "saved_servers"
    private let linksKey = "saved_video_links_v2"
    private let playlistsKey = "video_playlists_v1"
    private let pikPakCachePrefix = "pikpak_webdav_cache_v1_"

    init() {
        loadServers()
        loadSavedLinks()
        loadPlaylists()
        pikpakAccount = PikPakClient.shared.loadAccount()
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
        savedLinks = decoded.sorted { ($0.lastPlayed ?? $0.dateAdded) > ($1.lastPlayed ?? $1.dateAdded) }
    }

    func persistSavedLinksImmediately() {
        if let data = try? JSONEncoder().encode(savedLinks) {
            UserDefaults.standard.set(data, forKey: linksKey)
            UserDefaults.standard.synchronize()
        }
    }

    func isFavorite(_ item: VideoDetailsItem) -> Bool {
        savedLinks.first(where: { matches($0, item: item) })?.isFavorite == true
    }

    @discardableResult
    func toggleFavorite(_ item: VideoDetailsItem) -> Bool {
        if let index = savedLinks.firstIndex(where: { matches($0, item: item) }) {
            savedLinks[index].isFavorite.toggle()
            savedLinks[index].favoriteIdentity = item.id
            let result = savedLinks[index].isFavorite
            if result { cachePoster(for: item, savedID: savedLinks[index].id) }
            savedLinks = savedLinks
            persistSavedLinksImmediately()
            return result
        }

        let source: SavedVideoLink.LinkSource = {
            let label = item.source.lowercased()
            if label.contains("offcloud") { return .offcloud }
            if label.contains("pikpak") || label.contains("webdav") { return .webdav }
            if item.url.pathExtension.lowercased() == "m3u8" { return .hls }
            return .direct
        }()
        let link = SavedVideoLink(
            urlString: item.url.absoluteString,
            resolvedStreamURL: item.url.absoluteString,
            title: item.title,
            dateAdded: Date(),
            lastPlayed: nil,
            source: source,
            durationSeconds: item.durationSeconds,
            videoWidth: item.videoWidth,
            videoHeight: item.videoHeight,
            fileSizeBytes: item.fileSizeBytes,
            isFavorite: true,
            favoriteIdentity: item.id
        )
        savedLinks.insert(link, at: 0)
        cachePoster(for: item, savedID: link.id)
        persistSavedLinksImmediately()
        return true
    }

    private func cachePoster(for item: VideoDetailsItem, savedID: UUID) {
        let image = item.customPosterImage
            ?? item.customPosterFileName.flatMap { VideoThumbnailLoader.loadCustomPoster(fileName: $0) }
            ?? item.posterCacheKey.flatMap { VideoThumbnailLoader.cachedImage(forStableKey: $0) }
        guard let image else { return }
        VideoThumbnailLoader.cacheImage(image, forStableKey: "saved|\(savedID.uuidString)")
        if let key = item.posterCacheKey { VideoThumbnailLoader.cacheImage(image, forStableKey: key) }
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

        let source: SavedVideoLink.LinkSource = {
            let label = item.source.lowercased()
            if label.contains("offcloud") { return .offcloud }
            if label.contains("pikpak") || label.contains("webdav") { return .webdav }
            if item.url.pathExtension.lowercased() == "m3u8" { return .hls }
            return .direct
        }()
        let link = SavedVideoLink(
            urlString: item.url.absoluteString,
            resolvedStreamURL: item.url.absoluteString,
            title: item.title,
            dateAdded: Date(),
            lastPlayed: nil,
            source: source,
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
        if let data = try? JSONEncoder().encode(playlists) {
            UserDefaults.standard.set(data, forKey: playlistsKey)
            UserDefaults.standard.synchronize()
        }
    }

    /// فيديوهات قائمة تشغيل معيّنة، بترتيب الإضافة (الأحدث أولاً)
    func links(in playlist: VideoPlaylist) -> [SavedVideoLink] {
        playlist.linkIDs.compactMap { id in savedLinks.first(where: { $0.id == id }) }
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
    func togglePlaylistMembership(_ item: VideoDetailsItem, playlist: VideoPlaylist) {
        guard let idx = playlists.firstIndex(where: { $0.id == playlist.id }) else { return }
        let link = resolvedLink(for: item)
        if let pos = playlists[idx].linkIDs.firstIndex(of: link.id) {
            playlists[idx].linkIDs.remove(at: pos)
        } else {
            playlists[idx].linkIDs.insert(link.id, at: 0)
        }
        persistPlaylistsImmediately()
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
        // Magnets without PikPak resolution are stored but not directly playable
        if kind == .magnet || kind == .pikpakMagnet {
            let title = title ?? "Magnet download"
            if let idx = savedLinks.firstIndex(where: { $0.urlString == raw.trimmingCharacters(in: .whitespacesAndNewlines) }) {
                savedLinks[idx].lastPlayed = Date()
                persistSavedLinksImmediately()
                return savedLinks[idx]
            }
            let link = SavedVideoLink(
                urlString: raw.trimmingCharacters(in: .whitespacesAndNewlines),
                resolvedStreamURL: resolvedStream?.absoluteString,
                title: title,
                dateAdded: Date(),
                lastPlayed: Date(),
                source: .pikpak,
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
        guard let providerKey,
              let poster = VideoThumbnailLoader.cachedImage(forStableKey: providerKey) else { return }
        VideoThumbnailLoader.cacheImage(poster, forStableKey: "saved|\(savedID.uuidString)")
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
        guard let fileName = VideoThumbnailLoader.saveCustomPoster(image, for: link.id) else { return }
        if let idx = savedLinks.firstIndex(where: { $0.id == link.id }) {
            // Remove previous custom file if different
            if let old = savedLinks[idx].thumbnailFileName, old != fileName {
                VideoThumbnailLoader.deleteCustomPoster(fileName: old)
            }
            savedLinks[idx].thumbnailFileName = fileName
            let keys = Set(["saved|\(link.id.uuidString)", link.favoriteIdentity].compactMap { $0 })
            for key in keys { VideoThumbnailLoader.cacheImage(image, forStableKey: key) }
            // Assign the array back so every grid that is showing this link,
            // including Recent, immediately receives the new file name.
            savedLinks = savedLinks
            persistSavedLinksImmediately()
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
        // Tokenized PikPak direct download links - preserve fid/sign/userid/etc.
        if LinkResolver.isPikPakDirectDownload(link.urlString)
            || (link.source == .pikpak && LinkResolver.isPikPakDirectDownload(link.resolvedStreamURL ?? "")) {
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

        // Re-resolve PikPak cloud file id if needed
        if link.source == .pikpak, let fileId = link.pikpakFileId {
            isLoading = true
            defer { isLoading = false }
            do {
                let stream = try await PikPakClient.shared.streamURL(forFileId: fileId)
                startPlayback(url: stream, title: link.title, linkId: link.id)
                if let idx = savedLinks.firstIndex(where: { $0.id == link.id }) {
                    savedLinks[idx].resolvedStreamURL = stream.absoluteString
                    persistSavedLinksImmediately()
                }
                return
            } catch {
                // Fall through to stored URL
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
        if link.source == .webdav,
           let host = url.host?.lowercased(),
           let server = servers.first(where: { $0.baseURL?.host?.lowercased() == host }) {
            startPlayback(
                url: url,
                title: link.title,
                linkId: link.id,
                headers: WebDAVClient(server: server).streamHeaders()
            )
            return
        }
        startPlayback(url: url, title: link.title, linkId: link.id)
    }

    private func startPlayback(
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

        let playbackURL = BackgroundVideoCacheManager.shared.playbackURL(
            for: url,
            stableKey: matchedId?.uuidString ?? url.absoluteString,
            suggestedFileName: title,
            headers: headers ?? [:]
        )

        nowPlayingForceVR = nextPlaybackForceVR
        nextPlaybackForceVR = false
        nowPlayingLinkId = matchedId
        nowPlayingResumeAt = resume
        nowPlayingHeaders = playbackURL.isFileURL ? nil : headers
        nowPlaying = WebDAVFile(
            name: VideoTitleFormatter.title(from: title),
            path: playbackURL.absoluteString,
            isDirectory: false,
            contentType: "video"
        )
        nowPlayingURL = playbackURL

        // Let the player transition appear first; moving the library card before
        // the cover opens causes a visible jump in the library.
        if let matchedId {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
                guard let self, self.nowPlayingLinkId == matchedId,
                      let idx = self.savedLinks.firstIndex(where: { $0.id == matchedId }) else { return }
                self.savedLinks[idx].lastPlayed = Date()
                let updated = self.savedLinks.remove(at: idx)
                self.savedLinks.insert(updated, at: 0)
                self.persistSavedLinksImmediately()
            }
        }
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
            currentFiles = files.sorted { a, b in
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
        return try? JSONDecoder().decode([WebDAVFile].self, from: data)
    }

    private func savePikPakFilesToCache(_ files: [WebDAVFile], server: WebDAVServer, path: String, flattenFolders: Bool, extractSmallFolders: Bool) {
        guard let data = try? JSONEncoder().encode(files) else { return }
        UserDefaults.standard.set(data, forKey: pikPakCacheKey(server: server, path: path, flattenFolders: flattenFolders, extractSmallFolders: extractSmallFolders))
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
            let sortedFiles = files.sorted {
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
    func contentLibraryFiles(server: WebDAVServer, forceRefresh: Bool = false) async -> [WebDAVFile] {
        let configuredRoots = WebDAVContentSelectionStore.selectedPaths(for: server.id)
        let roots = configuredRoots.map(WebDAVContentSelectionStore.minimalRoots) ?? [""]
        guard !roots.isEmpty else { return [] }
        let revision = WebDAVContentSelectionStore.revision(for: server.id)
        if !forceRefresh, let cached = WebDAVContentIndexStore.load(serverID: server.id, revision: revision) {
            return cached
        }
        let client = WebDAVClient(server: server)
        var collected: [WebDAVFile] = []
        await withTaskGroup(of: [WebDAVFile].self) { group in
            for root in roots {
                group.addTask {
                    (try? await self.collectPikPakVideos(client: client, startingAt: root, maximumFiles: 5_000, forceRefresh: forceRefresh)) ?? []
                }
            }
            for await files in group { collected.append(contentsOf: files) }
        }
        var seen = Set<String>()
        let result = collected.filter { seen.insert($0.path).inserted }
        WebDAVContentIndexStore.save(result, serverID: server.id, revision: revision)
        return result
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

    func play(file: WebDAVFile, server: WebDAVServer) {
        let client = WebDAVClient(server: server)
        guard let url = client.streamURL(for: file) else {
            errorMessage = "Could not build stream URL for this file"
            return
        }
        let headers = client.streamHeaders()
        // Auto-save WebDAV streams to library too
        let saved = saveDirectLink(
            url.absoluteString,
            resolvedStream: url,
            source: .webdav,
            title: file.name,
            fileSizeBytes: file.size
        )
        startPlayback(url: url, title: file.name, linkId: saved?.id, headers: headers)
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
            guard pikpakAccount != nil || PikPakClient.shared.loadAccount() != nil else {
                _ = saveDirectLink(trimmed, source: .pikpak, title: "Magnet (needs PikPak)")
                return "Magnet links need a PikPak account. Use a direct stream or WebDAV instead."
            }
            isLoading = true
            defer { isLoading = false }
            do {
                _ = try await PikPakClient.shared.addOfflineTask(urlOrMagnet: trimmed)
                _ = saveDirectLink(trimmed, source: .pikpak, title: "Magnet -> PikPak")
                pikpakStatus = "Magnet added to PikPak offline downloads"
                try await refreshPikPakFiles()
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
            try await refreshPikPakFiles()
            return nil
        } catch {
            return error.localizedDescription
        }
    }
    func pikpakLoginWithPersonalAccessToken(_ token: String) async -> String? {
        isLoading = true
        defer { isLoading = false }
        do {
            let acc = try await PikPakClient.shared.loginWithPersonalAccessToken(token)
            pikpakAccount = acc
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
    }

    func refreshPikPakFiles(parentId: String? = nil, force: Bool = false) async throws {
        let pid = parentId ?? pikpakPath.last?.id ?? ""
        if !force, let cached = pikpakFilesCache[pid] {
            pikpakFiles = cached
            return
        }
        isLoading = true
        defer { isLoading = false }
        let files = try await PikPakClient.shared.listFiles(parentId: pid)
        let sorted = files.sorted { a, b in
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
            startPlayback(url: stream, title: file.name)
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
        startPlayback(url: stream, title: file.name)
    }

    func addMagnetToPikPak(_ magnet: String) async -> String? {
        isLoading = true
        defer { isLoading = false }
        do {
            _ = try await PikPakClient.shared.addOfflineTask(urlOrMagnet: magnet)
            _ = saveDirectLink(magnet, source: .pikpak, title: "Magnet task")
            try await refreshPikPakFiles()
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}
