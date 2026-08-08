import SwiftUI
import UIKit
import Combine

/// Dedicated PikPak WebDAV tab. Other WebDAV browsers keep their normal folder list.
struct PikPakWebDAVView: View {
    @ObservedObject var vm: AppViewModel
    var homeToken: Int = 0
    var isActive: Bool = true
    @State private var files: [WebDAVFile] = []
    @State private var globalSearchResults: [WebDAVFile] = []
    @State private var globalSearchText = ""
    @State private var isGlobalSearching = false
    @State private var globalSearchTask: Task<Void, Never>?
    @State private var locations: [PikPakLocation] = []
    @State private var showingPlayer = false
    @State private var detailShowingPlayer = false
    @State private var selectedVideoFile: WebDAVFile?
    @State private var showingSetup = false
    @State private var isRefreshing = false
    @State private var folderCoverVersion = 0
    @State private var showingTMDBSettings = false
    @State private var showingAutoSync = false
    @State private var searchCoverKey: String?
    @State private var searchCoverTitle = ""
    @State private var thePornDBKey: String?
    @State private var thePornDBTitle = ""

    // 2 per row — matches the Offcloud grid exactly.
    private let columns = (0..<3).map { _ in GridItem(.flexible(), spacing: 10, alignment: .top) }
    /// Videos smaller than this are hidden in the PikPak section.
    private static let minimumVideoSizeBytes: Int64 = 500 * 1024 * 1024 // 500 MB
    private let mainFolderNames: Set<String> = [
        "my pack", "my tiktok", "top", "korean movies", "english series",
        "my upload", "anime", "english movies", "elza", "korean drama"
    ]

    private var server: WebDAVServer? {
        vm.servers.first { $0.host.lowercased().contains("dav.mypikpak.com") }
    }

    private var location: PikPakLocation {
        locations.last ?? PikPakLocation(title: "PikPak", path: "", flattensFolders: false, extractSmallFolders: false)
    }

    private var displayedFiles: [WebDAVFile] {
        globalSearchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? files
            : globalSearchResults
    }

    private var seriesEpisodeFiles: [WebDAVFile] {
        displayedFiles.filter { !$0.isDirectory && VideoTitleFormatter.episodeComponents(from: $0.name) != nil }
            .sorted {
                let a = VideoTitleFormatter.episodeComponents(from: $0.name)!
                let b = VideoTitleFormatter.episodeComponents(from: $1.name)!
                return a.season == b.season ? a.episode < b.episode : a.season < b.season
            }
    }

    private var isSeriesLocation: Bool {
        let normalizedFolder = location.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !location.path.isEmpty,
              !mainFolderNames.contains(normalizedFolder),
              seriesEpisodeFiles.count >= 2 else { return false }
        let folderTitle = TMDBService.searchTitle(from: location.title).lowercased()
        let matchingEpisodes = seriesEpisodeFiles.filter {
            let episodeTitle = TMDBService.searchTitle(from: $0.name).lowercased()
            return episodeTitle == folderTitle || episodeTitle.contains(folderTitle) || folderTitle.contains(episodeTitle)
        }
        return matchingEpisodes.count >= 2
    }
    private func episodeItems(server: WebDAVServer) -> [VideoEpisodeItem] {
        seriesEpisodeFiles.compactMap { file in
            guard let value = VideoTitleFormatter.episodeComponents(from: file.name) else { return nil }
            return VideoEpisodeItem(id: coverKey(for: file, server: server), title: file.name, season: value.season, episode: value.episode)
        }
    }
    var body: some View {
        NavigationView {
            Group {
                if let server {
                    browser(for: server)
                } else {
                    setupPrompt
                }
            }
            .background(
                ZStack {
                    AppTheme.bg
                    RadialGradient(
                        colors: [Color.cyan.opacity(0.10), Color.clear],
                        center: .topTrailing,
                        startRadius: 10,
                        endRadius: 420
                    )
                }
                .ignoresSafeArea()
            )
            .navigationTitle(globalSearchText.isEmpty ? location.title : "Search PikPak")
            .navigationBarTitleDisplayMode(.large)
            .searchable(
                text: $globalSearchText,
                placement: .navigationBarDrawer(displayMode: .always),
                prompt: "Search all PikPak folders"
            )
            .toolbar {
                ToolbarItemGroup(placement: .navigationBarTrailing) {
                    Button { Task { await refreshCurrentLocation() } } label: {
                        Image(systemName: "arrow.clockwise")
                            .rotationEffect(.degrees(isRefreshing ? 360 : 0))
                            .animation(isRefreshing ? .linear(duration: 0.9).repeatForever(autoreverses: false) : .default, value: isRefreshing)
                    }
                    .disabled(isRefreshing || server == nil)

                    Button { showingAutoSync = true } label: {
                        Image(systemName: PikPakAutoSyncManager.shared.isEnabled
                              ? "bolt.fill" : "bolt.slash")
                    }

                    Button { showingTMDBSettings = true } label: {
                        Image(systemName: "film.stack")
                    }

                    Button { showingSetup = true } label: {
                        Image(systemName: "gearshape")
                    }
                }
            }
        }
        .sheet(isPresented: $showingTMDBSettings) {
            TMDBSettingsView()
        }
        .sheet(isPresented: $showingAutoSync) {
            PikPakAutoSyncSettingsView(vm: vm)
        }
        .sheet(isPresented: Binding(
            get: { searchCoverKey != nil },
            set: { if !$0 { searchCoverKey = nil } }
        )) {
            YandexImageSearchView(initialQuery: searchCoverTitle) { image in
                if let key = searchCoverKey { cachePikPakCover(image, key: key) }
                searchCoverKey = nil
            }
        }
        .sheet(isPresented: Binding(
            get: { thePornDBKey != nil },
            set: { if !$0 { thePornDBKey = nil } }
        )) {
            ThePornDBSearchView(initialQuery: thePornDBTitle) { image in
                if let key = thePornDBKey { cachePikPakCover(image, key: key) }
                thePornDBKey = nil
            }
        }
        // Folder changes are immediate: no slide, fade or list transition.
        .transaction { transaction in
            transaction.animation = nil
            transaction.disablesAnimations = true
        }
        .fullScreenCover(isPresented: Binding(
            get: { selectedVideoFile != nil },
            set: { if !$0 { selectedVideoFile = nil } }
        )) {
            if let file = selectedVideoFile {
            if let server,
               let url = WebDAVClient(server: server).streamURL(for: file) {
                let saved = vm.savedLinks.first {
                    $0.url?.absoluteString == url.absoluteString
                        || $0.resolvedStreamURL == url.absoluteString
                }
                VideoDetailsView(
                    vm: vm,
                    item: VideoDetailsItem(
                        id: coverKey(for: file, server: server),
                        title: file.name,
                        url: url,
                        httpHeaders: WebDAVClient(server: server).streamHeaders(),
                        posterCacheKey: coverKey(for: file, server: server),
                        customPosterFileName: saved?.thumbnailFileName,
                        customPosterImage: PikPakFolderCoverStore.image(for: coverKey(for: file, server: server)),
                        fileSizeBytes: file.size,
                        durationSeconds: saved?.durationSeconds,
                        videoWidth: saved?.videoWidth,
                        videoHeight: saved?.videoHeight,
                        fileExtension: file.fileExtension,
                        source: "PikPak",
                        resumePositionSeconds: saved?.resumePositionSeconds,
                        relatedEpisodes: episodeItems(server: server)
                    ),
                    onPlay: { play(file, on: server, fromDetails: true) },
                    onDelete: { delete(file, on: server) },
                    dismissOnPlay: false,
                    onSelectEpisode: { episodeID in
                        if let next = seriesEpisodeFiles.first(where: { coverKey(for: $0, server: server) == episodeID }) {
                            selectedVideoFile = next
                        }
                    }
                )
                .fullScreenCover(isPresented: $detailShowingPlayer, onDismiss: {
                    folderCoverVersion &+= 1
                }) {
                    ResolvedPlayerScreen(vm: vm)
                }
            } else {
                Text("Could not open this PikPak video.").padding()
            }
        }
        }
        .sheet(isPresented: $showingSetup) {
            WebDAVSettingsView(vm: vm)
        }
        .fullScreenCover(isPresented: $showingPlayer, onDismiss: {
            folderCoverVersion &+= 1
        }) {
            if let url = vm.nowPlayingURL, let file = vm.nowPlaying {
                VideoPlayerView(
                    url: url,
                    title: file.name,
                    resumeAt: vm.nowPlayingResumeAt,
                    linkId: vm.nowPlayingLinkId,
                    httpHeaders: vm.nowPlayingHeaders
                ) { seconds, duration, width, height in
                    vm.updatePlaybackProgress(
                        seconds: seconds,
                        duration: duration,
                        width: width,
                        height: height,
                        linkId: vm.nowPlayingLinkId,
                        streamURL: url
                    )
                }
            }
        }
        .onAppear {
            loadCurrentLocation()
        }
        .onChange(of: vm.servers.count) { _ in loadCurrentLocation() }
        .onChange(of: homeToken) { _ in
            globalSearchTask?.cancel()
            globalSearchText = ""
            globalSearchResults = []
            locations = []
            vm.errorMessage = nil
            loadCurrentLocation()
        }
        .onChange(of: globalSearchText) { text in
            startGlobalSearch(text)
        }
    }

    @ViewBuilder
    private func browser(for server: WebDAVServer) -> some View {
        if isRefreshing && files.isEmpty {
            ProgressView("Loading...")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let error = vm.errorMessage, files.isEmpty {
            VStack(spacing: 14) {
                Image(systemName: "wifi.slash").font(.system(size: 38)).foregroundColor(.gray)
                Text(error).font(.footnote).foregroundColor(.gray).multilineTextAlignment(.center)
                Button("Retry") { Task { await refreshCurrentLocation() } }
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if !locations.isEmpty {
                        Button {
                            updateFolderImmediately {
                                locations.removeLast()
                            }
                            loadCurrentLocation()
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: "chevron.left")
                                    .font(.system(size: 12, weight: .bold))
                                Text("Back")
                                    .font(.system(size: 13, weight: .semibold))
                            }
                            .foregroundColor(.cyan)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(Color.cyan.opacity(0.14), in: Capsule())
                            .overlay(Capsule().stroke(Color.cyan.opacity(0.25), lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                    }

                    if location.flattensFolders {
                        Text("VIDEOS IN THIS FOLDER")
                            .font(.system(size: 11, weight: .bold))
                            .tracking(0.6)
                            .foregroundColor(AppTheme.mutedDeep)
                    }

                    if isGlobalSearching {
                        HStack(spacing: 10) {
                            ProgressView().tint(.cyan)
                            Text("Searching every PikPak folder…")
                                .font(.footnote)
                                .foregroundColor(AppTheme.muted)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 42)
                    } else if displayedFiles.isEmpty {
                        VStack(spacing: 12) {
                            ZStack {
                                Circle()
                                    .fill(Color.white.opacity(0.06))
                                    .frame(width: 76, height: 76)
                                Image(systemName: "film")
                                    .font(.system(size: 30, weight: .medium))
                                    .foregroundColor(AppTheme.muted)
                            }
                            Text("No videos here")
                                .font(.headline)
                                .foregroundColor(.white)
                            Text("There are no playable videos in this folder yet.")
                                .font(.footnote)
                                .foregroundColor(AppTheme.mutedDeep)
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.top, 80)
                    } else {
                        if isSeriesLocation {
                            LazyVStack(spacing: 10) {
                                ForEach(seriesEpisodeFiles) { file in
                                    PikPakEpisodeRow(file: file) { open(file, on: server) }
                                }
                            }
                        } else {
                        LazyVGrid(columns: columns, spacing: 10) {
                            ForEach(displayedFiles) { file in
                                PikPakFilePoster(
                                    file: file,
                                    server: server,
                                    posterRefreshVersion: folderCoverVersion,
                                    usesMainFolderArtwork: location.path.isEmpty
                                        && file.isDirectory
                                        && mainFolderNames.contains(file.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()),
                                    onSearchCover: {
                                        searchCoverTitle = file.displayName
                                        searchCoverKey = coverKey(for: file, server: server)
                                    },
                                    onSearchThePornDB: {
                                        thePornDBTitle = file.displayName
                                        thePornDBKey = coverKey(for: file, server: server)
                                    },
                                    onRemoveCover: {
                                        PikPakFolderCoverStore.remove(for: coverKey(for: file, server: server))
                                        VideoThumbnailLoader.removeCachedImage(forStableKey: coverKey(for: file, server: server))
                                        folderCoverVersion &+= 1
                                    }
                                ) {
                                    open(file, on: server)
                                }
                            }
                        }
                        }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 12)
            }
            .refreshable {
                await refreshCurrentLocation()
            }
        }
    }

    private var setupPrompt: some View {
        VStack(spacing: 22) {
            Spacer(minLength: 0)

            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [Color.cyan.opacity(0.35), Color.indigo.opacity(0.28)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 108, height: 108)
                    .blur(radius: 1)
                Circle()
                    .stroke(Color.cyan.opacity(0.35), lineWidth: 1)
                    .frame(width: 108, height: 108)
                Image(systemName: "externaldrive.connected.to.line.below")
                    .font(.system(size: 40, weight: .medium))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [Color.white, Color.cyan],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
            }

            VStack(spacing: 8) {
                Text("Connect PikPak")
                    .font(.title2.weight(.bold))
                    .foregroundStyle(AppTheme.titleGradient)
                Text("Add your PikPak WebDAV username and password to browse and stream your library right here.")
                    .font(.subheadline)
                    .foregroundColor(AppTheme.muted)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
            }

            Button {
                showingSetup = true
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "plus.circle.fill")
                    Text("Set Up PikPak")
                        .fontWeight(.semibold)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 13)
            }
            .buttonStyle(.plain)
            .foregroundColor(.black)
            .background(AppTheme.accentGradient, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .padding(.horizontal, 44)
            .shadow(color: AppTheme.accent.opacity(0.35), radius: 14, y: 6)

            HStack(spacing: 18) {
                setupHint(icon: "bolt.fill", text: "Fast streaming")
                setupHint(icon: "square.grid.2x2.fill", text: "Auto covers")
                setupHint(icon: "lock.fill", text: "Private")
            }
            .padding(.top, 4)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func setupHint(icon: String, text: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(.cyan)
            Text(text)
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(AppTheme.mutedDeep)
        }
        .frame(width: 78)
    }

    private func open(_ file: WebDAVFile, on server: WebDAVServer) {
        if file.isDirectory {
            let opensMainFolder = locations.isEmpty
                && mainFolderNames.contains(file.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
            updateFolderImmediately {
                locations.append(PikPakLocation(
                    title: file.name,
                    path: file.path,
                    flattensFolders: !opensMainFolder,
                    extractSmallFolders: opensMainFolder
                ))
            }
            loadCurrentLocation()
        } else if file.isVideo {
            selectedVideoFile = file
        }
    }

    @MainActor
    private func play(_ file: WebDAVFile, on server: WebDAVServer, fromDetails: Bool = false) {
        vm.play(file: file, server: server)
        if fromDetails {
            detailShowingPlayer = vm.nowPlayingURL != nil
        } else {
            showingPlayer = vm.nowPlayingURL != nil
        }
    }

    private func delete(_ file: WebDAVFile, on server: WebDAVServer) {
        Task {
            do {
                let client = WebDAVClient(server: server)
                try await client.delete(file: file)
                if let url = client.streamURL(for: file) {
                    VideoThumbnailLoader.deleteCache(for: url)
                }
                PikPakFolderCoverStore.remove(for: coverKey(for: file, server: server))
                folderCoverVersion &+= 1
                await refreshCurrentLocation()
            } catch {
                vm.errorMessage = error.localizedDescription
            }
        }
    }

    private func updateFolderImmediately(_ update: () -> Void) {
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction, update)
    }
    /// A cover belongs to this exact server item, never just a visible name.
    private func coverKey(for file: WebDAVFile, server: WebDAVServer) -> String {
        server.id.uuidString + "|" + (file.isDirectory ? "folder" : "file") + "|" + file.path + "|" + file.name
    }

    /// Saves a manually picked cover (Yandex search/paste or ThePornDB search)
    /// so it persists and overrides the automatic ThePornDB thumbnail.
    private func cachePikPakCover(_ image: UIImage, key: String) {
        PikPakFolderCoverStore.save(image, for: key)
        folderCoverVersion &+= 1
    }

    /// Folders always allowed; any other file only if size ≥ 500 MB.
    private func meetsMinimumVideoSize(_ file: WebDAVFile) -> Bool {
        if file.isDirectory { return true }
        guard let size = file.size else { return false } // unknown size → hide
        return size >= Self.minimumVideoSizeBytes
    }

    private func visibleFiles(_ source: [WebDAVFile], at current: PikPakLocation) -> [WebDAVFile] {
        let normalizedFolder = current.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let seriesFolder = !current.path.isEmpty && !mainFolderNames.contains(normalizedFolder)
            && source.filter { !$0.isDirectory && VideoTitleFormatter.episodeComponents(from: $0.name) != nil }.count >= 2
        let sized = source.filter {
            if seriesFolder, !$0.isDirectory, VideoTitleFormatter.episodeComponents(from: $0.name) != nil { return true }
            return meetsMinimumVideoSize($0)
        }
        guard current.path.isEmpty else { return sized }
        return sized.filter {
            !$0.isDirectory || mainFolderNames.contains($0.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
        }
    }
    @MainActor
    private func refreshCurrentLocation() async {
        guard let server else { return }
        let current = location
        isRefreshing = true
        defer { isRefreshing = false }
        let refreshedFiles = await vm.pikPakFiles(server: server, path: current.path, flattenFolders: current.flattensFolders, extractSmallFolders: current.extractSmallFolders, forceRefresh: true)
        if vm.errorMessage == nil || !refreshedFiles.isEmpty {
            files = visibleFiles(refreshedFiles, at: current)
        }
        guard current.path.isEmpty else { return }
        for folder in refreshedFiles where folder.isDirectory {
            if Task.isCancelled { return }
            _ = await vm.pikPakFiles(server: server, path: folder.path, flattenFolders: false, extractSmallFolders: true, forceRefresh: true)
        }
    }
    private func startGlobalSearch(_ rawQuery: String) {
        globalSearchTask?.cancel()
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, let server else {
            globalSearchResults = []
            isGlobalSearching = false
            return
        }
        isGlobalSearching = true
        globalSearchTask = Task {
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled else { return }
            let results = await vm.searchPikPakVideos(server: server, query: query)
            guard !Task.isCancelled, globalSearchText.trimmingCharacters(in: .whitespacesAndNewlines) == query else { return }
            globalSearchResults = results
            isGlobalSearching = false
        }
    }

    private func loadCurrentLocation() {
        guard let server else {
            files = []
            return
        }
        let current = location
        if let cachedFiles = vm.cachedPikPakFiles(server: server, path: current.path, flattenFolders: current.flattensFolders, extractSmallFolders: current.extractSmallFolders) {
            files = visibleFiles(cachedFiles, at: current)
        } else {
            // Without this, the previous folder's grid stays on screen while the
            // new one loads in the background — looks exactly like a frozen tap.
            // Clearing the list + flipping isRefreshing right away (instead of
            // waiting for the Task below to start) makes the spinner appear
            // immediately when a folder isn't cached yet.
            files = []
            isRefreshing = true
            Task { await refreshCurrentLocation() }
        }
    }
}

actor TMDBPosterLoadGate {
    static let shared = TMDBPosterLoadGate()
    private let maximum = 2
    private var running = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        if running < maximum { running += 1; return }
        await withCheckedContinuation { waiters.append($0) }
        running += 1
    }

    func release() {
        running -= 1
        if !waiters.isEmpty { waiters.removeFirst().resume() }
    }
}
actor PikPakPersistentPosterLoader {
    static let shared = PikPakPersistentPosterLoader()
    private var tasks: [String: Task<UIImage?, Never>] = [:]

    func tmdbCover(for key: String, query: String) async -> UIImage? {
        let taskKey = "tmdb|\(key)"
        if let existing = tasks[taskKey] { return await existing.value }
        let task: Task<UIImage?, Never> = Task.detached(priority: .utility) {
            await TMDBPosterLoadGate.shared.acquire()
            defer { Task { await TMDBPosterLoadGate.shared.release() } }
            guard let details = await TMDBService.shared.details(for: query),
                  let imageURL = details.posterURL ?? details.imageURL,
                  let (data, _) = try? await URLSession.shared.data(from: imageURL),
                  let cover = UIImage(data: data) else { return nil }
            await PikPakFolderCoverStore.saveAutomaticCoverAsync(cover, for: key)
            return cover
        }
        tasks[taskKey] = task
        let result = await task.value
        tasks[taskKey] = nil
        return result
    }
    func cover(for key: String, query: String) async -> UIImage? {
        if let existing = tasks[key] { return await existing.value }
        let task: Task<UIImage?, Never> = Task.detached(priority: .utility) {
            await ThumbnailLoadGate.shared.acquire()
            defer { Task { await ThumbnailLoadGate.shared.release() } }
            guard let metadata = await VideoThumbnailLoader.fetchThePornDBMetadata(for: query),
                  let cover = metadata.coverImage else { return nil }
            await PikPakFolderCoverStore.saveAutomaticCoverAsync(cover, for: key)
            return cover
        }
        tasks[key] = task
        let result = await task.value
        tasks[key] = nil
        return result
    }
}

private struct PikPakLocation: Identifiable {
    let id = UUID()
    let title: String
    let path: String
    let flattensFolders: Bool
    let extractSmallFolders: Bool
}

private struct PikPakEpisodeRow: View {
    let file: WebDAVFile
    let action: () -> Void

    private var episode: (season: Int, episode: Int) {
        VideoTitleFormatter.episodeComponents(from: file.name) ?? (1, 0)
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 13).fill(AppTheme.accent.opacity(0.16))
                    VStack(spacing: 1) {
                        Text("\(episode.episode)").font(.title2.bold()).foregroundColor(.white)
                        Text("EPISODE").font(.caption2).foregroundColor(AppTheme.accent)
                    }
                }.frame(width: 66, height: 66)

                VStack(alignment: .leading, spacing: 5) {
                    Text("Season \(episode.season) · Episode \(episode.episode)").font(.caption.weight(.semibold)).foregroundColor(AppTheme.accent)
                    Text(VideoTitleFormatter.episodeTitle(from: file.name)).font(.headline).foregroundColor(.white).lineLimit(2)
                    if !file.sizeFormatted.isEmpty { Text(file.sizeFormatted).font(.caption2).foregroundColor(.secondary) }
                }
                Spacer()
                Image(systemName: "play.circle.fill").font(.title2).foregroundStyle(AppTheme.accent)
            }
            .padding(12)
            .background(Color.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 17))
            .overlay(RoundedRectangle(cornerRadius: 17).stroke(Color.white.opacity(0.07)))
        }.buttonStyle(.plain)
    }
}
private struct PikPakFilePoster: View {
    let file: WebDAVFile
    let server: WebDAVServer
    let posterRefreshVersion: Int
    let usesMainFolderArtwork: Bool
    var onSearchCover: (() -> Void)? = nil
    var onSearchThePornDB: (() -> Void)? = nil
    var onRemoveCover: (() -> Void)? = nil
    let action: () -> Void
    @ObservedObject private var downloadManager = VideoDownloadManager.shared
    @State private var poster: UIImage?
    @State private var isLoadingPoster = false

    init(
        file: WebDAVFile,
        server: WebDAVServer,
        posterRefreshVersion: Int,
        usesMainFolderArtwork: Bool,
        onSearchCover: (() -> Void)? = nil,
        onSearchThePornDB: (() -> Void)? = nil,
        onRemoveCover: (() -> Void)? = nil,
        action: @escaping () -> Void
    ) {
        self.file = file
        self.server = server
        self.posterRefreshVersion = posterRefreshVersion
        self.usesMainFolderArtwork = usesMainFolderArtwork
        self.onSearchCover = onSearchCover
        self.onSearchThePornDB = onSearchThePornDB
        self.onRemoveCover = onRemoveCover
        self.action = action
        let key = server.id.uuidString + "|" + (file.isDirectory ? "folder" : "file") + "|" + file.path + "|" + file.name
        _poster = State(initialValue: PikPakFolderCoverStore.cachedImage(for: key) ?? VideoThumbnailLoader.cachedImage(forStableKey: key))
    }
    private var stableCacheKey: String {
        server.id.uuidString + "|" + (file.isDirectory ? "folder" : "file") + "|" + file.path + "|" + file.name
    }

    private var currentDownload: ManagedVideoDownload? {
        guard !file.isDirectory else { return nil }
        return downloadManager.download(forSourceURL: WebDAVClient(server: server).streamURL(for: file))
    }

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                GeometryReader { proxy in
                    ZStack {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(file.isDirectory ? Color.indigo.opacity(0.45) : Color.white.opacity(0.10))

                        if let poster {
                            Image(uiImage: poster)
                                .resizable()
                                .scaledToFill()
                                .frame(width: proxy.size.width, height: proxy.size.height)
                                .clipped()
                        } else if usesMainFolderArtwork, PikPakMainFolderArtwork.supports(file.name) {
                            PikPakMainFolderArtwork(name: file.name)
                                .frame(width: proxy.size.width, height: proxy.size.height)
                        } else if !file.isDirectory && isLoadingPoster {
                            ProgressView()
                                .tint(.cyan)
                                .controlSize(.small)
                        } else {
                            Image(systemName: file.isDirectory ? "folder.fill" : "play.rectangle.fill")
                                .font(.system(size: file.isDirectory ? 22 : 24, weight: .medium))
                                .foregroundColor(file.isDirectory ? .yellow : .cyan)
                        }

                        if !file.isDirectory {
                            VStack {
                                HStack {
                                    if !file.sizeFormatted.isEmpty {
                                        Text(file.sizeFormatted)
                                            .font(.system(size: 7, weight: .bold))
                                            .foregroundColor(.white)
                                            .padding(.horizontal, 4)
                                            .padding(.vertical, 3)
                                            .background(Color.black.opacity(0.72), in: Capsule())
                                    }
                                    Spacer()
                                    Text(file.fileExtension)
                                        .font(.system(size: 8, weight: .bold))
                                        .foregroundColor(.white)
                                        .padding(.horizontal, 5)
                                        .padding(.vertical, 3)
                                        .background(Color.black.opacity(0.72), in: Capsule())
                                }
                                Spacer()
                            }
                            .padding(5)
                        }

                        if let currentDownload {
                            VideoDownloadStateOverlay(download: currentDownload, compact: true)
                        }
                    }
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(Color.white.opacity(0.08), lineWidth: 1)
                    )
                    .clipped()
                }
                .aspectRatio(2 / 3, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .shadow(color: .black.opacity(0.25), radius: 6, y: 3)

                Text(file.displayName)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.white)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .clipped()
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .clipped()
        .contextMenu { menuContent }
        .task(id: "\(server.id.uuidString)|\(file.path)|\(posterRefreshVersion)") {
            if let customCover = await PikPakFolderCoverStore.imageAsync(for: stableCacheKey) {
                poster = customCover
                isLoadingPoster = false
                return
            }
            if let cached = await VideoThumbnailLoader.cachedImageAsync(forStableKey: stableCacheKey) {
                poster = cached
                isLoadingPoster = false
                return
            }

            if usesMainFolderArtwork, PikPakMainFolderArtwork.supports(file.name) {
                isLoadingPoster = false
                return
            }

            let query = TMDBService.searchTitle(from: file.name)
            isLoadingPoster = true
            if !query.isEmpty, TMDBSettings.isConfigured,
               let cover = await PikPakPersistentPosterLoader.shared.tmdbCover(for: stableCacheKey, query: query) {
                poster = cover
                isLoadingPoster = false
                return
            }

            // Non-TMDB videos retain the existing metadata provider as fallback.
            if !file.isDirectory, !query.isEmpty, ThePornDBSettings.hasValidAPIKey,
               let cover = await PikPakPersistentPosterLoader.shared.cover(for: stableCacheKey, query: query) {
                poster = cover
            }
            isLoadingPoster = false
        }
        .onReceive(NotificationCenter.default.publisher(for: VideoThumbnailLoader.stablePosterDidUpdateNotification)) { notification in
            guard let key = notification.object as? String,
                  key == stableCacheKey,
                  let cached = VideoThumbnailLoader.cachedImage(forStableKey: key) else { return }
            poster = cached
            isLoadingPoster = false
        }
        .onReceive(NotificationCenter.default.publisher(for: VideoThumbnailLoader.posterPrefetchDidFinishNotification)) { notification in
            guard let key = notification.object as? String, key == stableCacheKey else { return }
            if let cached = VideoThumbnailLoader.cachedImage(forStableKey: key) {
                poster = cached
            }
            isLoadingPoster = false
        }
    }

    @ViewBuilder
    private var menuContent: some View {
        Button(action: action) {
            Label(file.isDirectory ? "Open" : "Play", systemImage: file.isDirectory ? "folder" : "play.fill")
        }
        if let onSearchCover {
            Button(action: onSearchCover) {
                Label("Search or Paste Image URL", systemImage: "magnifyingglass")
            }
        }
        if let onSearchThePornDB {
            Button(action: onSearchThePornDB) {
                Label("Search ThePornDB", systemImage: "star.fill")
            }
        }
        if let onRemoveCover {
            Button(role: .destructive, action: onRemoveCover) {
                Label("Remove Cover", systemImage: "photo.badge.minus")
            }
        }
    }
}

private struct PikPakMainFolderArtwork: View {
    let name: String

    static func supports(_ name: String) -> Bool {
        switch normalized(name) {
        case "my pack", "my tiktok", "top", "korean movies", "english series",
             "my upload", "anime", "english movies", "elza", "korean drama":
            return true
        default:
            return false
        }
    }

    var body: some View {
        let folderDesign = design
        ZStack {
            LinearGradient(
                colors: [folderDesign.start, folderDesign.end],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            Circle()
                .fill(Color.white.opacity(0.10))
                .frame(width: 92, height: 92)
                .offset(x: 38, y: -54)

            Circle()
                .fill(Color.black.opacity(0.10))
                .frame(width: 74, height: 74)
                .offset(x: -40, y: 58)

            Image(systemName: folderDesign.symbol)
                .font(.system(size: 62, weight: .bold))
                .foregroundColor(.white.opacity(0.07))
                .rotationEffect(.degrees(-14))
                .offset(x: 25, y: 34)

            VStack(spacing: 8) {
                Spacer()

                ZStack {
                    Circle()
                        .fill(Color.white.opacity(0.17))
                        .frame(width: 48, height: 48)
                    Circle()
                        .stroke(Color.white.opacity(0.32), lineWidth: 1)
                        .frame(width: 48, height: 48)
                    Image(systemName: folderDesign.symbol)
                        .font(.system(size: 23, weight: .semibold))
                        .foregroundColor(.white)
                }

                Text(folderDesign.caption)
                    .font(.system(size: 8, weight: .heavy, design: .rounded))
                    .foregroundColor(.white.opacity(0.94))
                    .tracking(0.8)
                    .lineLimit(1)
                    .minimumScaleFactor(0.65)
                    .padding(.horizontal, 6)

                Spacer()
            }
        }
        .clipped()
    }

    private var design: (symbol: String, caption: String, start: Color, end: Color) {
        switch Self.normalized(name) {
        case "my pack":
            return ("archivebox.fill", "MY PACK", Color(red: 0.18, green: 0.42, blue: 0.96), Color(red: 0.38, green: 0.16, blue: 0.72))
        case "my tiktok":
            return ("music.note", "TIKTOK", Color(red: 0.98, green: 0.18, blue: 0.48), Color(red: 0.02, green: 0.72, blue: 0.82))
        case "top":
            return ("crown.fill", "TOP", Color(red: 0.98, green: 0.68, blue: 0.10), Color(red: 0.92, green: 0.28, blue: 0.08))
        case "korean movies":
            return ("film.fill", "K-MOVIES", Color(red: 0.82, green: 0.10, blue: 0.20), Color(red: 0.28, green: 0.08, blue: 0.42))
        case "english series":
            return ("tv.fill", "SERIES", Color(red: 0.12, green: 0.52, blue: 0.94), Color(red: 0.18, green: 0.12, blue: 0.58))
        case "my upload":
            return ("cloud.fill", "UPLOAD", Color(red: 0.08, green: 0.72, blue: 0.88), Color(red: 0.06, green: 0.28, blue: 0.68))
        case "anime":
            return ("sparkles", "ANIME", Color(red: 0.96, green: 0.26, blue: 0.68), Color(red: 0.42, green: 0.12, blue: 0.78))
        case "english movies":
            return ("film.fill", "MOVIES", Color(red: 0.06, green: 0.68, blue: 0.58), Color(red: 0.06, green: 0.30, blue: 0.62))
        case "elza":
            return ("snowflake", "ELZA", Color(red: 0.48, green: 0.88, blue: 1.00), Color(red: 0.24, green: 0.34, blue: 0.86))
        case "korean drama":
            return ("heart.fill", "K-DRAMA", Color(red: 0.98, green: 0.34, blue: 0.50), Color(red: 0.64, green: 0.08, blue: 0.28))
        default:
            return ("folder.fill", "FOLDER", Color.indigo, Color.purple)
        }
    }

    private static func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

private enum PikPakFolderCoverStore {
    private static let mapKey = "pikpak_item_cover_files_v2"
    private static var cachedValues: [String: String]?
    private static let imageCache = NSCache<NSString, UIImage>()

    static func cachedImage(for path: String) -> UIImage? {
        imageCache.object(forKey: path as NSString)
    }

    static func image(for path: String) -> UIImage? {
        if let cached = cachedImage(for: path) { return cached }
        guard let filename = map()[path], let image = VideoThumbnailLoader.loadCustomPoster(fileName: filename) else { return nil }
        imageCache.setObject(image, forKey: path as NSString)
        return image
    }

    static func imageAsync(for path: String) async -> UIImage? {
        if let cached = cachedImage(for: path) { return cached }
        let filename = map()[path]
        guard let filename else { return nil }
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let image = VideoThumbnailLoader.loadCustomPoster(fileName: filename)
                if let image { imageCache.setObject(image, forKey: path as NSString) }
                continuation.resume(returning: image)
            }
        }
    }

    static func save(_ image: UIImage, for path: String) {
        imageCache.setObject(image, forKey: path as NSString)
        var values = map()
        if let old = values[path] { VideoThumbnailLoader.deleteCustomPoster(fileName: old) }
        guard let filename = VideoThumbnailLoader.saveCustomPoster(image, for: UUID()) else { return }
        values[path] = filename
        saveMap(values)
    }

    static func saveIfMissing(_ image: UIImage, for path: String) {
        imageCache.setObject(image, forKey: path as NSString)
        var values = map()
        guard values[path] == nil else { return }
        guard let filename = VideoThumbnailLoader.saveCustomPoster(image, for: UUID()) else { return }
        values[path] = filename
        saveMap(values)
    }

    static func saveAutomaticCoverAsync(_ image: UIImage, for path: String) async {
        let filename = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                VideoThumbnailLoader.cacheImage(image, forStableKey: path)
                continuation.resume(returning: VideoThumbnailLoader.saveCustomPoster(image, for: UUID()))
            }
        }
        guard let filename else { return }
        imageCache.setObject(image, forKey: path as NSString)
        await MainActor.run {
            var values = map()
            guard values[path] == nil else {
                VideoThumbnailLoader.deleteCustomPoster(fileName: filename)
                return
            }
            values[path] = filename
            saveMap(values)
        }
    }

    static func remove(for path: String) {
        imageCache.removeObject(forKey: path as NSString)
        var values = map()
        if let old = values.removeValue(forKey: path) { VideoThumbnailLoader.deleteCustomPoster(fileName: old) }
        saveMap(values)
    }

    private static func map() -> [String: String] {
        if let cachedValues { return cachedValues }
        guard let data = UserDefaults.standard.data(forKey: mapKey),
              let values = try? JSONDecoder().decode([String: String].self, from: data) else {
            cachedValues = [:]
            return [:]
        }
        cachedValues = values
        return values
    }

    private static func saveMap(_ values: [String: String]) {
        cachedValues = values
        guard let data = try? JSONEncoder().encode(values) else { return }
        UserDefaults.standard.set(data, forKey: mapKey)
    }
}