import SwiftUI
import PhotosUI
import UIKit

struct RecentVideosView: View {
    @ObservedObject var vm: AppViewModel
    var isActive: Bool = true
    @State private var showPlayer = false
    @State private var detailShowPlayer = false
    @State private var detailLink: SavedVideoLink?
    @State private var renameTarget: SavedVideoLink?
    @State private var renameText = ""
    @State private var thumbTarget: SavedVideoLink?
    @State private var searchCoverTarget: SavedVideoLink?
    @State private var thePornDBTarget: SavedVideoLink?
    @State private var photoItem: PhotosPickerItem?
    @State private var isPhotoPickerPresented = false
    @State private var notice: String?
    @State private var isAddLinkPresented = false

    private let gridColumns = [
        GridItem(.flexible(), spacing: 10, alignment: .top),
        GridItem(.flexible(), spacing: 10, alignment: .top)
    ]

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    headerBar

                    if vm.recentLinks.isEmpty {
                        emptyState
                    } else {
                        LazyVGrid(columns: gridColumns, alignment: .center, spacing: 10) {
                            ForEach(vm.recentLinks) { link in
                                RecentVideoCard(
                                    link: link,
                                    onPlay: { detailLink = link },
                                    onRename: {
                                        renameText = link.title
                                        renameTarget = link
                                    },
                                    onChangeThumb: {
                                        photoItem = nil
                                        thumbTarget = link
                                        isPhotoPickerPresented = true
                                    },
                                    onSearchThumb: { searchCoverTarget = link },
                                    onSearchThePornDB: { thePornDBTarget = link },
                                    onRemoveThumb: { vm.clearCustomThumbnail(for: link) },
                                    onDelete: { vm.deleteSavedLink(link) }
                                )
                                .frame(maxWidth: .infinity, alignment: .top)
                            }
                        }
                        .padding(.horizontal, 10)
                    }
                }
                .padding(.top, 8)
                .padding(.bottom, 28)
            }
            .background(AppTheme.bg.ignoresSafeArea())
            .navigationTitle("Direct Links")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        isAddLinkPresented = true
                    } label: {
                        Image(systemName: "plus.circle.fill")
                    }
                    .accessibilityLabel("Add video link")
                }
            }
            .sheet(isPresented: $isAddLinkPresented) {
                AddVideoLinkSheet { raw, title in
                    if vm.saveDirectLink(raw, title: title) != nil {
                        toast("Added")
                    } else {
                        toast("Couldn't add that link")
                    }
                }
            }
            .fullScreenCover(isPresented: $showPlayer, onDismiss: {
                UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
            }) {
                if let url = vm.nowPlayingURL, let file = vm.nowPlaying {
                    RoutedVideoPlayerView(
                        url: url,
                        title: file.name,
                        resumeAt: vm.nowPlayingResumeAt,
                        linkId: vm.nowPlayingLinkId,
                        httpHeaders: vm.nowPlayingHeaders,
                    ) { seconds, duration, w, h in
                        vm.updatePlaybackProgress(
                            seconds: seconds,
                            duration: duration,
                            width: w,
                            height: h,
                            linkId: vm.nowPlayingLinkId,
                            streamURL: url
                        )
                    }
                } else {
                    ImmediatePlayerLoadingView()
                }
            }
            .fullScreenCover(item: $detailLink) { link in
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
                        onPlay: { play(link, fromDetails: true) },
                        onDelete: { vm.deleteSavedLink(link) },
                        dismissOnPlay: false
                    )
                    .fullScreenCover(isPresented: $detailShowPlayer) {
                        ResolvedPlayerScreen(vm: vm)
                    }
                } else {
                    Text("This item does not contain a playable video URL.")
                        .padding()
                }
            }
            .alert("Rename video", isPresented: Binding(
                get: { renameTarget != nil },
                set: { if !$0 { renameTarget = nil } }
            )) {
                TextField("Title", text: $renameText)
                Button("Cancel", role: .cancel) { renameTarget = nil }
                Button("Save") {
                    if let target = renameTarget {
                        vm.renameSavedLink(target, to: renameText)
                        toast("Renamed")
                    }
                    renameTarget = nil
                }
            } message: {
                Text("Choose a display name for this video.")
            }
            .photosPicker(isPresented: $isPhotoPickerPresented, selection: $photoItem, matching: .images)
            .onChange(of: photoItem) { newItem in
                guard let newItem, let target = thumbTarget else { return }
                Task {
                    if let data = try? await newItem.loadTransferable(type: Data.self),
                       let image = UIImage(data: data) {
                        await MainActor.run {
                            vm.setCustomThumbnail(image, for: target)
                            toast("Cover updated")
                        }
                    }
                    await MainActor.run {
                        photoItem = nil
                        thumbTarget = nil
                        isPhotoPickerPresented = false
                    }
                }
            }
            .sheet(item: $searchCoverTarget) { target in
                YandexImageSearchView(initialQuery: target.displayTitle) { image in
                    vm.setCustomThumbnail(image, for: target)
                    toast("Cover updated")
                    searchCoverTarget = nil
                }
            }
            .sheet(item: $thePornDBTarget) { target in
                ThePornDBSearchView(initialQuery: target.displayTitle) { image in
                    vm.setCustomThumbnail(image, for: target)
                    toast("Cover updated")
                    thePornDBTarget = nil
                }
            }
            .overlay(alignment: .bottom) {
                if let notice {
                    Text(notice)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(AppPalette.gradient, in: Capsule())
                        .padding(.bottom, 24)
                        .transition(.opacity)
                }
            }
        }
        .preferredColorScheme(.dark)
        .task(id: recentPosterPrefetchID) {
            VideoThumbnailLoader.schedulePrefetchSavedLinks(vm.recentLinks)
        }
    }

    private var recentPosterPrefetchID: [String] {
        ["active|\(isActive)"] + vm.recentLinks.map {
            "\($0.id.uuidString)|\($0.url?.absoluteString ?? "")|\($0.thumbnailFileName ?? "")|\($0.remotePosterURL ?? "")"
        }
    }

    private var headerBar: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Watch History")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.white)
                Text("Tap to play · buttons to edit")
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.4))
            }
            Spacer(minLength: 8)
            Text("\(vm.recentLinks.count)")
                .font(.system(size: 13, weight: .bold).monospacedDigit())
                .foregroundColor(AppPalette.accent)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(AppPalette.accent.opacity(0.15), in: Capsule())
                .overlay(Capsule().stroke(AppPalette.accent.opacity(0.34), lineWidth: 1))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(Color.white.opacity(0.05))
                    .frame(width: 88, height: 88)
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 36, weight: .medium))
                    .foregroundColor(.white.opacity(0.28))
            }
            Text("No recent videos")
                .font(.system(size: 17, weight: .semibold))
                .foregroundColor(.white.opacity(0.6))
            Text("Play something from Library — it will appear here as a poster card.")
                .font(.system(size: 13))
                .foregroundColor(.white.opacity(0.35))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 72)
    }

    @MainActor
    private func play(_ link: SavedVideoLink, fromDetails: Bool = false) {
        vm.nowPlaying = nil
        vm.nowPlayingURL = nil
        vm.nowPlayingHeaders = nil
        if fromDetails {
            detailShowPlayer = true
        } else {
            showPlayer = true
        }

        Task { @MainActor in
            await vm.playSavedLinkAsync(link)
            if vm.nowPlayingURL == nil {
                if fromDetails {
                    detailShowPlayer = false
                } else {
                    showPlayer = false
                }
            }
        }
    }

    private func toast(_ text: String) {
        withAnimation { notice = text }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
            withAnimation { if notice == text { notice = nil } }
        }
    }
}

struct RecentVideoCard: View {
    let link: SavedVideoLink
    let onPlay: () -> Void
    let onRename: () -> Void
    let onChangeThumb: () -> Void
    let onSearchThumb: () -> Void
    let onSearchThePornDB: () -> Void
    let onRemoveThumb: () -> Void
    let onDelete: () -> Void
    @ObservedObject private var downloadManager = VideoDownloadManager.shared

    private let posterAspect: CGFloat = 16.0 / 9.0

    // Precomputed as plain properties (not inline ternaries) so the SwiftUI
    // type-checker doesn't have to solve them as part of the giant view expression.
    private var remotePosterHeaders: [String: String] {
        link.source == .pikpak ? PikPakClient.shared.directPlaybackHeaders() : [:]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            posterButton
            titleBlock
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .contentShape(Rectangle())
        .clipped()
        .contextMenu {
            Button(action: onPlay) { Label(link.hasResumePoint ? "Resume" : "Play", systemImage: "play.fill") }
            Button(action: onRename) { Label("Rename", systemImage: "pencil") }
            Button(action: onChangeThumb) { Label("Change Cover", systemImage: "photo") }
            Button(action: onSearchThumb) { Label("Search Cover", systemImage: "magnifyingglass") }
            Button(action: onSearchThePornDB) { Label("Search ThePornDB", systemImage: "star.fill") }
            if link.thumbnailFileName != nil {
                Button(role: .destructive, action: onRemoveThumb) {
                    Label("Remove Cover", systemImage: "photo.badge.minus")
                }
            }
            Divider()
            Button(role: .destructive, action: onDelete) { Label("Delete", systemImage: "trash") }
        }
    }

    @ViewBuilder
    private var posterButton: some View {
        Button(action: onPlay) {
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
            .overlay(alignment: .bottom) { progressBar }
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
            .aspectRatio(posterAspect, contentMode: .fit)
            .overlay {
                PosterThumbnailView(
                    url: link.url,
                    remotePosterURL: link.remotePosterURL.flatMap { URL(string: $0) },
                    remotePosterHeaders: remotePosterHeaders,
                    customFileName: link.thumbnailFileName,
                    stableCacheKey: link.favoriteIdentity ?? "saved|\(link.id.uuidString)",
                    title: link.title,
                    badge: link.fileExtension
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
                    .foregroundStyle(.white, AppPalette.accent)
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
            chip("Resume", color: .orange)
                .opacity(link.hasResumePoint ? 1 : 0)
                .accessibilityHidden(!link.hasResumePoint)
            Spacer(minLength: 4)
            ResolutionBadgeView(tier: link.resolutionTier, compact: true)
        }
        .padding(8)
        .frame(height: 30, alignment: .top)
    }

    @ViewBuilder
    private var bottomBadgeRow: some View {
        HStack(alignment: .bottom, spacing: 6) {
            chip(link.fileExtension, color: sourceColor)
            Spacer(minLength: 4)
            if let duration = formatDuration(link.durationSeconds) {
                chip(duration, color: Color.black.opacity(0.65))
            } else {
                chip(" ", color: .clear)
                    .opacity(0)
                    .accessibilityHidden(true)
            }
        }
        .padding(8)
        .frame(height: 30, alignment: .bottom)
    }

    @ViewBuilder
    private var progressBar: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Rectangle().fill(Color.white.opacity(link.hasResumePoint ? 0.15 : 0))
                if link.hasResumePoint, let progress = resumeProgress {
                    Rectangle()
                        .fill(Color.orange)
                        .frame(width: max(4, geo.size.width * CGFloat(progress)))
                }
            }
        }
        .frame(height: 3)
    }

    @ViewBuilder
    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(displayTitle)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(.white)
                .lineLimit(1)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, minHeight: 26, maxHeight: 26, alignment: .topLeading)

            HStack(spacing: 6) {
                Text(relativeDate(link.lastPlayed ?? link.dateAdded))
                    .font(.system(size: 8, weight: .medium))
                    .foregroundColor(.white.opacity(0.42))
                    .lineLimit(1)
                Group {
                    if link.hasResumePoint, let pos = link.resumePositionSeconds {
                        Text("·")
                            .foregroundColor(.white.opacity(0.25))
                        Text(formatClock(pos))
                            .font(.system(size: 8, weight: .semibold).monospacedDigit())
                            .foregroundColor(.orange.opacity(0.95))
                    } else {
                        Text("· 00:00")
                            .font(.system(size: 8, weight: .semibold).monospacedDigit())
                            .opacity(0)
                    }
                }
                .lineLimit(1)
                Spacer(minLength: 0)
            }
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

    private var displayTitle: String { link.displayTitle }

    private var resumeProgress: Double? {
        guard let pos = link.resumePositionSeconds, let dur = link.durationSeconds, dur > 0 else {
            return link.hasResumePoint ? 0.35 : nil
        }
        return min(1, max(0, pos / dur))
    }

    private var currentDownload: ManagedVideoDownload? {
        downloadManager.download(for: link)
    }

    private var sourceColor: Color {
        switch link.source {
        case .webdav: return Color.orange.opacity(0.85)
        case .offcloud: return Color.cyan.opacity(0.85)
        case .hls: return Color.purple.opacity(0.85)
        case .direct: return Color.black.opacity(0.55)
        case .pikpak: return Color.blue.opacity(0.85)
        }
    }

    private func webdavHeaders(from url: URL?) -> [String: String] {
        guard let url,
              let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let user = comps.user, !user.isEmpty else { return [:] }
        let pass = comps.password ?? ""
        let b64 = Data("\(user):\(pass)".utf8).base64EncodedString()
        return [
            "Authorization": "Basic \(b64)",
            "User-Agent": "VideoPlayer/1.0 (iOS; Poster; WebDAV)",
            "Accept": "*/*"
        ]
    }

    private func relativeDate(_ date: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f.localizedString(for: date, relativeTo: Date())
    }

    private func formatDuration(_ seconds: Double?) -> String? {
        guard let seconds, seconds.isFinite, seconds > 0 else { return nil }
        return formatClock(seconds)
    }

    private func formatClock(_ seconds: Double) -> String {
        let s = max(0, Int(seconds.rounded(.down)))
        let h = s / 3600
        let m = (s % 3600) / 60
        let r = s % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, r) }
        return String(format: "%d:%02d", m, r)
    }
}

/// Small sheet for manually adding a video by URL, reachable from the "+" next to
/// the "Recent" nav title. Reuses AppViewModel.saveDirectLink for the actual save.
private struct AddVideoLinkSheet: View {
    @Environment(\.dismiss) var dismiss
    @State private var urlText = ""
    @State private var titleText = ""
    var onAdd: (_ raw: String, _ title: String?) -> Void

    var body: some View {
        NavigationView {
            Form {
                Section {
                    TextField("https://example.com/video.mp4", text: $urlText)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                        .keyboardType(.URL)
                } header: {
                    Text("Video URL")
                } footer: {
                    Text("Direct links, HLS (.m3u8), and PikPak share links are supported.")
                }

                Section(header: Text("Title (optional)")) {
                    TextField("Display name", text: $titleText)
                }
            }
            .navigationTitle("Add Video")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        let trimmedTitle = titleText.trimmingCharacters(in: .whitespacesAndNewlines)
                        onAdd(urlText, trimmedTitle.isEmpty ? nil : trimmedTitle)
                        dismiss()
                    }
                    .disabled(urlText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}

