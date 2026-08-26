import SwiftUI
import UIKit
import Combine
import UniformTypeIdentifiers

// MARK: - Visual palette (styling only — matches the Offcloud redesign mockup)
// NOTE: This enum only controls colors/appearance for this screen. It does not
// touch any view-model, networking, or business logic.
private enum OffcloudPalette {
    static let bgPrimary = Color(red: 0x09 / 255, green: 0x0B / 255, blue: 0x0E / 255)
    static let bgSecondary = Color(red: 0x14 / 255, green: 0x16 / 255, blue: 0x1C / 255)
    static let bgCard = Color(red: 0x1A / 255, green: 0x1D / 255, blue: 0x25 / 255)
    static let accentTeal = AppPalette.accent
    static let textSecondary = Color(red: 0x88 / 255, green: 0x92 / 255, blue: 0xA8 / 255)
    static let borderSubtle = Color.white.opacity(0.08)
    static let badgeOrange = Color(red: 0xF5 / 255, green: 0xA6 / 255, blue: 0x23 / 255)
    static let badgeBlue = Color(red: 0x4A / 255, green: 0x90 / 255, blue: 0xE2 / 255)
}

@MainActor
final class OffcloudViewModel: ObservableObject {
    @Published var apiKey: String
    @Published var transfers: [OffcloudTransfer]
    @Published var selectedTransfer: OffcloudTransfer?
    @Published var selectedFiles: [OffcloudFile] = []
    @Published var selectedFilesError: String?
    @Published var isRefreshing = false
    @Published var isSubmitting = false
    @Published var isLoadingFiles = false
    @Published var errorMessage: String?
    @Published private(set) var filesCacheVersion = 0


    private let historyCacheKey = "offcloud_history_cache_v1"
    private let filesCacheKey = "offcloud_files_cache_v1"
    private let sourcesCacheKey = "offcloud_sources_cache_v1"
    private let filesCacheDatesKey = "offcloud_files_cache_dates_v1"
    private var filesCache: [String: [OffcloudFile]] = [:]
    private var sourceByRequest: [String: String] = [:]
    private var filesCacheDates: [String: Date] = [:]
    private var pollingTask: Task<Void, Never>?
    private var fileLoadTask: Task<Void, Never>?
    private var loadingRequestID: String?
    private let filesCacheLifetime: TimeInterval = 24 * 60 * 60
    private let silentRefreshAge: TimeInterval = 12 * 60 * 60

    init() {
        apiKey = OffcloudKeyStore.load()
        transfers = []
        filesCache = [:]
        sourceByRequest = [:]
        filesCacheDates = [:]
    }

    func reloadPersistedState() async {
        let historyKey = historyCacheKey
        let filesKey = filesCacheKey
        let sourcesKey = sourcesCacheKey
        let datesKey = filesCacheDatesKey
        let state = await Task.detached(priority: .utility) {
            (
                OffcloudKeyStore.load(),
                Self.load([OffcloudTransfer].self, key: historyKey) ?? [],
                Self.load([String: [OffcloudFile]].self, key: filesKey) ?? [:],
                Self.load([String: String].self, key: sourcesKey) ?? [:],
                Self.load([String: Date].self, key: datesKey) ?? [:]
            )
        }.value
        apiKey = state.0
        transfers = state.1
        filesCache = state.2
        sourceByRequest = state.3
        filesCacheDates = state.4
        filesCacheVersion &+= 1
    }

    var hasKey: Bool { !apiKey.isEmpty }
    var hasActiveTransfers: Bool {
        transfers.contains { !$0.isDownloaded && !$0.isFailed }
    }

    func saveKey(_ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        apiKey = trimmed
        if OffcloudKeyStore.save(trimmed) {
            errorMessage = nil
        } else {
            errorMessage = "The API key could not be stored securely."
        }
    }

    func clearKey() {
        _ = OffcloudKeyStore.delete()
        apiKey = ""
        pollingTask?.cancel()
        pollingTask = nil
    }

    func loadInitial() async {
        await reloadPersistedState()
        guard hasKey else { return }
        if transfers.isEmpty {
            await refreshHistory(startPolling: false)
        }
        beginPollingIfNeeded()
        Task(priority: .utility) { [weak self] in
            await self?.refreshDownloadedFileCaches(force: false)
        }
    }

    func refreshHistory(startPolling: Bool = true, silent: Bool = false) async {
        guard hasKey else { return }
        // Silent polls must not toggle isRefreshing — that rebuilds the whole grid mid-scroll.
        if !silent {
            guard !isRefreshing else { return }
            isRefreshing = true
        }

        do {
            let remote = try await OffcloudClient(apiKey: apiKey).history()
            let instant = transfers.filter(\.isInstantCache)
            let merged = (instant + remote)
                .reduce(into: [String: OffcloudTransfer]()) { $0[$1.requestId] = $1 }
                .values
                .sorted { ($0.createdOn ?? "") > ($1.createdOn ?? "") }
            if merged != transfers {
                transfers = merged
                persist(transfers, key: historyCacheKey)
            }
            if !silent {
                errorMessage = nil
            }
            if startPolling { beginPollingIfNeeded() }
        } catch {
            if !silent {
                errorMessage = error.localizedDescription
            }
        }

        if !silent {
            isRefreshing = false
        }
    }

    func refreshAll() async {
        await refreshHistory(startPolling: false)
        await refreshDownloadedFileCaches(force: true)
        beginPollingIfNeeded()
    }
    func addDownload(_ raw: String) async -> Bool {
        let source = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard hasKey, !source.isEmpty else {
            errorMessage = hasKey ? "Paste a link or magnet first." : OffcloudError.missingKey.localizedDescription
            return false
        }

        isSubmitting = true
        defer { isSubmitting = false }

        let client = OffcloudClient(apiKey: apiKey)
        do {
            if let cached = try await client.cachedFilesIfAvailable(for: source), !cached.isEmpty {
                addInstantTransfer(files: cached, source: source)
                errorMessage = nil
                return true
            }
        } catch OffcloudError.missingKey {
            errorMessage = OffcloudError.missingKey.localizedDescription
            return false
        } catch {
            // Cache lookup is an optimization. If it is unavailable, continue
            // with a normal cloud transfer.
        }

        do {
            let transfer = try await client.create(url: source)
            register(transfer, source: source)
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func addDownloadFile(_ fileURL: URL) async -> Bool {
        guard hasKey else {
            errorMessage = OffcloudError.missingKey.localizedDescription
            return false
        }

        let didAccess = fileURL.startAccessingSecurityScopedResource()
        defer {
            if didAccess { fileURL.stopAccessingSecurityScopedResource() }
        }

        isSubmitting = true
        defer { isSubmitting = false }

        let client = OffcloudClient(apiKey: apiKey)
        let magnetSource = TorrentInfoHash.magnetSource(for: fileURL)

        if let magnetSource {
            do {
                if let cached = try await client.cachedFilesIfAvailable(for: magnetSource),
                   !cached.isEmpty {
                    addInstantTransfer(files: cached, source: magnetSource)
                    errorMessage = nil
                    return true
                }
            } catch {
                // Continue with the uploaded file when cache lookup is unavailable.
            }
        }

        do {
            let transfer = try await client.create(fileURL: fileURL)
            register(transfer, source: magnetSource)
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func beginOpen(_ transfer: OffcloudTransfer) {
        guard transfer.isDownloaded else {
            Task { await refreshHistory() }
            return
        }
        if loadingRequestID == transfer.requestId { return }

        fileLoadTask?.cancel()
        selectedTransfer = transfer
        selectedFilesError = nil

        if let cached = freshCachedFiles(for: transfer.requestId) {
            selectedFiles = cached
            isLoadingFiles = false
            let age = Date().timeIntervalSince(filesCacheDates[transfer.requestId] ?? .distantPast)
            if age >= silentRefreshAge, !transfer.isInstantCache {
                startFileLoad(for: transfer, showSkeleton: false)
            }
            return
        }

        selectedFiles = []
        startFileLoad(for: transfer, showSkeleton: true)
    }

    func retrySelectedTransfer() {
        guard let transfer = selectedTransfer else { return }
        fileLoadTask?.cancel()
        selectedFiles = []
        selectedFilesError = nil
        startFileLoad(for: transfer, showSkeleton: true)
    }

    func refreshSelectedTransfer() async {
        guard let transfer = selectedTransfer else { return }
        fileLoadTask?.cancel()
        await fetchAndApplyFiles(for: transfer, showSkeleton: false)
    }

    func cancelFileLoad(for requestId: String) {
        guard loadingRequestID == requestId else { return }
        fileLoadTask?.cancel()
        fileLoadTask = nil
        loadingRequestID = nil
        isLoadingFiles = false
    }

    private func freshCachedFiles(for requestId: String) -> [OffcloudFile]? {
        guard let files = filesCache[requestId],
              let date = filesCacheDates[requestId],
              Date().timeIntervalSince(date) < filesCacheLifetime else { return nil }
        return files
    }

    private func startFileLoad(for transfer: OffcloudTransfer, showSkeleton: Bool) {
        loadingRequestID = transfer.requestId
        isLoadingFiles = showSkeleton
        fileLoadTask = Task { [weak self] in
            guard let self else { return }
            await self.fetchAndApplyFiles(for: transfer, showSkeleton: showSkeleton)
        }
    }

    private func fetchAndApplyFiles(for transfer: OffcloudTransfer, showSkeleton: Bool) async {
        let requestId = transfer.requestId
        loadingRequestID = requestId
        if showSkeleton { isLoadingFiles = true }
        let client = OffcloudClient(apiKey: apiKey)

        do {
            let files: [OffcloudFile]
            do {
                files = try await client.explore(requestId: requestId)
            } catch OffcloudError.badArchive {
                files = try await recoverSingleFile(for: transfer, client: client)
            }
            guard !Task.isCancelled, loadingRequestID == requestId else { return }
            saveFiles(files, for: requestId)
            errorMessage = nil
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled, loadingRequestID == requestId else { return }
            if selectedTransfer?.requestId == requestId, selectedFiles.isEmpty {
                selectedFilesError = error.localizedDescription
                errorMessage = error.localizedDescription
            }
        }

        guard loadingRequestID == requestId else { return }
        loadingRequestID = nil
        fileLoadTask = nil
        isLoadingFiles = false
    }

    private static func visibleVideoFiles(from files: [OffcloudFile]) -> [OffcloudFile] {
        files
            .filter(\.isVideo)
            .sorted { ($0.path ?? $0.name) < ($1.path ?? $1.name) }
    }
    func cachedVideoFiles(for transfer: OffcloudTransfer) -> [OffcloudFile] {
        Self.visibleVideoFiles(from: filesCache[transfer.requestId] ?? [])
    }

    /// Cheap count for grid cells — avoids allocating filtered arrays while scrolling.
    func cachedVideoCount(for transfer: OffcloudTransfer) -> Int {
        (filesCache[transfer.requestId] ?? []).reduce(into: 0) { count, file in
            if file.isVideo { count += 1 }
        }
    }

    fileprivate var visibleVideoEntries: [OffcloudVideoEntry] {
        transfers.flatMap { transfer in
            cachedVideoFiles(for: transfer).map {
                OffcloudVideoEntry(transfer: transfer, file: $0)
            }
        }
    }

    fileprivate var allVideoEntries: [OffcloudVideoEntry] { visibleVideoEntries }

    fileprivate var standaloneVideoEntries: [OffcloudVideoEntry] {
        transfers.flatMap { transfer in
            let videos = cachedVideoFiles(for: transfer)
            guard (1...2).contains(videos.count) else { return [OffcloudVideoEntry]() }
            return videos.map { OffcloudVideoEntry(transfer: transfer, file: $0) }
        }
    }

    fileprivate var folderTransfers: [OffcloudTransfer] {
        transfers.filter { cachedVideoFiles(for: $0).count >= 3 }
    }
    func beginPollingIfNeeded() {
        guard hasActiveTransfers, pollingTask == nil else { return }
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.hasActiveTransfers else { break }
                try? await Task.sleep(nanoseconds: 15_000_000_000) // 15s — was 5s
                guard !Task.isCancelled else { break }
                await self.refreshHistory(startPolling: false, silent: true)
            }
            self?.pollingTask = nil
        }
    }

    private func recoverSingleFile(
        for transfer: OffcloudTransfer,
        client: OffcloudClient
    ) async throws -> [OffcloudFile] {
        let source = sourceByRequest[transfer.requestId]
            ?? OffcloudClient.recoverSource(from: transfer.originalLink)

        guard let source else { throw OffcloudError.singleFileUnavailable }

        if let cached = try await client.cachedFilesIfAvailable(for: source),
           !cached.isEmpty {
            return cached
        }

        if let url = URL(string: source),
           LinkResolver.isVideoFileName(url.lastPathComponent) {
            return [
                OffcloudFile(
                    legacyName: transfer.fileName,
                    path: transfer.fileName,
                    url: source
                )
            ]
        }

        throw OffcloudError.singleFileUnavailable
    }

    private func register(_ transfer: OffcloudTransfer, source: String?) {
        transfers.removeAll { $0.requestId == transfer.requestId }
        transfers.insert(transfer, at: 0)
        if let source, !source.isEmpty {
            sourceByRequest[transfer.requestId] = source
            persist(sourceByRequest, key: sourcesCacheKey)
        }
        persist(transfers, key: historyCacheKey)
        errorMessage = nil
        beginPollingIfNeeded()
    }

    private func addInstantTransfer(files: [OffcloudFile], source: String) {
        let requestId = "instant-cache-\(UUID().uuidString)"
        let title = instantTitle(for: files)
        let transfer = OffcloudTransfer(
            requestId: requestId,
            fileName: title,
            status: "downloaded",
            progress: nil,
            message: nil,
            originalLink: source,
            createdOn: ISO8601DateFormatter().string(from: Date())
        )
        filesCache[requestId] = files
        sourceByRequest[requestId] = source
        transfers.insert(transfer, at: 0)
        persist(filesCache, key: filesCacheKey)
        persist(sourceByRequest, key: sourcesCacheKey)
        persist(transfers, key: historyCacheKey)
    }

    private func instantTitle(for files: [OffcloudFile]) -> String {
        if files.count == 1 { return files[0].name }
        if let path = files.first?.path {
            let root = path.split(separator: "/").first.map(String.init) ?? ""
            if !root.isEmpty { return root }
        }
        return "Cached Torrent"
    }

    func filesForPosterGeneration(for transfer: OffcloudTransfer) async -> [OffcloudFile] {
        if let cached = filesCache[transfer.requestId], !cached.isEmpty { return cached }
        guard hasKey, transfer.isDownloaded else { return [] }
        let client = OffcloudClient(apiKey: apiKey)
        do {
            let files = try await client.explore(requestId: transfer.requestId)
            saveFiles(files, for: transfer.requestId)
            return files
        } catch {
            return []
        }
    }

    func prepareGlobalSearch() async {
        await refreshDownloadedFileCaches(force: false)
    }

    private func refreshDownloadedFileCaches(force: Bool = false) async {
        guard hasKey else { return }
        var changed = false
        let client = OffcloudClient(apiKey: apiKey)
        for transfer in transfers where transfer.isDownloaded && !transfer.isInstantCache {
            if !force, freshCachedFiles(for: transfer.requestId) != nil { continue }
            do {
                let files = try await client.explore(requestId: transfer.requestId)
                saveFiles(files, for: transfer.requestId, persistImmediately: false)
                changed = true
            } catch OffcloudError.badArchive {
                if let files = try? await recoverSingleFile(for: transfer, client: client) {
                    saveFiles(files, for: transfer.requestId, persistImmediately: false)
                    changed = true
                }
            } catch {
                continue
            }
        }
        if changed {
            filesCacheVersion &+= 1
            persist(filesCache, key: filesCacheKey)
            persist(filesCacheDates, key: filesCacheDatesKey)
        }
    }
    /// Sequentially generates and permanently caches thumbnails (cell + detail
    /// sizes) for every entry in `entries`, in the given order. Videos that
    /// already have a cached cell thumbnail are skipped immediately. Safe to
    /// call again while already running (ignored) or after cancellation.
    private func offcloudStableKey(for transfer: OffcloudTransfer, file: OffcloudFile) -> String {
        "offcloud|\(transfer.requestId)|\(file.path ?? file.name)"
    }

    private func saveFiles(_ files: [OffcloudFile], for requestId: String, persistImmediately: Bool = true) {
        filesCache[requestId] = files
        filesCacheDates[requestId] = Date()
        if persistImmediately {
            filesCacheVersion &+= 1
            persist(filesCache, key: filesCacheKey)
            persist(filesCacheDates, key: filesCacheDatesKey)
        }
        guard selectedTransfer?.requestId == requestId else { return }
        selectedFiles = files
        selectedFilesError = nil
    }

    private func persist<T: Encodable>(_ value: T, key: String) {
        DispatchQueue.global(qos: .utility).async {
            guard let data = try? JSONEncoder().encode(value) else { return }
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    nonisolated private static func load<T: Decodable>(_ type: T.Type, key: String) -> T? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
}

private struct OffcloudVideoEntry: Identifiable {
    let transfer: OffcloudTransfer
    let file: OffcloudFile

    var id: String {
        "\(transfer.requestId)|\(file.id)"
    }
}

private enum OffcloudSection: String, CaseIterable, Identifiable {
    case videos = "Videos"
    case folders = "Folders"

    var id: String { rawValue }
}
struct OffcloudView: View {
    @ObservedObject var vm: AppViewModel
    @StateObject private var cloud = OffcloudViewModel()
    @State private var link = ""
    @State private var showingSettings = false
    @State private var showingFileImporter = false
    @State private var navigationPath = NavigationPath()
    @State private var directVideoSelection: OffcloudDirectVideoSelection?
    @State private var offcloudSearchText = ""
    @State private var searchCoverKey: String?
    @State private var searchCoverTitle = ""
    @State private var selectedSection: OffcloudSection = .videos

    private let columns = (0..<2).map { _ in GridItem(.flexible(), spacing: 10, alignment: .top) }
    private var filteredTransfers: [OffcloudTransfer] {
        let query = offcloudSearchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return cloud.transfers }
        return cloud.transfers.filter { transfer in
            transfer.fileName.lowercased().contains(query)
                || VideoTitleFormatter.title(from: transfer.fileName).lowercased().contains(query)
        }
    }

    private var filteredFolderTransfers: [OffcloudTransfer] {
        let query = offcloudSearchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return cloud.folderTransfers.filter { transfer in
            query.isEmpty
                || transfer.fileName.lowercased().contains(query)
                || VideoTitleFormatter.title(from: transfer.fileName).lowercased().contains(query)
        }
    }

    private var filteredStandaloneVideos: [OffcloudVideoEntry] {
        let query = offcloudSearchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let entries = query.isEmpty ? cloud.standaloneVideoEntries : cloud.allVideoEntries
        return entries.filter { entry in
            query.isEmpty
                || entry.file.name.lowercased().contains(query)
                || entry.file.displayName.lowercased().contains(query)
                || (entry.file.path ?? "").lowercased().contains(query)
                || entry.transfer.fileName.lowercased().contains(query)
        }
    }
    private var folderCoverGenerationID: String {
        cloud.transfers.map { "\($0.requestId)|\($0.fileName)|\($0.status)" }.joined(separator: ";")
    }

    private var standalonePosterPrefetchID: [String] {
        filteredStandaloneVideos.map {
            "\($0.transfer.requestId)|\($0.file.path ?? $0.file.name)|\($0.file.url)"
        }
    }
    private var torrentFileTypes: [UTType] {
        [
            UTType(filenameExtension: "torrent") ?? .data,
            UTType(filenameExtension: "nzb") ?? .xml
        ]
    }

    var body: some View {
        NavigationStack(path: $navigationPath) {
            Group {
                if cloud.hasKey { cloudHome } else { setupPrompt }
            }
            .background(OffcloudPalette.bgPrimary.ignoresSafeArea())
            .navigationTitle("Offcloud")
            .navigationBarTitleDisplayMode(.large)
            .searchable(
                text: $offcloudSearchText,
                placement: .navigationBarDrawer(displayMode: .always),
                prompt: "Search videos"
            )
            .toolbar {
                ToolbarItemGroup(placement: .navigationBarTrailing) {
                    Button { Task { await cloud.refreshAll() } } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(!cloud.hasKey || cloud.isRefreshing)

                    Button { showingSettings = true } label: {
                        Image(systemName: "gearshape")
                    }
                }
            }
            .navigationDestination(for: OffcloudTransfer.self) { transfer in
                OffcloudFilesView(
                    vm: vm,
                    transfer: transfer,
                    files: cloud.selectedTransfer?.requestId == transfer.requestId ? cloud.selectedFiles : [],
                    isLoading: cloud.selectedTransfer?.requestId == transfer.requestId && cloud.isLoadingFiles,
                    errorMessage: cloud.selectedFilesError,
                    onRetry: { cloud.retrySelectedTransfer() },
                    onRefresh: { await cloud.refreshSelectedTransfer() },
                    onDisappear: { }
                )
            }
        }
        .preferredColorScheme(.dark)
        .transaction { $0.animation = nil }
        .sheet(isPresented: $showingSettings) { settingsSheet }
        .fullScreenCover(item: $directVideoSelection) { selection in
            OffcloudVideoDetailsHost(
                vm: vm,
                file: selection.file,
                stableCacheKey: offcloudStableKey(for: selection.transfer, file: selection.file)
            )
        }        .sheet(isPresented: Binding(
            get: { searchCoverKey != nil },
            set: { if !$0 { searchCoverKey = nil } }
        )) {
            YandexImageSearchView(initialQuery: searchCoverTitle) { image in
                if let key = searchCoverKey { cacheOffcloudCover(image, key: key) }
                searchCoverKey = nil
            }
        }
        .fileImporter(
            isPresented: $showingFileImporter,
            allowedContentTypes: torrentFileTypes,
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case let .success(urls):
                guard let fileURL = urls.first else { return }
                Task { _ = await cloud.addDownloadFile(fileURL) }
            case let .failure(error):
                cloud.errorMessage = error.localizedDescription
            }
        }
        .task {
            await cloud.loadInitial()
            cloud.beginPollingIfNeeded()
        }
        .task(id: folderCoverGenerationID) {
            await generateMissingFolderCovers()
        }
        .task(id: standalonePosterPrefetchID) {
            prefetchStandaloneVideoPosters()
        }
        .onChange(of: offcloudSearchText) { text in
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            selectedSection = .videos
            Task { await cloud.prepareGlobalSearch() }
        }
    }
    private func prefetchStandaloneVideoPosters() {
        let requests = filteredStandaloneVideos.compactMap { entry -> VideoThumbnailLoader.PrefetchRequest? in
            guard let url = entry.file.streamURL else { return nil }
            return .init(
                url: url,
                remotePosterURL: nil,
                stableKey: offcloudStableKey(for: entry.transfer, file: entry.file),
                headers: [:],
                fileExtension: entry.file.fileExtension
            )
        }
        VideoThumbnailLoader.schedulePrefetchPosters(requests)
    }
    private func offcloudStableKey(for transfer: OffcloudTransfer, file: OffcloudFile) -> String {
        "offcloud|\(transfer.requestId)|\(file.path ?? file.name)"
    }

    private func openTransferOrDirectVideo(_ transfer: OffcloudTransfer) {
        guard transfer.isDownloaded else {
            Task { await cloud.refreshHistory() }
            return
        }
        cloud.beginOpen(transfer)
        navigationPath.append(transfer)
    }

    private func offcloudFolderCoverKey(for transfer: OffcloudTransfer) -> String {
        "offcloud-folder|\(transfer.requestId)"
    }

    private func cacheOffcloudCover(_ image: UIImage, key: String) {
        if key.hasPrefix("offcloud-folder|") {
            VideoThumbnailLoader.cacheHighQualityImageInBackground(image, forStableKey: key)
        } else {
            VideoThumbnailLoader.cacheImageInBackground(image, forStableKey: key)
        }
    }

    private func generateMissingFolderCovers() async {
        var jobs: [(key: String, title: String, videoURL: URL?)] = []
        for (index, transfer) in cloud.transfers.enumerated() {
            guard transfer.isDownloaded else { continue }
            let key = offcloudFolderCoverKey(for: transfer)
            guard await VideoThumbnailLoader.cachedImageAsync(forStableKey: key) == nil,
                  !VideoThumbnailLoader.isStableImageSuppressed(forKey: key) else { continue }
            let firstVideoURL = cloud.cachedVideoFiles(for: transfer).first?.streamURL
            jobs.append((key, VideoTitleFormatter.title(from: transfer.fileName), firstVideoURL))
            if index.isMultiple(of: 32) { await Task.yield() }
        }

        // Batches control how many frame-extraction tasks exist at once; the shared
        // thumbnail gate keeps network and image decoding bounded.
        let batchSize = 8
        for start in stride(from: 0, to: jobs.count, by: batchSize) {
            guard !Task.isCancelled else { return }
            let batch = Array(jobs[start..<min(start + batchSize, jobs.count)])
            await withTaskGroup(of: Void.self) { group in
                for job in batch {
                    group.addTask {
                        guard VideoThumbnailLoader.cachedImage(forStableKey: job.key) == nil else { return }
                        await ThumbnailLoadGate.shared.acquire()
                        defer { Task { await ThumbnailLoadGate.shared.release() } }
                        guard !Task.isCancelled else { return }
                        if let videoURL = job.videoURL,
                           let image = await VideoThumbnailLoader.loadPoster(
                               for: videoURL,
                               stableKey: job.key,
                               targetPointSize: ThumbnailPipeline.targetPointSize(for: .small)
                           ) {
                            VideoThumbnailLoader.cacheImage(image, forStableKey: job.key)
                        }
                    }
                }
                await group.waitForAll()
            }
        }
    }
    private var cloudHome: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                addCard

                if let error = cloud.errorMessage {
                    Text(error)
                        .font(.footnote)
                        .foregroundColor(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                offcloudTabsBar

                HStack {
                    Label(
                        selectedSection == .videos ? "Videos" : "Folders", systemImage: selectedSection == .videos ? "play.rectangle.fill" : "folder.fill.badge.play"
                    )
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(.white)
                    Spacer()
                    if cloud.isRefreshing { ProgressView().controlSize(.small) }
                    Text("\(selectedSection == .videos ? filteredStandaloneVideos.count : filteredFolderTransfers.count)")
                        .foregroundColor(OffcloudPalette.textSecondary)
                }

                ZStack(alignment: .top) {
                    standaloneVideosGrid
                        .opacity(selectedSection == .videos ? 1 : 0)
                        .allowsHitTesting(selectedSection == .videos)
                        .zIndex(selectedSection == .videos ? 1 : 0)
                    foldersGrid
                        .opacity(selectedSection == .folders ? 1 : 0)
                        .allowsHitTesting(selectedSection == .folders)
                        .zIndex(selectedSection == .folders ? 1 : 0)
                }
                .animation(nil, value: selectedSection)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 12)
        }
        .refreshable { await cloud.refreshAll() }
    }

    private var offcloudTabsBar: some View {
        HStack(spacing: 4) {
            ForEach(OffcloudSection.allCases) { section in
                Button {
                    selectedSection = section
                } label: {
                    Text(section.rawValue)
                        .font(.system(size: 14, weight: .medium))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .foregroundStyle(selectedSection == section ? Color.white : OffcloudPalette.textSecondary)
                        .background(
                            selectedSection == section ? OffcloudPalette.bgCard : Color.clear,
                            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .background(OffcloudPalette.bgSecondary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    @ViewBuilder
    private var standaloneVideosGrid: some View {
        if filteredStandaloneVideos.isEmpty {
            offcloudSectionEmptyState(
                icon: "play.rectangle",
                title: "Offcloud", message: "Could not load the Offcloud list."
            )
        } else {
            LazyVGrid(columns: columns, spacing: 10) {
                ForEach(filteredStandaloneVideos) { entry in
                    let key = offcloudStableKey(for: entry.transfer, file: entry.file)
                    OffcloudFilePoster(
                        file: entry.file,
                        stableCacheKey: key,                        onSearchCover: {
                            searchCoverTitle = entry.file.displayName
                            searchCoverKey = key
                        },
                        onRemoveCover: {
                            VideoThumbnailLoader.removeCachedImage(forStableKey: key)
                        }
                    ) {
                        directVideoSelection = OffcloudDirectVideoSelection(
                            transfer: entry.transfer,
                            file: entry.file
                        )
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var foldersGrid: some View {
        if filteredFolderTransfers.isEmpty {
            offcloudSectionEmptyState(
                icon: "folder.badge.questionmark",
                title: "Offcloud", message: "Could not load the Offcloud list."
            )
        } else {
            LazyVGrid(columns: columns, spacing: 10) {
                ForEach(filteredFolderTransfers) { transfer in
                    OffcloudTransferPoster(
                        transfer: transfer,
                        videoCount: cloud.cachedVideoCount(for: transfer),
                        stableCacheKey: offcloudFolderCoverKey(for: transfer),                        onSearchCover: {
                            searchCoverTitle = VideoTitleFormatter.title(from: transfer.fileName)
                            searchCoverKey = offcloudFolderCoverKey(for: transfer)
                        },
                        onRemoveCover: {
                            VideoThumbnailLoader.removeCachedImage(forStableKey: offcloudFolderCoverKey(for: transfer))
                        }
                    ) {
                        openTransferOrDirectVideo(transfer)
                    }
                }
            }
        }
    }

    private func offcloudSectionEmptyState(icon: String, title: String, message: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 38))
                .foregroundColor(OffcloudPalette.accentTeal)
            Text(title).font(.headline)
            Text(message)
                .font(.footnote)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 48)
    }

    private var addCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Add to Offcloud", systemImage: "cloud.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(OffcloudPalette.accentTeal)

            TextField("Paste a link or magnet", text: $link)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                .padding(12)
                .background(OffcloudPalette.bgPrimary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(OffcloudPalette.borderSubtle, lineWidth: 1)
                )

            HStack(spacing: 10) {
                Button {
                    link = UIPasteboard.general.string ?? ""
                } label: {
                    Label("Paste", systemImage: "doc.on.clipboard")
                        .font(.system(size: 14, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                }
                .foregroundStyle(OffcloudPalette.textSecondary)
                .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(OffcloudPalette.borderSubtle, lineWidth: 1)
                )
                .buttonStyle(.plain)

                Button {
                    Task {
                        if await cloud.addDownload(link) { link = "" }
                    }
                } label: {
                    Group {
                        if cloud.isSubmitting {
                            ProgressView()
                        } else {
                            Label("Add", systemImage: "plus.circle.fill")
                        }
                    }
                    .font(.system(size: 14, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                }
                .foregroundStyle(Color.black)
                .background(OffcloudPalette.accentTeal, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .buttonStyle(.plain)
                .disabled(link.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || cloud.isSubmitting)
                .opacity(link.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || cloud.isSubmitting ? 0.5 : 1)
            }

            Button {
                showingFileImporter = true
            } label: {
                Label("Choose Torrent or NZB File", systemImage: "doc.badge.plus")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
            }
            .foregroundStyle(OffcloudPalette.accentTeal)
            .background(OffcloudPalette.accentTeal.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(OffcloudPalette.accentTeal.opacity(0.2), lineWidth: 1)
            )
            .buttonStyle(.plain)
            .disabled(cloud.isSubmitting)
        }
        .padding(16)
        .background(OffcloudPalette.bgSecondary, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(OffcloudPalette.borderSubtle, lineWidth: 1)
        )
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "cloud")
                .font(.system(size: 40))
                .foregroundColor(OffcloudPalette.accentTeal)
            Text("No cloud transfers").font(.headline)
            Text("Add a link above, or pull down to refresh.")
                .font(.footnote)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
    }

    private var setupPrompt: some View {
        VStack(spacing: 16) {
            Image(systemName: "cloud.fill")
                .font(.system(size: 50))
                .foregroundColor(OffcloudPalette.accentTeal)
            Text("Connect Offcloud").font(.title3.bold())
            Text("Your API key is kept securely on this iPhone and is never added to the project.")
                .font(.footnote)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 36)
            Button("Enter API Key") { showingSettings = true }
                .buttonStyle(.borderedProminent)
                .tint(OffcloudPalette.accentTeal)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var settingsSheet: some View {
        OffcloudSettingsView(currentKey: cloud.apiKey) { key in
            cloud.saveKey(key)
            showingSettings = false
            Task { await cloud.refreshAll() }
        } onDisconnect: {
            cloud.clearKey()
            showingSettings = false
        }
    }


}

private struct OffcloudSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @State var currentKey: String
    let onSave: (String) -> Void
    let onDisconnect: () -> Void

    var body: some View {
        NavigationView {
            Form {
                Section("API Key") {
                    SecureField("Paste your Offcloud API key", text: $currentKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Text("Stored only in the iPhone Keychain.")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }

                if !currentKey.isEmpty {
                    Section {
                        Button("Disconnect", role: .destructive, action: onDisconnect)
                    }
                }
            }
            .navigationTitle("Offcloud Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    AppAnimatedBackButton(size: 36) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { onSave(currentKey) }
                        .disabled(currentKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}

private struct OffcloudDirectVideoSelection: Identifiable {
    let transfer: OffcloudTransfer
    let file: OffcloudFile

    var id: String { "\(transfer.requestId)|\(file.id)" }
}

private struct OffcloudTransferPoster: View {
    let transfer: OffcloudTransfer
    var videoCount: Int = 0
    let stableCacheKey: String
    let onSearchCover: () -> Void
    let onRemoveCover: () -> Void
    let action: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            posterButton
            titleBlock
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .contentShape(Rectangle())
        .clipped()
        .contextMenu {
            Button(action: onSearchCover) {
                Label("Search or Paste Image URL", systemImage: "magnifyingglass")
            }
            Button(role: .destructive, action: onRemoveCover) {
                Label("Remove Cover", systemImage: "photo.badge.minus")
            }
        }
    }

    @ViewBuilder
    private var posterButton: some View {
        Button(action: action) {
            posterContent
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var posterContent: some View {
        posterBase
            .overlay(alignment: .topTrailing) { statusChip }
            .overlay { progressOverlay }
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color.white.opacity(0.08), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.35), radius: 8, y: 4)
    }

    @ViewBuilder
    private var posterBase: some View {
        Color.black
            .aspectRatio(16.0 / 9.0, contentMode: .fit)
            .overlay {
                PosterThumbnailView(
                    url: nil,
                    stableCacheKey: stableCacheKey,
                    title: "Offcloud",
                    badge: "FOLDER", preferredTier: .small
                )
            }
            .overlay {
                VStack {
                    Spacer()
                    LinearGradient(
                        colors: [.clear, .black.opacity(0.75)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .frame(height: 40)
                }
            }
            .overlay {
                Image(systemName: "folder.fill")
                    .font(.system(size: 22))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, OffcloudPalette.accentTeal.opacity(0.92))
                    .shadow(color: .black.opacity(0.45), radius: 6, y: 2)
            }
    }

    @ViewBuilder
    private var statusChip: some View {
        chip(statusLabel, color: OffcloudPalette.accentTeal.opacity(0.85))
            .padding(8)
    }

    @ViewBuilder
    private var progressOverlay: some View {
        if !transfer.isDownloaded && !transfer.isFailed {
            VStack {
                Spacer()
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Rectangle().fill(Color.white.opacity(0.15))
                        Rectangle()
                            .fill(OffcloudPalette.accentTeal)
                            .frame(width: max(4, geo.size.width * CGFloat(transfer.displayProgress)))
                    }
                }
                .frame(height: 3)
            }
        }
    }

    @ViewBuilder
    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(VideoTitleFormatter.title(from: transfer.fileName))
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(.white)
                .lineLimit(1)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, minHeight: 26, maxHeight: 26, alignment: .topLeading)

            Text("\(max(videoCount, 1)) videos")
                .font(.system(size: 8, weight: .medium))
                .foregroundColor(.white.opacity(0.42))
                .lineLimit(1)
                .frame(maxWidth: .infinity, minHeight: 12, maxHeight: 12, alignment: .leading)
        }
        .frame(maxWidth: .infinity, minHeight: 42, maxHeight: 42, alignment: .topLeading)
        .padding(.top, 10)
        .padding(.horizontal, 2)
    }

    private func chip(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .bold))
            .foregroundColor(.white)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(color, in: Capsule())
            .lineLimit(1)
    }

    private var statusLabel: String {
        if transfer.isInstantCache { return "\(max(videoCount, 1))" }
        if transfer.isDownloaded { return "\(max(videoCount, 1))" }
        if transfer.isFailed { return "ERROR" }
        return "\(Int(transfer.displayProgress * 100))%"
    }
}

private struct OffcloudFileGroup: Identifiable {
    let id: String
    let files: [OffcloudFile]
}

private struct OffcloudFilesSkeleton: View {
    let columns: [GridItem]

    var body: some View {
        LazyVGrid(columns: columns, spacing: 10) {
            ForEach(0..<6, id: \.self) { _ in
                VStack(alignment: .leading, spacing: 8) {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color.white.opacity(0.08))
                        .frame(height: 160)
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(Color.white.opacity(0.08))
                        .frame(height: 12)
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(Color.white.opacity(0.06))
                        .frame(width: 120, height: 10)
                }
            }
        }
    }
}

private struct OffcloudFilesView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var vm: AppViewModel
    @State private var detailFile: OffcloudFile?
    @State private var searchCoverKey: String?
    @State private var searchCoverTitle = ""
    let transfer: OffcloudTransfer
    let files: [OffcloudFile]
    let isLoading: Bool
    let errorMessage: String?
    let onRetry: () -> Void
    let onRefresh: () async -> Void
    let onDisappear: () -> Void
    private let columns = (0..<2).map { _ in GridItem(.flexible(), spacing: 10, alignment: .top) }
    private var visibleVideoFiles: [OffcloudFile] {
        files
            .filter(\.isVideo)
            .sorted { ($0.path ?? $0.name) < ($1.path ?? $1.name) }
    }

    private var offcloudPosterPrefetchID: [String] {
        visibleVideoFiles.map {
            "\($0.id)|\($0.path ?? $0.name)|\($0.url)"
        }
    }


    private func prefetchVisibleVideoPosters() {
        let requests = visibleVideoFiles.compactMap { file -> VideoThumbnailLoader.PrefetchRequest? in
            guard let url = file.streamURL else { return nil }
            return .init(
                url: url,
                remotePosterURL: nil,
                stableKey: "offcloud|\(transfer.requestId)|\(file.path ?? file.name)",
                headers: [:],
                fileExtension: file.fileExtension
            )
        }
        VideoThumbnailLoader.schedulePrefetchPosters(requests)
    }
    var body: some View {
        Group {
            if isLoading && files.isEmpty {
                OffcloudFilesSkeleton(columns: columns)
                    .padding(.horizontal, 10)
                    .padding(.top, 10)
            } else if visibleVideoFiles.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 32))
                        .foregroundColor(.orange)
                    Text(errorMessage ?? "No playable videos found")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                    Button("Retry", action: onRetry)
                        .font(.footnote.weight(.semibold))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(Color.white.opacity(0.10), in: Capsule())
                }
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 10) {
                        ForEach(visibleVideoFiles) { file in
                            OffcloudFilePoster(
                                file: file,
                                stableCacheKey: "offcloud|\(transfer.requestId)|\(file.path ?? file.name)",                                onSearchCover: {
                                    searchCoverTitle = file.displayName
                                    searchCoverKey = "offcloud|\(transfer.requestId)|\(file.path ?? file.name)"
                                },
                                onRemoveCover: {
                                    VideoThumbnailLoader.removeCachedImage(forStableKey: "offcloud|\(transfer.requestId)|\(file.path ?? file.name)")
                                }
                            ) { detailFile = file }
                        }
                    }
                    .padding(10)
                }
            }
        }
        .background(OffcloudPalette.bgPrimary.ignoresSafeArea())
        .navigationTitle(VideoTitleFormatter.title(from: transfer.fileName))
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                AppAnimatedBackButton(size: 36) { dismiss() }
            }
        }
        .preferredColorScheme(.dark)
        .task(id: offcloudPosterPrefetchID) {
            prefetchVisibleVideoPosters()
        }        .sheet(isPresented: Binding(
            get: { searchCoverKey != nil },
            set: { if !$0 { searchCoverKey = nil } }
        )) {
            YandexImageSearchView(initialQuery: searchCoverTitle) { image in
                if let key = searchCoverKey { VideoThumbnailLoader.cacheImage(image, forStableKey: key) }
                searchCoverKey = nil
            }
        }
        .fullScreenCover(item: $detailFile) { file in
            OffcloudVideoDetailsHost(
                vm: vm,
                file: file,
                stableCacheKey: "offcloud|\(transfer.requestId)|\(file.path ?? file.name)"
            )
        }
    }
}
private struct OffcloudFolderFilesView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var vm: AppViewModel
    let transfer: OffcloudTransfer
    let group: OffcloudFileGroup
    @State private var detailFile: OffcloudFile?
    @State private var searchCoverKey: String?
    @State private var searchCoverTitle = ""
    private let columns = (0..<2).map { _ in GridItem(.flexible(), spacing: 10, alignment: .top) }

    private var folderPosterPrefetchID: [String] {
        group.files.map { "\($0.id)|\($0.url)" }
    }

    private func prefetchFolderVideoPosters() {
        let requests = group.files.compactMap { file -> VideoThumbnailLoader.PrefetchRequest? in
            guard file.isVideo, let url = file.streamURL else { return nil }
            return .init(
                url: url,
                remotePosterURL: nil,
                stableKey: "offcloud|\(transfer.requestId)|\(file.path ?? file.name)",
                headers: [:],
                fileExtension: file.fileExtension
            )
        }
        VideoThumbnailLoader.schedulePrefetchPosters(requests)
    }
    var body: some View {
        NavigationView {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 10) {
                    ForEach(group.files) { file in
                        OffcloudFilePoster(
                                file: file,
                                stableCacheKey: "offcloud|\(transfer.requestId)|\(file.path ?? file.name)",                                onSearchCover: {
                                    searchCoverTitle = file.displayName
                                    searchCoverKey = "offcloud|\(transfer.requestId)|\(file.path ?? file.name)"
                                },
                                onRemoveCover: {
                                    VideoThumbnailLoader.removeCachedImage(forStableKey: "offcloud|\(transfer.requestId)|\(file.path ?? file.name)")
                                }
                            ) { detailFile = file }
                    }
                }
                .padding(10)
            }
            .background(OffcloudPalette.bgPrimary.ignoresSafeArea())
            .navigationTitle(group.id)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    AppAnimatedBackButton(size: 36) { dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
        .task(id: folderPosterPrefetchID) {
            prefetchFolderVideoPosters()
        }
        .fullScreenCover(item: $detailFile) { file in
            OffcloudVideoDetailsHost(
                vm: vm,
                file: file,
                stableCacheKey: "offcloud|\(transfer.requestId)|\(file.path ?? file.name)"
            )
        }        .sheet(isPresented: Binding(
            get: { searchCoverKey != nil },
            set: { if !$0 { searchCoverKey = nil } }
        )) {
            YandexImageSearchView(initialQuery: searchCoverTitle) { image in
                if let key = searchCoverKey { VideoThumbnailLoader.cacheImage(image, forStableKey: key) }
                searchCoverKey = nil
            }
        }
    }
}

private struct OffcloudFolderPoster: View {
    let group: OffcloudFileGroup
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [OffcloudPalette.accentTeal.opacity(0.30), Color.blue.opacity(0.18), Color.white.opacity(0.08)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                    Image(systemName: "folder.fill")
                        .font(.system(size: 34, weight: .semibold))
                        .foregroundColor(OffcloudPalette.accentTeal)
                }
                .frame(width: 76, height: 86)

                VStack(alignment: .leading, spacing: 6) {
                    Text(group.id)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.white)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text("\(group.files.count) videos")
                        .font(.caption2.monospacedDigit().weight(.semibold))
                        .foregroundColor(OffcloudPalette.accentTeal)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
                    .foregroundColor(.secondary)
            }
            .padding(10)
            .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}
private struct OffcloudVideoDetailsHost: View {
    @ObservedObject var vm: AppViewModel
    let file: OffcloudFile
    let stableCacheKey: String
    @State private var showingPlayer = false

    var body: some View {
        if let url = file.streamURL {
            VideoDetailsView(
                vm: vm,
                item: VideoDetailsItem(
                    id: stableCacheKey,
                    title: file.name,
                    url: url,
                    posterCacheKey: stableCacheKey,
                    fileSizeBytes: file.size,
                    videoWidth: VideoTitleFormatter.dimensions(from: file.name)?.0,
                    videoHeight: VideoTitleFormatter.dimensions(from: file.name)?.1,
                    fileExtension: file.fileExtension,
                    source: "Offcloud"
                ),
                onPlay: startPlayback,
                dismissOnPlay: false
            )
            .fullScreenCover(isPresented: $showingPlayer) {
                if let playbackURL = vm.nowPlayingURL, vm.nowPlaying != nil {
                    RoutedVideoPlayerView(
                        url: playbackURL,
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
                            streamURL: playbackURL
                        )
                    }
                    .onDisappear {
                        vm.finishPlaybackHistory()
                    }
                } else {
                    ImmediatePlayerLoadingView()
                }
            }
        } else {
            Text("Could not open this Offcloud video.")
                .padding()
        }
    }

    @MainActor
    private func startPlayback() {
        guard let url = file.streamURL,
              let saved = vm.saveDirectLink(
                url.absoluteString,
                resolvedStream: url,
                source: .offcloud,
                title: file.name,
                fileSizeBytes: file.size,
                posterCacheKey: stableCacheKey
              ) else { return }

        vm.nowPlaying = nil
        vm.nowPlayingURL = nil
        vm.nowPlayingHeaders = nil
        showingPlayer = true

        Task { @MainActor in
            await vm.playSavedLinkAsync(saved)
            if vm.nowPlayingURL == nil { showingPlayer = false }
        }
    }
}

private struct OffcloudFilePoster: View {
    let file: OffcloudFile
    let stableCacheKey: String
    var onSearchCover: (() -> Void)? = nil
    var onRemoveCover: (() -> Void)? = nil
    let action: () -> Void

    @ObservedObject private var downloadManager = VideoDownloadManager.shared

    private var currentDownload: ManagedVideoDownload? {
        downloadManager.download(forSourceURL: file.streamURL)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            posterButton
            titleBlock
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .contentShape(Rectangle())
        .clipped()
        .contextMenu { menuContent }
    }

    @ViewBuilder
    private var posterButton: some View {
        Button(action: action) {
            posterContent
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var posterContent: some View {
        posterBase
            .overlay(alignment: .top) { topBadgeRow }
            .overlay(alignment: .bottom) { bottomBadgeRow }
            .overlay { downloadOverlay }
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color.white.opacity(0.08), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.35), radius: 8, y: 4)
    }

    @ViewBuilder
    private var posterBase: some View {
        Color.black
            .aspectRatio(16.0 / 9.0, contentMode: .fit)
            .overlay {
                PosterThumbnailView(
                    url: file.streamURL,
                    stableCacheKey: stableCacheKey,
                    title: file.name,
                    badge: file.fileExtension, preferredTier: .small
                )
            }
            .overlay {
                VStack {
                    Spacer()
                    LinearGradient(
                        colors: [.clear, .black.opacity(0.75)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .frame(height: 40)
                }
            }
            .overlay {
                Image(systemName: "play.circle.fill")
                    .font(.system(size: 24))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, OffcloudPalette.accentTeal.opacity(0.92))
                    .shadow(color: .black.opacity(0.45), radius: 6, y: 2)
            }
    }

    @ViewBuilder
    private var downloadOverlay: some View {
        if let currentDownload {
            VideoDownloadStateOverlay(download: currentDownload, compact: true)
        }
    }

    @ViewBuilder
    private var topBadgeRow: some View {
        HStack(alignment: .top, spacing: 6) {
            if let currentDownload {
                chip(currentDownload.state.rawValue.capitalized, color: .green)
            } else {
                chip(" ", color: .clear).opacity(0).accessibilityHidden(true)
            }
            Spacer(minLength: 4)
            if !file.sizeLabel.isEmpty {
                chip(file.sizeLabel, color: OffcloudPalette.badgeOrange)
            }
        }
        .padding(8)
        .frame(height: 30, alignment: .top)
    }

    @ViewBuilder
    private var bottomBadgeRow: some View {
        HStack(alignment: .bottom, spacing: 6) {
            chip(file.fileExtension.uppercased(), color: sourceColor)
            Spacer(minLength: 4)
            chip("OFFCLOUD", color: OffcloudPalette.accentTeal.opacity(0.9))
        }
        .padding(8)
        .frame(height: 30, alignment: .bottom)
    }

    @ViewBuilder
    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(file.displayName)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(.white)
                .lineLimit(1)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, minHeight: 26, maxHeight: 26, alignment: .topLeading)

            Text(file.folderPath.isEmpty ? "Offcloud · \(file.sizeLabel)" : "\(file.folderPath) · \(file.sizeLabel)")
                .font(.system(size: 8, weight: .medium))
                .foregroundColor(.white.opacity(0.42))
                .lineLimit(1)
                .frame(maxWidth: .infinity, minHeight: 12, maxHeight: 12, alignment: .leading)
        }
        .frame(maxWidth: .infinity, minHeight: 42, maxHeight: 42, alignment: .topLeading)
        .padding(.top, 10)
        .padding(.horizontal, 2)
    }

    @ViewBuilder
    private var menuContent: some View {
        Button { } label: { Label("Rename", systemImage: "pencil") }

        Button(action: action) {
            Label("Play", systemImage: "play.fill")
        }   
        if let onSearchCover {
            Button(action: onSearchCover) {
                Label("Search or Paste Image URL", systemImage: "magnifyingglass")
            }
        }
        if let onRemoveCover {
            Button(role: .destructive, action: onRemoveCover) {
                Label("Remove Cover", systemImage: "photo.badge.minus")
            }
        }
    }

    private func chip(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .bold))
            .foregroundColor(.white)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(color, in: Capsule())
            .lineLimit(1)
    }

    private var sourceColor: Color {
        OffcloudPalette.badgeBlue.opacity(0.9)
    }
}
