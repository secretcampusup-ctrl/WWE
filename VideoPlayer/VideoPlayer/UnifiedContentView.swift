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

private enum UnifiedSource: Codable {
    case webDAV(server: WebDAVServer, file: WebDAVFile)
    case offcloud(transfer: OffcloudTransfer, file: OffcloudFile)
    case torBox(torrent: TorBoxTorrent, file: TorBoxFile)
}

private struct UnifiedMediaEntry: Identifiable, Codable {
    let id: String
    let rawTitle: String
    var title: String
    let sourceLabel: String
    let source: UnifiedSource
    let streamURL: URL
    var details: TMDBTitleDetails?
    var adultScene: ThePornDBScene?
    var episodes: [UnifiedEpisode] = []
    var posterURL: URL? {
        if let url = details?.posterURL { return url }
        if let raw = adultScene?.bestImage { return URL(string: raw) }
        return nil
    }
}

private struct UnifiedEpisode: Identifiable, Codable {
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
private final class UnifiedContentModel: ObservableObject {
    @Published var movies: [UnifiedMediaEntry] = []
    @Published var shows: [UnifiedMediaEntry] = []
    @Published var unknown: [UnifiedMediaEntry] = []
    @Published var isLoading = false
    @Published var status = ""
    @Published var scanCompleted = false
    @Published var processedCount = 0
    @Published var totalCount = 0

    var remainingCount: Int { max(0, totalCount - processedCount) }
    var progressFraction: Double {
        guard totalCount > 0 else { return 0 }
        return min(1, Double(processedCount) / Double(totalCount))
    }
    private var loaded = false
    private var lastSourceSignature = ""
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
            movies = snapshot.movies
            shows = snapshot.shows
            unknown = snapshot.unknown
            lastSourceSignature = snapshot.sourceSignature ?? ""
            loaded = true
        }
    }

    func load(vm: AppViewModel, force: Bool = false) async {
        let metadataMatcherRevision = "release-v2"
        let baseSourceSignature = vm.servers.map {
            $0.id.uuidString + $0.displayAddress + WebDAVContentSelectionStore.revision(for: $0.id)
        }.joined(separator: "|") + "|tmdb:" + Self.stableSignature(TMDBSettings.readAccessToken)
            + "|matcher:" + metadataMatcherRevision
        var sourceSignature = baseSourceSignature + "|torbox:\(TorBoxLibraryStore.revision)"
        let shouldFetchMetadata = force || sourceSignature != lastSourceSignature
        // A cached library is immutable until the user explicitly refreshes.
        if loaded && !force && sourceSignature == lastSourceSignature { return }
        guard !isLoading else { return }
        isLoading = true
        scanCompleted = false
        processedCount = 0
        totalCount = 0
        status = "Reading connected libraries…"

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
            lastSourceSignature = sourceSignature
            persistSnapshot()
            scanCompleted = true
            status = "Library updated"
            try? await Task.sleep(nanoseconds: 550_000_000)
            isLoading = false
            status = ""
            return
        }
        totalCount = raw.count
        status = "Preparing metadata scan…"

        // Match each cleaned title once. Episode packs can contain hundreds of files
        // that all resolve to the same show, so querying each file serially made the
        // Content screen appear to load forever.
        var representativeByKey: [String: UnifiedMediaEntry] = [:]
        var fileCountByKey: [String: Int] = [:]
        for entry in raw {
            let key = metadataGroupKey(for: entry)
            representativeByKey[key] = entry
            fileCountByKey[key, default: 0] += 1
        }
        let representatives = Array(representativeByKey)
        // Do not hold the Content screen behind TMDB. Publish every discovered
        // file immediately, then progressively replace filename cards with the
        // canonical title and artwork as each lookup finishes.
        publishProgressiveLibrary(raw: raw, metadataByQuery: [:])
        loaded = true
        persistSnapshot()
        isLoading = false
        status = "Matching movies and TV shows with TMDB…"
        var metadataByQuery: [String: TMDBTitleDetails] = [:]
        await withTaskGroup(of: (String, TMDBTitleDetails?).self) { group in
            var iterator = representatives.makeIterator()
            for _ in 0..<min(12, representatives.count) {
                guard let (key, entry) = iterator.next() else { break }
                let lookupTitle = metadataLookupTitle(for: entry)
                let preferredType = preferredMediaType(for: entry)
                group.addTask {
                    let details: TMDBTitleDetails?
                    if shouldFetchMetadata {
                        details = await TMDBService.shared.detailsOriginalFirst(
                            for: lookupTitle,
                            preferredMediaType: preferredType,
                            persistImmediately: false
                        )
                    } else {
                        details = await TMDBService.shared.cachedDetailsOriginalFirst(for: lookupTitle, preferredMediaType: preferredType)
                    }
                    return (key, details)
                }
            }
            while let (key, details) = await group.next() {
                if let details { metadataByQuery[key] = details }
                processedCount = min(totalCount, processedCount + (fileCountByKey[key] ?? 1))
                publishProgressiveLibrary(raw: raw, metadataByQuery: metadataByQuery)
                if let (nextKey, nextEntry) = iterator.next() {
                    let lookupTitle = metadataLookupTitle(for: nextEntry)
                    let preferredType = preferredMediaType(for: nextEntry)
                    group.addTask {
                        let details: TMDBTitleDetails?
                        if shouldFetchMetadata {
                            details = await TMDBService.shared.detailsOriginalFirst(
                                for: lookupTitle,
                                preferredMediaType: preferredType,
                                persistImmediately: false
                            )
                        } else {
                            details = await TMDBService.shared.cachedDetailsOriginalFirst(for: lookupTitle, preferredMediaType: preferredType)
                        }
                        return (nextKey, details)
                    }
                }
            }
        }
        if shouldFetchMetadata {
            await TMDBService.shared.flushPersistentCache()
        }

        var movieItems: [UnifiedMediaEntry] = []
        var showEpisodes: [String: [(UnifiedMediaEntry, UnifiedEpisode)]] = [:]
        var unknownItems: [UnifiedMediaEntry] = []
        for var entry in raw {
            let query = metadataGroupKey(for: entry)
            entry.details = metadataByQuery[query]
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

        status = "Saving library…"
        processedCount = totalCount
        movies = deduplicatedMovies(movieItems).sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        shows = showItems.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        unknown = unknownItems.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }

        // Adult fallback runs after the usable Content screen has finished loading.
        if force && ThePornDBSettings.hasValidAPIKey && !unknownItems.isEmpty {
            Task { await self.enrichUnknownWithAdultMetadata() }
        }
        loaded = true
        lastSourceSignature = sourceSignature
        persistSnapshot()
        scanCompleted = true
        status = "Library updated"
        try? await Task.sleep(nanoseconds: 700_000_000)
        isLoading = false
        status = ""
    }

    private func publishProgressiveLibrary(
        raw: [UnifiedMediaEntry],
        metadataByQuery: [String: TMDBTitleDetails]
    ) {
        var movieItems: [UnifiedMediaEntry] = []
        var showEpisodes: [String: [(UnifiedMediaEntry, UnifiedEpisode)]] = [:]

        for var entry in raw {
            entry.details = metadataByQuery[metadataGroupKey(for: entry)]
            if let canonicalTitle = entry.details?.title, !canonicalTitle.isEmpty {
                entry.title = canonicalTitle
            }

            let looksLikeSeries = entry.details?.isSeries == true
                || (entry.details == nil && preferredMediaType(for: entry) == "tv")
            if looksLikeSeries {
                let parts = VideoTitleFormatter.episodeComponents(from: entry.rawTitle)
                let season = parts?.season ?? 1
                let episode = parts?.episode ?? 1
                let key = entry.details.map { "tmdb|\($0.id)" } ?? metadataGroupKey(for: entry)
                let item = UnifiedEpisode(
                    id: entry.id,
                    title: entry.rawTitle,
                    season: season,
                    episode: episode,
                    source: entry.source,
                    url: entry.streamURL
                )
                showEpisodes[key, default: []].append((entry, item))
            } else {
                // Movie-like filenames remain visible while their TMDB request is
                // pending. A failed lookup is moved to Unknown by the final pass.
                movieItems.append(entry)
            }
        }

        var showItems: [UnifiedMediaEntry] = []
        for values in showEpisodes.values {
            guard var first = values.first?.0 else { continue }
            first.title = first.details?.title ?? TMDBService.searchTitle(from: first.rawTitle)
            first.episodes = values.map(\.1).sorted { lhs, rhs in
                lhs.season == rhs.season ? lhs.episode < rhs.episode : lhs.season < rhs.season
            }
            showItems.append(first)
        }

        movies = deduplicatedMovies(movieItems).sorted {
            $0.title.localizedStandardCompare($1.title) == .orderedAscending
        }
        shows = showItems.sorted {
            $0.title.localizedStandardCompare($1.title) == .orderedAscending
        }
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
        let limit = min(items.count, 200)
        for index in 0..<limit {
            guard items[index].adultScene == nil else { continue }
            let query = TMDBService.searchTitle(from: items[index].rawTitle)
            if let response = try? await ThePornDBAPIService.shared.searchScenes(query: query, limit: 5),
               let scene = bestAdultMatch(response.list, query: query) {
                items[index].adultScene = scene
                items[index].title = scene.title ?? items[index].title
                unknown = items
            }
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

struct UnifiedContentView: View {
    @ObservedObject var vm: AppViewModel
    var isActive: Bool
    @StateObject private var model = UnifiedContentModel()
    @State private var section: UnifiedMediaSection = .movies
    @State private var selected: UnifiedMediaEntry?
    @State private var showPlayer = false
    @Namespace private var selectionAnimation

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 12), count: 3)

    var body: some View {
        NavigationStack {
            ZStack {
                AppTheme.bg.ignoresSafeArea()
                ScrollView {
                    VStack(spacing: 16) {
                        sectionPicker
                        if currentEntries.isEmpty {
                            emptyState
                        } else if section == .unknown {
                            LazyVStack(spacing: 10) { ForEach(currentEntries) { unknownRow($0) } }
                        } else {
                            LazyVGrid(columns: columns, spacing: 18) { ForEach(currentEntries) { posterCard($0) } }
                        }
                    }.padding(.horizontal, 14).padding(.bottom, 110)
                }.refreshable { await model.load(vm: vm, force: true) }

                if model.isLoading { scanProgressOverlay }
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
        }
    }

    private var scanProgressOverlay: some View {
        ZStack {
            Color.black.opacity(0.38).ignoresSafeArea()
            VStack(spacing: 17) {
                ZStack {
                    Circle().stroke(Color.white.opacity(0.10), lineWidth: 7)
                    Circle()
                        .trim(from: 0, to: model.totalCount == 0 ? 0.18 : model.progressFraction)
                        .stroke(AppPalette.gradient, style: StrokeStyle(lineWidth: 7, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .animation(.spring(response: 0.38, dampingFraction: 0.82), value: model.progressFraction)
                    if model.scanCompleted {
                        Image(systemName: "checkmark").font(.system(size: 26, weight: .bold)).foregroundStyle(.white)
                    } else if model.totalCount > 0 {
                        Text("\(Int(model.progressFraction * 100))%")
                            .font(.system(size: 16, weight: .bold, design: .rounded)).monospacedDigit()
                    } else {
                        ProgressView().tint(.white)
                    }
                }
                .frame(width: 82, height: 82)

                VStack(spacing: 6) {
                    Text(model.scanCompleted ? "Complete" : model.status)
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                        .multilineTextAlignment(.center)
                    if model.totalCount > 0 {
                        Text("Scanning \(model.processedCount) of \(model.totalCount)")
                            .font(.system(size: 13, weight: .semibold, design: .rounded)).monospacedDigit()
                        Text("\(model.remainingCount) files remaining")
                            .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    } else if !model.scanCompleted {
                        Text("Reading folders and files")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 28).padding(.vertical, 24)
            .frame(width: 275)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 26).stroke(Color.white.opacity(0.14)))
            .shadow(color: AppPalette.accent.opacity(0.22), radius: 28)
            .transition(.scale(scale: 0.88).combined(with: .opacity))
        }
        .zIndex(200)
        .animation(.spring(response: 0.4, dampingFraction: 0.82), value: model.scanCompleted)
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
                    if let url = entry.posterURL {
                        KFImage(url)
                            .placeholder { ProgressView().tint(AppPalette.accent) }
                            .cacheOriginalImage()
                            .fade(duration: 0.12)
                            .resizable()
                            .scaledToFill()
                    } else { Image(systemName: section == .shows ? "tv.fill" : "film.fill").font(.title).foregroundStyle(AppPalette.gradient) }
                }.aspectRatio(2/3, contentMode: .fit).clipShape(RoundedRectangle(cornerRadius: 14))
                Text(entry.title).font(.caption.weight(.semibold)).lineLimit(2).multilineTextAlignment(.leading)
                if !entry.episodes.isEmpty { Text("\(entry.episodes.count) episodes").font(.caption2).foregroundStyle(AppPalette.accent) }
            }
        }.buttonStyle(.plain)
    }

    private func unknownRow(_ entry: UnifiedMediaEntry) -> some View {
        Button { selected = entry } label: {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.07))
                    if let url = entry.posterURL {
                        KFImage(url).placeholder { ProgressView() }.cacheOriginalImage().fade(duration: 0.12).resizable().scaledToFill()
                    }
                    else { Image(systemName: "play.rectangle.fill").foregroundStyle(.secondary) }
                }.frame(width: 72, height: 72).clipShape(RoundedRectangle(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 5) {
                    Text(entry.title).font(.subheadline.weight(.semibold)).lineLimit(2)
                    Text(entry.sourceLabel).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(); Image(systemName: "chevron.right").foregroundStyle(.tertiary)
            }.padding(10).background(Color.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 15))
        }.buttonStyle(.plain)
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

@MainActor private final class UnifiedEpisodeSelection: ObservableObject {
    @Published var id: String?
    init(id: String? = nil) { self.id = id }
}

private struct UnifiedMediaDetailsHost: View {
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
                // Every episode shares the series artwork/metadata identity. The
                // selected file and S/E label change, but story/rating/cast do not.
                posterCacheKey: "unified|\(entry.id)",
                fileExtension: (episode.title as NSString).pathExtension.uppercased(),
                source: entry.sourceLabel, relatedEpisodes: relatedEpisodes
            )
        }
        return VideoDetailsItem(
            id: entry.id, title: entry.title, url: entry.streamURL,
            posterCacheKey: "unified|\(entry.id)",
            fileExtension: (entry.rawTitle as NSString).pathExtension.uppercased(),
            source: entry.sourceLabel, relatedEpisodes: relatedEpisodes
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
