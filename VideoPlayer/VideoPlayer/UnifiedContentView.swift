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

private enum UnifiedSource {
    case webDAV(server: WebDAVServer, file: WebDAVFile)
    case offcloud(transfer: OffcloudTransfer, file: OffcloudFile)
}

private struct UnifiedMediaEntry: Identifiable {
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

private struct UnifiedEpisode: Identifiable {
    let id: String
    let title: String
    let season: Int
    let episode: Int
    let source: UnifiedSource
    let url: URL
}

@MainActor
private final class UnifiedContentModel: ObservableObject {
    @Published var movies: [UnifiedMediaEntry] = []
    @Published var shows: [UnifiedMediaEntry] = []
    @Published var unknown: [UnifiedMediaEntry] = []
    @Published var isLoading = false
    @Published var status = ""
    private var loaded = false
    private var lastSourceSignature = ""
    private let cloud = OffcloudViewModel()

    func load(vm: AppViewModel, force: Bool = false) async {
        let sourceSignature = vm.servers.map {
            $0.id.uuidString + $0.displayAddress + WebDAVContentSelectionStore.revision(for: $0.id)
        }.joined(separator: "|") + "|tmdb:" + String(TMDBSettings.readAccessToken.hashValue)
        if loaded && !force && sourceSignature == lastSourceSignature { return }
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
            await cloud.refreshAll()
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

        guard !raw.isEmpty else {
            movies = []; shows = []; unknown = []; loaded = true
            lastSourceSignature = sourceSignature; status = ""
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
                group.addTask { (key, await TMDBService.shared.detailsOriginalFirst(for: lookupTitle, preferredMediaType: preferredType)) }
            }
            while let (key, details) = await group.next() {
                if let details { metadataByQuery[key] = details }
                if let (nextKey, nextEntry) = iterator.next() {
                    let lookupTitle = metadataLookupTitle(for: nextEntry)
                    let preferredType = preferredMediaType(for: nextEntry)
                    group.addTask { (nextKey, await TMDBService.shared.detailsOriginalFirst(for: lookupTitle, preferredMediaType: preferredType)) }
                }
            }
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

        movies = deduplicatedMovies(movieItems).sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        shows = showItems.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        unknown = unknownItems.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }

        // Adult fallback runs after the usable Content screen has finished loading.
        if ThePornDBSettings.hasValidAPIKey && !unknownItems.isEmpty {
            Task { await self.enrichUnknownWithAdultMetadata() }
        }
        loaded = true
        lastSourceSignature = sourceSignature
        status = ""
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
                        if model.isLoading && currentEntries.isEmpty {
                            VStack(spacing: 14) {
                                ProgressView().tint(AppPalette.accent).scaleEffect(1.15)
                                Text(model.status).font(.subheadline).foregroundStyle(.secondary)
                            }.frame(maxWidth: .infinity).padding(.top, 90)
                        } else if currentEntries.isEmpty {
                            emptyState
                        } else if section == .unknown {
                            LazyVStack(spacing: 10) { ForEach(currentEntries) { unknownRow($0) } }
                        } else {
                            LazyVGrid(columns: columns, spacing: 18) { ForEach(currentEntries) { posterCard($0) } }
                        }
                    }.padding(.horizontal, 14).padding(.bottom, 110)
                }.refreshable { await model.load(vm: vm, force: true) }
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

    private var contentRefreshID: String {
        "\(isActive)|" + vm.servers.map {
            $0.id.uuidString + $0.displayAddress + WebDAVContentSelectionStore.revision(for: $0.id)
        }.joined(separator: "|")
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
            Text("Pull to refresh after adding WebDAV or Offcloud in Home settings.")
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
        }
        showPlayer = true
    }
}

@MainActor private final class UnifiedEpisodeSelection: ObservableObject {
    @Published var id: String?
}

private struct UnifiedMediaDetailsHost: View {
    @ObservedObject var vm: AppViewModel
    let entry: UnifiedMediaEntry
    @StateObject private var selection = UnifiedEpisodeSelection()
    @State private var showPlayer = false

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
                withAnimation(.easeOut(duration: 0.16)) { selection.id = episodeID }
            }
        )
        .animation(.easeInOut(duration: 0.18), value: selection.id)
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
                posterCacheKey: "episode|\(episode.id)",
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
        }
        showPlayer = true
    }
}

struct UnifiedSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var vm: AppViewModel
    @StateObject private var cloud = OffcloudViewModel()
    @State private var offcloudKey = ""
    @State private var destination: SettingsDestination?

    private enum SettingsDestination: String, Identifiable {
        case webdav, offcloud, tmdb, adult
        var id: String { rawValue }
    }

    var body: some View {
        NavigationStack {
            List {
                Section("Cloud Sources") {
                    settingsRow("WebDAV", "Connect PikPak or another WebDAV server", "externaldrive.connected.to.line.below", .webdav)
                    settingsRow("Offcloud", "Add or update the Offcloud API key", "cloud.fill", .offcloud)
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
            .onAppear { offcloudKey = cloud.apiKey }
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
}
