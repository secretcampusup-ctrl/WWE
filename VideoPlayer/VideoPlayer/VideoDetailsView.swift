import SwiftUI
import Foundation
import UIKit
import Combine

struct VideoEpisodeItem: Identifiable {
    let id: String
    let title: String
    let season: Int
    let episode: Int

    var numberLabel: String { String(format: "S%02d · E%02d", season, episode) }
    var episodeTitle: String { VideoTitleFormatter.episodeTitle(from: title) }
}

struct VideoDetailsSuggestion: Identifiable {
    let id: String
    let title: String
    let posterCacheKey: String
    let imageURL: URL?
}

struct VideoDetailsItem: Identifiable {
    let id: String
    let title: String
    let url: URL
    var httpHeaders: [String: String] = [:]
    var posterCacheKey: String? = nil
    var customPosterFileName: String? = nil
    var customPosterImage: UIImage? = nil
    var fileSizeBytes: Int64? = nil
    var durationSeconds: Double? = nil
    var videoWidth: Int? = nil
    var videoHeight: Int? = nil
    var fileExtension: String = "VIDEO"
    var source: String = "Stream"
    var resumePositionSeconds: Double? = nil
    var relatedEpisodes: [VideoEpisodeItem] = []
    var suppliedTMDBDetails: TMDBTitleDetails? = nil
    var suppliedAdultMetadata: VideoThumbnailLoader.ThePornDBMetadata? = nil
    var manualMetadataProvider: String? = nil

    var fileSizeLabel: String {
        guard let fileSizeBytes, fileSizeBytes > 0 else { return "Unknown" }
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: fileSizeBytes)
    }

    var durationLabel: String {
        guard let durationSeconds, durationSeconds.isFinite, durationSeconds > 0 else { return "Unknown" }
        let seconds = Int(durationSeconds.rounded())
        return String(format: "%02d:%02d:%02d", seconds / 3600, (seconds % 3600) / 60, seconds % 60)
    }

    var resolutionLabel: String {
        guard let videoWidth, let videoHeight, videoWidth > 0, videoHeight > 0 else { return "Unknown" }
        return "\(videoWidth) x \(videoHeight)"
    }


    var displayDate: String {
        let pattern = #"^\s*((?:19|20)\d{2})[._ -](\d{1,2})[._ -](\d{1,2})(?=\D|$)"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: title, range: NSRange(title.startIndex..., in: title)),
              let yearRange = Range(match.range(at: 1), in: title),
              let monthRange = Range(match.range(at: 2), in: title),
              let dayRange = Range(match.range(at: 3), in: title),
              let year = Int(title[yearRange]),
              let month = Int(title[monthRange]),
              let day = Int(title[dayRange]) else { return "-" }
        return String(format: "%04d.%02d.%02d", year, month, day)
    }

    var seasonEpisodeLabel: String? {
        VideoTitleFormatter.seasonEpisode(from: title)
    }

    var metadataValue: String {
        displayDate != "-" ? displayDate : (seasonEpisodeLabel ?? "-")
    }

    var metadataLabel: String {
        displayDate != "-" ? "Date" : (seasonEpisodeLabel == nil ? "Details" : "Season · Episode")
    }

    var automaticSeriesPosterCacheKey: String? {
        guard displayDate == "-", seasonEpisodeLabel != nil else { return nil }
        return "series-poster|\(displayTitle.lowercased())"
    }

    var displayTitle: String {
        VideoTitleFormatter.title(from: title)
    }
    var is4K: Bool {
        if let videoWidth, let videoHeight,
           max(videoWidth, videoHeight) >= 3_840,
           min(videoWidth, videoHeight) >= 2_000 {
            return true
        }

        let normalized = title.lowercased()
        return normalized.contains("2160p") ||
            normalized.contains("2160 p") ||
            normalized.contains("4k") ||
            normalized.contains("4 k")
    }

    var qualityLabel: String {
        if is4K { return "4K" }
        if isFullHD { return "FHD" }
        guard let videoWidth, let videoHeight else { return "-" }
        let shortEdge = min(videoWidth, videoHeight)
        if shortEdge >= 720 { return "HD" }
        return "SD"
    }

    var isFullHD: Bool {
        if let videoWidth, let videoHeight,
           max(videoWidth, videoHeight) >= 1_920,
           min(videoWidth, videoHeight) >= 1_080 {
            return true
        }
        let normalized = title.lowercased()
        return normalized.contains("1080p") ||
            normalized.contains("1080 p") ||
            normalized.contains("full hd") ||
            normalized.contains("fhd")
    }
}

@MainActor
private enum VideoDetailsMemoryCache {
    static var details: [String: TMDBTitleDetails] = [:]
    static var episodes: [String: TMDBEpisodeDetails] = [:]
    static var adultMetadata: [String: VideoThumbnailLoader.ThePornDBMetadata] = [:]
}

struct VideoDetailsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @ObservedObject var vm: AppViewModel
    @ObservedObject private var downloadManager = VideoDownloadManager.shared

    let item: VideoDetailsItem
    let onPlay: () -> Void
    var onDelete: (() -> Void)? = nil
    var dismissOnPlay: Bool = true
    var onSelectEpisode: ((String) -> Void)? = nil
    var suggestionsTitle: String = "Unwatched"
    var suggestions: [VideoDetailsSuggestion] = []
    var onSelectSuggestion: ((String) -> Void)? = nil

    @State private var frame: UIImage?
    @State private var showDownloadManager = false
    @State private var showDeleteConfirmation = false
    @State private var showDeleteUnavailable = false
    @State private var showPlaylistPicker = false
    @State private var thePornDBMetadata: VideoThumbnailLoader.ThePornDBMetadata?
    @State private var tmdbDetails: TMDBTitleDetails?
    @State private var tmdbEpisode: TMDBEpisodeDetails?
    @State private var isPreparingPlayback = false
    @State private var movieHeaderScrollOffset: CGFloat = 0
    @State private var standardHeaderScrollOffset: CGFloat = 0
    @State private var displayedSeriesSeason: Int?

    var body: some View {
        NavigationStack {
            Group {
                if isMovieDetailsPage {
                    movieDetailsScreen
                } else {
                    ZStack(alignment: .top) {
                        preview

                        ScrollView(showsIndicators: false) {
                            VStack(alignment: .leading, spacing: 0) {
                                Color.clear
                                    .frame(height: heroHeight - 24)

                                VStack(alignment: .leading, spacing: 14) {
                                if item.is4K || item.isFullHD || qualityStyle != nil {
                                    qualityFeatureStrip
                                }

                        VStack(spacing: 12) {
                            primaryPlayButton

                            HStack(spacing: 12) {
                                actionButton(
                                    title: downloadButtonTitle,
                                    icon: downloadButtonIcon,
                                    color: .blue,
                                    action: startDownload
                                )

                                actionButton(
                                    title: "Playlist",
                                    icon: "text.badge.plus",
                                    color: .purple
                                ) {
                                    showPlaylistPicker = true
                                }

                                actionButton(
                                    title: vm.isFavorite(item) ? "Favorited" : "Favorite",
                                    icon: vm.isFavorite(item) ? "star.fill" : "star",
                                    color: .yellow
                                ) {
                                    withAnimation(.easeInOut(duration: 0.2)) {
                                        _ = vm.toggleFavorite(item)
                                    }
                                }

                                actionButton(
                                    title: "Delete",
                                    icon: "trash.fill",
                                    color: .red
                                ) {
                                    if onDelete == nil {
                                        showDeleteUnavailable = true
                                    } else {
                                        showDeleteConfirmation = true
                                    }
                                }
                            }
                        }

                        if !item.relatedEpisodes.isEmpty { seriesEpisodesSection }

                        videoInformationCard
                        if let tmdbDetails {
                            tmdbInformationCard(tmdbDetails)
                        } else if ThePornDBSettings.isEnabled, let thePornDBMetadata {
                            thePornDBInfoCard(thePornDBMetadata)
                        }
                        if !suggestions.isEmpty {
                            unwatchedSuggestionsSection
                        }
                    }
                        .padding(.horizontal, 16)
                        .padding(.top, 18)
                        .padding(.bottom, 28)
                        .background(AppTheme.bg)
                        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                            }
                            .background(DetailsScrollOffsetObserver(offset: $standardHeaderScrollOffset))
                        }
                    }
                }
            }
            .background(AppTheme.bg.ignoresSafeArea())
            .ignoresSafeArea(edges: .top)
            .toolbar(.hidden, for: .navigationBar)
        }
        .preferredColorScheme(.dark)
        .task(id: detailsLoadingIdentity) {
            let requestedURL = item.url

            if let fileName = item.customPosterFileName,
               let custom = VideoThumbnailLoader.loadCustomPoster(fileName: fileName) {
                frame = custom
                return
            }
            if let custom = item.customPosterImage {
                frame = custom
                return
            }

            if let seriesKey = item.automaticSeriesPosterCacheKey {
                if let cachedSeriesPoster = VideoThumbnailLoader.cachedImage(forStableKey: seriesKey) {
                    frame = cachedSeriesPoster
                    return
                }
                if let seriesPoster = await VideoThumbnailLoader.loadSeriesPoster(named: item.displayTitle) {
                    guard !Task.isCancelled, requestedURL == item.url else { return }
                    VideoThumbnailLoader.cacheImage(seriesPoster, forStableKey: seriesKey)
                    if let key = item.posterCacheKey {
                        VideoThumbnailLoader.cacheImage(seriesPoster, forStableKey: key)
                    }
                    frame = seriesPoster
                    return
                }
            }

            // Metadata artwork is already persisted on disk under these stable
            // keys. On subsequent opens, use it and do not probe the remote
            // video again merely to regenerate a background frame.
            let cachedMetadataArtwork = VideoThumbnailLoader.cachedImage(
                forStableKey: "tmdb-episode|\(stableMetadataCacheKey)"
            ) ?? VideoThumbnailLoader.cachedImage(forStableKey: tmdbTitleArtworkCacheKey)
            if let cachedMetadataArtwork {
                frame = cachedMetadataArtwork
                return
            }

            let detailKey = "details-artwork|\(stableMetadataCacheKey)"
            if let highResolution = VideoThumbnailLoader.cachedImage(forStableKey: detailKey) {
                frame = highResolution
                return
            }

            // Show the lightweight grid image immediately, then upgrade it.
            if let key = item.posterCacheKey,
               let lightweight = VideoThumbnailLoader.cachedImage(forStableKey: key) {
                frame = lightweight
            } else if let cached = VideoThumbnailLoader.cachedImage(for: requestedURL) {
                frame = cached
            }

            if let highResolution = await VideoThumbnailLoader.loadPoster(
                for: requestedURL,
                headers: item.httpHeaders,
                stableKey: detailKey,
                targetPointSize: ThumbnailPipeline.targetPointSize(for: .large)
            ) {
                guard !Task.isCancelled, requestedURL == item.url else { return }
                frame = highResolution
            }
            // Note: the ThePornDB cover/metadata fallback runs in its own `.task`
            // below (always on), so it isn't duplicated here.
        }
        .onAppear {
            prepareForCurrentItem()
        }
        .onChange(of: item.id) { _ in
            isPreparingPlayback = false
            movieHeaderScrollOffset = 0
            standardHeaderScrollOffset = 0
            displayedSeriesSeason = selectedEpisodeItem?.season
            prepareForCurrentItem()
        }
        .onChange(of: vm.isLoading) { isLoading in
            guard !isLoading, isPreparingPlayback else { return }
            withAnimation(.easeOut(duration: 0.18)) { isPreparingPlayback = false }
        }
        .onReceive(NotificationCenter.default.publisher(for: VideoThumbnailLoader.stablePosterDidUpdateNotification)) { notification in
            guard let key = notification.object as? String,
                  key == item.posterCacheKey,
                  let cached = VideoThumbnailLoader.cachedImage(forStableKey: key) else { return }
            frame = cached
        }
        // ThePornDB metadata (cover + title/performers/tags/date) is the one automatic
        // lookup that's always on, independent of the poster-frame logic above — see
        // VideoThumbnailLoader.fetchThePornDBMetadata.
        .task(id: metadataLoadingIdentity) {
            let requestedItemID = item.id
            let metadataKey = stableMetadataCacheKey
            tmdbDetails = item.manualMetadataProvider == "theporndb"
                ? nil
                : (item.suppliedTMDBDetails ?? VideoDetailsMemoryCache.details[metadataKey])
            tmdbEpisode = item.relatedEpisodes.isEmpty
                ? VideoDetailsMemoryCache.episodes[metadataKey]
                : nil
            thePornDBMetadata = ThePornDBSettings.isEnabled && item.manualMetadataProvider != "tmdb"
                ? (item.suppliedAdultMetadata ?? VideoDetailsMemoryCache.adultMetadata[metadataKey])
                : nil

            let episodeArtworkKey = "tmdb-episode|\(metadataKey)"
            let titleArtworkKey = tmdbTitleArtworkCacheKey
            if let cachedEpisode = VideoThumbnailLoader.cachedImage(forStableKey: episodeArtworkKey) {
                frame = cachedEpisode
            } else if let cachedTitle = VideoThumbnailLoader.cachedImage(forStableKey: titleArtworkKey) {
                frame = cachedTitle
            }
            if item.relatedEpisodes.isEmpty,
               tmdbEpisode == nil,
               let value = VideoTitleFormatter.episodeComponents(from: item.title) {
                let loadedEpisode = await TMDBService.shared.episodeDetails(seriesTitle: item.title, season: value.season, episode: value.episode)
                guard !Task.isCancelled, requestedItemID == item.id else { return }
                tmdbEpisode = loadedEpisode
                if let loadedEpisode { VideoDetailsMemoryCache.episodes[metadataKey] = loadedEpisode }
                if VideoThumbnailLoader.cachedImage(forStableKey: episodeArtworkKey) == nil,
                   let imageURL = loadedEpisode?.imageURL,
                   let (data, _) = try? await HighPriorityNetworkManager.shared.responsiveData(from: imageURL),
                   let image = UIImage(data: data) {
                    guard !Task.isCancelled, requestedItemID == item.id else { return }
                    frame = image
                    VideoThumbnailLoader.cacheImage(image, forStableKey: episodeArtworkKey)
                    if let key = item.posterCacheKey { VideoThumbnailLoader.cacheImage(image, forStableKey: key) }
                }
            }
            // Snapshots created before poster-based Details do not contain the
            // preferred No Language/English poster path. Upgrade them once.
            if tmdbDetails?.detailsPosterPath == nil, item.manualMetadataProvider != "theporndb" {
                let loadedDetails = await TMDBService.shared.details(for: item.title)
                guard !Task.isCancelled, requestedItemID == item.id else { return }
                if let loadedDetails { tmdbDetails = loadedDetails }
            }
            if let tmdbDetails { VideoDetailsMemoryCache.details[metadataKey] = tmdbDetails }
            if tmdbEpisode?.imageURL == nil,
               VideoThumbnailLoader.cachedImage(forStableKey: titleArtworkKey) == nil,
               let imageURL = isMovieDetailsPage ? tmdbDetails?.detailsPosterURL : tmdbDetails?.imageURL,
               let (data, _) = try? await HighPriorityNetworkManager.shared.responsiveData(from: imageURL),
               let image = UIImage(data: data) {
                guard !Task.isCancelled, requestedItemID == item.id else { return }
                frame = image
                if isMovieDetailsPage {
                    VideoThumbnailLoader.cacheHighQualityImage(
                        image,
                        forStableKey: titleArtworkKey,
                        maximumBytes: ThumbnailPipeline.largeMaximumBytes
                    )
                } else {
                    VideoThumbnailLoader.cacheImage(image, forStableKey: titleArtworkKey)
                }
                VideoThumbnailLoader.cacheImage(image, forStableKey: VideoThumbnailLoader.canonicalPosterCacheKey(for: item.title))
                // Full portrait artwork belongs only to Details. Sharing this
                // key with the grid would overwrite its lightweight poster.
                if !isMovieDetailsPage, let key = item.posterCacheKey {
                    VideoThumbnailLoader.cacheImage(image, forStableKey: key)
                }
            }
            guard tmdbDetails == nil else { return }
            if ThePornDBSettings.isEnabled, thePornDBMetadata == nil {
                thePornDBMetadata = await VideoThumbnailLoader.fetchThePornDBMetadata(for: item.displayTitle)
            }
            if ThePornDBSettings.isEnabled, let thePornDBMetadata {
                VideoDetailsMemoryCache.adultMetadata[metadataKey] = thePornDBMetadata
            }
            if ThePornDBSettings.isEnabled, let cover = thePornDBMetadata?.coverImage {
                if frame == nil || item.suppliedAdultMetadata != nil || item.manualMetadataProvider == "theporndb" {
                    frame = cover
                }
                VideoThumbnailLoader.cacheImage(
                    cover,
                    forStableKey: VideoThumbnailLoader.canonicalPosterCacheKey(for: item.title)
                )
                if let key = item.posterCacheKey {
                    VideoThumbnailLoader.cacheImage(cover, forStableKey: key)
                    if key.hasPrefix("unified|") {
                        let suffix = String(key.dropFirst("unified|".count))
                        VideoThumbnailLoader.cacheImage(cover, forStableKey: "unified-adult|\(suffix)")
                    }
                }
            }
        }
        .alert("Delete video?", isPresented: $showDeleteConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                onDelete?()
                dismiss()
            }
        } message: {
            Text("This action cannot be undone.")
        }
        .alert("Delete unavailable", isPresented: $showDeleteUnavailable) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("This source does not allow deleting one file from the app.")
        }
        .sheet(isPresented: $showDownloadManager) {
            DownloadManagerView()
        }
        .sheet(isPresented: $showPlaylistPicker) {
            PlaylistPickerView(vm: vm, item: item)
        }
    }

    private var isMovieDetailsPage: Bool {
        item.suppliedAdultMetadata != nil
            || item.manualMetadataProvider == "theporndb"
            || !item.relatedEpisodes.isEmpty
            || (item.relatedEpisodes.isEmpty && item.seasonEpisodeLabel == nil)
    }

    /// Warm solid background used by the movie artwork fade (#211A13).
    private var movieDetailsBaseColor: Color {
        Color(red: 33.0 / 255.0, green: 26.0 / 255.0, blue: 19.0 / 255.0)
    }

    private var movieDetailsScreen: some View {
        ZStack(alignment: .top) {
            GeometryReader { proxy in
                // Keep artwork underneath the complete blend. The final opaque
                // stop lands exactly where this hero ends, so no hard image edge
                // can appear on tall or short displays.
                let heroHeight = max(320, proxy.size.height * 0.54)
                let pullDistance = max(0, movieHeaderScrollOffset)
                let upwardDistance = max(0, -movieHeaderScrollOffset)
                let headerScale = 1 + min(pullDistance / max(heroHeight, 1), 0.18)
                let parallaxOffset = movieHeaderScrollOffset < 0
                    ? movieHeaderScrollOffset * 0.22
                    : 0
                let fadeAmount = min(1.0, Double(upwardDistance / 210))
                ZStack {
                    movieDetailsBaseColor
                    Group {
                        if let backdrop = movieBackdropFrame {
                            FullPosterDetailsBackdrop(image: backdrop)
                        } else if let displayedFrame {
                            FullPosterDetailsBackdrop(image: displayedFrame)
                        } else {
                            DetailsLoadingSpinner(size: 38, lineWidth: 3.2)
                        }
                    }
                    .frame(width: proxy.size.width, height: proxy.size.height, alignment: .top)
                    .scaleEffect(headerScale, anchor: .top)
                    .offset(y: parallaxOffset)

                    LinearGradient(
                        stops: [
                            // Keep status and navigation controls legible over
                            // bright artwork while retaining the poster detail.
                            .init(color: .black.opacity(0.50), location: 0.00),
                            .init(color: .black.opacity(0.38), location: 0.18),

                            // Blend into the warm details background around the
                            // middle of the display, then hide artwork entirely.
                            .init(color: movieDetailsBaseColor.opacity(0.20), location: 0.30),
                            .init(color: movieDetailsBaseColor.opacity(0.72), location: 0.41),
                            .init(color: movieDetailsBaseColor.opacity(0.96), location: 0.49),
                            .init(color: movieDetailsBaseColor, location: 0.54),
                            .init(color: movieDetailsBaseColor, location: 1.00)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .allowsHitTesting(false)

                    // This extra layer is driven only by upward scrolling. It
                    // leaves the artwork open initially, then darkens it smoothly
                    // as content approaches the top controls.
                    LinearGradient(
                        colors: [
                            Color.black.opacity(0.48 * fadeAmount),
                            Color.black.opacity(0.30 * fadeAmount),
                            Color.clear
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .frame(height: heroHeight)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .allowsHitTesting(false)
                }
                .clipped()
            }
            .ignoresSafeArea()

            ScrollView(showsIndicators: false) {
                VStack(spacing: 0) {
                    Color.clear
                        .frame(height: max(300, UIScreen.main.bounds.height * 0.39))

                    VStack(spacing: 16) {
                        movieTitleTreatment
                        movieDataRow

                        Label(
                            resolvedMovieDetails.map { String(format: "%.1f", $0.voteAverage) } ?? "-",
                            systemImage: "star.fill"
                        )
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .foregroundStyle(Color.yellow)
                        .monospacedDigit()

                        moviePlayButton
                        movieActionRow

                        if let details = resolvedMovieDetails, !details.overview.isEmpty {
                            Text("\(details.title) — \(details.overview)")
                                .font(.system(size: 12.5, weight: .regular))
                                .foregroundStyle(.white.opacity(0.82))
                                .lineSpacing(3)
                                .lineLimit(3)
                                .truncationMode(.tail)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }

                        if !item.relatedEpisodes.isEmpty {
                            seriesEpisodesSection
                        }

                        if let details = resolvedMovieDetails, details.director != nil || !details.cast.isEmpty {
                            movieCastAndCrew(details)
                        }

                        if resolvedMovieDetails == nil,
                           ThePornDBSettings.isEnabled,
                           let thePornDBMetadata {
                            if !thePornDBMetadata.performers.isEmpty {
                                adultCastAndCrew(thePornDBMetadata)
                            }
                            thePornDBInfoCard(thePornDBMetadata)
                        }

                        if !suggestions.isEmpty {
                            unwatchedSuggestionsSection
                        }

                        VStack(spacing: 3) {
                            Text("\(item.source) · \(item.fileExtension.uppercased())")
                            Text(item.relatedEpisodes.isEmpty ? "My Library · Movies" : "My Library · TV Shows")
                        }
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.white.opacity(0.34))
                        .frame(maxWidth: .infinity)
                        .padding(.top, 8)
                    }
                    .padding(.horizontal, 18)
                    .padding(.bottom, 42)
                }
                .background(DetailsScrollOffsetObserver(offset: $movieHeaderScrollOffset))
            }

            HStack {
                movieTopButton(icon: "chevron.left") { dismiss() }
                Spacer()
                Menu {
                    Button(action: startDownload) { Label("Download", systemImage: "arrow.down.circle") }
                    Button { showPlaylistPicker = true } label: { Label("Add to Playlist", systemImage: "text.badge.plus") }
                    if onDelete != nil {
                        Button(role: .destructive) { showDeleteConfirmation = true } label: { Label("Delete", systemImage: "trash") }
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 42, height: 42)
                        .background(.ultraThinMaterial, in: Circle())
                        .overlay(Circle().stroke(Color.white.opacity(0.18)))
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, topSafeAreaInset + 8)
        }
    }

    private var movieTitleTreatment: some View {
        Group {
            if let logoURL = resolvedMovieDetails?.logoURL {
                CachedTMDBImage(url: logoURL, contentMode: .fit)
                .frame(maxWidth: 270, minHeight: 72, maxHeight: 122)
            } else {
                fallbackMovieTitle
            }
        }
        .shadow(color: .black.opacity(0.92), radius: 5, x: 0, y: 3)
        .shadow(color: .black.opacity(0.6), radius: 14)
        .frame(maxWidth: .infinity)
    }

    private var fallbackMovieTitle: some View {
        Text((resolvedMovieDetails?.title ?? thePornDBMetadata?.title ?? item.displayTitle).uppercased())
            .font(.system(size: 38, weight: .black, design: .rounded))
            .italic()
            .tracking(-1.6)
            .multilineTextAlignment(.center)
            .lineLimit(2)
            .minimumScaleFactor(0.55)
            .foregroundStyle(.white)
    }

    private var movieDataRow: some View {
        HStack(spacing: 8) {
            Text(adultMovieDateLabel ?? movieReleaseDateLabel)
            movieDataDivider
            Text(adultMovieSiteLabel ?? resolvedMovieDetails?.productionCountries?.first ?? "-")
            movieDataDivider
            Text(adultMovieTagsLabel ?? resolvedMovieDetails?.genres.prefix(2).map(\.name).joined(separator: ", ") ?? "-")
            movieDataDivider
            Text(resolvedMovieDetails == nil && thePornDBMetadata != nil ? "[TPDB]" : "[\(movieCertificationLabel)]")
        }
        .font(.system(size: 10.5, weight: .semibold, design: .rounded))
        .foregroundStyle(.white.opacity(0.88))
        .lineLimit(1)
        .minimumScaleFactor(0.65)
        .frame(maxWidth: .infinity)
    }

    private var movieDataDivider: some View {
        Rectangle().fill(Color.white.opacity(0.34)).frame(width: 1, height: 12)
    }

    private var movieReleaseDateLabel: String {
        guard let raw = resolvedMovieDetails?.releaseDate else { return movieYearLabel }
        let input = DateFormatter()
        input.locale = Locale(identifier: "en_US_POSIX")
        input.dateFormat = "yyyy-MM-dd"
        guard let date = input.date(from: raw) else { return raw }
        let output = DateFormatter()
        output.locale = Locale(identifier: "en_US_POSIX")
        output.dateFormat = "MM/dd/yyyy"
        return output.string(from: date)
    }

    private var movieCertificationLabel: String {
        guard let value = resolvedMovieDetails?.certification, !value.isEmpty else { return "NR" }
        return value
    }

    private var adultMovieDateLabel: String? {
        guard resolvedMovieDetails == nil else { return nil }
        return thePornDBMetadata?.date
    }

    private var adultMovieSiteLabel: String? {
        guard resolvedMovieDetails == nil else { return nil }
        return thePornDBMetadata?.siteName
    }

    private var adultMovieTagsLabel: String? {
        guard resolvedMovieDetails == nil else { return nil }
        let value = thePornDBMetadata?.tags.prefix(2).joined(separator: ", ") ?? ""
        return value.isEmpty ? nil : value
    }

    private var moviePlayButton: some View {
        Button(action: playAndClose) {
            Group {
                if isPreparingPlayback {
                    HStack(spacing: 9) {
                        DetailsLoadingSpinner(size: 18, lineWidth: 2.2, color: Color.black.opacity(0.78))
                        Text("Preparing...").font(.system(size: 15, weight: .bold))
                    }
                } else {
                    VStack(spacing: 2) {
                        Label(playButtonTitle, systemImage: "play.fill")
                            .font(.system(size: 15, weight: .bold))
                        if hasMovieProgress {
                            Text("Played: \(movieProgressPercent)%")
                                .font(.system(size: 9, weight: .semibold))
                                .opacity(0.65)
                        }
                    }
                }
            }
            .foregroundStyle(Color.black.opacity(0.86))
            .frame(maxWidth: .infinity)
            .frame(height: hasMovieProgress ? 52 : 46)
            .background(Color.white.opacity(0.92), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        }
        .buttonStyle(PremiumPressButtonStyle())
        .disabled(isPreparingPlayback)
    }

    private var hasMovieProgress: Bool {
        effectiveResumePosition > 3
    }

    private var movieProgressPercent: Int {
        let current = effectiveResumePosition
        let duration = vm.playbackHistoryEntry(for: item)?.durationSeconds ?? item.durationSeconds ?? 0
        guard current > 0, duration > 0 else { return 1 }
        return min(99, max(1, Int((current / duration) * 100)))
    }

    private var effectiveResumePosition: Double {
        if let history = vm.playbackHistoryEntry(for: item), history.hasResumePoint {
            return history.positionSeconds
        }
        return item.resumePositionSeconds ?? 0
    }

    private var movieActionRow: some View {
        HStack {
            movieActionButton(icon: "arrow.down.circle", action: startDownload)
            Spacer()
            movieActionButton(icon: vm.isFavorite(item) ? "heart.fill" : "heart") { _ = vm.toggleFavorite(item) }
            Spacer()
            movieActionButton(icon: "text.badge.plus") { showPlaylistPicker = true }
            Spacer()
            movieActionButton(icon: "flag") {
                if onDelete != nil { showDeleteConfirmation = true }
                else { showDeleteUnavailable = true }
            }
        }
        .padding(.horizontal, 22)
    }

    private func movieActionButton(icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(.white.opacity(0.9))
                .frame(width: 42, height: 36)
        }
        .buttonStyle(.plain)
    }

    private func movieTopButton(icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 42, height: 42)
                .background(.ultraThinMaterial, in: Circle())
                .overlay(Circle().stroke(Color.white.opacity(0.18)))
        }
        .buttonStyle(.plain)
    }

    private func movieCastAndCrew(_ details: TMDBTitleDetails) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Cast & Crew")
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(.white)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 14) {
                    if let director = details.director {
                        moviePersonCard(name: director.name, role: "Director", imageURL: director.imageURL)
                    }
                    ForEach(details.cast.prefix(12)) { member in
                        moviePersonCard(name: member.name, role: member.character, imageURL: member.imageURL)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func adultCastAndCrew(_ metadata: VideoThumbnailLoader.ThePornDBMetadata) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Cast & Crew")
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(.white)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 14) {
                    ForEach(Array(metadata.performers.prefix(12).enumerated()), id: \.offset) { _, name in
                        moviePersonCard(name: name, role: "Performer", imageURL: nil)
                    }
                }
            }
            .scrollIndicators(.hidden)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func moviePersonCard(name: String, role: String, imageURL: URL?) -> some View {
        VStack(spacing: 5) {
            CachedTMDBImage(url: imageURL, contentMode: .fill, placeholderSystemName: "person.fill")
            .frame(width: 66, height: 76)
            .background(Color.white.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

            Text(name).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
            Text(role).font(.system(size: 9)).foregroundStyle(.white.opacity(0.55)).lineLimit(1)
        }
        .frame(width: 78)
    }

    private var unwatchedSuggestionsSection: some View {
        VStack(alignment: .leading, spacing: 11) {
            Text(suggestionsTitle)
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(.white)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 12) {
                    ForEach(suggestions) { suggestion in
                        suggestionPoster(suggestion)
                    }
                }
                .padding(.horizontal, 1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func suggestionPoster(_ suggestion: VideoDetailsSuggestion) -> some View {
        Button {
            onSelectSuggestion?(suggestion.id)
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                ZStack {
                    Color.white.opacity(0.07)
                    if let poster = VideoThumbnailLoader.cachedImage(forStableKey: suggestion.posterCacheKey) {
                        Image(uiImage: poster)
                            .resizable()
                            .scaledToFill()
                    } else {
                        CachedTMDBImage(
                            url: suggestion.imageURL,
                            contentMode: .fill,
                            placeholderSystemName: "film.fill"
                        )
                    }
                }
                .frame(width: 112, height: 154)
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous).stroke(Color.white.opacity(0.10)))

                Text(suggestion.title)
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.88))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(width: 112, alignment: .leading)
            }
        }
        .buttonStyle(PremiumPressButtonStyle())
    }

    private var preview: some View {
        GeometryReader { proxy in
            let pullDistance = max(0, standardHeaderScrollOffset)
            let upwardDistance = max(0, -standardHeaderScrollOffset)
            let headerScale = 1 + min(pullDistance / max(proxy.size.height, 1), 0.18)
            let parallaxOffset = standardHeaderScrollOffset < 0
                ? standardHeaderScrollOffset * 0.22
                : 0
            let fadeAmount = min(0.52, Double(upwardDistance / 230) * 0.52)
            ZStack {
                Button(action: playAndClose) {
                    ZStack {
                        Color.white.opacity(0.06)

                        if let displayedFrame {
                            Image(uiImage: displayedFrame)
                                .resizable()
                                .scaledToFill()
                                .frame(width: proxy.size.width, height: proxy.size.height, alignment: .top)
                                .clipped()
                                .scaleEffect(headerScale, anchor: .top)
                                .offset(y: parallaxOffset)
                        } else {
                            DetailsLoadingSpinner(size: 36, lineWidth: 3, color: .white)
                        }

                        Color.black.opacity(displayedFrame == nil ? 0.10 : 0.16)

                        Color.black.opacity(fadeAmount)
                            .allowsHitTesting(false)

                        LinearGradient(
                            stops: [
                                .init(color: Color.clear, location: 0.42),
                                .init(color: AppTheme.bg.opacity(0.12), location: 0.62),
                                .init(color: AppTheme.bg.opacity(0.72), location: 0.84),
                                .init(color: AppTheme.bg, location: 1.0)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                        .allowsHitTesting(false)
                    }
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .clipped()
                }
                .buttonStyle(.plain)

                VStack {
                    HStack {
                        Button { dismiss() } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 16, weight: .bold))
                                .foregroundColor(.white)
                                .frame(width: 44, height: 44)
                                .background(.ultraThinMaterial, in: Circle())
                                .overlay(
                                    Circle()
                                        .stroke(Color.white.opacity(0.14), lineWidth: 1)
                                )
                        }
                        .buttonStyle(.plain)

                        Spacer()
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, topSafeAreaInset + 8)

                    Spacer()
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .clipped()
        }
        .frame(height: heroHeight)
    }

    private var heroHeight: CGFloat {
        max(360, UIScreen.main.bounds.height * 0.44)
    }

    private var displayedFrame: UIImage? {
        VideoThumbnailLoader.cachedImage(forStableKey: tmdbTitleArtworkCacheKey)
            ?? VideoThumbnailLoader.cachedImage(forStableKey: VideoThumbnailLoader.canonicalPosterCacheKey(for: item.title))
            ?? frame
            ?? VideoThumbnailLoader.cachedImage(forStableKey: "tmdb-episode|\(stableMetadataCacheKey)")
            ?? VideoThumbnailLoader.cachedImage(forStableKey: "details-artwork|\(stableMetadataCacheKey)")
            ?? item.posterCacheKey.flatMap { VideoThumbnailLoader.cachedImage(forStableKey: $0) }
            ?? VideoThumbnailLoader.cachedImage(for: item.url)
    }

    private var movieBackdropFrame: UIImage? {
        guard isMovieDetailsPage else { return nil }
        if resolvedMovieDetails == nil,
           let adultCover = thePornDBMetadata?.coverImage {
            return adultCover
        }
        return VideoThumbnailLoader.cachedImage(forStableKey: tmdbTitleArtworkCacheKey)
    }

    private var tmdbTitleArtworkCacheKey: String {
        (isMovieDetailsPage ? "tmdb-details-poster-nolang-en-original-v1|" : "tmdb-title|") + stableMetadataCacheKey
    }

    private var topSafeAreaInset: CGFloat {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
        return scene?.windows.first(where: \.isKeyWindow)?.safeAreaInsets.top ?? 44
    }

    @ViewBuilder
    private var qualityFeatureStrip: some View {
        if let style = qualityStyle {
            HStack(spacing: 12) {
                // Label text — no background (matches current transparent look)
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(style.prefix)
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                        .foregroundColor(.white)

                    Text(style.emphasis)
                        .font(.system(size: 16, weight: .black, design: .rounded))
                        .foregroundColor(.white)

                    Text("·")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundColor(.white.opacity(0.45))

                    Text(style.detail)
                        .font(.system(size: 15, weight: .semibold, design: .rounded).monospacedDigit())
                        .foregroundColor(.white.opacity(0.82))
                }

                Spacer(minLength: 8)

                // Colored badge box from the HTML design
                Text(style.badge)
                    .font(.system(size: 13, weight: .black))
                    .tracking(0.8)
                    .foregroundColor(style.badgeForeground)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 5)
                    .background(
                        LinearGradient(
                            colors: style.badgeGradient,
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(Color.white.opacity(0.15), lineWidth: 1)
                    )
                    .shadow(color: style.badgeShadow.opacity(0.45), radius: 8, y: 2)
            }
            .environment(\.layoutDirection, .leftToRight)
            .padding(.horizontal, 2)
            .padding(.vertical, 6)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(style.accessibility)
        }
    }

    /// Visual style driven by detected resolution (from HTML cards, no outer background).
    private var qualityStyle: QualityStripStyle? {
        if item.is4K {
            return QualityStripStyle(
                prefix: "ULTRA HD",
                emphasis: "4K",
                detail: "2160p",
                badge: "4K",
                badgeGradient: [
                    Color(red: 0.96, green: 0.69, blue: 0.26),
                    Color(red: 0.88, green: 0.49, blue: 0.12)
                ],
                badgeForeground: .black,
                badgeShadow: Color(red: 0.88, green: 0.49, blue: 0.12),
                accessibility: "Ultra HD 4K, 2160p"
            )
        }
        if item.isFullHD {
            return QualityStripStyle(
                prefix: "FULL HD",
                emphasis: "1080p",
                detail: "1920×1080",
                badge: "1080p",
                badgeGradient: [
                    Color(red: 0.38, green: 0.65, blue: 0.98),
                    Color(red: 0.15, green: 0.39, blue: 0.92)
                ],
                badgeForeground: .white,
                badgeShadow: Color(red: 0.15, green: 0.39, blue: 0.92),
                accessibility: "Full HD 1080p"
            )
        }
        // 720p / HD fallback when we can detect it from the title/label
        let label = (item.resolutionLabel + " " + item.displayTitle).lowercased()
        if label.contains("720") || label.contains("hd") && !label.contains("full") {
            return QualityStripStyle(
                prefix: "HD",
                emphasis: "720p",
                detail: "1280×720",
                badge: "720p",
                badgeGradient: [
                    Color(red: 0.65, green: 0.55, blue: 0.98),
                    Color(red: 0.43, green: 0.16, blue: 0.85)
                ],
                badgeForeground: .white,
                badgeShadow: Color(red: 0.43, green: 0.16, blue: 0.85),
                accessibility: "HD 720p"
            )
        }
        return nil
    }
    private var videoInformationCard: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(item.displayTitle)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundColor(.white)
                        .lineLimit(2)
                        .textSelection(.enabled)

                    Text("\(item.durationLabel)  ·  \(item.source)")
                        .font(.system(size: 12, weight: .medium).monospacedDigit())
                        .foregroundColor(.white.opacity(0.50))
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                ZStack {
                    Circle()
                        .fill(Color.white.opacity(0.08))
                        .frame(width: 34, height: 34)
                    Image(systemName: "bolt.horizontal.circle.fill")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundColor(.white)
                }
            }
            .padding(14)

            Divider().overlay(Color.white.opacity(0.08))

            HStack(spacing: 0) {
                informationMetric(value: item.fileSizeLabel, label: "File size")
                metricDivider
                if item.seasonEpisodeLabel == nil {
                    informationMetric(value: movieYearLabel, label: "Year")
                } else {
                    informationMetric(value: item.metadataValue, label: item.metadataLabel, subtitle: tmdbEpisode?.name ?? VideoTitleFormatter.episodeTitle(from: item.title))
                }
                metricDivider
                informationMetric(value: item.seasonEpisodeLabel == nil ? movieRuntimeLabel : item.fileExtension.uppercased(), label: item.seasonEpisodeLabel == nil ? "Runtime" : "Format")
            }
            .frame(minHeight: 72)
        }
        .background(AppTheme.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.white.opacity(0.06), lineWidth: 1)
        )
    }

    private var metadataLoadingIdentity: String {
        "metadata|\(stableMetadataCacheKey)"
    }

    private var stableMetadataCacheKey: String {
        if !item.relatedEpisodes.isEmpty, let details = item.suppliedTMDBDetails {
            return "series|tmdb|\(details.id)"
        }
        let normalizedTitle = item.displayTitle
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let episode = VideoTitleFormatter.episodeComponents(from: item.title) {
            return "episode|\(normalizedTitle)|s\(episode.season)e\(episode.episode)"
        }
        return (item.relatedEpisodes.isEmpty ? "movie|" : "series|") + normalizedTitle
    }

    private var resolvedMovieDetails: TMDBTitleDetails? {
        tmdbDetails ?? VideoDetailsMemoryCache.details[stableMetadataCacheKey]
    }

    private var movieYearLabel: String {
        if let date = resolvedMovieDetails?.releaseDate, date.count >= 4 {
            return String(date.prefix(4))
        }
        let pattern = #"(?<!\d)((?:19|20)\d{2})(?!\d)"#
        if let range = item.title.range(of: pattern, options: .regularExpression) {
            return String(item.title[range])
        }
        return "Unknown"
    }

    private var movieRuntimeLabel: String {
        if let minutes = resolvedMovieDetails?.runtimeMinutes, minutes > 0 {
            let hours = minutes / 60
            let remainder = minutes % 60
            return hours > 0 ? "\(hours)h \(remainder)m" : "\(minutes)m"
        }
        guard let seconds = item.durationSeconds, seconds > 0 else { return "Unknown" }
        let minutes = Int(seconds / 60)
        return minutes >= 60 ? "\(minutes / 60)h \(minutes % 60)m" : "\(minutes)m"
    }

    private var detailsLoadingIdentity: String {
        "details|\(stableMetadataCacheKey)"
    }

    private func prepareForCurrentItem() {
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            let metadataKey = stableMetadataCacheKey
            tmdbDetails = item.manualMetadataProvider == "theporndb"
                ? nil
                : (item.suppliedTMDBDetails ?? VideoDetailsMemoryCache.details[metadataKey])
            tmdbEpisode = item.relatedEpisodes.isEmpty
                ? VideoDetailsMemoryCache.episodes[metadataKey]
                : nil
            thePornDBMetadata = ThePornDBSettings.isEnabled && item.manualMetadataProvider != "tmdb"
                ? (item.suppliedAdultMetadata ?? VideoDetailsMemoryCache.adultMetadata[metadataKey])
                : nil

            let episodeArtworkKey = "tmdb-episode|\(metadataKey)"
            let titleArtworkKey = tmdbTitleArtworkCacheKey
            frame = VideoThumbnailLoader.cachedImage(forStableKey: episodeArtworkKey)
                ?? VideoThumbnailLoader.cachedImage(forStableKey: titleArtworkKey)
                ?? item.posterCacheKey.flatMap { VideoThumbnailLoader.cachedImage(forStableKey: $0) }
        }
    }

    private var selectedEpisodeItem: VideoEpisodeItem? {
        item.relatedEpisodes.first { $0.id == item.id }
    }

    private var availableSeriesSeasons: [Int] {
        Array(Set(item.relatedEpisodes.map(\.season))).sorted()
    }

    private var visibleSeriesSeason: Int {
        displayedSeriesSeason
            ?? selectedEpisodeItem?.season
            ?? availableSeriesSeasons.first
            ?? 1
    }

    private var visibleSeriesEpisodes: [VideoEpisodeItem] {
        item.relatedEpisodes
            .filter { $0.season == visibleSeriesSeason }
            .sorted { $0.episode < $1.episode }
    }

    private var seriesEpisodesSection: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack {
                Text("Season \(visibleSeriesSeason)")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(.white)
                Spacer()
                Text("\(visibleSeriesEpisodes.count) Episodes")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.58))
            }

            if availableSeriesSeasons.count > 1 {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(availableSeriesSeasons, id: \.self) { season in
                            Button {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    displayedSeriesSeason = season
                                }
                            } label: {
                                Text("Season \(season)")
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundStyle(visibleSeriesSeason == season ? .black : .white.opacity(0.72))
                                    .padding(.horizontal, 13)
                                    .frame(height: 32)
                                    .background(
                                        visibleSeriesSeason == season ? Color.white : Color.white.opacity(0.07),
                                        in: Capsule()
                                    )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }

            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 13) {
                        ForEach(visibleSeriesEpisodes) { episode in
                            cinematicEpisodeCard(episode)
                                .id(episode.id)
                        }
                    }
                    .padding(.vertical, 2)
                }
                .environment(\.layoutDirection, .leftToRight)
                .onAppear {
                    displayedSeriesSeason = selectedEpisodeItem?.season ?? availableSeriesSeasons.first
                    scrollToSelectedEpisode(using: proxy)
                }
                .onChange(of: item.id) { _ in scrollToSelectedEpisode(using: proxy) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func cinematicEpisodeCard(_ episode: VideoEpisodeItem) -> some View {
        let current = episode.id == item.id
        return Button { onSelectEpisode?(episode.id) } label: {
            VStack(alignment: .leading, spacing: 7) {
                ZStack {
                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .fill(Color.white.opacity(0.07))
                    EpisodeStillArtwork(
                        seriesID: resolvedMovieDetails?.id,
                        season: episode.season,
                        episode: episode.episode,
                        fallback: movieBackdropFrame ?? displayedFrame
                    )
                    LinearGradient(
                        colors: [.clear, .black.opacity(0.78)],
                        startPoint: .center,
                        endPoint: .bottom
                    )
                    Image(systemName: "play.fill")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.black)
                        .frame(width: 31, height: 31)
                        .background(Color.white.opacity(0.92), in: Circle())
                }
                .frame(width: 166, height: 94)
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .stroke(current ? AppPalette.accent : Color.white.opacity(0.10), lineWidth: current ? 2 : 1)
                )
                .overlay(alignment: .bottom) {
                    let progress = seriesEpisodeProgress(episode)
                    if progress > 0 {
                        GeometryReader { proxy in
                            AppPalette.gradient
                                .frame(width: proxy.size.width * progress)
                        }
                        .frame(height: 4)
                    }
                }

                Text("\(episode.episode). \(episode.episodeTitle)")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .frame(width: 166, alignment: .leading)
            }
        }
        .buttonStyle(PremiumPressButtonStyle())
    }

    private func seriesEpisodeProgress(_ episode: VideoEpisodeItem) -> CGFloat {
        guard let history = vm.playbackHistory[episode.id], history.durationSeconds > 0 else { return 0 }
        return CGFloat(min(1, max(0, history.positionSeconds / history.durationSeconds)))
    }

    private func scrollToSelectedEpisode(using proxy: ScrollViewProxy) {
        guard item.relatedEpisodes.contains(where: { $0.id == item.id }) else { return }
        DispatchQueue.main.async {
            withAnimation(.easeInOut(duration: 0.22)) {
                proxy.scrollTo(item.id, anchor: .center)
            }
        }
    }

    private func tmdbInformationCard(_ details: TMDBTitleDetails) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack { Text(details.title).font(.title3.bold()); Spacer(); if details.voteAverage > 0 { Label(String(format: "%.1f", details.voteAverage), systemImage: "star.fill").foregroundColor(.yellow) } }
            Text(details.isSeries ? "Series · TMDB" : "Movie · TMDB").font(.caption).foregroundColor(.secondary)
            if !details.overview.isEmpty { Text(details.overview).font(.subheadline).foregroundColor(.white.opacity(0.82)) }
            if let key = details.trailerKey, let url = URL(string: "https://www.youtube.com/watch?v=\(key)") { Button { openURL(url) } label: { Label("Watch Trailer", systemImage: "play.rectangle.fill").font(.subheadline.bold()).frame(maxWidth: .infinity).padding(.vertical, 11).background(Color.red.opacity(0.85), in: Capsule()) }.buttonStyle(.plain) }
            if !details.cast.isEmpty { Text("Cast").font(.headline); ScrollView(.horizontal, showsIndicators: false) { HStack(spacing: 12) { ForEach(details.cast) { member in VStack(spacing: 6) { CachedTMDBImage(url: member.imageURL, contentMode: .fill, placeholderSystemName: "person.crop.circle.fill").frame(width: 68, height: 68).clipShape(Circle()); Text(member.name).font(.caption.bold()).lineLimit(1).frame(width: 88); Text(member.character).font(.caption2).foregroundColor(.secondary).lineLimit(1).frame(width: 88) } } } } }
            if details.isSeries, !details.seasons.isEmpty { Text("Seasons & Episodes").font(.headline); ForEach(details.seasons) { season in HStack { Image(systemName: "rectangle.stack.fill").foregroundColor(AppTheme.accent); Text(season.name).font(.subheadline.bold()); Spacer(); Text("\(season.episodeCount) episodes").font(.caption).foregroundColor(.secondary) }.padding(10).background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 12)) } }
        }.padding(16).background(AppTheme.card, in: RoundedRectangle(cornerRadius: 18))
    }
    /// بطاقة معلومات ThePornDB: العنوان، الممثلين، التاغز، والتاريخ — تظهر فقط إذا
    /// نجح البحث التلقائي (مشاهد أولاً، وإلا ممثلين).
    private func thePornDBInfoCard(_ metadata: VideoThumbnailLoader.ThePornDBMetadata) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white.opacity(0.6))
                Text(metadata.source == .scene ? "ThePornDB · Scene" : "ThePornDB · Performer")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white.opacity(0.6))
            }

            if let title = metadata.title, !title.isEmpty {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.white)
                    .lineLimit(2)
                    .textSelection(.enabled)
            }

            if !metadata.performers.isEmpty {
                thePornDBInfoRow(label: "Performers", value: metadata.performers.joined(separator: ", "))
            }
            if !metadata.tags.isEmpty {
                thePornDBInfoRow(label: "Tags", value: metadata.tags.joined(separator: ", "))
            }
            if let date = metadata.date, !date.isEmpty {
                thePornDBInfoRow(label: "Date", value: date)
            }
            if let site = metadata.siteName, !site.isEmpty {
                thePornDBInfoRow(label: "Site", value: site)
            }
        }
        .padding(.vertical, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func thePornDBInfoRow(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.white.opacity(0.42))
            Text(value)
                .font(.system(size: 13, weight: .regular))
                .foregroundColor(.white.opacity(0.85))
                .textSelection(.enabled)
        }
    }

    private var metricDivider: some View {
        Rectangle()
            .fill(Color.white.opacity(0.08))
            .frame(width: 1, height: 34)
    }

    private func informationMetric(value: String, label: String, subtitle: String? = nil) -> some View {
        VStack(spacing: 5) {
            Text(value)
                .font(.system(size: 16, weight: .semibold).monospacedDigit())
                .foregroundColor(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.68)

            if let subtitle, !subtitle.isEmpty, subtitle != "Episode" {
                Text(subtitle).font(.system(size: 10, weight: .semibold)).foregroundColor(.white.opacity(0.72)).lineLimit(1).minimumScaleFactor(0.7)
            }

            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.white.opacity(0.42))
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 6)
    }
    /// زر التشغيل الرئيسي — يأخذ العرض الكامل بتصميم بارز فوق باقي الأزرار
    private var playButtonTitle: String {
        let action = effectiveResumePosition > 3 ? "Resume" : "Play"
        guard let value = VideoTitleFormatter.episodeComponents(from: item.title) else { return action }
        return String(format: "%@ E%02d", action, value.episode)
    }

    private var primaryPlayButton: some View {
        Button(action: playAndClose) {
            HStack(spacing: 10) {
                if isPreparingPlayback {
                    DetailsLoadingSpinner(size: 19, lineWidth: 2.3, color: .white)
                    Text("Preparing...")
                        .font(.system(size: 17, weight: .bold, design: .rounded))
                } else {
                    Image(systemName: "play.fill")
                        .font(.system(size: 18, weight: .bold))
                    Text(playButtonTitle)
                        .font(.system(size: 17, weight: .bold, design: .rounded))
                }
            }
            .foregroundColor(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(AppPalette.gradient, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(Color.white.opacity(0.18), lineWidth: 1)
            )
            .shadow(color: AppPalette.purple.opacity(0.34), radius: 14, y: 6)
        }
        .buttonStyle(PremiumPressButtonStyle())
        .disabled(isPreparingPlayback)
    }

    private func actionButton(
        title: String,
        icon: String,
        color: Color,
        isBusy: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 8) {
                if isBusy {
                    ProgressView()
                        .tint(color)
                        .frame(height: 22)
                } else {
                    Image(systemName: icon)
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundColor(color)
                        .frame(height: 22)
                }
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 13)
            .background(AppTheme.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color.white.opacity(0.06), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .disabled(isBusy)
    }

    private func playAndClose() {
        guard !isPreparingPlayback else { return }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        withAnimation(.easeOut(duration: 0.16)) { isPreparingPlayback = true }
        vm.preparePlaybackHistory(for: item)
        onPlay()
        if dismissOnPlay {
            dismiss()
        } else {
            // A direct stream may be ready without toggling vm.isLoading. Reset
            // the covered details screen so Play is normal after leaving player.
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 900_000_000)
                if !vm.isLoading {
                    withAnimation(.easeOut(duration: 0.18)) { isPreparingPlayback = false }
                }
            }
        }
    }

    private var currentDownload: ManagedVideoDownload? {
        downloadManager.download(forStableKey: item.id)
    }

    private var downloadButtonTitle: String {
        guard let download = currentDownload else { return "Download" }
        switch download.state {
        case .queued:
            return "Queued"
        case .downloading:
            return "\(Int((download.progress * 100).rounded()))%"
        case .paused:
            return "Resume"
        case .completed:
            return "Downloaded"
        case .failed, .cancelled:
            return "Download"
        }
    }

    private var downloadButtonIcon: String {
        guard let download = currentDownload else { return "arrow.down.to.line" }
        switch download.state {
        case .queued, .downloading:
            return "arrow.down.circle.fill"
        case .paused:
            return "play.circle.fill"
        case .completed:
            return "checkmark.circle.fill"
        case .failed, .cancelled:
            return "arrow.clockwise.circle.fill"
        }
    }

    private func startDownload() {
        if let download = currentDownload,
           download.isActive || download.state == .paused || download.state == .completed {
            showDownloadManager = true
            return
        }

        downloadManager.startDownload(
            url: item.url,
            stableKey: item.id,
            title: item.displayTitle,
            suggestedFileName: downloadSuggestedFileName,
            headers: item.httpHeaders
        )
        showDownloadManager = true
    }

    private var downloadSuggestedFileName: String {
        var name = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty { name = item.displayTitle }

        let currentExtension = (name as NSString).pathExtension.lowercased()
        if isDownloadVideoExtension(currentExtension) { return name }

        if !currentExtension.isEmpty {
            name = (name as NSString).deletingPathExtension
        }

        let itemExtension = item.fileExtension.lowercased()
        let remoteExtension = item.url.pathExtension.lowercased()
        let ext: String
        if isDownloadVideoExtension(itemExtension) {
            ext = itemExtension
        } else if isDownloadVideoExtension(remoteExtension) {
            ext = remoteExtension
        } else {
            ext = "mp4"
        }
        return (name.isEmpty ? "video" : name) + ".\(ext)"
    }

    private func isDownloadVideoExtension(_ ext: String) -> Bool {
        ["mp4", "m4v", "mov", "mkv", "avi", "webm", "wmv", "flv", "ts", "m3u8"].contains(ext.lowercased())
    }
}

// MARK: - إضافة الفيديو لقائمة تشغيل

private struct DetailsScrollOffsetObserver: UIViewRepresentable {
    @Binding var offset: CGFloat

    func makeCoordinator() -> Coordinator {
        Coordinator(offset: $offset)
    }

    func makeUIView(context: Context) -> UIView {
        let probe = UIView(frame: .zero)
        probe.isUserInteractionEnabled = false
        probe.backgroundColor = .clear
        DispatchQueue.main.async { context.coordinator.attach(from: probe) }
        return probe
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.offset = $offset
        guard !context.coordinator.isAttached else { return }
        DispatchQueue.main.async { context.coordinator.attach(from: uiView) }
    }

    static func dismantleUIView(_ uiView: UIView, coordinator: Coordinator) {
        coordinator.detach()
    }

    final class Coordinator: NSObject {
        var offset: Binding<CGFloat>
        private weak var scrollView: UIScrollView?
        private var observation: NSKeyValueObservation?
        private var attachAttempts = 0
        var isAttached: Bool { scrollView != nil }

        init(offset: Binding<CGFloat>) {
            self.offset = offset
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
            // At rest: contentOffset.y == -adjustedContentInset.top. Pulling
            // down becomes positive; scrolling content up becomes negative.
            let value = -(scrollView.contentOffset.y + scrollView.adjustedContentInset.top)
            if abs(offset.wrappedValue - value) > 0.1 {
                offset.wrappedValue = value
            }
        }
    }
}

private struct FullPosterDetailsBackdrop: View {
    let image: UIImage

    var body: some View {
        GeometryReader { proxy in
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .frame(width: proxy.size.width, height: proxy.size.height, alignment: .top)
        }
        .transaction { $0.animation = nil }
    }
}

/// A Core Animation-backed spinner used while details artwork and playback URLs
/// are prepared. Unlike the platform ProgressView it always has explicit motion.
private struct DetailsLoadingSpinner: View {
    let size: CGFloat
    let lineWidth: CGFloat
    var color: Color = AppPalette.accent
    @State private var rotating = false

    var body: some View {
        Circle()
            .trim(from: 0.08, to: 0.82)
            .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
            .frame(width: size, height: size)
            .rotationEffect(.degrees(rotating ? 360 : 0))
            .onAppear {
                rotating = false
                withAnimation(.linear(duration: 0.72).repeatForever(autoreverses: false)) {
                    rotating = true
                }
            }
            .accessibilityLabel("Loading")
    }
}

private struct EpisodeStillArtwork: View {
    let seriesID: Int?
    let season: Int
    let episode: Int
    let fallback: UIImage?
    @State private var stillURL: URL?

    var body: some View {
        ZStack {
            if let fallback {
                Image(uiImage: fallback)
                    .resizable()
                    .scaledToFill()
            }

            if let stillURL {
                CachedTMDBImage(url: stillURL, contentMode: .fill)
                    .transition(.opacity)
            }
        }
        .task(id: loadingIdentity) {
            guard let seriesID else { return }
            let details = await TMDBService.shared.episodeDetails(
                seriesID: seriesID,
                season: season,
                episode: episode
            )
            guard !Task.isCancelled else { return }
            stillURL = details?.imageURL
        }
    }

    private var loadingIdentity: String {
        "\(seriesID ?? 0)|s\(season)|e\(episode)"
    }
}

private struct CachedTMDBImage: View {
    let url: URL?
    let contentMode: ContentMode
    var placeholderSystemName: String? = nil
    @State private var image: UIImage?

    init(url: URL?, contentMode: ContentMode, placeholderSystemName: String? = nil) {
        self.url = url
        self.contentMode = contentMode
        self.placeholderSystemName = placeholderSystemName
        let cached = url.flatMap { VideoThumbnailLoader.cachedImage(forStableKey: "tmdb-remote|\($0.absoluteString)") }
        _image = State(initialValue: cached)
    }

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
            } else if let placeholderSystemName {
                Image(systemName: placeholderSystemName)
                    .resizable()
                    .scaledToFit()
                    .padding(18)
                    .foregroundStyle(.white.opacity(0.38))
            } else {
                Color.clear
            }
        }
        .task(id: url) {
            guard image == nil, let url else { return }
            let key = "tmdb-remote|\(url.absoluteString)"
            if let cached = VideoThumbnailLoader.cachedImage(forStableKey: key) {
                image = cached
                return
            }
            guard let (data, _) = try? await HighPriorityNetworkManager.shared.responsiveData(from: url),
                  let loaded = UIImage(data: data),
                  !Task.isCancelled else { return }
            VideoThumbnailLoader.cacheImage(loaded, forStableKey: key)
            image = loaded
        }
    }
}

struct PlaylistPickerView: View {
    @ObservedObject var vm: AppViewModel
    let item: VideoDetailsItem
    @Environment(\.dismiss) private var dismiss

    @State private var isCreatingNew = false
    @State private var newPlaylistName = ""
    @FocusState private var nameFieldFocused: Bool

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if isCreatingNew {
                        HStack(spacing: 10) {
                            TextField("Playlist name", text: $newPlaylistName)
                                .focused($nameFieldFocused)
                                .foregroundColor(.white)
                                .submitLabel(.done)
                                .onSubmit(createAndAdd)

                            Button("Add", action: createAndAdd)
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundColor(AppTheme.accent)
                                .disabled(newPlaylistName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                        .listRowBackground(AppTheme.card)
                    } else {
                        Button {
                            isCreatingNew = true
                            nameFieldFocused = true
                        } label: {
                            Label("New Playlist", systemImage: "plus.circle.fill")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundColor(AppTheme.accent)
                        }
                        .listRowBackground(AppTheme.card)
                    }
                }

                if !vm.playlists.isEmpty {
                    Section("Your Playlists") {
                        ForEach(vm.playlists) { playlist in
                            Button {
                                withAnimation(.easeInOut(duration: 0.15)) {
                                    vm.togglePlaylistMembership(item, playlist: playlist)
                                }
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: "text.badge.plus")
                                        .font(.system(size: 15, weight: .semibold))
                                        .foregroundColor(.purple)
                                        .frame(width: 22)

                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(playlist.name)
                                            .font(.system(size: 15, weight: .semibold))
                                            .foregroundColor(.white)
                                        Text("\(playlist.linkIDs.count) videos")
                                            .font(.system(size: 12))
                                            .foregroundColor(.white.opacity(0.4))
                                    }

                                    Spacer()

                                    Image(systemName: vm.isInPlaylist(item, playlist: playlist) ? "checkmark.circle.fill" : "circle")
                                        .font(.system(size: 20))
                                        .foregroundColor(vm.isInPlaylist(item, playlist: playlist) ? AppTheme.accent : .white.opacity(0.25))
                                }
                            }
                            .buttonStyle(.plain)
                            .listRowBackground(AppTheme.card)
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(AppTheme.bg.ignoresSafeArea())
            .navigationTitle("Add to Playlist")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .tint(AppTheme.accent)
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private func createAndAdd() {
        let name = newPlaylistName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        let playlist = vm.createPlaylist(name: name)
        vm.togglePlaylistMembership(item, playlist: playlist)
        newPlaylistName = ""
        isCreatingNew = false
        nameFieldFocused = false
    }
}

struct ImmediatePlayerLoadingView: View {
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 14) {
                DetailsLoadingSpinner(size: 42, lineWidth: 3.4, color: .white)
                Text("Loading video…")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.white.opacity(0.72))
            }
        }
        .preferredColorScheme(.dark)
    }
}
struct ResolvedPlayerScreen: View {
    @ObservedObject var vm: AppViewModel
    var episodeOptions: [PlayerEpisodeOption] = []
    var onSelectEpisode: ((String) -> Void)? = nil

    var body: some View {
        Group {
        if let url = vm.nowPlayingURL, let file = vm.nowPlaying {
            RoutedVideoPlayerView(
                url: url,
                title: file.name,
                resumeAt: vm.nowPlayingResumeAt,
                linkId: vm.nowPlayingLinkId,
                httpHeaders: vm.nowPlayingHeaders,
                episodeOptions: episodeOptions,
                onSelectEpisode: onSelectEpisode
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
        } else {
            ImmediatePlayerLoadingView()
        }
        }
        .onDisappear {
            vm.endPlaybackPresentation()
        }
    }
}



private struct QualityStripStyle {
    let prefix: String
    let emphasis: String
    let detail: String
    let badge: String
    let badgeGradient: [Color]
    let badgeForeground: Color
    let badgeShadow: Color
    let accessibility: String
}
