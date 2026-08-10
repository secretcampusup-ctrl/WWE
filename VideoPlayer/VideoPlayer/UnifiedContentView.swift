import SwiftUI
import UIKit

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
    private let cloud = OffcloudViewModel()

    func load(vm: AppViewModel, force: Bool = false) async {
        if loaded && !force { return }
        guard !isLoading else { return }
        isLoading = true
        status = "Scanning connected libraries…"
        defer { isLoading = false }

        var raw: [UnifiedMediaEntry] = []
        for server in vm.servers {
            let files = await vm.searchPikPakVideos(server: server, query: "")
            let client = WebDAVClient(server: server)
            for file in files where file.isVideo && !file.isDirectory {
                guard let url = client.streamURL(for: file) else { continue }
                raw.append(UnifiedMediaEntry(
                    id: "webdav|\(server.id.uuidString)|\(file.path)", rawTitle: file.name,
                    title: VideoTitleFormatter.title(from: file.name), sourceLabel: server.name,
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
                        title: VideoTitleFormatter.title(from: file.name), sourceLabel: "Offcloud",
                        source: .offcloud(transfer: transfer, file: file), streamURL: url
                    ))
                }
            }
        }

        status = "Matching metadata with TMDB…"
        var movieItems: [UnifiedMediaEntry] = []
        var showEpisodes: [String: [(UnifiedMediaEntry, UnifiedEpisode)]] = [:]
        var unknownItems: [UnifiedMediaEntry] = []

        for index in raw.indices {
            var entry = raw[index]
            entry.details = await TMDBService.shared.details(for: entry.rawTitle)
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
        for (_, values) in showEpisodes {
            guard var first = values.first?.0 else { continue }
            first.title = first.details?.title ?? first.title
            first.episodes = values.map(\.1).sorted { lhs, rhs in
                lhs.season == rhs.season ? lhs.episode < rhs.episode : lhs.season < rhs.season
            }
            showItems.append(first)
        }

        if ThePornDBSettings.hasValidAPIKey && !unknownItems.isEmpty {
            status = "Finding metadata for unknown content…"
            for index in unknownItems.indices {
                let query = TMDBService.searchTitle(from: unknownItems[index].rawTitle)
                if let response = try? await ThePornDBAPIService.shared.searchScenes(query: query, limit: 8),
                   let scene = response.list.first {
                    unknownItems[index].adultScene = scene
                    unknownItems[index].title = scene.title ?? unknownItems[index].title
                }
            }
        }

        movies = deduplicatedMovies(movieItems).sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        shows = showItems.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        unknown = unknownItems.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        loaded = true
        status = ""
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
            .task(id: contentRefreshID) { if isActive { await model.load(vm: vm, force: true) } }
            .fullScreenCover(item: $selected) { entry in detailsHost(entry) }
            .fullScreenCover(isPresented: $showPlayer) { ResolvedPlayerScreen(vm: vm) }
        }
    }

    private var contentRefreshID: String {
        "\(isActive)|" + vm.servers.map { $0.id.uuidString + $0.displayAddress }.joined(separator: "|")
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
                        AsyncImage(url: url) { image in image.resizable().scaledToFill() } placeholder: { ProgressView().tint(AppPalette.accent) }
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
                    if let url = entry.posterURL { AsyncImage(url: url) { $0.resizable().scaledToFill() } placeholder: { ProgressView() } }
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
        VideoDetailsView(
            vm: vm,
            item: detailsItem(entry),
            onPlay: { play(entry.source) },
            dismissOnPlay: false,
            onSelectEpisode: { id in
                if let episode = entry.episodes.first(where: { $0.id == id }) { play(episode.source) }
            }
        ).fullScreenCover(isPresented: $showPlayer) { ResolvedPlayerScreen(vm: vm) }
    }

    private func detailsItem(_ entry: UnifiedMediaEntry) -> VideoDetailsItem {
        let related = entry.episodes.map { episode in
            VideoEpisodeItem(
                id: episode.id, title: episode.title,
                season: episode.season, episode: episode.episode
            )
        }
        return VideoDetailsItem(
            id: entry.id, title: entry.title, url: entry.streamURL,
            posterCacheKey: "unified|\(entry.id)", fileExtension: (entry.rawTitle as NSString).pathExtension.uppercased(),
            source: entry.sourceLabel, relatedEpisodes: related
        )
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
                    settingsRow("ThePornDB", "Metadata fallback for unknown content", "sparkles.rectangle.stack.fill", .adult)
                }
                Section {
                    Text("TMDB is always checked first. Unmatched files remain in Unknown and can then receive ThePornDB metadata.")
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
