import SwiftUI
import UIKit
import Kingfisher
import Combine

struct MainTabView: View {
    @StateObject private var vm = AppViewModel()
    @StateObject private var catalog = UnifiedContentModel()
    @State private var selectedTab = 0
    @Namespace private var dockSelection

    var body: some View {
        ZStack(alignment: .bottom) {
            HomeLibraryView(vm: vm, catalog: catalog, isActive: selectedTab == 0)
                .opacity(selectedTab == 0 ? 1 : 0).allowsHitTesting(selectedTab == 0)
            UnifiedContentView(vm: vm, model: catalog, isActive: selectedTab == 1)
                .opacity(selectedTab == 1 ? 1 : 0).allowsHitTesting(selectedTab == 1)
            PirateBayView(vm: vm)
                .opacity(selectedTab == 2 ? 1 : 0).allowsHitTesting(selectedTab == 2)

            HStack(spacing: 4) {
                dockButton("Home", "house.fill", 0)
                dockButton("Content", "rectangle.stack.fill", 1)
                dockButton("Discover", "sailboat.fill", 2)
            }
            .padding(6)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(Capsule().stroke(Color.white.opacity(0.13), lineWidth: 0.7))
            .shadow(color: .black.opacity(0.38), radius: 18, y: 8)
            .padding(.horizontal, 20)
            .padding(.bottom, 1)
        }
        .animation(.easeOut(duration: 0.18), value: selectedTab)
        .ignoresSafeArea(.keyboard, edges: .bottom)
        .tint(AppPalette.accent)
        .preferredColorScheme(.dark)
    }

    private func dockButton(_ title: String, _ icon: String, _ tab: Int) -> some View {
        Button {
            withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) { selectedTab = tab }
        } label: {
            VStack(spacing: 3) {
                Image(systemName: icon).font(.system(size: 16, weight: .semibold))
                Text(title).font(.system(size: 8.5, weight: .semibold)).lineLimit(1)
            }
            .foregroundStyle(selectedTab == tab ? Color.white : Color.white.opacity(0.48))
            .frame(maxWidth: .infinity).padding(.vertical, 7)
            .background {
                if selectedTab == tab {
                    Capsule().fill(Color.white.opacity(0.14))
                        .matchedGeometryEffect(id: "dock", in: dockSelection)
                }
            }
        }.buttonStyle(.plain)
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

struct HomeLibraryView: View {
    @ObservedObject var vm: AppViewModel
    @ObservedObject var catalog: UnifiedContentModel
    let isActive: Bool

    @State private var selectedEntry: UnifiedMediaEntry?
    @State private var selectedSavedLink: SavedVideoLink?
    @State private var showSavedPlayer = false
    @State private var selectedCollection: HomeCollection?
    @State private var showFavorites = false
    @State private var showSettings = false
    @State private var showDownloads = false
    @State private var showRefreshOverlay = false
    @State private var heroPage = 1
    @State private var showHeroPlayer = false

    private let heroTimer = Timer.publish(every: 7, on: .main, in: .common).autoconnect()

    private let posterWidth: CGFloat = 112
    private let posterHeight: CGFloat = 168

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
                    heroPinnedBackground
                        .frame(maxHeight: .infinity, alignment: .top)
                        .ignoresSafeArea(edges: .top)
                        .allowsHitTesting(false)
                }

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        heroSection

                        LazyVStack(alignment: .leading, spacing: 28) {
                            resumeSection
                            posterSection("Recently Added", items: recentlyAdded)
                            posterSection("Movies", items: catalog.movies)
                            posterSection("TV Shows", items: catalog.shows)
                            posterSection("Anime", items: animeItems)
                            posterSection("Others", items: otherItems)
                            posterSection("Unwatched", items: unwatchedItems)
                            posterSection("Watched", items: watchedItems)
                            favoritesSection
                            categorySection("By Genre", categories: genreCategories)
                            categorySection("By Rating", categories: ratingCategories)
                            categorySection("By Release Date", categories: releaseCategories)
                            categorySection("By Age Rating", categories: ageRatingCategories)
                        }
                        .padding(.top, -34)
                        .background(AppTheme.bg)
                    }
                    .padding(.bottom, 110)
                    .tint(AppPalette.accent)
                }
                .scrollIndicators(.hidden)
                // The native refresh control still supplies the familiar pull
                // gesture, while its spinner is replaced by our centered loader.
                .tint(.clear)
                .refreshable { await refreshLibrary() }

                if showRefreshOverlay {
                    MediaOrbitRefreshView()
                        .transition(.scale(scale: 0.86).combined(with: .opacity))
                        .allowsHitTesting(false)
                        .zIndex(20)
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            .task(id: homeRefreshID) {
                guard isActive else { return }
                await catalog.load(vm: vm, force: false)
            }
            .onReceive(heroTimer) { _ in
                guard isActive, featuredItems.count > 1 else { return }
                withAnimation(.easeInOut(duration: 0.55)) {
                    heroPage += 1
                }
            }
            .onChange(of: featuredItems.map(\.id)) { items in
                heroPage = items.count > 1 ? 1 : 0
            }
            .onChange(of: heroPage) { page in
                normalizeHeroPageIfNeeded(page)
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
                if let url = link.url {
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
                ResolvedPlayerScreen(vm: vm)
            }
            .sheet(isPresented: $showSettings, onDismiss: {
                Task { await catalog.load(vm: vm, force: true) }
            }) { UnifiedSettingsView(vm: vm) }
            .sheet(isPresented: $showDownloads) { DownloadManagerView() }
        }
        .preferredColorScheme(.dark)
    }

    private var homeHeader: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                Text("HOME")
                    .font(.system(size: 11, weight: .black, design: .rounded))
                    .tracking(2.2)
                    .foregroundStyle(AppPalette.accent)
                Text("My Library")
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                    .foregroundStyle(AppTheme.titleGradient)
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
            }
            .layoutPriority(1)
            Spacer()
            homeHeaderButton("arrow.clockwise") {
                Task { await refreshLibrary() }
            }
            homeHeaderButton("arrow.down.circle.fill") { showDownloads = true }
            homeHeaderButton("gearshape.fill") { showSettings = true }
        }
        .padding(.horizontal, 16)
    }

    @ViewBuilder
    private var heroSection: some View {
        if featuredItems.isEmpty {
            homeHeader
                .padding(.top, 12)
                .padding(.bottom, 22)
        } else {
            ZStack(alignment: .top) {
                TabView(selection: $heroPage) {
                    ForEach(Array(heroCarouselItems.enumerated()), id: \.offset) { index, entry in
                        heroSlide(entry)
                            .tag(index)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))

                homeHeader
                    .padding(.top, 12)

                VStack {
                    Spacer()
                    HStack(spacing: 7) {
                        ForEach(featuredItems.indices, id: \.self) { index in
                            Button {
                                withAnimation(.easeInOut(duration: 0.42)) { heroPage = index + 1 }
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
                    .padding(.bottom, 52)
                }
            }
            .environment(\.layoutDirection, .leftToRight)
            .frame(maxWidth: .infinity)
            .frame(height: 610)
        }
    }

    private var heroPinnedBackground: some View {
        ZStack {
            ForEach(Array(featuredItems.enumerated()), id: \.element.id) { index, entry in
                Group {
                    if let imageURL = entry.details?.detailsBackdropURL ?? entry.details?.imageURL ?? entry.posterURL {
                        KFImage(imageURL)
                            .cacheOriginalImage()
                            .fade(duration: 0.18)
                            .resizable()
                            .scaledToFill()
                    } else {
                        AppTheme.bg
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
                .opacity(index == currentHeroIndex ? 1 : 0)
            }

            LinearGradient(
                colors: [.black.opacity(0.78), .black.opacity(0.38), .clear],
                startPoint: .leading,
                endPoint: .trailing
            )
            LinearGradient(
                stops: [
                    .init(color: .black.opacity(0.42), location: 0),
                    .init(color: .clear, location: 0.32),
                    .init(color: AppTheme.bg.opacity(0.22), location: 0.62),
                    .init(color: AppTheme.bg.opacity(0.9), location: 0.86),
                    .init(color: AppTheme.bg, location: 1)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        .frame(height: 670)
        .animation(.easeInOut(duration: 0.5), value: currentHeroIndex)
    }

    private func heroSlide(_ entry: UnifiedMediaEntry) -> some View {
        GeometryReader { proxy in
            let contentWidth = max(260, min(470, proxy.size.width - 40))
            VStack(alignment: .leading, spacing: 12) {
                HomeHeroTitleTreatment(title: entry.title, logoURL: entry.details?.logoURL)
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
            .padding(.leading, 20)
            .padding(.bottom, 88)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        }
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
        await catalog.load(vm: vm, force: true)

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
            sectionHeader("Resume Playback", items: resumeItems.map(\.entry))
            if resumeItems.isEmpty {
                emptyRow("Nothing to resume")
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 14) {
                        ForEach(resumeItems) { item in resumeCard(item) }
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
                                if let entry = entry(matching: link) { selectedEntry = entry }
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
        return (catalog.movies + catalog.shows + catalog.unknown).filter { seen.insert($0.id).inserted }
    }

    private var featuredItems: [UnifiedMediaEntry] {
        let candidates = (catalog.movies + catalog.shows).filter { entry in
            guard entry.details != nil else { return false }
            return entry.details?.detailsBackdropURL != nil
                || entry.details?.imageURL != nil
                || entry.posterURL != nil
        }
        return Array(candidates.sorted { lhs, rhs in
            let leftDate = sourceDate(lhs)
            let rightDate = sourceDate(rhs)
            if leftDate != rightDate { return leftDate > rightDate }
            return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
        }.prefix(5))
    }

    private var heroCarouselItems: [UnifiedMediaEntry] {
        guard featuredItems.count > 1,
              let first = featuredItems.first,
              let last = featuredItems.last else { return featuredItems }
        return [last] + featuredItems + [first]
    }

    private var currentHeroIndex: Int {
        let count = featuredItems.count
        guard count > 1 else { return 0 }
        if heroPage <= 0 { return count - 1 }
        if heroPage > count { return 0 }
        return heroPage - 1
    }

    private func normalizeHeroPageIfNeeded(_ page: Int) {
        let count = featuredItems.count
        guard count > 1, page == 0 || page == count + 1 else { return }
        let target = page == 0 ? count : 1
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 450_000_000)
            guard heroPage == page else { return }
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { heroPage = target }
        }
    }

    private var historyByID: [String: PlaybackHistoryEntry] {
        Dictionary(uniqueKeysWithValues: vm.recentPlaybackHistory.map { ($0.id, $0) })
    }

    private func history(for entry: UnifiedMediaEntry) -> PlaybackHistoryEntry? {
        if let direct = historyByID[entry.id] { return direct }
        return entry.episodes.compactMap { historyByID[$0.id] }.max { $0.watchedAt < $1.watchedAt }
    }

    private var resumeItems: [HomeMediaItem] {
        allItems.compactMap { entry in
            guard let history = history(for: entry), history.hasResumePoint else { return nil }
            return HomeMediaItem(entry: entry, history: history)
        }
        .sorted { ($0.history?.watchedAt ?? .distantPast) > ($1.history?.watchedAt ?? .distantPast) }
    }

    private var recentlyAdded: [UnifiedMediaEntry] {
        allItems.sorted { sourceDate($0) > sourceDate($1) }
    }

    private var watchedItems: [UnifiedMediaEntry] {
        allItems.filter { history(for: $0) != nil }
            .sorted { (history(for: $0)?.watchedAt ?? .distantPast) > (history(for: $1)?.watchedAt ?? .distantPast) }
    }

    private var unwatchedItems: [UnifiedMediaEntry] {
        allItems.filter { history(for: $0) == nil }
    }

    private var animeItems: [UnifiedMediaEntry] {
        allItems.filter {
            $0.details?.genres.contains(where: { $0.name.localizedCaseInsensitiveContains("animation") }) == true
                || $0.title.localizedCaseInsensitiveContains("anime")
        }
    }

    private var otherItems: [UnifiedMediaEntry] {
        catalog.unknown.filter { entry in !animeItems.contains(where: { $0.id == entry.id }) }
    }

    private var genreCategories: [HomeCategoryCardModel] {
        let pairs = allItems.flatMap { entry in (entry.details?.genres ?? []).map { ($0.name, entry) } }
        return groupedCategories(pairs, tint: AppPalette.accent)
    }

    private var ratingCategories: [HomeCategoryCardModel] {
        let pairs = allItems.compactMap { entry -> (String, UnifiedMediaEntry)? in
            guard let value = entry.details?.voteAverage, value > 0 else { return nil }
            return ("\(Int(value.rounded(.down))) Score", entry)
        }
        return groupedCategories(pairs, tint: .yellow)
            .sorted { $0.title > $1.title }
    }

    private var releaseCategories: [HomeCategoryCardModel] {
        let yearPairs = allItems.compactMap { entry -> (String, UnifiedMediaEntry)? in
            guard let date = entry.details?.releaseDate, date.count >= 4 else { return nil }
            return (String(date.prefix(4)), entry)
        }
        let decadePairs = yearPairs.compactMap { year, entry -> (String, UnifiedMediaEntry)? in
            guard let value = Int(year) else { return nil }
            return ("\((value / 10) * 10)s", entry)
        }
        let years = groupedCategories(yearPairs, tint: .cyan).sorted { $0.title > $1.title }.prefix(8)
        let decades = groupedCategories(decadePairs, tint: .blue).sorted { $0.title > $1.title }
        return Array(years) + decades
    }

    private var ageRatingCategories: [HomeCategoryCardModel] {
        let pairs = allItems.compactMap { entry -> (String, UnifiedMediaEntry)? in
            guard let value = entry.details?.certification?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !value.isEmpty else { return nil }
            return (value, entry)
        }
        return groupedCategories(pairs, tint: .orange)
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

    private func entry(matching link: SavedVideoLink) -> UnifiedMediaEntry? {
        allItems.first {
            link.favoriteIdentity == $0.id
                || $0.episodes.contains(where: { $0.id == link.favoriteIdentity })
                || $0.streamURL.absoluteString == link.urlString
        }
    }

    private func section(for entry: UnifiedMediaEntry) -> UnifiedMediaSection {
        if catalog.shows.contains(where: { $0.id == entry.id }) { return .shows }
        if catalog.unknown.contains(where: { $0.id == entry.id }) { return .unknown }
        return .movies
    }

    private func categoryEntries(for entry: UnifiedMediaEntry) -> [UnifiedMediaEntry] {
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
            return ISO8601DateFormatter().date(from: raw) ?? .distantPast
        case .torBox: return .distantPast
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
        let source = episode?.source ?? entry.source
        let playbackTitle = episode?.title ?? entry.rawTitle

        switch source {
        case let .webDAV(server, file):
            vm.play(file: file, server: server)
            showHeroPlayer = true

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
        }
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

private struct HomeHeroTitleTreatment: View {
    let title: String
    let logoURL: URL?
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
                    .onSuccess { _ in logoLoaded = true }
                    .cacheOriginalImage()
                    .fade(duration: 0.18)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 270, maxHeight: 92, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 72, maxHeight: 92, alignment: .leading)
        .onChange(of: logoURL) { _ in logoLoaded = false }
    }
}

/// Compact native SwiftUI version of the supplied media-orbit loader.
/// It is intentionally rendered as an overlay so refreshing never moves cards.
private struct MediaOrbitRefreshView: View {
    private let symbols = ["film.fill", "music.note", "video.fill", "play.rectangle.fill"]
    @State private var isRotating = false
    @State private var isPulsing = false

    var body: some View {
        ZStack {
            Circle()
                .fill(Color(red: 0.075, green: 0.065, blue: 0.085).opacity(0.96))
                .overlay(Circle().stroke(Color.white.opacity(0.1), lineWidth: 0.8))
                .shadow(color: .black.opacity(0.3), radius: 12, y: 6)

            ZStack {
                Circle()
                    .stroke(
                        AppPalette.accent.opacity(0.25),
                        style: StrokeStyle(lineWidth: 1.2, dash: [3, 5])
                    )
                    .frame(width: 82, height: 82)

                ForEach(Array(symbols.enumerated()), id: \.offset) { index, symbol in
                    Image(systemName: symbol)
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(Color.white.opacity(0.88))
                        .frame(width: 25, height: 25)
                        .background(Color.white.opacity(0.075), in: Circle())
                        .overlay(Circle().stroke(AppPalette.accent.opacity(0.2), lineWidth: 0.7))
                        .offset(y: -35)
                        .rotationEffect(.degrees(Double(index) * 90))
                }
            }
            .drawingGroup(opaque: false)
            .rotationEffect(.degrees(isRotating ? 360 : 0))

            Circle()
                .stroke(AppPalette.blue.opacity(0.16), lineWidth: 1)
                .frame(width: 57, height: 57)
                .scaleEffect(isPulsing ? 1.08 : 0.94)

            Circle()
                .fill(AppPalette.diagonalGradient)
                .frame(width: 29, height: 29)
                .shadow(color: AppPalette.accent.opacity(0.4), radius: 8)
                .scaleEffect(isPulsing ? 1.06 : 0.94)

            Image(systemName: "bolt.fill")
                .font(.system(size: 12, weight: .black))
                .foregroundStyle(.white)
        }
        .frame(width: 108, height: 108)
        .onAppear {
            withAnimation(.linear(duration: 4.8).repeatForever(autoreverses: false)) {
                isRotating = true
            }
            withAnimation(.easeInOut(duration: 1.15).repeatForever(autoreverses: true)) {
                isPulsing = true
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
            Text(title)
                .font(.system(size: 20, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
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
                ToolbarItem(placement: .topBarLeading) { Button("Close") { dismiss() } }
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
        if catalog.shows.contains(where: { $0.id == entry.id }) { return .shows }
        if catalog.unknown.contains(where: { $0.id == entry.id }) { return .unknown }
        return .movies
    }

    private func categoryEntries(for entry: UnifiedMediaEntry) -> [UnifiedMediaEntry] {
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
    @Published var error: String?
    private var requestID = UUID()

    func load(section: PirateBaySection, quality: PirateBayQuality, query rawQuery: String = "") async {
        let currentID = UUID(); requestID = currentID
        isLoading = true; error = nil
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
            items = decoded.filter { $0.id != "0" && !$0.infoHash.isEmpty }.sorted { $0.addedDate > $1.addedDate }
            if items.isEmpty { error = "No results found" }
        } catch {
            guard requestID == currentID else { return }
            items = []; self.error = "Could not load this category"
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
        if model.isLoading { ProgressView().tint(section.tint).padding(.top, 35) }
        else if let error = model.error { Text(error).foregroundStyle(.secondary).padding(.top, 35) }
        else {
            HStack {
                Text("LATEST \(section.rawValue.uppercased()) · \(quality.rawValue)").font(.caption.bold()).tracking(0.8).foregroundStyle(.secondary)
                Spacer()
                Menu { Picker("Sort", selection: $sort) { ForEach(PirateBaySort.allCases) { option in Label(option.rawValue, systemImage: option.icon).tag(option) } } }
                label: { Label(sort.rawValue, systemImage: sort.icon).font(.caption.bold()).foregroundStyle(.white).padding(.horizontal, 11).padding(.vertical, 7).background(Color.white.opacity(0.09), in: Capsule()) }
                Text("\(model.items.count)").font(.caption.monospacedDigit()).foregroundStyle(section.tint)
            }
                .padding(.horizontal, 3).padding(.top, 3)
        }
    }

    private func resultCard(_ item: PirateBayResult) -> some View {
        NavigationLink { PirateBayDetailsView(item: item, tint: section.tint) } label: {
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
    let item: PirateBayResult; let tint: Color
    @StateObject private var model = PirateBayDetailsModel()
    @State private var sendingOffcloud = false; @State private var sendingTorBox = false; @State private var message: String?; @State private var selectedImage = 0; @State private var showViewer = false
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text(item.name).font(.title2.bold()).fixedSize(horizontal: false, vertical: true)
                VStack(spacing: 10) {
                    HStack(spacing: 10) {
                        actionButton("Offcloud", icon: "cloud.fill", busy: sendingOffcloud) { sendToOffcloud() }
                        actionButton("TorBox", icon: "shippingbox.fill", busy: sendingTorBox) { sendToTorBox() }
                    }
                    actionButton("Copy Magnet", icon: "doc.on.doc.fill") { UIPasteboard.general.string = item.magnet; toast("Magnet copied") }
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
        .overlay(alignment: .top) { if let message { Text(message).font(.subheadline.bold()).padding(.horizontal, 16).padding(.vertical, 10).background(.ultraThinMaterial, in: Capsule()).padding(.top, 8) } }
        .task { await model.load(id: item.id) }.fullScreenCover(isPresented: $showViewer) { PirateBayImageViewer(urls: model.imageURLs, selection: $selectedImage) }
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
    private func toast(_ value: String) { message = value; Task { try? await Task.sleep(nanoseconds: 2_000_000_000); if message == value { message = nil } } }
}

private struct PirateBayImageViewer: View {
    let urls: [URL]; @Binding var selection: Int; @Environment(\.dismiss) private var dismiss
    var body: some View { ZStack(alignment: .topTrailing) { Color.black.ignoresSafeArea(); TabView(selection: $selection) { ForEach(Array(urls.enumerated()), id: \.offset) { index, url in PirateBayZoomImage(url: url).tag(index) } }.tabViewStyle(.page(indexDisplayMode: .always)); Button { dismiss() } label: { Image(systemName: "xmark").font(.headline.bold()).padding(12).background(.ultraThinMaterial, in: Circle()) }.foregroundStyle(.white).padding() } }
}

private struct PirateBayZoomImage: View {
    let url: URL; @State private var scale: CGFloat = 1; @State private var finalScale: CGFloat = 1
    var body: some View { KFImage(url).requestModifier(pirateBayImageRequestModifier).placeholder { ProgressView().tint(.white) }.resizable().scaledToFit().scaleEffect(scale).gesture(MagnificationGesture().onChanged { scale = max(1, min(finalScale * $0, 5)) }.onEnded { _ in finalScale = scale }).onTapGesture(count: 2) { withAnimation(.spring()) { scale = scale > 1 ? 1 : 2; finalScale = scale } }.padding(.vertical, 55) }
}
