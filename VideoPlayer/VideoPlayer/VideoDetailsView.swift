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

    @State private var frame: UIImage?
    @State private var showDownloadManager = false
    @State private var showDeleteConfirmation = false
    @State private var showDeleteUnavailable = false
    @State private var showPlaylistPicker = false
    @State private var thePornDBMetadata: VideoThumbnailLoader.ThePornDBMetadata?
    @State private var tmdbDetails: TMDBTitleDetails?
    @State private var tmdbEpisode: TMDBEpisodeDetails?

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    preview

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
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 2)
                    .padding(.bottom, 28)
                }
            }
            .background(AppTheme.bg.ignoresSafeArea())
            .ignoresSafeArea(edges: .top)
            .toolbar(.hidden, for: .navigationBar)
        }
        .preferredColorScheme(.dark)
        .task(id: item.id + "|" + item.url.absoluteString + "|" + (item.posterCacheKey ?? "")) {
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

            let detailKey = item.posterCacheKey.map { "\($0)|detail" }
            if let detailKey,
               let highResolution = VideoThumbnailLoader.cachedImage(forStableKey: detailKey) {
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
        .onReceive(NotificationCenter.default.publisher(for: VideoThumbnailLoader.stablePosterDidUpdateNotification)) { notification in
            guard let key = notification.object as? String,
                  key == item.posterCacheKey,
                  let cached = VideoThumbnailLoader.cachedImage(forStableKey: key) else { return }
            frame = cached
        }
        // ThePornDB metadata (cover + title/performers/tags/date) is the one automatic
        // lookup that's always on, independent of the poster-frame logic above — see
        // VideoThumbnailLoader.fetchThePornDBMetadata.
        .task(id: item.id) {
            let metadataKey = item.posterCacheKey ?? item.id
            tmdbDetails = VideoDetailsMemoryCache.details[metadataKey]
            tmdbEpisode = VideoDetailsMemoryCache.episodes[metadataKey]
            thePornDBMetadata = ThePornDBSettings.isEnabled
                ? VideoDetailsMemoryCache.adultMetadata[metadataKey]
                : nil
            if tmdbEpisode == nil, let value = VideoTitleFormatter.episodeComponents(from: item.title) {
                tmdbEpisode = await TMDBService.shared.episodeDetails(seriesTitle: item.title, season: value.season, episode: value.episode)
                if let tmdbEpisode { VideoDetailsMemoryCache.episodes[metadataKey] = tmdbEpisode }
                if let imageURL = tmdbEpisode?.imageURL,
                   let (data, _) = try? await HighPriorityNetworkManager.shared.responsiveData(from: imageURL),
                   let image = UIImage(data: data) {
                    frame = image
                    if let key = item.posterCacheKey { VideoThumbnailLoader.cacheImage(image, forStableKey: key) }
                }
            }
            if tmdbDetails == nil { tmdbDetails = await TMDBService.shared.details(for: item.title) }
            if let tmdbDetails { VideoDetailsMemoryCache.details[metadataKey] = tmdbDetails }
            if tmdbEpisode?.imageURL == nil, let imageURL = tmdbDetails?.imageURL,
               let (data, _) = try? await HighPriorityNetworkManager.shared.responsiveData(from: imageURL),
               let image = UIImage(data: data) {
                frame = image
                if let key = item.posterCacheKey { VideoThumbnailLoader.cacheImage(image, forStableKey: key) }
            }
            guard tmdbDetails == nil else { return }
            if ThePornDBSettings.isEnabled, thePornDBMetadata == nil {
                thePornDBMetadata = await VideoThumbnailLoader.fetchThePornDBMetadata(for: item.displayTitle)
            }
            if ThePornDBSettings.isEnabled, let thePornDBMetadata {
                VideoDetailsMemoryCache.adultMetadata[metadataKey] = thePornDBMetadata
            }
            if ThePornDBSettings.isEnabled, let cover = thePornDBMetadata?.coverImage, frame == nil {
                frame = cover
                if let key = item.posterCacheKey {
                    VideoThumbnailLoader.cacheImage(cover, forStableKey: key)
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

    private var preview: some View {
        GeometryReader { proxy in
            ZStack {
                Button(action: playAndClose) {
                    ZStack {
                        Color.white.opacity(0.06)

                        if let frame {
                            Image(uiImage: frame)
                                .resizable()
                                .scaledToFill()
                                .frame(width: proxy.size.width, height: proxy.size.height, alignment: .top)
                                .clipped()
                        } else {
                            ProgressView()
                                .controlSize(.large)
                                .tint(.white)
                        }

                        Color.black.opacity(frame == nil ? 0.10 : 0.16)

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
                informationMetric(value: item.metadataValue, label: item.metadataLabel, subtitle: tmdbEpisode?.name ?? (item.seasonEpisodeLabel == nil ? nil : VideoTitleFormatter.episodeTitle(from: item.title)))
                metricDivider
                informationMetric(value: item.fileExtension.uppercased(), label: "Format")
            }
            .frame(minHeight: 72)
        }
        .background(AppTheme.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.white.opacity(0.06), lineWidth: 1)
        )
    }

    private var seriesEpisodesSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                ZStack { Circle().fill(AppPalette.accent.opacity(0.14)); Image(systemName: "rectangle.stack.fill").foregroundStyle(AppPalette.accent) }.frame(width: 34, height: 34)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Episodes").font(.headline).foregroundStyle(.white)
                    Text("Continue watching the series").font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                Text("\(item.relatedEpisodes.count)").font(.caption.bold().monospacedDigit()).foregroundStyle(.white)
                    .padding(.horizontal, 10).padding(.vertical, 6).background(AppPalette.accent.opacity(0.18), in: Capsule())
            }
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 12) {
                        ForEach(item.relatedEpisodes) { episode in
                            let current = episode.id == item.id
                            Button { onSelectEpisode?(episode.id) } label: {
                                Text(episode.numberLabel)
                                    .font(.system(size: 12, weight: .bold, design: .rounded))
                                    .tracking(0.35)
                                    .foregroundStyle(current ? Color.white : AppPalette.accent)
                                    .frame(width: 104, height: 46)
                                    .background(
                                        current ? AnyShapeStyle(AppPalette.diagonalGradient) : AnyShapeStyle(Color.white.opacity(0.055)),
                                        in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    )
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                                            .stroke(current ? Color.white.opacity(0.24) : AppPalette.blue.opacity(0.16), lineWidth: 1)
                                    )
                                    .shadow(color: current ? AppPalette.purple.opacity(0.24) : .clear, radius: 8, y: 4)
                            }
                            .id(episode.id)
                            .buttonStyle(PremiumPressButtonStyle())
                        }
                    }.padding(.vertical, 3).padding(.horizontal, 1)
                }
                .onAppear { scrollToSelectedEpisode(using: proxy) }
                .onChange(of: item.id) { _ in scrollToSelectedEpisode(using: proxy) }
            }
        }
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
            if !details.cast.isEmpty { Text("Cast").font(.headline); ScrollView(.horizontal, showsIndicators: false) { HStack(spacing: 12) { ForEach(details.cast) { member in VStack(spacing: 6) { AsyncImage(url: member.imageURL) { image in image.resizable().scaledToFill() } placeholder: { Image(systemName: "person.crop.circle.fill").resizable().foregroundColor(.secondary) }.frame(width: 68, height: 68).clipShape(Circle()); Text(member.name).font(.caption.bold()).lineLimit(1).frame(width: 88); Text(member.character).font(.caption2).foregroundColor(.secondary).lineLimit(1).frame(width: 88) } } } } }
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
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppTheme.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.white.opacity(0.06), lineWidth: 1)
        )
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
        guard let value = VideoTitleFormatter.episodeComponents(from: item.title) else { return "Play" }
        return String(format: "Play E%02d", value.episode)
    }

    private var primaryPlayButton: some View {
        Button(action: playAndClose) {
            HStack(spacing: 10) {
                Image(systemName: "play.fill")
                    .font(.system(size: 18, weight: .bold))
                Text(playButtonTitle)
                    .font(.system(size: 17, weight: .bold, design: .rounded))
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
        .buttonStyle(.plain)
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
        onPlay()
        if dismissOnPlay { dismiss() }
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
                ProgressView()
                    .controlSize(.large)
                    .tint(.white)
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
