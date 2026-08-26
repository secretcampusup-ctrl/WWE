import SwiftUI
import UIKit
import Kingfisher
import Combine

struct MainTabView: View {
    @StateObject private var vm = AppViewModel()
    @StateObject private var catalog = UnifiedContentModel()
    @State private var selectedTab = 0
    @State private var showPreparedOnlinePlayer = false
    @Namespace private var dockSelection

    var body: some View {
        ZStack(alignment: .bottom) {
            HomeLibraryView(vm: vm, catalog: catalog, isActive: selectedTab == 0)
                .opacity(selectedTab == 0 ? 1 : 0).allowsHitTesting(selectedTab == 0)
                .animation(.easeOut(duration: 0.18), value: selectedTab)
            UnifiedContentView(vm: vm, model: catalog, isActive: selectedTab == 1)
                .opacity(selectedTab == 1 ? 1 : 0).allowsHitTesting(selectedTab == 1)
                .animation(.easeOut(duration: 0.18), value: selectedTab)
            PirateBayView(vm: vm)
                .opacity(selectedTab == 2 ? 1 : 0).allowsHitTesting(selectedTab == 2)
                .animation(.easeOut(duration: 0.18), value: selectedTab)
            UnifiedSettingsView(vm: vm, showsDoneButton: false)
                .opacity(selectedTab == 3 ? 1 : 0).allowsHitTesting(selectedTab == 3)
                .animation(.easeOut(duration: 0.18), value: selectedTab)

            if let transfer = vm.onlinePlaybackTransfer {
                onlineTransferBanner(transfer)
                    .padding(.horizontal, 24)
                    .padding(.bottom, 55)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .zIndex(4)
            }

            HStack(spacing: 10) {
                dockSurface
                    .frame(maxWidth: .infinity)

                settingsSurface
            }
                .padding(.horizontal, 24)
                .padding(.bottom, -16)
        }
        .ignoresSafeArea(.keyboard, edges: .bottom)
        .tint(AppPalette.accent)
        .preferredColorScheme(.dark)
        .animation(.spring(response: 0.38, dampingFraction: 0.82), value: vm.onlinePlaybackTransfer)
        .fullScreenCover(isPresented: $showPreparedOnlinePlayer) {
            ResolvedPlayerScreen(vm: vm)
        }
    }

    private func onlineTransferBanner(_ transfer: OnlinePlaybackTransfer) -> some View {
        let isReady = transfer.phase == .ready
        let isFailed = transfer.phase == .failed
        return Button {
            if isReady, vm.playPreparedOnlineSource() {
                showPreparedOnlinePlayer = true
            } else if isFailed {
                vm.clearFinishedOnlineTransfer()
            }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: transferIcon(transfer.phase))
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(transferTint(transfer.phase))
                    .frame(width: 40, height: 40)
                    .background(transferTint(transfer.phase).opacity(0.14), in: RoundedRectangle(cornerRadius: 12))

                VStack(alignment: .leading, spacing: 2) {
                    Text(transferTitle(transfer.phase))
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(.white)
                    Text(isReady ? transfer.title : transfer.message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                if isReady {
                    Text("Play")
                        .font(.caption.bold())
                        .foregroundStyle(.black)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(AppPalette.gradient, in: Capsule())
                } else if isFailed {
                    Image(systemName: "xmark")
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)
                        .frame(width: 30, height: 30)
                } else {
                    Text(transfer.provider)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .padding(10)
            .background {
                ZStack {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(.ultraThinMaterial)
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(Color.black.opacity(0.28))
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(transferTint(transfer.phase).opacity(0.28), lineWidth: 0.8)
            }
            .shadow(color: .black.opacity(0.28), radius: 14, y: 6)
        }
        .buttonStyle(.plain)
    }

    private func transferIcon(_ phase: OnlinePlaybackTransfer.Phase) -> String {
        switch phase {
        case .preparing: return "hourglass"
        case .downloading: return "arrow.down.circle.fill"
        case .ready: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        }
    }

    private func transferTitle(_ phase: OnlinePlaybackTransfer.Phase) -> String {
        switch phase {
        case .preparing: return "Preparing stream"
        case .downloading: return "Downloading"
        case .ready: return "Ready to Play"
        case .failed: return "Download failed"
        }
    }

    private func transferTint(_ phase: OnlinePlaybackTransfer.Phase) -> Color {
        switch phase {
        case .preparing: return .white
        case .downloading: return AppPalette.accent
        case .ready: return .green
        case .failed: return .orange
        }
    }

    private var dockSurface: some View {
        dockContent
            .padding(4)
            .background {
                ZStack {
                    Capsule().fill(.ultraThinMaterial).opacity(0.68)
                    Capsule().fill(Color.black.opacity(0.13))
                }
            }
            .overlay {
                Capsule()
                    .stroke(
                        LinearGradient(
                            colors: [Color.white.opacity(0.34), Color.white.opacity(0.09)],
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                        lineWidth: 0.9
                    )
            }
            .shadow(color: .black.opacity(0.3), radius: 14, y: 6)
    }

    private var dockContent: some View {
        HStack(spacing: 3) {
            dockButton("Home", "house.fill", 0)
            dockButton("Content", "rectangle.stack.fill", 1)
            dockButton("Discover", "sailboat.fill", 2)
        }
    }

    private var settingsSurface: some View {
        let isSelected = selectedTab == 3
        return Button {
            selectTab(3)
        } label: {
            Image(systemName: "gearshape.fill")
                .font(.system(size: 23, weight: .medium))
                .symbolRenderingMode(.monochrome)
                .foregroundStyle(isSelected ? AppPalette.accent : Color.white.opacity(0.9))
                .scaleEffect(isSelected ? 1.08 : 1)
                .shadow(color: isSelected ? AppPalette.accent.opacity(0.44) : .clear, radius: 6)
                .frame(width: 50, height: 50)
                .background {
                    if isSelected {
                        Circle()
                            .fill(
                                LinearGradient(
                                    colors: [Color.white.opacity(0.18), AppPalette.accent.opacity(0.14)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .matchedGeometryEffect(id: "dock", in: dockSelection)
                    }
                }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .padding(4)
        .background {
            ZStack {
                Circle().fill(.ultraThinMaterial).opacity(0.68)
                Circle().fill(Color.black.opacity(0.13))
            }
        }
        .overlay {
            Circle().stroke(
                LinearGradient(
                    colors: [Color.white.opacity(0.34), Color.white.opacity(0.09)],
                    startPoint: .top,
                    endPoint: .bottom
                ),
                lineWidth: 0.9
            )
        }
        .shadow(color: .black.opacity(0.3), radius: 14, y: 6)
        .animation(.spring(response: 0.38, dampingFraction: 0.7), value: isSelected)
        .accessibilityLabel("Settings")
    }

    private func dockButton(_ title: String, _ icon: String, _ tab: Int) -> some View {
        let isSelected = selectedTab == tab
        return Button {
            selectTab(tab)
        } label: {
            Image(systemName: icon)
                .font(.system(size: 23, weight: .medium))
                .symbolRenderingMode(.monochrome)
                .foregroundStyle(isSelected ? AppPalette.accent : Color.white.opacity(0.9))
                .scaleEffect(isSelected ? 1.08 : 1)
                .shadow(color: isSelected ? AppPalette.accent.opacity(0.42) : .clear, radius: 6)
                .matchedGeometryEffect(id: "dock-icon-\(tab)", in: dockSelection)
                .frame(maxWidth: .infinity)
                .frame(height: 50)
                .background {
                    if isSelected {
                        Capsule()
                            .fill(
                                LinearGradient(
                                    colors: [Color.white.opacity(0.17), AppPalette.accent.opacity(0.13)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .matchedGeometryEffect(id: "dock", in: dockSelection)
                            .overlay(Capsule().stroke(AppPalette.accent.opacity(0.34), lineWidth: 0.7))
                    }
                }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .animation(.spring(response: 0.38, dampingFraction: 0.7), value: isSelected)
        .accessibilityLabel(title)
    }

    private func selectTab(_ tab: Int) {
        guard selectedTab != tab else { return }
        UISelectionFeedbackGenerator().selectionChanged()
        withAnimation(.spring(response: 0.38, dampingFraction: 0.72)) {
            selectedTab = tab
        }
    }
}

// MARK: - Home library dashboard

private struct HomeMediaItem: Identifiable {
    let entry: UnifiedMediaEntry
    let history: PlaybackHistoryEntry?
    var id: String { entry.id }
}

private struct HomeCategoryCardModel: Identifiable {
    let id: String
    let title: String
    let items: [UnifiedMediaEntry]
    let tint: Color
}

private struct HomeCollection: Identifiable {
    let id = UUID()
    let title: String
    let items: [UnifiedMediaEntry]
}

private struct HomeLibraryDerivedData {
    var showIDs = Set<String>()
    var unknownIDs = Set<String>()
    var featured: [UnifiedMediaEntry] = []
    var resume: [HomeMediaItem] = []
    var recentlyAdded: [UnifiedMediaEntry] = []
    var watched: [UnifiedMediaEntry] = []
    var unwatched: [UnifiedMediaEntry] = []
    var anime: [UnifiedMediaEntry] = []
    var others: [UnifiedMediaEntry] = []
    var genres: [HomeCategoryCardModel] = []
    var ratings: [HomeCategoryCardModel] = []
    var releases: [HomeCategoryCardModel] = []
    var ageRatings: [HomeCategoryCardModel] = []
}

@MainActor
private final class ExperimentalOnlineCatalogModel: ObservableObject {
    @Published private(set) var featured: [UnifiedMediaEntry] = []
    @Published private(set) var trending: [UnifiedMediaEntry] = []
    @Published private(set) var newMovies: [UnifiedMediaEntry] = []
    @Published private(set) var popularMovies: [UnifiedMediaEntry] = []
    @Published private(set) var airingTV: [UnifiedMediaEntry] = []
    @Published private(set) var newEpisodes: [UnifiedMediaEntry] = []
    @Published private(set) var topRated: [UnifiedMediaEntry] = []
    @Published private(set) var genres: [HomeCategoryCardModel] = []
    /// Search results are not part of the rotating online catalogue. Retain a
    /// small local snapshot for titles the user actually opens so their saved
    /// playback position has a Home card to attach to later.
    @Published private(set) var resumeCandidates: [UnifiedMediaEntry] = []
    @Published private(set) var isLoading = false
    @Published private(set) var error: String?

    private var didRestoreCache = false
    private let resumeCandidatesKey = "home.online.resumeCandidates.v1"

    init() {
        guard let data = UserDefaults.standard.data(forKey: resumeCandidatesKey),
              let stored = try? JSONDecoder().decode([UnifiedMediaEntry].self, from: data) else { return }
        resumeCandidates = Array(stored.prefix(30))
    }

    func rememberForResume(_ entry: UnifiedMediaEntry) {
        guard case .catalog = entry.source else { return }
        resumeCandidates.removeAll { $0.id == entry.id }
        resumeCandidates.insert(entry, at: 0)
        resumeCandidates = Array(resumeCandidates.prefix(30))
        guard let data = try? JSONEncoder().encode(resumeCandidates) else { return }
        UserDefaults.standard.set(data, forKey: resumeCandidatesKey)
    }

    func load(force: Bool = false) async {
        if !didRestoreCache {
            didRestoreCache = true
            let cached = await TMDBOnlineCatalogService.shared.cachedSnapshot()
            if !cached.isEmpty {
                apply(cached)
                await enrichFeatured(from: cached.trending)
            }
        }
        let currentSnapshot = await TMDBOnlineCatalogService.shared.cachedSnapshot()
        let shouldRefresh = force || featured.isEmpty || currentSnapshot.isStale
        guard shouldRefresh else { return }
        guard !isLoading else { return }
        isLoading = true
        error = nil
        do {
            let snapshot = try await TMDBOnlineCatalogService.shared.refresh(force: force)
            apply(snapshot)
            await enrichFeatured(from: snapshot.trending)
        } catch {
            if featured.isEmpty { self.error = "Could not refresh the online catalogue" }
        }
        isLoading = false
    }

    func search(_ query: String) async throws -> [UnifiedMediaEntry] {
        let items = try await TMDBOnlineCatalogService.shared.search(query)
        let snapshot = await TMDBOnlineCatalogService.shared.cachedSnapshot()
        return entries(items, snapshot: snapshot)
    }

    private func apply(_ snapshot: TMDBOnlineCatalogSnapshot) {
        trending = entries(snapshot.trending, snapshot: snapshot)
        // Do not publish list-card posters to the Hero. A title becomes
        // featured only after `enrichFeatured` has resolved its dedicated
        // No Language poster, so the visible artwork never swaps a moment
        // after the Home screen opens.
        newMovies = entries(snapshot.newMovies, snapshot: snapshot)
        popularMovies = entries(snapshot.popularMovies, snapshot: snapshot)
        airingTV = entries(snapshot.airingTV, snapshot: snapshot)
        newEpisodes = entries(snapshot.newEpisodes, snapshot: snapshot)
        topRated = entries(snapshot.topRated, snapshot: snapshot)

        let genrePool = trending + newMovies + popularMovies + airingTV + newEpisodes + topRated
        let uniqueGenreNames = Set(genrePool.flatMap { $0.details?.genres.map(\.name) ?? [] })
        genres = uniqueGenreNames.sorted().compactMap { name in
            let matches = genrePool.filter { $0.details?.genres.contains(where: { $0.name == name }) == true }
            guard !matches.isEmpty else { return nil }
            return HomeCategoryCardModel(
                id: "online-genre|\(name.lowercased())",
                title: name,
                items: deduplicated(matches),
                tint: tint(for: name)
            )
        }
    }

    private func entries(
        _ items: [TMDBCatalogItem],
        snapshot: TMDBOnlineCatalogSnapshot
    ) -> [UnifiedMediaEntry] {
        deduplicated(items.map { item in
            let mediaType = item.resolvedMediaType
            let genreMap = mediaType == "tv" ? snapshot.tvGenres : snapshot.movieGenres
            let genres = (item.genreIds ?? []).compactMap { id in
                genreMap[id].map { TMDBGenre(id: id, name: $0) }
            }
            let details = TMDBTitleDetails(
                id: item.id,
                mediaType: mediaType,
                imdbID: nil,
                title: item.displayTitle,
                overview: item.overview ?? "",
                posterPath: item.posterPath,
                backdropPath: item.backdropPath,
                releaseDate: item.displayDate,
                voteAverage: item.voteAverage ?? 0,
                genres: genres,
                cast: [],
                seasons: [],
                trailerKey: nil,
                runtimeMinutes: nil,
                productionCountries: nil,
                certification: nil,
                director: nil,
                logoPath: nil,
                noLanguageBackdropPath: nil,
                noLanguagePosterPath: nil,
                detailsPosterPath: item.posterPath
            )
            return UnifiedMediaEntry(
                id: "catalog|tmdb|\(mediaType)|\(item.id)",
                rawTitle: item.displayTitle,
                title: item.displayTitle,
                sourceLabel: "Orion Catalog",
                source: .catalog(mediaType: mediaType, tmdbID: item.id),
                streamURL: URL(string: "catalog://tmdb/\(mediaType)/\(item.id)")!,
                details: details,
                metadataLookupCompleted: true,
                adultLookupCompleted: true
            )
        })
    }

    private func enrichFeatured(from items: [TMDBCatalogItem]) async {
        let entriesByID = Dictionary(
            trending.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var enriched: [UnifiedMediaEntry] = []
        for item in items.prefix(10) {
            let entryID = "catalog|tmdb|\(item.resolvedMediaType)|\(item.id)"
            guard var entry = entriesByID[entryID] else { continue }
            if let details = await TMDBService.shared.detailsOriginalFirst(
                for: item.displayTitle,
                preferredMediaType: item.resolvedMediaType
            ), let noLanguagePosterPath = details.noLanguagePosterPath,
              !noLanguagePosterPath.isEmpty {
                entry.details = details
                enriched.append(entry)
                featured = enriched
            }
        }
    }

    private func deduplicated(_ entries: [UnifiedMediaEntry]) -> [UnifiedMediaEntry] {
        var seen = Set<String>()
        return entries.filter { seen.insert($0.id).inserted }
    }

    private func tint(for name: String) -> Color {
        let palette: [Color] = [.blue, .purple, .orange, .pink, .cyan, .indigo, .green, .red]
        let value = name.unicodeScalars.reduce(0) { ($0 &* 31) &+ Int($1.value) }
        return palette[Int(value.magnitude % UInt(palette.count))]
    }
}

private struct HomeSearchRadialRevealModifier: AnimatableModifier {
    var progress: CGFloat
    let topInset: CGFloat

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        content.mask {
            GeometryReader { proxy in
                let diagonal = (
                    proxy.size.width * proxy.size.width
                        + proxy.size.height * proxy.size.height
                ).squareRoot()
                let diameter = max(1, diagonal * 2.25 * progress)
                Circle()
                    .frame(width: diameter, height: diameter)
                    // The search control sits immediately left of the 40pt
                    // refresh control (16pt edge inset + 8pt spacing).
                    .position(x: proxy.size.width - 84, y: topInset + 32)
            }
        }
    }
}

private extension AnyTransition {
    static func homeSearchRadialReveal(topInset: CGFloat) -> AnyTransition {
        .modifier(
            active: HomeSearchRadialRevealModifier(progress: 0, topInset: topInset),
            identity: HomeSearchRadialRevealModifier(progress: 1, topInset: topInset)
        )
    }
}

struct HomeLibraryView: View {
    @ObservedObject var vm: AppViewModel
    @ObservedObject var catalog: UnifiedContentModel
    let isActive: Bool
    @AppStorage("online_platform_experimental_enabled_v1") private var onlinePlatformEnabled = true
    @StateObject private var onlineCatalog = ExperimentalOnlineCatalogModel()

    @State private var selectedEntry: UnifiedMediaEntry?
    @State private var selectedSavedLink: SavedVideoLink?
    @State private var showSavedPlayer = false
    @State private var selectedCollection: HomeCollection?
    @State private var showFavorites = false
    @State private var showRefreshOverlay = false
    @State private var isHomeSearchExpanded = false
    @State private var isHomeSearchContentVisible = false
    @State private var homeSearchText = ""
    @State private var homeSearchResults: [UnifiedMediaEntry] = []
    @State private var homeSearchFilter: HomeSearchFilter = .all
    @State private var isHomeSearching = false
    @State private var homeSearchMessage: String?
    @State private var homeSearchTask: Task<Void, Never>?
    @State private var homeSearchRevision = 0
    @State private var heroIndex = 0
    @State private var preparedHeroArtworkIDs: Set<String> = []
    @State private var preparedHeroTitleIDs: Set<String> = []
    @State private var pendingHeroID: String?
    @State private var heroRotationSlot = Int(Date().timeIntervalSince1970 / 7_200)
    @State private var showHeroPlayer = false
    @State private var heroPlayingEntry: UnifiedMediaEntry?
    @State private var heroMotion = HomeHeroMotionModel()
    @State private var derivedData = HomeLibraryDerivedData()
    @State private var derivedRebuildTask: Task<Void, Never>?
    @FocusState private var isHomeSearchFocused: Bool

    // Check the wall-clock slot periodically. The featured set itself only
    // changes when a new two-hour window begins.
    private let heroSlideTimer = Timer.publish(every: 7, on: .main, in: .common).autoconnect()
    private let heroRotationTimer = Timer.publish(every: 60, on: .main, in: .common).autoconnect()

    private let posterWidth: CGFloat = 112
    private let posterHeight: CGFloat = 168
    private static let sourceISO8601Formatter = ISO8601DateFormatter()

    private enum HomeSearchFilter: String, CaseIterable, Identifiable {
        case all = "All"
        case movies = "Movies"
        case shows = "TV Shows"

        var id: String { rawValue }
    }

    init(vm: AppViewModel, catalog: UnifiedContentModel, isActive: Bool) {
        self.vm = vm
        self.catalog = catalog
        self.isActive = isActive
    }

    var body: some View {
        NavigationStack {
            ZStack {
                LinearGradient(
                    colors: [AppTheme.bg, Color(red: 0.12, green: 0.095, blue: 0.08), AppTheme.bg],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .ignoresSafeArea()

                if !featuredItems.isEmpty {
                    HomeHeroZoomContainer(motion: heroMotion) {
                        heroPinnedBackground
                    }
                    // Compensate for pulling the artwork above the safe area;
                    // otherwise that offset silently consumes the lower
                    // overscan reserved for the pull-down animation.
                    .frame(
                        width: UIScreen.main.bounds.width,
                        height: 670 + homeTopSafeAreaInset,
                        alignment: .top
                    )
                    .clipped()
                    // The NavigationStack lays its content below the status-bar
                    // safe area. Pull only the pinned artwork back to the real
                    // screen top; the hero controls keep their safe positioning.
                    .offset(y: -homeTopSafeAreaInset)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .ignoresSafeArea(edges: .top)
                    .allowsHitTesting(false)
                }

                ScrollView {
                    // Keep the Hero and its UIKit scroll probe alive for the
                    // lifetime of the Home screen. A root LazyVStack recycled
                    // both after a long downward scroll; their onDisappear
                    // callbacks then cleared the prepared artwork/title state,
                    // so every Hero layer returned with opacity zero.
                    VStack(alignment: .leading, spacing: 0) {
                        HomeHeroScrollOffsetObserver(motion: heroMotion)
                            .frame(height: 0)
                        heroSection
                            // The list's upward fade belongs over the artwork,
                            // never over the title or CTA controls.
                            .zIndex(2)

                        LazyVStack(alignment: .leading, spacing: 28) {
                            resumeSection
                            favoritesSection
                            if onlinePlatformEnabled {
                                posterSection("Trending Now", items: onlineCatalog.trending)
                                posterSection("New Movies", items: onlineCatalog.newMovies)
                                posterSection("Popular Movies", items: onlineCatalog.popularMovies)
                                posterSection("TV Shows Airing Now", items: onlineCatalog.airingTV)
                                posterSection("New Episodes", items: onlineCatalog.newEpisodes)
                                posterSection("Top Rated", items: onlineCatalog.topRated)
                                categorySection("Genres", categories: onlineCatalog.genres)
                            } else {
                                posterSection("Recently Added", items: derivedData.recentlyAdded)
                                posterSection("Movies", items: catalog.movies)
                                posterSection("TV Shows", items: catalog.shows)
                                posterSection("Anime", items: derivedData.anime)
                                posterSection("Others", items: derivedData.others)
                                posterSection("Unwatched", items: derivedData.unwatched)
                                posterSection("Watched", items: derivedData.watched)
                                categorySection("By Genre", categories: derivedData.genres)
                                categorySection("By Rating", categories: derivedData.ratings)
                                categorySection("By Release Date", categories: derivedData.releases)
                                categorySection("By Age Rating", categories: derivedData.ageRatings)
                            }
                        }
                        .padding(.top, 0)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(AppTheme.bg)
                        .overlay(alignment: .top) {
                            LinearGradient(
                                stops: [
                                    .init(color: AppTheme.bg.opacity(0), location: 0),
                                    .init(color: AppTheme.bg.opacity(0.14), location: 0.24),
                                    .init(color: AppTheme.bg.opacity(0.58), location: 0.62),
                                    .init(color: AppTheme.bg, location: 1)
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                            .frame(height: 220)
                            .offset(y: -220)
                            .allowsHitTesting(false)
                        }
                    }
                    .frame(width: UIScreen.main.bounds.width, alignment: .leading)
                    .padding(.bottom, 110)
                    .tint(AppPalette.accent)
                }
                .scrollIndicators(.hidden)

                if isHomeSearchExpanded {
                    homeSearchResultsOverlay
                        .transition(.homeSearchRadialReveal(topInset: homeTopSafeAreaInset))
                        .zIndex(14)
                }

                homeHeader
                    .padding(.top, 12)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .zIndex(15)

                if showRefreshOverlay {
                    MediaOrbitRefreshView()
                        .transition(.scale(scale: 0.86).combined(with: .opacity))
                        .allowsHitTesting(false)
                        .zIndex(20)
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            .task(id: "\(homeRefreshID)|online:\(onlinePlatformEnabled)") {
                guard isActive else { return }
                updateHeroRotationIfNeeded()
                await catalog.load(vm: vm, force: false)
                if onlinePlatformEnabled { await onlineCatalog.load(force: false) }
                scheduleDerivedDataRebuild()
            }
            .onReceive(catalog.$movies) { _ in scheduleDerivedDataRebuild() }
            .onReceive(catalog.$shows) { _ in scheduleDerivedDataRebuild() }
            .onReceive(catalog.$unknown) { _ in scheduleDerivedDataRebuild() }
            .onReceive(onlineCatalog.$resumeCandidates) { _ in scheduleDerivedDataRebuild() }
            .onReceive(vm.$playbackHistory) { _ in scheduleDerivedDataRebuild() }
            .onReceive(vm.$savedLinks) { _ in scheduleDerivedDataRebuild() }
            .onChange(of: heroRotationSlot) { _ in scheduleDerivedDataRebuild() }
            .onChange(of: homeSearchText) { query in scheduleHomeSearch(query) }
            .onChange(of: isActive) { active in
                if !active {
                    if isHomeSearchExpanded {
                        closeHomeSearch()
                    } else {
                        isHomeSearchFocused = false
                    }
                }
            }
            .onReceive(heroSlideTimer) { _ in
                guard isActive, !isHomeSearchExpanded,
                      featuredItems.count > 1, pendingHeroID == nil else { return }
                requestHeroIndex((heroIndex + 1) % featuredItems.count)
            }
            .onReceive(heroRotationTimer) { date in
                guard isActive else { return }
                updateHeroRotationIfNeeded(at: date)
            }
            .onChange(of: featuredItems.map(\.id)) { items in
                if items.isEmpty || heroIndex >= items.count { heroIndex = 0 }
                if let pendingHeroID,
                   !featuredItems.contains(where: { heroAssetIdentity(for: $0) == pendingHeroID }) {
                    self.pendingHeroID = nil
                }
            }
            .fullScreenCover(item: $selectedEntry) { entry in
                UnifiedMediaDetailsHost(
                    vm: vm,
                    entry: entry,
                    section: section(for: entry),
                    categoryEntries: categoryEntries(for: entry)
                )
            }
            .fullScreenCover(item: $selectedSavedLink) { link in
                if let catalogEntry = restoredCatalogEntry(from: link) {
                    UnifiedMediaDetailsHost(
                        vm: vm,
                        entry: catalogEntry,
                        section: catalogEntry.id.contains("|tv|") ? .shows : .movies,
                        categoryEntries: [catalogEntry]
                    )
                } else if let url = link.url {
                    VideoDetailsView(
                        vm: vm,
                        item: VideoDetailsItem(
                            id: link.id.uuidString,
                            title: link.title,
                            url: url,
                            posterCacheKey: link.favoriteIdentity ?? "saved|\(link.id.uuidString)",
                            customPosterFileName: link.thumbnailFileName,
                            fileSizeBytes: link.fileSizeBytes,
                            durationSeconds: link.durationSeconds,
                            videoWidth: link.videoWidth,
                            videoHeight: link.videoHeight,
                            fileExtension: link.fileExtension,
                            source: link.hostLabel,
                            resumePositionSeconds: link.resumePositionSeconds
                        ),
                        onPlay: { playSaved(link) },
                        dismissOnPlay: false
                    )
                    .fullScreenCover(isPresented: $showSavedPlayer) {
                        ResolvedPlayerScreen(vm: vm)
                    }
                }
            }
            .fullScreenCover(item: $selectedCollection) { collection in
                HomeCollectionView(vm: vm, catalog: catalog, collection: collection)
            }
            .fullScreenCover(isPresented: $showFavorites) {
                FavoritesAllView(vm: vm)
            }
            .fullScreenCover(isPresented: $showHeroPlayer) {
                ResolvedPlayerScreen(
                    vm: vm,
                    episodeOptions: heroPlayerEpisodeOptions,
                    onSelectEpisode: switchHeroEpisode
                )
            }
            .onDisappear { homeSearchTask?.cancel() }
        }
        .preferredColorScheme(.dark)
    }

    private var homeHeader: some View {
        HStack(spacing: 8) {
            Spacer(minLength: 0)
            if !isHomeSearchExpanded {
                Button(action: openHomeSearch) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 40, height: 40)
                        .background(.ultraThinMaterial, in: Circle())
                        .overlay(Circle().stroke(Color.white.opacity(0.2), lineWidth: 0.8))
                        .shadow(color: .black.opacity(0.28), radius: 9, y: 4)
                }
                .buttonStyle(PremiumPressButtonStyle())
                .accessibilityLabel("Search")
                homeHeaderButton("arrow.clockwise") {
                    Task { await refreshLibrary() }
                }
            }
        }
        .padding(.horizontal, 16)
        .frame(width: UIScreen.main.bounds.width)
        .animation(.easeOut(duration: 0.16), value: isHomeSearchExpanded)
    }

    private var homeSearchResultsOverlay: some View {
        ZStack {
            Color(red: 0.035, green: 0.035, blue: 0.052)
            RadialGradient(
                colors: [AppPalette.accent.opacity(0.27), Color.clear],
                center: .topTrailing,
                startRadius: 4,
                endRadius: 260
            )

            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .bottom) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("DISCOVER")
                            .font(.system(size: 10, weight: .black))
                            .tracking(1.8)
                            .foregroundStyle(Color(red: 0.64, green: 0.58, blue: 1))
                        Text("Search")
                            .font(.system(size: 30, weight: .black, design: .rounded))
                            .tracking(-1.1)
                            .foregroundStyle(.white)
                    }
                    Spacer(minLength: 12)
                    Button(action: closeHomeSearch) {
                        Image(systemName: "xmark")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(.white.opacity(0.86))
                            .frame(width: 39, height: 39)
                            .background(Color.white.opacity(0.075), in: Circle())
                            .overlay(Circle().stroke(Color.white.opacity(0.1), lineWidth: 0.8))
                    }
                    .buttonStyle(PremiumPressButtonStyle())
                    .accessibilityLabel("Close Search")
                }
                .padding(.bottom, 15)
                .opacity(isHomeSearchContentVisible ? 1 : 0)
                .offset(y: isHomeSearchContentVisible ? 0 : -14)
                .animation(.easeOut(duration: 0.34).delay(0.08), value: isHomeSearchContentVisible)

                HStack(spacing: 11) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.88))

                    TextField("Movie, show or actor", text: $homeSearchText)
                        .textInputAutocapitalization(.words)
                        .autocorrectionDisabled()
                        .submitLabel(.search)
                        .focused($isHomeSearchFocused)
                        .foregroundStyle(.white)
                        .font(.system(size: 15, weight: .semibold))
                        .onSubmit { scheduleHomeSearch(homeSearchText, debounceNanoseconds: 0) }

                    if isHomeSearching {
                        ProgressView()
                            .controlSize(.small)
                            .tint(AppPalette.accent)
                    } else if !homeSearchText.isEmpty {
                        Button {
                            homeSearchText = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 17, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.48))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 15)
                .frame(height: 57)
                .background {
                    RoundedRectangle(cornerRadius: 19, style: .continuous)
                        .fill(.ultraThinMaterial)
                    RoundedRectangle(cornerRadius: 19, style: .continuous)
                        .fill(Color.white.opacity(0.035))
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 19, style: .continuous)
                        .stroke(
                            isHomeSearchFocused ? AppPalette.accent.opacity(0.62) : Color.white.opacity(0.15),
                            lineWidth: isHomeSearchFocused ? 1.1 : 0.8
                        )
                }
                .shadow(color: .black.opacity(0.34), radius: 24, y: 12)
                .scaleEffect(isHomeSearchContentVisible ? 1 : 0.86, anchor: .topTrailing)
                .opacity(isHomeSearchContentVisible ? 1 : 0)
                .animation(
                    .spring(response: 0.54, dampingFraction: 0.78).delay(0.04),
                    value: isHomeSearchContentVisible
                )

                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        ForEach(HomeSearchFilter.allCases) { filter in
                            Button {
                                UISelectionFeedbackGenerator().selectionChanged()
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    homeSearchFilter = filter
                                }
                            } label: {
                                Text(filter.rawValue)
                                    .font(.system(size: 12, weight: .bold))
                                    .foregroundStyle(homeSearchFilter == filter ? .white : .white.opacity(0.55))
                                    .padding(.horizontal, 14)
                                    .frame(height: 34)
                                    .background {
                                        if homeSearchFilter == filter {
                                            Capsule()
                                                .fill(AppPalette.gradient)
                                                .opacity(0.42)
                                        } else {
                                            Capsule().fill(Color.white.opacity(0.055))
                                        }
                                    }
                                    .overlay {
                                        Capsule().stroke(
                                            homeSearchFilter == filter
                                                ? AppPalette.accent.opacity(0.54)
                                                : Color.white.opacity(0.09),
                                            lineWidth: 0.8
                                        )
                                    }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .scrollIndicators(.hidden)
                .padding(.vertical, 13)
                .opacity(isHomeSearchContentVisible ? 1 : 0)
                .offset(y: isHomeSearchContentVisible ? 0 : 8)
                .animation(.easeOut(duration: 0.32).delay(0.16), value: isHomeSearchContentVisible)

                HStack {
                    Text(searchResultHeading)
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.white)
                    Spacer()
                    if !visibleHomeSearchResults.isEmpty {
                        Text(
                            visibleHomeSearchResults.count == 1
                                ? "1 result"
                                : "\(visibleHomeSearchResults.count) results"
                        )
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.46))
                    }
                }
                .padding(.horizontal, 4)
                .padding(.bottom, 10)
                .opacity(isHomeSearchContentVisible ? 1 : 0)
                .animation(.easeOut(duration: 0.3).delay(0.23), value: isHomeSearchContentVisible)

                Group {
                    if homeSearchText.trimmingCharacters(in: .whitespacesAndNewlines).count < 2 {
                        homeSearchEmptyState(
                            icon: "magnifyingglass.circle.fill",
                            title: "Find your next story",
                            subtitle: "Search movies, TV shows, or an actor."
                        )
                    } else if isHomeSearching && homeSearchResults.isEmpty {
                        homeSearchEmptyState(
                            icon: "magnifyingglass",
                            title: "Searching…",
                            subtitle: "Looking through movies and TV shows."
                        )
                    } else if visibleHomeSearchResults.isEmpty {
                        homeSearchEmptyState(
                            icon: "film.stack",
                            title: homeSearchMessage ?? "No results found",
                            subtitle: homeSearchMessage == nil
                                ? "Try another title or choose a different filter."
                                : "Please try again in a moment."
                        )
                    } else {
                        ScrollView {
                            LazyVStack(spacing: 10) {
                                ForEach(Array(visibleHomeSearchResults.enumerated()), id: \.element.id) { index, entry in
                                    homeSearchResultRow(entry)
                                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                                        .animation(
                                            .spring(response: 0.5, dampingFraction: 0.82)
                                                .delay(min(Double(index) * 0.055, 0.33)),
                                            value: visibleHomeSearchResults.map(\.id)
                                        )
                                }
                            }
                            .padding(.bottom, 120)
                        }
                        .scrollIndicators(.hidden)
                        .scrollDismissesKeyboard(.interactively)
                    }
                }
                .opacity(isHomeSearchContentVisible ? 1 : 0)
                .offset(y: isHomeSearchContentVisible ? 0 : 22)
                .animation(.easeOut(duration: 0.38).delay(0.28), value: isHomeSearchContentVisible)
            }
            .padding(.horizontal, 18)
            .padding(.top, homeTopSafeAreaInset + 13)
        }
        .ignoresSafeArea()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
    }

    private var visibleHomeSearchResults: [UnifiedMediaEntry] {
        switch homeSearchFilter {
        case .all:
            return homeSearchResults
        case .movies:
            return homeSearchResults.filter { section(for: $0) == .movies }
        case .shows:
            return homeSearchResults.filter { section(for: $0) == .shows }
        }
    }

    private var searchResultHeading: String {
        let query = homeSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return query.count < 2 ? "Start typing to search" : "Top matches"
    }

    private func homeSearchEmptyState(icon: String, title: String, subtitle: String) -> some View {
        VStack(spacing: 13) {
            Image(systemName: icon)
                .font(.system(size: 34, weight: .medium))
                .foregroundStyle(AppPalette.gradient)
            Text(title)
                .font(.headline)
                .foregroundStyle(.white)
            Text(subtitle)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .offset(y: -42)
    }

    private func homeSearchResultRow(_ entry: UnifiedMediaEntry) -> some View {
        Button {
            isHomeSearchFocused = false
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            onlineCatalog.rememberForResume(entry)
            selectedEntry = entry
        } label: {
            HStack(spacing: 13) {
                ZStack {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(AppTheme.cardElevated)
                    UnifiedPosterArtwork(entry: entry, section: section(for: entry))
                        .frame(width: 77, height: 103)
                        .clipped()
                }
                .frame(width: 77, height: 103)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(Color.white.opacity(0.11), lineWidth: 0.8)
                }
                .shadow(color: .black.opacity(0.28), radius: 9, y: 5)

                VStack(alignment: .leading, spacing: 5) {
                    Text(section(for: entry) == .shows ? "TV SERIES" : "MOVIE")
                        .font(.system(size: 9, weight: .black))
                        .tracking(1.1)
                        .foregroundStyle(Color(red: 0.66, green: 0.59, blue: 1))

                    Text(entry.title)
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(.white)
                        .lineLimit(1)

                    Text(searchResultMetadata(entry))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.58))
                        .lineLimit(1)

                    if let overview = entry.details?.overview, !overview.isEmpty {
                        Text(overview)
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(.white.opacity(0.42))
                            .lineLimit(2)
                            .lineSpacing(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white.opacity(0.42))
                    .frame(width: 28, height: 28)
                    .background(Color.white.opacity(0.06), in: Circle())
            }
            .padding(9)
            .frame(maxWidth: .infinity, minHeight: 121, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(.ultraThinMaterial)
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(Color.white.opacity(0.018))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .stroke(Color.white.opacity(0.085), lineWidth: 0.8)
            }
        }
        .buttonStyle(PremiumPressButtonStyle())
    }

    private func searchResultMetadata(_ entry: UnifiedMediaEntry) -> String {
        var values: [String] = []
        if let rating = ratingLabel(entry) { values.append("★ \(rating)") }
        let year = releaseYear(entry)
        if year != "—" { values.append(year) }
        if entry.details?.isSeries == true || !entry.episodes.isEmpty {
            values.append(subtitle(entry))
        } else if let runtime = entry.details?.runtimeMinutes, runtime > 0 {
            values.append("\(runtime / 60)h \(runtime % 60)m")
        }
        return values.joined(separator: "  •  ")
    }

    private func openHomeSearch() {
        UISelectionFeedbackGenerator().selectionChanged()
        withAnimation(.timingCurve(0.64, 0, 0.22, 1, duration: 0.72)) {
            isHomeSearchExpanded = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
            guard isHomeSearchExpanded else { return }
            withAnimation(.spring(response: 0.52, dampingFraction: 0.8)) {
                isHomeSearchContentVisible = true
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.42) {
            if isHomeSearchExpanded { isHomeSearchFocused = true }
        }
        scheduleHomeSearch(homeSearchText)
    }

    private func closeHomeSearch() {
        homeSearchTask?.cancel()
        homeSearchRevision &+= 1
        isHomeSearchFocused = false
        withAnimation(.easeOut(duration: 0.15)) {
            isHomeSearchContentVisible = false
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            withAnimation(.timingCurve(0.64, 0, 0.22, 1, duration: 0.58)) {
                isHomeSearchExpanded = false
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.58) {
            guard !isHomeSearchExpanded else { return }
            homeSearchText = ""
            homeSearchResults = []
            homeSearchMessage = nil
            homeSearchFilter = .all
            isHomeSearching = false
        }
    }

    private func scheduleHomeSearch(
        _ rawQuery: String,
        debounceNanoseconds: UInt64 = 320_000_000
    ) {
        homeSearchTask?.cancel()
        homeSearchRevision &+= 1
        let revision = homeSearchRevision
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isHomeSearchExpanded, query.count >= 2 else {
            homeSearchResults = []
            homeSearchMessage = nil
            isHomeSearching = false
            return
        }

        isHomeSearching = true
        homeSearchMessage = nil
        homeSearchResults = []
        homeSearchTask = Task { @MainActor in
            do {
                if debounceNanoseconds > 0 {
                    try await Task.sleep(nanoseconds: debounceNanoseconds)
                }
                try Task.checkCancellation()
                let results = try await onlineCatalog.search(query)
                try Task.checkCancellation()
                guard homeSearchRevision == revision,
                      isHomeSearchExpanded,
                      homeSearchText.trimmingCharacters(in: .whitespacesAndNewlines) == query else { return }
                withAnimation(.easeOut(duration: 0.22)) {
                    homeSearchResults = results
                    homeSearchMessage = nil
                    isHomeSearching = false
                }
            } catch is CancellationError {
                return
            } catch {
                guard homeSearchRevision == revision,
                      homeSearchText.trimmingCharacters(in: .whitespacesAndNewlines) == query else { return }
                homeSearchResults = []
                homeSearchMessage = "Search unavailable"
                isHomeSearching = false
            }
        }
    }

    private var homeTopSafeAreaInset: CGFloat {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first(where: { $0.isKeyWindow })?
            .safeAreaInsets.top ?? 0
    }

    @ViewBuilder
    private var heroSection: some View {
        if featuredItems.isEmpty {
            // Keep the final Hero geometry while the persisted catalogue is
            // restored. The old 96pt placeholder exposed the list background as
            // a black horizontal band, then pushed everything down once artwork
            // arrived.
            AppTheme.bg.frame(height: 610)
        } else {
            let pageWidth = UIScreen.main.bounds.width
            ZStack(alignment: .top) {
                // Keep neighboring information layers alive long enough to warm
                // their title logos. Unlike the artwork, foreground copy must
                // never cross-fade: two title treatments briefly stacked on top
                // of each other during a carousel step (e.g. MUTINY + REACHER).
                // The foreground therefore swaps atomically while the pinned
                // artwork below it performs the visual fade.
                ForEach(Array(featuredItems.enumerated()), id: \.element.id) { index, entry in
                    if shouldPrepareHeroArtwork(at: index) {
                        let isVisible = index == currentHeroIndex && isHeroAssetPrepared(entry)
                        heroSlide(entry, viewportWidth: pageWidth)
                            .frame(width: pageWidth, height: 610)
                            .clipped()
                            .opacity(isVisible ? 1 : 0)
                            .allowsHitTesting(isVisible)
                            .accessibilityHidden(!isVisible)
                    }
                }
                .animation(nil, value: currentHeroIndex)

                VStack {
                    Spacer()
                    HStack(spacing: 7) {
                        ForEach(heroIndicatorIndices, id: \.self) { index in
                            Button {
                                requestHeroIndex(index)
                            } label: {
                                Capsule()
                                    .fill(index == currentHeroIndex ? Color.white : Color.white.opacity(0.32))
                                    .frame(width: index == currentHeroIndex ? 22 : 6, height: 6)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Featured item \(index + 1)")
                        }
                    }
                    .animation(.easeOut(duration: 0.25), value: currentHeroIndex)
                    .padding(.bottom, 24)
                }
            }
            .frame(width: pageWidth, height: 610)
            .clipped()
            .contentShape(Rectangle())
            .simultaneousGesture(
                DragGesture(minimumDistance: 20)
                    .onEnded { value in
                        guard abs(value.translation.width) > abs(value.translation.height),
                              abs(value.translation.width) > 42,
                              featuredItems.count > 1 else { return }
                        if value.translation.width < 0 {
                            requestHeroIndex((heroIndex + 1) % featuredItems.count)
                        } else {
                            requestHeroIndex((heroIndex - 1 + featuredItems.count) % featuredItems.count)
                        }
                    }
            )
            .environment(\.layoutDirection, .leftToRight)
            .frame(height: 610)
        }
    }

    private var heroPinnedBackground: some View {
        ZStack {
            ForEach(Array(featuredItems.enumerated()), id: \.element.id) { index, entry in
                PersistentHeroArtwork(
                    entry: entry,
                    shouldPrepare: shouldPrepareHeroArtwork(at: index),
                    isCurrent: index == currentHeroIndex,
                    onPrepared: { markHeroArtworkPrepared(entry) },
                    onReleased: { markHeroArtworkReleased(entry) }
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
                .opacity(index == currentHeroIndex ? 1 : 0)
            }

            LinearGradient(
                stops: [
                    .init(color: .black.opacity(0.16), location: 0),
                    .init(color: .black.opacity(0.06), location: 0.30),
                    .init(color: .clear, location: 0.58),
                    .init(color: .clear, location: 1)
                ],
                startPoint: .leading,
                endPoint: .trailing
            )

            LinearGradient(
                stops: [
                    .init(color: .black.opacity(0.42), location: 0),
                    .init(color: .clear, location: 0.32),
                    .init(color: AppTheme.bg.opacity(0.28), location: 0.54),
                    .init(color: AppTheme.bg.opacity(0.9), location: 0.72),
                    .init(color: AppTheme.bg, location: 0.82),
                    .init(color: AppTheme.bg, location: 1)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        .frame(width: UIScreen.main.bounds.width, height: 670 + homeTopSafeAreaInset)
        .clipped()
        .animation(.easeInOut(duration: 0.48), value: currentHeroIndex)
    }

    private func heroSlide(_ entry: UnifiedMediaEntry, viewportWidth: CGFloat) -> some View {
        let contentWidth = max(240, viewportWidth - 32)
        return VStack {
            Spacer(minLength: 0)
            VStack(alignment: .leading, spacing: 12) {
                HomeHeroTitleTreatment(
                    title: entry.title,
                    logoURL: entry.details?.logoURL,
                    onPrepared: { markHeroTitlePrepared(entry) },
                    onReleased: { markHeroTitleReleased(entry) }
                )
                    .frame(width: contentWidth, alignment: .leading)

                heroMetadata(entry)
                    .frame(width: contentWidth, alignment: .leading)

                if let overview = entry.details?.overview, !overview.isEmpty {
                    Text(overview)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white.opacity(0.76))
                        .lineLimit(2)
                        .lineSpacing(2)
                        .frame(width: contentWidth, alignment: .leading)
                }

                HStack(spacing: 10) {
                    Button { playHero(entry) } label: {
                        Label("Play", systemImage: "play.fill")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(.black)
                            .frame(maxWidth: .infinity)
                            .frame(height: 46)
                            .background(Color.white, in: Capsule())
                    }
                    .buttonStyle(PremiumPressButtonStyle())

                    Button {
                        catalog.prioritizeEpisodeMetadata(for: entry)
                        selectedEntry = entry
                    } label: {
                        Label("More Info", systemImage: "info.circle")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .frame(height: 46)
                            .background(.ultraThinMaterial, in: Capsule())
                            .overlay(Capsule().stroke(Color.white.opacity(0.17)))
                    }
                    .buttonStyle(PremiumPressButtonStyle())
                }
                .frame(width: contentWidth)
            }
            .frame(width: contentWidth, alignment: .leading)
            // Keep the CTA group visually connected to the page indicators.
            // The previous 88pt lift left a large dead band between the
            // buttons and dots on current iPhone aspect ratios.
            // Lift the information/CTA group slightly above the strongest
            // lower fade while keeping a balanced gap to the page indicators.
            .padding(.bottom, 64)
        }
        .frame(width: viewportWidth, height: 610, alignment: .center)
        .clipped()
        .contentShape(Rectangle())
    }

    private func heroMetadata(_ entry: UnifiedMediaEntry) -> some View {
        let values = heroMetadataValues(entry)
        return Text(values.joined(separator: "  •  "))
        .foregroundStyle(.white.opacity(0.9))
        .font(.system(size: 11, weight: .bold))
        .lineLimit(1)
        .minimumScaleFactor(0.68)
    }

    private func heroMetadataValues(_ entry: UnifiedMediaEntry) -> [String] {
        var values: [String] = []
        if let rating = entry.details?.voteAverage, rating > 0 {
            values.append(String(format: "★ %.1f", rating))
        }
        let year = releaseYear(entry)
        if year != "—" { values.append(year) }
        if let genres = entry.details?.genres.prefix(2).map(\.name), !genres.isEmpty {
            values.append(genres.joined(separator: " · "))
        }
        if entry.details?.isSeries == true || !entry.episodes.isEmpty {
            let count = max(1, Set(entry.episodes.map(\.season)).count)
            values.append(count == 1 ? "1 Season" : "\(count) Seasons")
        } else if let runtime = entry.details?.runtimeMinutes, runtime > 0 {
            values.append("\(runtime / 60)h \(runtime % 60)m")
        }
        return values
    }

    private var homeRefreshID: String {
        "\(isActive)|" + vm.servers.map {
            $0.id.uuidString + $0.displayAddress + WebDAVContentSelectionStore.revision(for: $0.id)
        }.joined(separator: "|")
            + "|torbox:\(TorBoxLibraryStore.revision)"
            + "|offcloud:\(OffcloudKeyStore.load().isEmpty ? 0 : 1)"
    }

    private func homeHeaderButton(_ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 40, height: 40)
                .background(.ultraThinMaterial, in: Circle())
                .overlay(Circle().stroke(Color.white.opacity(0.2), lineWidth: 0.8))
                .shadow(color: .black.opacity(0.28), radius: 9, y: 4)
        }
        .buttonStyle(.plain)
    }

    @MainActor
    private func refreshLibrary() async {
        guard !showRefreshOverlay else { return }
        showRefreshOverlay = true
        let startedAt = Date()
        async let localRefresh: Void = catalog.load(vm: vm, force: true)
        if onlinePlatformEnabled {
            async let onlineRefresh: Void = onlineCatalog.load(force: true)
            _ = await (localRefresh, onlineRefresh)
        } else {
            _ = await localRefresh
        }

        // If the pull happened while another scan was ending, the model queues
        // this forced refresh. Keep the overlay up through that queued pass too.
        var idleChecks = 0
        while idleChecks < 3 {
            try? await Task.sleep(nanoseconds: 80_000_000)
            idleChecks = catalog.isLoading ? 0 : idleChecks + 1
        }

        // Avoid an abrupt flash when a cached refresh finishes immediately.
        let minimumVisibleTime: TimeInterval = 0.55
        let remaining = minimumVisibleTime - Date().timeIntervalSince(startedAt)
        if remaining > 0 {
            try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
        }
        showRefreshOverlay = false
    }

    private var resumeSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("Resume Playback", items: derivedData.resume.map(\.entry))
            if derivedData.resume.isEmpty {
                emptyRow("Nothing to resume")
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 14) {
                        ForEach(derivedData.resume) { item in resumeCard(item) }
                    }
                    .padding(.horizontal, 16)
                }
                .scrollIndicators(.hidden)
            }
        }
    }

    private func resumeCard(_ item: HomeMediaItem) -> some View {
        Button { selectedEntry = item.entry } label: {
            VStack(alignment: .leading, spacing: 7) {
                ZStack {
                    RoundedRectangle(cornerRadius: 14).fill(AppTheme.card)
                    if let url = item.entry.details?.detailsBackdropURL ?? item.entry.posterURL {
                        KFImage(url)
                            .placeholder { ProgressView().tint(AppPalette.accent) }
                            .cacheOriginalImage()
                            .resizable()
                            .scaledToFill()
                    } else {
                        UnifiedPosterArtwork(entry: item.entry, section: section(for: item.entry))
                    }
                    LinearGradient(colors: [.clear, .black.opacity(0.72)], startPoint: .center, endPoint: .bottom)
                    Image(systemName: "play.fill")
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(.black)
                        .frame(width: 42, height: 42)
                        .background(Color.white.opacity(0.92), in: Circle())
                    VStack {
                        Spacer()
                        GeometryReader { proxy in
                            ZStack(alignment: .leading) {
                                Capsule().fill(Color.white.opacity(0.25))
                                Capsule().fill(AppPalette.gradient)
                                    .frame(width: proxy.size.width * progress(for: item.history))
                            }
                        }
                        .frame(height: 4)
                        .padding(.horizontal, 9)
                        .padding(.bottom, 8)
                    }
                }
                .frame(width: 250, height: 140)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

                HStack(spacing: 6) {
                    Text(item.entry.title).lineLimit(1).truncationMode(.tail)
                    Spacer(minLength: 4)
                    Text(releaseYear(item.entry))
                }
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 250)
            }
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func posterSection(_ title: String, items: [UnifiedMediaEntry]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader(title, items: items)
            if items.isEmpty {
                emptyRow("No content")
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 14) {
                        ForEach(items.prefix(20)) { entry in posterCard(entry) }
                    }
                    .padding(.horizontal, 16)
                }
                .scrollIndicators(.hidden)
            }
        }
    }

    private func posterCard(_ entry: UnifiedMediaEntry) -> some View {
        Button { selectedEntry = entry } label: {
            VStack(alignment: .leading, spacing: 7) {
                ZStack(alignment: .bottomTrailing) {
                    RoundedRectangle(cornerRadius: 12).fill(AppTheme.card)
                    UnifiedPosterArtwork(entry: entry, section: section(for: entry))
                        .frame(width: posterWidth, height: posterHeight)
                        .clipped()
                    if let rating = ratingLabel(entry) {
                        Text(rating)
                            .font(.system(size: 9, weight: .black, design: .rounded))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6).padding(.vertical, 4)
                            .background(Color.black.opacity(0.78), in: Capsule())
                            .padding(7)
                    }
                }
                .frame(width: posterWidth, height: posterHeight)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.08)))

                Text(entry.title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(width: posterWidth, alignment: .leading)
                Text(subtitle(entry))
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.43))
                    .lineLimit(1)
                    .frame(width: posterWidth, alignment: .leading)
            }
        }
        .buttonStyle(.plain)
    }

    private var favoritesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HomeSectionHeader(title: "Favorites", hasItems: !vm.favoriteLinks.isEmpty) {
                showFavorites = true
            }
            if vm.favoriteLinks.isEmpty {
                emptyRow("No favorites")
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 14) {
                        ForEach(vm.favoriteLinks.prefix(20)) { link in
                            MoviePosterCard(link: link, width: posterWidth, height: posterHeight) {
                                if let matchedEntry = matchingEntry(for: link) { selectedEntry = matchedEntry }
                                else { selectedSavedLink = link }
                            } onDelete: {
                                vm.deleteSavedLink(link)
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                }
                .scrollIndicators(.hidden)
            }
        }
    }

    @ViewBuilder
    private func categorySection(_ title: String, categories: [HomeCategoryCardModel]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HomeSectionHeader(title: title, hasItems: !categories.isEmpty) {
                var seen = Set<String>()
                let items = categories.flatMap(\.items).filter { seen.insert($0.id).inserted }
                selectedCollection = HomeCollection(title: title, items: items)
            }
            if categories.isEmpty {
                emptyRow("Metadata will appear after the library finishes scanning")
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHGrid(
                        rows: [GridItem(.fixed(142), spacing: 12), GridItem(.fixed(142), spacing: 12)],
                        spacing: 12
                    ) {
                        ForEach(categories) { category in categoryCard(category) }
                    }
                    .padding(.horizontal, 16)
                }
                .frame(height: 296)
                .scrollIndicators(.hidden)
            }
        }
    }

    private func categoryCard(_ category: HomeCategoryCardModel) -> some View {
        Button {
            selectedCollection = HomeCollection(title: category.title, items: category.items)
        } label: {
            VStack(alignment: .leading, spacing: 9) {
                HStack(alignment: .bottom, spacing: -17) {
                    ForEach(Array(category.items.prefix(3).enumerated()), id: \.offset) { index, entry in
                        UnifiedPosterArtwork(entry: entry, section: section(for: entry))
                            .frame(width: 54, height: 79)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.16)))
                            .rotationEffect(.degrees(Double(index - 1) * 3.5))
                            .zIndex(Double(index))
                    }
                    Spacer(minLength: 0)
                }
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(category.title).font(.system(size: 13, weight: .bold)).lineLimit(1)
                        Text("\(category.items.count) items").font(.system(size: 9.5, weight: .medium)).opacity(0.5)
                    }
                    Spacer()
                    Image(systemName: "chevron.right").font(.caption.bold()).opacity(0.55)
                }
            }
            .foregroundStyle(.white)
            .padding(12)
            .frame(width: 205, height: 142, alignment: .leading)
            .background(
                LinearGradient(colors: [category.tint.opacity(0.35), AppTheme.card], startPoint: .topLeading, endPoint: .bottomTrailing),
                in: RoundedRectangle(cornerRadius: 14, style: .continuous)
            )
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.white.opacity(0.08)))
        }
        .buttonStyle(.plain)
    }

    private func sectionHeader(_ title: String, items: [UnifiedMediaEntry]) -> some View {
        HomeSectionHeader(title: title, hasItems: !items.isEmpty) {
            selectedCollection = HomeCollection(title: title, items: items)
        }
    }

    private func emptyRow(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.white.opacity(0.35))
            .padding(.horizontal, 16)
            .frame(height: 54)
    }

    private var allItems: [UnifiedMediaEntry] {
        var seen = Set<String>()
        let onlineItems = onlinePlatformEnabled
            ? onlineCatalog.trending + onlineCatalog.newMovies + onlineCatalog.popularMovies
                + onlineCatalog.airingTV + onlineCatalog.newEpisodes + onlineCatalog.topRated
                + onlineCatalog.resumeCandidates
            : []
        return (catalog.movies + catalog.shows + catalog.unknown + onlineItems)
            .filter { seen.insert($0.id).inserted }
    }

    private var featuredItems: [UnifiedMediaEntry] {
        onlinePlatformEnabled ? onlineCatalog.featured : derivedData.featured
    }

    private func buildFeaturedItems(from libraryItems: [UnifiedMediaEntry]) -> [UnifiedMediaEntry] {
        let candidates = (catalog.movies + catalog.shows).filter { entry in
            // Hero must never start from the 342px grid poster and replace it
            // after metadata arrives. Only titles with an original-size TMDB
            // poster are eligible for the carousel.
            entry.details?.heroPosterURL != nil
        }

        let candidateIDs = Set(candidates.map(\.id))
        let entriesByID = Dictionary(libraryItems.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let entriesByURL = Dictionary(libraryItems.map { ($0.streamURL.absoluteString, $0) }, uniquingKeysWith: { first, _ in first })
        var episodeOwners: [String: UnifiedMediaEntry] = [:]
        for entry in libraryItems {
            for episode in entry.episodes { episodeOwners[episode.id] = entry }
        }
        var seenFavorites = Set<String>()
        let favorites: [UnifiedMediaEntry] = vm.favoriteLinks.compactMap { link -> UnifiedMediaEntry? in
            let identity = normalizedLibraryIdentity(link.favoriteIdentity)
            let identityMatch = identity.flatMap { value in
                entriesByID[value] ?? episodeOwners[value]
            }
            let urlMatch = entriesByURL[link.resolvedStreamURL ?? link.urlString]
                ?? entriesByURL[link.urlString]
            guard let matched = identityMatch ?? urlMatch,
                  candidateIDs.contains(matched.id),
                  seenFavorites.insert(matched.id).inserted else { return nil }
            return matched
        }

        // Favorites always lead the Hero and are never capped. With fewer than
        // five favorites, fill only the remaining slots from a deterministic
        // two-hour shuffle so the carousel is stable while the user is browsing.
        let orderedFavorites: [UnifiedMediaEntry] = heroShuffled(
            favorites,
            salt: heroRotationSlot &* 31 &+ 7
        )
        guard orderedFavorites.count < 5 else { return orderedFavorites }

        let favoriteIDs = Set<String>(orderedFavorites.map { $0.id })
        let randomFill = heroShuffled(
            candidates.filter { !favoriteIDs.contains($0.id) },
            salt: heroRotationSlot
        )
        return orderedFavorites + Array(randomFill.prefix(5 - orderedFavorites.count))
    }

    private func matchingEntry(for link: SavedVideoLink) -> UnifiedMediaEntry? {
        let identity = normalizedLibraryIdentity(link.favoriteIdentity)
        if let identity {
            if let direct = allItems.first(where: { $0.id == identity }) { return direct }
            if let owner = allItems.first(where: { entry in
                entry.episodes.contains(where: { $0.id == identity })
            }) { return owner }
        }

        var candidateURLs: Set<String> = [link.urlString]
        if let resolvedStreamURL = link.resolvedStreamURL {
            candidateURLs.insert(resolvedStreamURL)
        }
        return allItems.first { candidateURLs.contains($0.streamURL.absoluteString) }
    }

    private func normalizedLibraryIdentity(_ identity: String?) -> String? {
        guard var identity = identity?.trimmingCharacters(in: .whitespacesAndNewlines),
              !identity.isEmpty else { return nil }
        for prefix in ["unified-manual|", "unified-adult|", "unified-hero|", "unified|"] {
            if identity.hasPrefix(prefix) {
                identity.removeFirst(prefix.count)
                break
            }
        }
        return identity
    }

    private func heroShuffled(
        _ entries: [UnifiedMediaEntry],
        salt: Int
    ) -> [UnifiedMediaEntry] {
        entries.sorted { lhs, rhs in
            let left = stableHeroScore(id: lhs.id, salt: salt)
            let right = stableHeroScore(id: rhs.id, salt: salt)
            if left != right { return left < right }
            return lhs.id < rhs.id
        }
    }

    private func stableHeroScore(id: String, salt: Int) -> UInt64 {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in "\(salt)|\(id)".utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return hash
    }

    @MainActor
    private func updateHeroRotationIfNeeded(at date: Date = Date()) {
        let slot = Int(date.timeIntervalSince1970 / 7_200)
        guard slot != heroRotationSlot else { return }
        heroRotationSlot = slot
        heroIndex = 0
    }

    private var currentHeroIndex: Int {
        let count = featuredItems.count
        guard count > 0 else { return 0 }
        return min(max(0, heroIndex), count - 1)
    }

    private func heroAssetIdentity(for entry: UnifiedMediaEntry) -> String {
        let poster = entry.details?.heroPosterURL?.absoluteString ?? "no-poster"
        let logo = entry.details?.logoURL?.absoluteString ?? "text-title"
        return "\(entry.id)|poster:\(poster)|logo:\(logo)"
    }

    private func isHeroAssetPrepared(_ entry: UnifiedMediaEntry) -> Bool {
        let identity = heroAssetIdentity(for: entry)
        return preparedHeroArtworkIDs.contains(identity) && preparedHeroTitleIDs.contains(identity)
    }

    private func requestHeroIndex(_ requestedIndex: Int) {
        guard featuredItems.indices.contains(requestedIndex) else { return }
        guard requestedIndex != currentHeroIndex else {
            pendingHeroID = nil
            return
        }
        let entry = featuredItems[requestedIndex]
        let identity = heroAssetIdentity(for: entry)
        guard isHeroAssetPrepared(entry) else {
            // Preserve the complete current Hero while the requested original
            // poster and title treatment are fetched/decoded.
            // `shouldPrepareHeroArtwork` includes this pending identity, so a
            // distant indicator tap is also handled.
            pendingHeroID = identity
            return
        }
        pendingHeroID = nil
        withAnimation(.easeInOut(duration: 0.48)) {
            heroIndex = requestedIndex
        }
    }

    private func markHeroArtworkPrepared(_ entry: UnifiedMediaEntry) {
        let identity = heroAssetIdentity(for: entry)
        preparedHeroArtworkIDs.insert(identity)
        finishPendingHeroTransitionIfReady(identity: identity)
    }

    private func markHeroArtworkReleased(_ entry: UnifiedMediaEntry) {
        let identity = heroAssetIdentity(for: entry)
        // A SwiftUI lifecycle callback from an off-screen/replaced view can be
        // delivered after the new current layer has already prepared. Never let
        // that stale callback hide the item that is on screen now.
        if featuredItems.indices.contains(currentHeroIndex),
           heroAssetIdentity(for: featuredItems[currentHeroIndex]) == identity { return }
        preparedHeroArtworkIDs.remove(identity)
    }

    private func markHeroTitlePrepared(_ entry: UnifiedMediaEntry) {
        let identity = heroAssetIdentity(for: entry)
        preparedHeroTitleIDs.insert(identity)
        finishPendingHeroTransitionIfReady(identity: identity)
    }

    private func markHeroTitleReleased(_ entry: UnifiedMediaEntry) {
        let identity = heroAssetIdentity(for: entry)
        if featuredItems.indices.contains(currentHeroIndex),
           heroAssetIdentity(for: featuredItems[currentHeroIndex]) == identity { return }
        preparedHeroTitleIDs.remove(identity)
    }

    private func finishPendingHeroTransitionIfReady(identity: String) {
        guard pendingHeroID == identity,
              preparedHeroArtworkIDs.contains(identity),
              preparedHeroTitleIDs.contains(identity),
              let requestedIndex = featuredItems.firstIndex(where: {
                  heroAssetIdentity(for: $0) == identity
              }) else { return }
        pendingHeroID = nil
        withAnimation(.easeInOut(duration: 0.48)) {
            heroIndex = requestedIndex
        }
    }

    private func shouldPrepareHeroArtwork(at index: Int) -> Bool {
        let count = featuredItems.count
        guard count > 0 else { return false }
        let current = currentHeroIndex
        let previous = (current - 1 + count) % count
        let next = (current + 1) % count
        let isPending = pendingHeroID.map {
            heroAssetIdentity(for: featuredItems[index]) == $0
        } ?? false
        return index == current || index == previous || index == next || isPending
    }

    private var heroIndicatorIndices: [Int] {
        let count = featuredItems.count
        guard count > 9 else { return Array(0..<count) }
        let start = min(max(0, currentHeroIndex - 4), count - 9)
        return Array(start..<(start + 9))
    }

    private var historyByID: [String: PlaybackHistoryEntry] {
        vm.playbackHistory
    }

    private func scheduleDerivedDataRebuild() {
        derivedRebuildTask?.cancel()
        derivedRebuildTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 60_000_000)
            guard !Task.isCancelled else { return }
            await rebuildDerivedData()
        }
    }

    @MainActor
    private func rebuildDerivedData() async {
        let items = allItems
        let unknownIDs = Set(catalog.unknown.map(\.id))
        let playbackHistory = vm.playbackHistory
        let historiesByPosterKey = Dictionary(
            grouping: playbackHistory.values.compactMap { history in
                history.posterCacheKey.map { ($0, history) }
            },
            by: { $0.0 }
        )

        func resolvedHistory(for entry: UnifiedMediaEntry) -> PlaybackHistoryEntry? {
            if let direct = playbackHistory[entry.id] { return direct }
            let latestEpisodeHistory = entry.episodes
                .compactMap { playbackHistory[$0.id] }
                .max(by: { $0.watchedAt < $1.watchedAt })
            if let latestEpisodeHistory { return latestEpisodeHistory }
            return historiesByPosterKey["unified|\(entry.id)"]?
                .map(\.1)
                .max(by: { $0.watchedAt < $1.watchedAt })
        }

        var resumed: [HomeMediaItem] = []
        var watched: [(UnifiedMediaEntry, Date)] = []
        var unwatched: [UnifiedMediaEntry] = []
        var anime: [UnifiedMediaEntry] = []
        var genrePairs: [(String, UnifiedMediaEntry)] = []
        var ratingPairs: [(String, UnifiedMediaEntry)] = []
        var yearPairs: [(String, UnifiedMediaEntry)] = []
        var agePairs: [(String, UnifiedMediaEntry)] = []

        for (index, entry) in items.enumerated() {
            if let history = resolvedHistory(for: entry) {
                watched.append((entry, history.watchedAt))
                // Others keeps its local playback position for reopening inside
                // the section, but it must never appear in Home Resume Playback.
                if history.hasResumePoint, !unknownIDs.contains(entry.id) {
                    resumed.append(HomeMediaItem(entry: entry, history: history))
                }
            } else {
                unwatched.append(entry)
            }
            if entry.details?.genres.contains(where: { $0.name.localizedCaseInsensitiveContains("animation") }) == true
                || entry.title.localizedCaseInsensitiveContains("anime") {
                anime.append(entry)
            }
            for genre in entry.details?.genres ?? [] { genrePairs.append((genre.name, entry)) }
            if let rating = entry.details?.voteAverage, rating > 0 {
                ratingPairs.append(("\(Int(rating.rounded(.down))) Score", entry))
            }
            if let date = entry.details?.releaseDate, date.count >= 4 {
                yearPairs.append((String(date.prefix(4)), entry))
            }
            if let age = entry.details?.certification?.trimmingCharacters(in: .whitespacesAndNewlines), !age.isEmpty {
                agePairs.append((age, entry))
            }
            if index.isMultiple(of: 48) { await Task.yield() }
        }
        guard !Task.isCancelled else { return }

        let animeIDs = Set(anime.map(\.id))
        let decadePairs = yearPairs.compactMap { year, entry -> (String, UnifiedMediaEntry)? in
            guard let value = Int(year) else { return nil }
            return ("\((value / 10) * 10)s", entry)
        }
        let years = groupedCategories(yearPairs, tint: .cyan).sorted { $0.title > $1.title }.prefix(8)
        let decades = groupedCategories(decadePairs, tint: .blue).sorted { $0.title > $1.title }

        derivedData = HomeLibraryDerivedData(
            showIDs: Set(catalog.shows.map(\.id)),
            unknownIDs: unknownIDs,
            featured: buildFeaturedItems(from: items),
            resume: Array(resumed.sorted {
                ($0.history?.watchedAt ?? .distantPast) > ($1.history?.watchedAt ?? .distantPast)
            }.prefix(12)),
            recentlyAdded: items.map { ($0, sourceDate($0)) }.sorted { $0.1 > $1.1 }.map(\.0),
            watched: watched.sorted { $0.1 > $1.1 }.map(\.0),
            unwatched: unwatched,
            anime: anime,
            others: catalog.unknown.filter { !animeIDs.contains($0.id) },
            genres: groupedCategories(genrePairs, tint: AppPalette.accent),
            ratings: groupedCategories(ratingPairs, tint: .yellow).sorted { $0.title > $1.title },
            releases: Array(years) + decades,
            ageRatings: groupedCategories(agePairs, tint: .orange)
        )
        derivedRebuildTask = nil
    }

    private func groupedCategories(
        _ pairs: [(String, UnifiedMediaEntry)],
        tint: Color
    ) -> [HomeCategoryCardModel] {
        Dictionary(grouping: pairs, by: { $0.0 })
            .map { title, values in
                HomeCategoryCardModel(
                    id: title,
                    title: title,
                    items: values.map { $0.1 },
                    tint: tint
                )
            }
            .filter { !$0.items.isEmpty }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    private func section(for entry: UnifiedMediaEntry) -> UnifiedMediaSection {
        if case let .catalog(mediaType, _) = entry.source {
            return mediaType == "tv" ? .shows : .movies
        }
        if derivedData.showIDs.contains(entry.id) { return .shows }
        if derivedData.unknownIDs.contains(entry.id) { return .unknown }
        if derivedData.showIDs.isEmpty, catalog.shows.contains(where: { $0.id == entry.id }) { return .shows }
        if derivedData.unknownIDs.isEmpty, catalog.unknown.contains(where: { $0.id == entry.id }) { return .unknown }
        return .movies
    }

    private func categoryEntries(for entry: UnifiedMediaEntry) -> [UnifiedMediaEntry] {
        if case let .catalog(mediaType, _) = entry.source {
            var seen = Set<String>()
            return (homeSearchResults + allItems).filter {
                guard case let .catalog(candidateType, _) = $0.source else { return false }
                return candidateType == mediaType && seen.insert($0.id).inserted
            }
        }
        switch section(for: entry) {
        case .movies: return catalog.movies
        case .shows: return catalog.shows
        case .unknown: return catalog.unknown
        }
    }

    private func subtitle(_ entry: UnifiedMediaEntry) -> String {
        if entry.details?.isSeries == true || !entry.episodes.isEmpty {
            let seasons = Set(entry.episodes.map(\.season)).count
            return seasons == 1 ? "1 Season" : "\(max(seasons, 1)) Seasons"
        }
        return releaseYear(entry)
    }

    private func releaseYear(_ entry: UnifiedMediaEntry) -> String {
        if let date = entry.details?.releaseDate, date.count >= 4 { return String(date.prefix(4)) }
        if let range = entry.rawTitle.range(of: #"(?<!\d)(?:19|20)\d{2}(?!\d)"#, options: .regularExpression) {
            return String(entry.rawTitle[range])
        }
        return "—"
    }

    private func ratingLabel(_ entry: UnifiedMediaEntry) -> String? {
        guard let rating = entry.details?.voteAverage, rating > 0 else { return nil }
        return String(format: "%.1f", rating)
    }

    private func sourceDate(_ entry: UnifiedMediaEntry) -> Date {
        switch entry.source {
        case let .webDAV(_, file): return file.lastModified ?? .distantPast
        case let .offcloud(transfer, _):
            guard let raw = transfer.createdOn else { return .distantPast }
            return Self.sourceISO8601Formatter.date(from: raw) ?? .distantPast
        case .torBox: return .distantPast
        case .catalog: return .distantPast
        }
    }

    private func progress(for history: PlaybackHistoryEntry?) -> CGFloat {
        guard let history, history.durationSeconds > 0 else { return 0 }
        return CGFloat(min(1, max(0, history.positionSeconds / history.durationSeconds)))
    }

    @MainActor
    private func playSaved(_ link: SavedVideoLink) {
        vm.nowPlaying = nil
        vm.nowPlayingURL = nil
        vm.nowPlayingHeaders = nil
        showSavedPlayer = true
        Task { @MainActor in
            await vm.playSavedLinkAsync(link)
            if vm.nowPlayingURL == nil { showSavedPlayer = false }
        }
    }

    @MainActor
    private func playHero(_ entry: UnifiedMediaEntry) {
        catalog.prioritizeEpisodeMetadata(for: entry)
        let episode = preferredHeroEpisode(for: entry)
        heroPlayingEntry = entry
        startHeroPlayback(entry: entry, episode: episode)
    }

    @MainActor
    private func startHeroPlayback(entry: UnifiedMediaEntry, episode: UnifiedEpisode?) {
        let source = episode?.source ?? entry.source
        let playbackTitle = episode?.title ?? entry.rawTitle

        // Hero playback bypasses VideoDetailsView, so it must attach the library
        // identity itself. Without this, player progress had no pending history
        // item and could never appear in Resume Playback.
        vm.preparePlaybackHistory(
            for: VideoDetailsItem(
                id: episode?.id ?? entry.id,
                title: episode?.title ?? entry.title,
                url: episode?.url ?? entry.streamURL,
                posterCacheKey: "unified|\(entry.id)",
                fileExtension: (playbackTitle as NSString).pathExtension.uppercased(),
                source: entry.sourceLabel
            )
        )

        switch source {
        case let .webDAV(server, file):
            Task { @MainActor in
                guard await vm.preparePlayback(file: file, server: server) else { return }
                showHeroPlayer = true
            }

        case let .offcloud(_, file):
            guard let url = file.streamURL else { return }
            if let saved = vm.saveDirectLink(
                url.absoluteString,
                resolvedStream: url,
                source: .offcloud,
                title: playbackTitle
            ) {
                vm.playSavedLink(saved)
            } else {
                _ = vm.playOnlineURL(url.absoluteString)
            }
            showHeroPlayer = true

        case let .torBox(torrent, file):
            Task { @MainActor in
                guard await vm.playTorBoxFile(torrentId: torrent.id, file: file) else { return }
                showHeroPlayer = true
            }
        case .catalog:
            // Online catalogue entries do not have a stream until Orion and an
            // enabled playback service resolve one. Open Details immediately.
            selectedEntry = entry
        }
    }

    private var heroPlayerEpisodeOptions: [PlayerEpisodeOption] {
        guard let entry = heroPlayingEntry else { return [] }
        return entry.episodes
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

    @MainActor
    private func switchHeroEpisode(_ episodeID: String) {
        guard let entry = heroPlayingEntry,
              let episode = entry.episodes.first(where: { $0.id == episodeID }) else { return }
        vm.endPlaybackPresentation()
        startHeroPlayback(entry: entry, episode: episode)
    }

    private func preferredHeroEpisode(for entry: UnifiedMediaEntry) -> UnifiedEpisode? {
        let resumable = entry.episodes.compactMap { episode -> (UnifiedEpisode, PlaybackHistoryEntry)? in
            guard let history = historyByID[episode.id], history.hasResumePoint else { return nil }
            return (episode, history)
        }
        if let recent = resumable.max(by: { $0.1.watchedAt < $1.1.watchedAt }) {
            return recent.0
        }
        return entry.episodes.sorted {
            $0.season == $1.season ? $0.episode < $1.episode : $0.season < $1.season
        }.first
    }
}

private final class HomeHeroMotionModel: ObservableObject {
    @Published var offset: CGFloat = 0
}

/// Reads the real UIScrollView offset, matching the reliable motion path used
/// by the video-details header. A SwiftUI GeometryReader preference can skip
/// frames during overscroll, which made the Hero appear static or update late.
private struct HomeHeroScrollOffsetObserver: UIViewRepresentable {
    let motion: HomeHeroMotionModel

    func makeCoordinator() -> Coordinator { Coordinator(motion: motion) }

    func makeUIView(context: Context) -> UIView {
        let probe = UIView(frame: .zero)
        probe.isUserInteractionEnabled = false
        probe.backgroundColor = .clear
        DispatchQueue.main.async { context.coordinator.attach(from: probe) }
        return probe
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        guard !context.coordinator.isAttached else { return }
        DispatchQueue.main.async { context.coordinator.attach(from: uiView) }
    }

    static func dismantleUIView(_ uiView: UIView, coordinator: Coordinator) {
        coordinator.detach()
    }

    final class Coordinator: NSObject {
        /// Hero content is 610pt high over 670pt of artwork. Retain an 8pt
        /// overscan buffer so the artwork's lower edge can never be exposed.
        private let maximumPullDistance: CGFloat = 52
        private let motion: HomeHeroMotionModel
        private weak var scrollView: UIScrollView?
        private var observation: NSKeyValueObservation?
        private var attachAttempts = 0
        var isAttached: Bool { scrollView != nil }

        init(motion: HomeHeroMotionModel) {
            self.motion = motion
        }

        func attach(from probe: UIView) {
            var ancestor = probe.superview
            while let view = ancestor, !(view is UIScrollView) {
                ancestor = view.superview
            }
            guard let found = ancestor as? UIScrollView else {
                guard attachAttempts < 8 else { return }
                attachAttempts += 1
                DispatchQueue.main.async { [weak self, weak probe] in
                    guard let self, let probe else { return }
                    self.attach(from: probe)
                }
                return
            }
            guard scrollView !== found else { return }
            attachAttempts = 0
            detach()
            scrollView = found
            publish(from: found)
            observation = found.observe(\.contentOffset, options: [.new]) { [weak self, weak found] _, _ in
                guard let self, let found else { return }
                self.publish(from: found)
            }
        }

        func detach() {
            observation?.invalidate()
            observation = nil
            scrollView = nil
        }

        private func publish(from scrollView: UIScrollView) {
            let rawValue = -(scrollView.contentOffset.y + scrollView.adjustedContentInset.top)
            // The hero only reacts to downward overscroll. Publishing every
            // normal upward-scroll pixel needlessly invalidates the large
            // background view while its scale remains exactly 1.
            let value = max(0, min(maximumPullDistance, rawValue))

            // Limit the actual elastic pull as well as the visual zoom. Merely
            // capping the scale still lets ScrollView move the foreground past
            // the 670pt artwork and reveal the poster's lower boundary.
            if rawValue > maximumPullDistance {
                let limitedY = -scrollView.adjustedContentInset.top - maximumPullDistance
                if abs(scrollView.contentOffset.y - limitedY) > 0.5 {
                    scrollView.contentOffset.y = limitedY
                }
            }
            if abs(motion.offset - value) > 0.35 {
                motion.offset = value
            }
        }
    }
}

private struct HomeHeroZoomContainer<Content: View>: View {
    @ObservedObject var motion: HomeHeroMotionModel
    let content: Content

    init(motion: HomeHeroMotionModel, @ViewBuilder content: () -> Content) {
        self.motion = motion
        self.content = content()
    }

    var body: some View {
        let pull = max(0, motion.offset)
        // Same pull-down zoom curve as the details artwork: responsive at the
        // start of the gesture and capped at 18% to keep the crop controlled.
        let scale = 1 + min(pull / 670, 0.18)
        content
            .scaleEffect(scale, anchor: .top)
            .transaction { transaction in transaction.animation = nil }
    }
}

private struct PersistentHeroArtwork: View {
    let entry: UnifiedMediaEntry
    let shouldPrepare: Bool
    let isCurrent: Bool
    let onPrepared: () -> Void
    let onReleased: () -> Void
    @State private var image: UIImage?
    @State private var didCheckStableCache = false

    // The TMDB artwork URL is the real image identity. Entry IDs include provider
    // paths/server UUIDs and may change even though the poster did not, which made
    // an already-downloaded Hero image look new after a library refresh.
    private var cacheKey: String {
        remoteURL.map { VideoThumbnailLoader.heroPosterCacheKey(for: $0) }
            ?? "unified-hero-nolang-original-v3|\(entry.id)"
    }
    private var legacyCacheKey: String {
        "unified-hero-nolang-original-v2|\(entry.id)|\(remoteURL?.absoluteString ?? "local")"
    }
    private var remoteURL: URL? {
        // heroPosterURL is always an /original TMDB URL and already applies
        // No Language -> English -> title-poster fallback ordering.
        entry.details?.heroPosterURL
    }

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                AppTheme.bg
            }

            if image == nil, didCheckStableCache, shouldPrepare, let remoteURL {
                KFImage(remoteURL)
                    .placeholder { Color.clear }
                    .cacheOriginalImage()
                    .onSuccess { result in
                        image = result.image
                        VideoThumbnailLoader.cacheHeroImageInBackground(
                            result.image,
                            forStableKey: cacheKey
                        )
                        onPrepared()
                    }
                    .resizable()
                    .scaledToFill()
            }
        }
        .task(id: "\(cacheKey)|\(shouldPrepare)") {
            if !shouldPrepare {
                // Preserve the outgoing artwork through the carousel fade, then
                // release its decoded pixels. Returning to it reuses disk cache.
                try? await Task.sleep(nanoseconds: 700_000_000)
                guard !Task.isCancelled else { return }
                image = nil
                didCheckStableCache = false
                onReleased()
                return
            }
            // A carousel step changes which off-screen item is the new "next"
            // poster. Starting its disk/network decode in the same frame as the
            // visible crossfade caused a small hitch. The incoming/current image
            // is already warm, so defer only this new neighbor until the fade is
            // complete; it still has several seconds before becoming visible.
            if !isCurrent, image == nil {
                try? await Task.sleep(nanoseconds: 620_000_000)
                guard !Task.isCancelled else { return }
            }
            didCheckStableCache = false
            image = nil
            if let primary = await VideoThumbnailLoader.cachedHeroImageAsync(forStableKey: cacheKey) {
                image = primary
                onPrepared()
            } else if let legacy = await VideoThumbnailLoader.cachedImageAsync(forStableKey: legacyCacheKey) {
                // One-time migration: reuse the already downloaded v2 image and
                // move it into the dedicated persistent Hero cache.
                image = legacy
                VideoThumbnailLoader.cacheHeroImageInBackground(legacy, forStableKey: cacheKey)
                onPrepared()
            }
            didCheckStableCache = true
        }
        .onDisappear { onReleased() }
    }
}

private struct HomeHeroTitleTreatment: View {
    let title: String
    let logoURL: URL?
    let onPrepared: () -> Void
    let onReleased: () -> Void
    @State private var logoLoaded = false

    var body: some View {
        ZStack(alignment: .leading) {
            if !logoLoaded {
                Text(title.uppercased())
                    .font(.system(size: 40, weight: .black, design: .rounded))
                    .tracking(-1.4)
                    .lineLimit(2)
                    .minimumScaleFactor(0.62)
            }

            if let logoURL {
                KFImage(logoURL)
                    .onSuccess { _ in
                        logoLoaded = true
                        onPrepared()
                    }
                    .onFailure { _ in onPrepared() }
                    .cacheOriginalImage()
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 270, maxHeight: 92, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 72, maxHeight: 92, alignment: .leading)
        .onChange(of: logoURL) { _ in logoLoaded = false }
        .task(id: logoURL?.absoluteString ?? "text-title") {
            if logoURL == nil { onPrepared() }
        }
        .onDisappear { onReleased() }
    }
}

/// Compact native SwiftUI version of the supplied media-orbit loader.
/// It is intentionally rendered as an overlay so refreshing never moves cards.
private struct MediaOrbitRefreshView: View {
    @State private var isRotating = false

    var body: some View {
        ZStack {
            Circle()
                .fill(Color.black.opacity(0.72))
                .overlay(Circle().stroke(Color.white.opacity(0.1), lineWidth: 0.8))

            Circle()
                .trim(from: 0.08, to: 0.78)
                .stroke(AppPalette.gradient, style: StrokeStyle(lineWidth: 3.5, lineCap: .round))
                .frame(width: 34, height: 34)
                .rotationEffect(.degrees(isRotating ? 360 : 0))

            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.white)
        }
        .frame(width: 58, height: 58)
        .onAppear {
            withAnimation(.linear(duration: 1.25).repeatForever(autoreverses: false)) {
                isRotating = true
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Refreshing library")
    }
}

private struct HomeSectionHeader: View {
    let title: String
    let hasItems: Bool
    let action: (() -> Void)?

    private var iconName: String {
        switch title {
        case "Resume Playback": return "play.rectangle.fill"
        case "Recently Added": return "plus.rectangle.on.rectangle"
        case "Movies": return "film.stack.fill"
        case "TV Shows": return "tv.fill"
        case "Anime": return "sparkles"
        case "Others": return "questionmark.folder.fill"
        case "Unwatched": return "eye.slash.fill"
        case "Watched": return "checkmark.circle.fill"
        case "Favorites": return "heart.fill"
        case "By Genre": return "theatermasks.fill"
        case "By Rating": return "star.fill"
        case "By Release Date": return "calendar"
        case "By Age Rating": return "lock.shield.fill"
        default: return "rectangle.stack.fill"
        }
    }

    init(title: String, hasItems: Bool, action: (() -> Void)?) {
        self.title = title
        self.hasItems = hasItems
        self.action = action
    }

    init(title: String, hasItems: Bool, action: @escaping () -> Void) {
        self.init(title: title, hasItems: hasItems, action: Optional(action))
    }

    var body: some View {
        HStack {
            HStack(spacing: 9) {
                Image(systemName: iconName)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(AppPalette.gradient)
                    .frame(width: 29, height: 29)
                    .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .stroke(Color.white.opacity(0.08), lineWidth: 0.7)
                    )

                Text(title)
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
            }
            Spacer()
            if let action, hasItems {
                Button(action: action) {
                    HStack(spacing: 3) {
                        Text("View All")
                        Image(systemName: "chevron.right")
                    }
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(AppPalette.accent)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
        .frame(width: UIScreen.main.bounds.width)
    }
}

private struct HomeCollectionView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var vm: AppViewModel
    @ObservedObject var catalog: UnifiedContentModel
    let collection: HomeCollection
    @State private var selected: UnifiedMediaEntry?
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 12, alignment: .top), count: 3)

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 18) {
                    ForEach(collection.items) { entry in
                        Button { selected = entry } label: {
                            VStack(alignment: .leading, spacing: 7) {
                                UnifiedPosterArtwork(entry: entry, section: section(for: entry))
                                    .aspectRatio(2 / 3, contentMode: .fit)
                                    .clipShape(RoundedRectangle(cornerRadius: 12))
                                Text(entry.title)
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.white)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(14)
            }
            .scrollIndicators(.hidden)
            .background(AppTheme.bg.ignoresSafeArea())
            .navigationTitle(collection.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    AppAnimatedBackButton(size: 36) { dismiss() }
                }
            }
            .fullScreenCover(item: $selected) { entry in
                UnifiedMediaDetailsHost(
                    vm: vm,
                    entry: entry,
                    section: section(for: entry),
                    categoryEntries: categoryEntries(for: entry)
                )
            }
        }
        .preferredColorScheme(.dark)
    }

    private func section(for entry: UnifiedMediaEntry) -> UnifiedMediaSection {
        if case let .catalog(mediaType, _) = entry.source {
            return mediaType == "tv" ? .shows : .movies
        }
        if catalog.shows.contains(where: { $0.id == entry.id }) { return .shows }
        if catalog.unknown.contains(where: { $0.id == entry.id }) { return .unknown }
        return .movies
    }

    private func categoryEntries(for entry: UnifiedMediaEntry) -> [UnifiedMediaEntry] {
        if case let .catalog(mediaType, _) = entry.source {
            return collection.items.filter {
                guard case let .catalog(candidateType, _) = $0.source else { return false }
                return candidateType == mediaType
            }
        }
        switch section(for: entry) {
        case .movies: return catalog.movies
        case .shows: return catalog.shows
        case .unknown: return catalog.unknown
        }
    }
}
// MARK: - Shared visual tokens

enum AppTheme {
    static let bg = Color(red: 0.04, green: 0.04, blue: 0.05)
    static let card = Color(red: 0.10, green: 0.10, blue: 0.12)
    static let cardElevated = Color(red: 0.13, green: 0.13, blue: 0.15)
    static let accent = AppPalette.accent
    static let accentDeep = Color(red: 0.0, green: 0.55, blue: 0.25)
    static let muted = Color.white.opacity(0.45)
    static let mutedDeep = Color.white.opacity(0.38)

    static let titleGradient = LinearGradient(
        colors: [
            Color(red: 0.85, green: 0.98, blue: 0.92),
            Color(red: 0.55, green: 0.95, blue: 0.75)
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    static let accentGradient = AppPalette.gradient
}

private struct PirateBayResult: Decodable, Identifiable {
    let id: String
    let name: String
    let infoHash: String
    let leechers: String
    let seeders: String
    let size: String
    let username: String
    let added: String
    let status: String
    let category: String
    enum CodingKeys: String, CodingKey {
        case id, name, leechers, seeders, size, username, added, status, category
        case infoHash = "info_hash"
    }
    init(from decoder: Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        func text(_ key: CodingKeys) -> String {
            if let value = try? box.decode(String.self, forKey: key) { return value }
            if let value = try? box.decode(Int64.self, forKey: key) { return String(value) }
            if let value = try? box.decode(Double.self, forKey: key) { return String(Int64(value)) }
            return ""
        }
        id = text(.id); name = text(.name); infoHash = text(.infoHash)
        leechers = text(.leechers); seeders = text(.seeders); size = text(.size)
        username = text(.username); added = text(.added); status = text(.status); category = text(.category)
    }
    var seedCount: Int { Int(seeders) ?? 0 }
    var leechCount: Int { Int(leechers) ?? 0 }
    var byteCount: Int64 { Int64(size) ?? 0 }
    var addedDate: Date { Date(timeIntervalSince1970: TimeInterval(added) ?? 0) }
    var magnet: String {
        var parts = URLComponents(); parts.scheme = "magnet"
        parts.queryItems = [
            URLQueryItem(name: "xt", value: "urn:btih:\(infoHash)"), URLQueryItem(name: "dn", value: name),
            URLQueryItem(name: "tr", value: "udp://tracker.opentrackr.org:1337/announce"),
            URLQueryItem(name: "tr", value: "udp://open.stealth.si:80/announce"),
            URLQueryItem(name: "tr", value: "udp://tracker.torrent.eu.org:451/announce")
        ]
        return parts.string ?? "magnet:?xt=urn:btih:\(infoHash)"
    }
}

private enum PirateBaySection: String, CaseIterable, Identifiable {
    case movies = "Movies", tv = "TV Shows", adult = "XXX"
    var id: String { rawValue }
    var icon: String { switch self { case .movies: return "film.fill"; case .tv: return "tv.fill"; case .adult: return "18.circle.fill" } }
    var tint: Color { switch self { case .movies: return .blue; case .tv: return .cyan; case .adult: return .pink } }
}

private enum PirateBaySort: String, CaseIterable, Identifiable {
    case newest = "Newest", seeders = "Seeders"
    var id: String { rawValue }
    var icon: String { self == .newest ? "clock.fill" : "arrow.up.circle.fill" }
}

private enum PirateBayQuality: String, CaseIterable, Identifiable {
    case fullHD = "1080p", ultraHD = "2160p"
    var id: String { rawValue }
    func category(for section: PirateBaySection) -> Int {
        switch (section, self) {
        case (.movies, .fullHD): return 207
        case (.movies, .ultraHD): return 211
        case (.tv, .fullHD): return 208
        case (.tv, .ultraHD): return 212
        case (.adult, .fullHD): return 505
        case (.adult, .ultraHD): return 507
        }
    }
}

@MainActor
private final class PirateBayLatestModel: ObservableObject {
    @Published var items: [PirateBayResult] = []
    @Published var isLoading = false
    @Published var loadingMessage = "Loading torrents…"
    @Published var error: String?
    private var requestID = UUID()

    func load(section: PirateBaySection, quality: PirateBayQuality, query rawQuery: String = "") async {
        let currentID = UUID(); requestID = currentID
        isLoading = true; loadingMessage = "Loading torrents…"; error = nil; items = []
        defer { if requestID == currentID { isLoading = false } }
        let category = quality.category(for: section)
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let url: URL?
        if query.isEmpty {
            var parts = URLComponents(string: "https://apibay.org/q.php")!
            parts.queryItems = [URLQueryItem(name: "q", value: "category:\(category)"), URLQueryItem(name: "_", value: String(Int(Date().timeIntervalSince1970 / 30)))]
            url = parts.url
        } else {
            var parts = URLComponents(string: "https://apibay.org/q.php")!
            parts.queryItems = [URLQueryItem(name: "q", value: query), URLQueryItem(name: "cat", value: String(category))]
            url = parts.url
        }
        guard let url else { error = "Invalid request"; return }
        do {
            var request = URLRequest(url: url); request.timeoutInterval = 25; request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
            let (data, response) = try await HighPriorityNetworkManager.shared.responsiveData(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else { throw URLError(.badServerResponse) }
            let decoded = try JSONDecoder().decode([PirateBayResult].self, from: data)
            guard requestID == currentID else { return }

            items = decoded
                .filter { $0.id != "0" && !$0.infoHash.isEmpty && $0.seedCount > 0 }
                .sorted {
                    if query.isEmpty { return $0.addedDate > $1.addedDate }
                    if $0.seedCount != $1.seedCount { return $0.seedCount > $1.seedCount }
                    return $0.addedDate > $1.addedDate
                }
            guard !items.isEmpty else {
                error = "No torrents with active seeders were found"
                return
            }
        } catch {
            guard requestID == currentID else { return }
            items = []
            self.error = error.localizedDescription.isEmpty
                ? "Could not load this category"
                : error.localizedDescription
        }
    }
}

private struct PirateBayView: View {
    @ObservedObject var vm: AppViewModel
    @StateObject private var model = PirateBayLatestModel()
    @State private var section: PirateBaySection = .movies
    @State private var quality: PirateBayQuality = .fullHD
    @State private var query = ""
    @State private var sort: PirateBaySort = .newest
    @State private var notice: String?
    @State private var addingID: String?
    @FocusState private var searchFocused: Bool
    @Namespace private var categorySelection
    @Namespace private var qualitySelection

    var body: some View {
        NavigationStack {
            ZStack {
                LinearGradient(colors: [AppTheme.bg, section.tint.opacity(0.10), AppTheme.bg], startPoint: .topLeading, endPoint: .bottomTrailing).ignoresSafeArea()
                ScrollView {
                    LazyVStack(spacing: 13) {
                        categoryBar
                        qualityBar
                        searchBar
                        statusArea
                        ForEach(sortedItems) { resultCard($0) }
                    }
                    .padding(.horizontal, 14).padding(.top, 8).padding(.bottom, 105)
                }
                .refreshable { await reload() }
            }
            .navigationTitle("Discover")
            .navigationBarTitleDisplayMode(.large)
            .toolbar { ToolbarItem(placement: .navigationBarTrailing) { Button { Task { await reload() } } label: { Image(systemName: "arrow.clockwise").foregroundStyle(AppPalette.accent) } } }
            .overlay(alignment: .top) { if let notice { Text(notice).font(.subheadline.bold()).padding(.horizontal, 18).padding(.vertical, 10).background(.ultraThinMaterial, in: Capsule()).padding(.top, 8) } }
            .task { if model.items.isEmpty { await reload() } }
        }
    }

    private var categoryBar: some View {
        HStack(spacing: 7) {
            ForEach(PirateBaySection.allCases) { value in
                Button {
                    guard section != value else { return }
                    withAnimation(.spring(response: 0.38, dampingFraction: 0.82)) { section = value }
                    query = ""; searchFocused = false; Task { await reload() }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: value.icon).font(.system(size: 13, weight: .bold))
                        Text(value.rawValue).font(.system(size: 13, weight: .bold, design: .rounded)).lineLimit(1)
                    }
                    .foregroundStyle(section == value ? .white : .white.opacity(0.55))
                    .frame(maxWidth: .infinity).padding(.vertical, 11)
                    .background {
                        if section == value {
                            Capsule().fill(LinearGradient(colors: [value.tint, value.tint.opacity(0.65)], startPoint: .topLeading, endPoint: .bottomTrailing)).matchedGeometryEffect(id: "category", in: categorySelection)
                        } else { Capsule().fill(Color.white.opacity(0.065)) }
                    }
                    .overlay(Capsule().stroke(Color.white.opacity(section == value ? 0.18 : 0.06)))
                }.buttonStyle(.plain)
            }
        }
        .padding(5).background(.ultraThinMaterial, in: Capsule())
    }

    private var qualityBar: some View {
        HStack(spacing: 8) {
            ForEach(PirateBayQuality.allCases) { value in
                Button {
                    guard quality != value else { return }
                    withAnimation(.spring(response: 0.36, dampingFraction: 0.84)) { quality = value }
                    query = ""; searchFocused = false; Task { await reload() }
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: value == .fullHD ? "rectangle.inset.filled" : "sparkles.tv.fill")
                        Text(value.rawValue).font(.system(size: 14, weight: .black, design: .rounded))
                    }
                    .foregroundStyle(quality == value ? .black : .white.opacity(0.62))
                    .frame(maxWidth: .infinity).padding(.vertical, 10)
                    .background {
                        if quality == value { Capsule().fill(Color.white).matchedGeometryEffect(id: "quality", in: qualitySelection) }
                        else { Capsule().fill(Color.white.opacity(0.06)) }
                    }
                }.buttonStyle(.plain)
            }
        }
        .padding(4).background(Color.black.opacity(0.26), in: Capsule())
    }

    private var searchBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search \(section.rawValue) · \(quality.rawValue)", text: $query)
                .textInputAutocapitalization(.never).autocorrectionDisabled().focused($searchFocused).submitLabel(.search)
                .onSubmit { searchFocused = false; Task { await reload() } }
            if !query.isEmpty { Button { query = ""; Task { await reload() } } label: { Image(systemName: "xmark.circle.fill") }.foregroundStyle(.secondary) }
            Button { searchFocused = false; Task { await reload() } } label: { Image(systemName: "arrow.right.circle.fill").font(.title2).foregroundStyle(section.tint) }
        }
        .padding(.horizontal, 14).padding(.vertical, 12).background(Color.white.opacity(0.07), in: Capsule()).overlay(Capsule().stroke(Color.white.opacity(0.07)))
    }

    private var sortedItems: [PirateBayResult] {
        sort == .newest
            ? model.items.sorted { $0.addedDate > $1.addedDate }
            : model.items.sorted { $0.seedCount == $1.seedCount ? $0.addedDate > $1.addedDate : $0.seedCount > $1.seedCount }
    }

    @ViewBuilder private var statusArea: some View {
        if model.isLoading {
            VStack(spacing: 10) {
                ProgressView().tint(section.tint)
                Text(model.loadingMessage)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 35)
        }
        else if let error = model.error { Text(error).foregroundStyle(.secondary).padding(.top, 35) }
        else {
            HStack {
                Text("\(section.rawValue.uppercased()) · \(quality.rawValue)").font(.caption.bold()).tracking(0.8).foregroundStyle(.secondary)
                Spacer()
                Menu { Picker("Sort", selection: $sort) { ForEach(PirateBaySort.allCases) { option in Label(option.rawValue, systemImage: option.icon).tag(option) } } }
                label: { Label(sort.rawValue, systemImage: sort.icon).font(.caption.bold()).foregroundStyle(.white).padding(.horizontal, 11).padding(.vertical, 7).background(Color.white.opacity(0.09), in: Capsule()) }
                Text("\(model.items.count)").font(.caption.monospacedDigit()).foregroundStyle(section.tint)
            }
                .padding(.horizontal, 3).padding(.top, 3)
        }
    }

    private func resultCard(_ item: PirateBayResult) -> some View {
        NavigationLink { PirateBayDetailsView(vm: vm, item: item, tint: section.tint) } label: {
            VStack(alignment: .leading, spacing: 11) {
                HStack(alignment: .top) { Text(item.name).font(.headline).foregroundStyle(.white).lineLimit(3); Spacer(minLength: 8); Image(systemName: "chevron.right").font(.caption.bold()).foregroundStyle(.secondary).padding(.top, 4) }
                HStack(spacing: 12) {
                    Label("\(item.seedCount)", systemImage: "arrow.up.circle.fill").foregroundStyle(.green)
                    Label("\(item.leechCount)", systemImage: "arrow.down.circle.fill").foregroundStyle(.orange)
                    Text(ByteCountFormatter.string(fromByteCount: item.byteCount, countStyle: .file)).foregroundStyle(.secondary)
                    Spacer(); Text(item.addedDate, style: .relative).foregroundStyle(.secondary)
                }.font(.caption.bold())
            }.padding(15).background(Color.white.opacity(0.065), in: RoundedRectangle(cornerRadius: 20)).overlay(RoundedRectangle(cornerRadius: 20).stroke(Color.white.opacity(0.07)))
        }.buttonStyle(.plain)
    }

    private func reload() async { await model.load(section: section, quality: quality, query: query) }
    private func toast(_ text: String) {
        notice = text
        Task { try? await Task.sleep(nanoseconds: 2_000_000_000); if notice == text { notice = nil } }
    }
}

private let pirateBayImageRequestModifier = AnyModifier { request in
    var request = request
    request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 Safari/604.1", forHTTPHeaderField: "User-Agent")
    request.setValue("https://trafficimage.club/", forHTTPHeaderField: "Referer")
    return request
}

@MainActor private final class PirateBayDetailsModel: ObservableObject {
    @Published var imageURLs: [URL] = []; @Published var isLoading = false
    func load(id: String) async {
        guard imageURLs.isEmpty, let url = URL(string: "https://apibay.org/t.php?id=\(id)") else { return }
        isLoading = true; defer { isLoading = false }
        do {
            let (data, response) = try await HighPriorityNetworkManager.shared.responsiveData(from: url)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode), let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
            let text = root.values.compactMap { $0 as? String }.joined(separator: "\n").replacingOccurrences(of: "&amp;", with: "&")
            let regex = try NSRegularExpression(pattern: #"https?://[^\s\]\[\"'<>]+"#, options: .caseInsensitive)
            let range = NSRange(text.startIndex..<text.endIndex, in: text), hosts = ["imgur", "imagebam", "imgbox", "postimg", "pixhost", "ibb.co", "imagevenue", "prnt", "trafficimage.club"]
            var seen = Set<String>()
            let candidates: [URL] = regex.matches(in: text, range: range).compactMap { match in
                guard let r = Range(match.range, in: text) else { return nil }
                let raw = String(text[r]).trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!?)")), lower = raw.lowercased()
                guard ([".jpg", ".jpeg", ".png", ".webp", ".gif"].contains { lower.contains($0) } || hosts.contains { lower.contains($0) }), seen.insert(raw).inserted else { return nil }
                return URL(string: raw)
            }
            var resolved: [URL] = []
            for candidate in candidates {
                if let direct = await resolveImage(candidate), !resolved.contains(direct) { resolved.append(direct) }
            }
            imageURLs = resolved
        } catch { imageURLs = [] }
    }

    private func resolveImage(_ url: URL) async -> URL? {
        let directExtensions = ["jpg", "jpeg", "png", "webp", "gif"]
        if directExtensions.contains(url.pathExtension.lowercased()) { return url }
        do {
            var request = URLRequest(url: url); request.timeoutInterval = 15
            request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 Safari/604.1", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await HighPriorityNetworkManager.shared.responsiveData(for: request)
            if (response.mimeType ?? "").lowercased().hasPrefix("image/") { return url }
            guard let html = String(data: data, encoding: .utf8) else { return nil }
            let patterns = [#"property=["']og:image["'][^>]+content=["']([^"']+)"#, #"content=["']([^"']+)["'][^>]+property=["']og:image"#, #"<img[^>]+src=["']([^"']+)"#]
            for pattern in patterns {
                let regex = try NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators])
                let full = NSRange(html.startIndex..<html.endIndex, in: html)
                guard let match = regex.firstMatch(in: html, range: full), match.numberOfRanges > 1, let r = Range(match.range(at: 1), in: html) else { continue }
                let raw = String(html[r]).replacingOccurrences(of: "&amp;", with: "&")
                if let found = URL(string: raw, relativeTo: url)?.absoluteURL { return found }
            }
        } catch { return nil }
        return nil
    }
}

private struct PirateBayDetailsView: View {
    @ObservedObject var vm: AppViewModel
    let item: PirateBayResult; let tint: Color
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model = PirateBayDetailsModel()
    @State private var sendingOffcloud = false
    @State private var sendingTorBox = false
    @State private var sendingPikPak = false
    @State private var resolvingSourceID: String?
    @State private var showTorrentPlayer = false
    @State private var message: String?
    @State private var selectedImage = 0
    @State private var showViewer = false
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text(item.name).font(.title2.bold()).fixedSize(horizontal: false, vertical: true)
                VStack(spacing: 10) {
                    torrentPlayButton
                    HStack(spacing: 10) {
                        actionButton("Offcloud", icon: "cloud.fill", busy: sendingOffcloud) { sendToOffcloud() }
                        actionButton("TorBox", icon: "shippingbox.fill", busy: sendingTorBox) { sendToTorBox() }
                    }
                    HStack(spacing: 10) {
                        actionButton("PikPak", icon: "bolt.horizontal.cloud.fill", busy: sendingPikPak) { sendToPikPak() }
                        actionButton("Copy Magnet", icon: "doc.on.doc.fill") { UIPasteboard.general.string = item.magnet; toast("Magnet copied") }
                    }
                }
                HStack(spacing: 14) { Label("\(item.seedCount)", systemImage: "arrow.up.circle.fill").foregroundStyle(.green); Label("\(item.leechCount)", systemImage: "arrow.down.circle.fill").foregroundStyle(.orange); Text(ByteCountFormatter.string(fromByteCount: item.byteCount, countStyle: .file)).foregroundStyle(.secondary) }.font(.caption.bold())
                if model.isLoading { ProgressView("Loading images…").frame(maxWidth: .infinity).padding(.top, 35) }
                else if !model.imageURLs.isEmpty {
                    Text("IMAGES").font(.caption.bold()).tracking(1).foregroundStyle(.secondary)
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                        ForEach(Array(model.imageURLs.enumerated()), id: \.offset) { index, url in
                            Button { selectedImage = index; showViewer = true } label: {
                                ZStack {
                                    Color.black.opacity(0.55)
                                    KFImage(url)
                                        .requestModifier(pirateBayImageRequestModifier)
                                        .placeholder { ProgressView() }
                                        .resizable().scaledToFit()
                                        .padding(7)
                                }
                                .frame(maxWidth: .infinity).frame(height: 165)
                                .clipShape(RoundedRectangle(cornerRadius: 16))
                                .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.white.opacity(0.28), lineWidth: 1.2))
                                .contentShape(RoundedRectangle(cornerRadius: 16))
                            }.buttonStyle(.plain)
                        }
                    }
                }
            }.padding(16).padding(.bottom, 90)
        }.background(AppTheme.bg.ignoresSafeArea()).navigationTitle("Details").navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                AppAnimatedBackButton(size: 36) { closeDetails() }
            }
        }
        .overlay(alignment: .top) { if let message { Text(message).font(.subheadline.bold()).padding(.horizontal, 16).padding(.vertical, 10).background(.ultraThinMaterial, in: Capsule()).padding(.top, 8) } }
        .task { await model.load(id: item.id) }
        .fullScreenCover(isPresented: $showViewer) {
            PirateBayImageViewer(urls: model.imageURLs, selection: $selectedImage)
        }
        .fullScreenCover(isPresented: $showTorrentPlayer) {
            ResolvedPlayerScreen(vm: vm)
        }
        .onChange(of: vm.onlinePlaybackTransfer) { handlePlaybackTransfer($0) }
    }
    private var torrentPlayButton: some View {
        let transfer = currentPlaybackTransfer
        let isPreparing = transfer?.phase == .preparing || transfer?.phase == .downloading
        return Button(action: playWithSelectedProvider) {
            HStack(spacing: 12) {
                Group {
                    if isPreparing {
                        ProgressView().tint(.black)
                    } else {
                        Image(systemName: "play.fill")
                    }
                }
                .frame(width: 22, height: 22)

                VStack(alignment: .leading, spacing: 2) {
                    Text(isPreparing ? "Preparing torrent…" : "Play Torrent")
                        .font(.headline)
                    Text(transfer.map { "\($0.provider) · \($0.message)" }
                         ?? "Using \(OnlinePlaybackProviderPreference.selected.title)")
                        .font(.caption)
                        .opacity(0.64)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                if !isPreparing {
                    Image(systemName: "chevron.right")
                        .font(.caption.bold())
                        .opacity(0.55)
                }
            }
            .foregroundStyle(.black)
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.white, in: RoundedRectangle(cornerRadius: 17, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(isPreparing)
        .animation(.easeInOut(duration: 0.18), value: isPreparing)
    }
    private func actionButton(_ title: String, icon: String, busy: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) { Group { if busy { ProgressView() } else { Label(title, systemImage: icon) } }.font(.subheadline.bold()).frame(maxWidth: .infinity).padding(.vertical, 13) }.buttonStyle(.plain).foregroundStyle(.white).background(tint.opacity(0.82), in: Capsule()).disabled(busy)
    }
    private func sendToOffcloud() {
        let key = OffcloudKeyStore.load(); guard !key.isEmpty else { toast("Add your Offcloud API key first"); return }; sendingOffcloud = true
        Task { do { _ = try await OffcloudClient(apiKey: key).create(url: item.magnet); toast("Sent to Offcloud") } catch { toast(error.localizedDescription) }; sendingOffcloud = false }
    }
    private func sendToTorBox() {
        let key = TorBoxKeyStore.load(); guard !key.isEmpty else { toast("Add your TorBox API key first"); return }; sendingTorBox = true
        Task {
            do {
                _ = try await TorBoxClient(apiKey: key).createTorrent(magnet: item.magnet)
                let torrents = try await TorBoxClient(apiKey: key).torrents(bypassCache: true)
                TorBoxLibraryStore.save(torrents)
                toast("Sent to TorBox")
            } catch { toast(error.localizedDescription) }
            sendingTorBox = false
        }
    }
    private func sendToPikPak() {
        guard vm.pikpakAccount != nil || PikPakClient.shared.loadAccount() != nil else {
            toast("Connect PikPak from Settings first")
            return
        }
        sendingPikPak = true
        Task { @MainActor in
            if let error = await vm.addMagnetToPikPak(item.magnet) {
                toast(error)
            } else {
                toast("Sent to PikPak")
            }
            sendingPikPak = false
        }
    }
    private var onlineSource: OnlineTorrentSource {
        OnlineTorrentSource(
            id: "discover-detail|\(item.id)",
            name: item.name,
            magnet: item.magnet,
            quality: OnlineStreamQuality.detect(hint: nil, fileName: item.name) ?? .p1080,
            seeders: item.seedCount,
            sizeBytes: item.byteCount,
            origin: .pirateBay
        )
    }
    private var currentPlaybackTransfer: OnlinePlaybackTransfer? {
        guard let resolvingSourceID,
              vm.onlinePlaybackTransfer?.id == resolvingSourceID else { return nil }
        return vm.onlinePlaybackTransfer
    }
    private func playWithSelectedProvider() {
        let source = onlineSource
        resolvingSourceID = source.id
        vm.prepareOnlineSource(source)
    }
    private func handlePlaybackTransfer(_ transfer: OnlinePlaybackTransfer?) {
        guard let resolvingSourceID,
              let transfer,
              transfer.id == resolvingSourceID else { return }
        switch transfer.phase {
        case .preparing, .downloading:
            break
        case .ready:
            if vm.playPreparedOnlineSource() {
                self.resolvingSourceID = nil
                showTorrentPlayer = true
            }
        case .failed:
            self.resolvingSourceID = nil
            toast(transfer.message)
        }
    }
    private func closeDetails() {
        dismiss()
    }
    private func toast(_ value: String) { message = value; Task { try? await Task.sleep(nanoseconds: 2_000_000_000); if message == value { message = nil } } }
}

private struct PirateBayImageViewer: View {
    let urls: [URL]; @Binding var selection: Int; @Environment(\.dismiss) private var dismiss
    var body: some View { ZStack(alignment: .topLeading) { Color.black.ignoresSafeArea(); TabView(selection: $selection) { ForEach(Array(urls.enumerated()), id: \.offset) { index, url in PirateBayZoomImage(url: url).tag(index) } }.tabViewStyle(.page(indexDisplayMode: .always)); AppAnimatedBackButton(size: 40) { dismiss() }.padding() } }
}

private struct PirateBayZoomImage: View {
    let url: URL; @State private var scale: CGFloat = 1; @State private var finalScale: CGFloat = 1
    var body: some View { KFImage(url).requestModifier(pirateBayImageRequestModifier).placeholder { ProgressView().tint(.white) }.resizable().scaledToFit().scaleEffect(scale).gesture(MagnificationGesture().onChanged { scale = max(1, min(finalScale * $0, 5)) }.onEnded { _ in finalScale = scale }).onTapGesture(count: 2) { withAnimation(.spring()) { scale = scale > 1 ? 1 : 2; finalScale = scale } }.padding(.vertical, 55) }
}
