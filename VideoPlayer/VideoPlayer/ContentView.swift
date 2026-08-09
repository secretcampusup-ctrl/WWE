import SwiftUI
import PhotosUI
import UIKit
import WebKit
import Security

struct ContentView: View {
    @ObservedObject var vm: AppViewModel
    @ObservedObject private var downloadManager = VideoDownloadManager.shared
    var isActive: Bool = true
    @Environment(\.scenePhase) private var scenePhase
    @State private var onlineURL = ""
    @AppStorage("clipboard_access_requested") private var clipboardAccessRequested = false
    @State private var urlError: String?
    @State private var showPlayer = false
    @State private var detailShowPlayer = false
    @State private var saveNotice: String?
    @State private var isResolving = false
    @State private var showLinkActions = false
    @State private var showDownloadManager = false
    @State private var detailLink: SavedVideoLink?
    @FocusState private var urlFieldFocused: Bool

    @State private var renameTarget: SavedVideoLink?
    @State private var renameText = ""
    @State private var clipboardLink: String?
    @State private var lastClipboardOffer = ""
    @State private var showAllFavorites = false
    @State private var selectedPlaylistForSeeAll: VideoPlaylist?

    private let posterWidth: CGFloat = 128
    private let posterHeight: CGFloat = 192

    private var posterColumns: [GridItem] {
        [GridItem(.adaptive(minimum: posterWidth, maximum: posterWidth + 20), spacing: 16)]
    }

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    header

                    addLinkCard

                    if let nowPlaying = vm.nowPlaying, vm.nowPlayingURL != nil {
                        nowPlayingCard(title: nowPlaying.name)
                    }

                    recentSection

                    favoritesSection

                    ForEach(vm.playlists) { playlist in
                        playlistSection(playlist)
                    }

                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
            }
            .background(AppTheme.bg.ignoresSafeArea())
            .navigationBarHidden(true)
            .fullScreenCover(isPresented: $showPlayer, onDismiss: {
                dismissKeyboard()
            }) {
                if let url = vm.nowPlayingURL, let file = vm.nowPlaying {
                    RoutedVideoPlayerView(
                        url: url,
                        title: file.name,
                        resumeAt: vm.nowPlayingResumeAt,
                        linkId: vm.nowPlayingLinkId,
                        httpHeaders: vm.nowPlayingHeaders
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
                        onDelete: {
                            withAnimation {
                                vm.deleteSavedLink(link)
                            }
                        },
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
            .overlay {
                if vm.isLoading || isResolving {
                    ProgressView("Resolving link…")
                        .padding(20)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
            }
            .overlay(alignment: .bottom) {
                if let saveNotice {
                    Text(saveNotice)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(Color.green.opacity(0.92), in: Capsule())
                        .padding(.bottom, 24)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .alert("Rename", isPresented: Binding(
                get: { renameTarget != nil },
                set: { if !$0 { renameTarget = nil } }
            )) {
                TextField("Title", text: $renameText)
                Button("Cancel", role: .cancel) { renameTarget = nil }
                Button("Save") {
                    if let t = renameTarget {
                        vm.renameSavedLink(t, to: renameText)
                    }
                    renameTarget = nil
                }
            }
            .confirmationDialog("Link actions", isPresented: $showLinkActions, titleVisibility: .visible) {
                Button("Paste") { pasteLink() }
                Button("Copy") { UIPasteboard.general.string = onlineURL }
                Button("Edit") { urlFieldFocused = true }
                Button("Clear", role: .destructive) {
                    onlineURL = ""
                    urlError = nil
                }
                Button("Cancel", role: .cancel) { }
            }
            .simultaneousGesture(
                TapGesture().onEnded { dismissKeyboard() }
            )
        }
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showDownloadManager) {
            DownloadManagerView()
        }
        .fullScreenCover(isPresented: $showAllFavorites) {
            FavoritesAllView(vm: vm)
        }
        .fullScreenCover(item: $selectedPlaylistForSeeAll) { playlist in
            PlaylistAllView(vm: vm, playlist: playlist)
        }
        .task(id: favoritesPosterPrefetchID) {
            VideoThumbnailLoader.schedulePrefetchSavedLinks(vm.savedLinks)
        }
    }

    private var favoritesPosterPrefetchID: [String] {
        ["active|\(isActive)"] + vm.savedLinks.map {
            "\($0.id.uuidString)|\($0.url?.absoluteString ?? "")|\($0.thumbnailFileName ?? "")|\($0.remotePosterURL ?? "")"
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            HStack(spacing: 10) {
                Image(systemName: "moon.stars.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(AppTheme.accent)
                Text("Library")
                    .font(.system(size: 28, weight: .bold))
                    .foregroundStyle(AppTheme.titleGradient)
            }
            Spacer()
            Button {
                dismissKeyboard()
                showDownloadManager = true
            } label: {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundColor(AppTheme.accent)
            }
            .buttonStyle(.plain)
        }
        .padding(.top, 4)
    }

    // MARK: - Add link

    private var addLinkCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            TextField("Paste video URL…", text: $onlineURL)
                .textFieldStyle(.plain)
                .padding(.vertical, 14)
                .padding(.horizontal, 20)
                .background(Color.white.opacity(0.03), in: Capsule())
                .overlay(
                    Capsule()
                        .stroke(urlFieldFocused ? AppTheme.accent.opacity(0.55) : Color.white.opacity(0.05), lineWidth: 1)
                )
                .foregroundColor(.white)
                .autocapitalization(.none)
                .disableAutocorrection(true)
                .keyboardType(.URL)
                .focused($urlFieldFocused)
                .submitLabel(.go)

                .onSubmit { saveAndPlay() }

            if let urlError {
                Text(urlError)
                    .font(.system(size: 12))
                    .foregroundColor(.red.opacity(0.9))
                    .padding(.horizontal, 4)
            }

            HStack(spacing: 10) {
                Button(action: saveAndPlay) { Label("Play", systemImage: "play.fill").font(.system(size: 15, weight: .semibold)).frame(maxWidth: .infinity).padding(.vertical, 13).background(AppTheme.accentGradient, in: Capsule()).foregroundColor(.white) }
                    .buttonStyle(.plain).disabled(onlineURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isResolving)
                Button(action: pasteLink) { Label("Paste", systemImage: "doc.on.clipboard").font(.system(size: 15, weight: .medium)).frame(maxWidth: .infinity).padding(.vertical, 13).background(Color.white.opacity(0.03), in: Capsule()).foregroundColor(AppTheme.mutedDeep) }
                    .buttonStyle(.plain)
                Button(action: downloadEnteredLink) { Label("Download", systemImage: "arrow.down.circle.fill").font(.system(size: 14, weight: .medium)).frame(maxWidth: .infinity).padding(.vertical, 13).background(Color.white.opacity(0.03), in: Capsule()).foregroundColor(AppTheme.mutedDeep) }
                    .buttonStyle(.plain).disabled(!canDownloadEnteredLink || isResolving)
            }
        }
    }
    // MARK: - Now playing

    private func nowPlayingCard(title: String) -> some View {
        Button {
            dismissKeyboard()
            showPlayer = true
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("NOW PLAYING")
                        .font(.system(size: 11, weight: .semibold))
                        .tracking(1.5)
                        .foregroundColor(AppTheme.mutedDeep)
                    HStack(spacing: 8) {
                        Circle()
                            .fill(AppTheme.accent)
                            .frame(width: 8, height: 8)
                        Text(VideoTitleFormatter.title(from: title))
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundColor(Color(red: 0.94, green: 0.99, blue: 0.98))
                            .lineLimit(1)
                    }
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .foregroundColor(AppTheme.mutedDeep)
            }
            .padding(.vertical, 14)
            .padding(.horizontal, 20)
            .background(Color.white.opacity(0.03), in: Capsule())
            .overlay(
                Capsule().strokeBorder(
                    LinearGradient(colors: [AppTheme.accent.opacity(0.6), .clear], startPoint: .leading, endPoint: .trailing),
                    lineWidth: 2
                )
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Poster library

    private var recentSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "clock.fill").font(.system(size: 17)).foregroundColor(AppTheme.accent)
                Text("Recent").font(.system(size: 20, weight: .semibold)).foregroundColor(Color(red: 0.8, green: 0.96, blue: 0.92))
                Spacer()
            }
            if vm.recentLinks.isEmpty {
                Text("No recently played videos").font(.system(size: 13, weight: .medium)).foregroundColor(.white.opacity(0.38)).frame(maxWidth: .infinity).padding(.vertical, 22)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 14) {
                        ForEach(Array(vm.recentLinks.prefix(12))) { link in
                            MoviePosterCard(link: link, width: 112, height: 168) {
                                dismissKeyboard(); detailLink = link
                            } onSetThumbnail: { vm.setCustomThumbnail($0, for: link) }
                            onClearThumbnail: { vm.clearCustomThumbnail(for: link) }
                            onRename: { renameText = link.title; renameTarget = link }
                            onDelete: { vm.deleteSavedLink(link) }
                        }
                    }.padding(.vertical, 2).padding(.trailing, 4)
                }
            }
        }
    }
    private var favoritesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "star.fill")
                    .font(.system(size: 17))
                    .foregroundColor(AppTheme.accent)
                Text("Favorites")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundColor(Color(red: 0.8, green: 0.96, blue: 0.92))
                Spacer()
                if !vm.favoriteLinks.isEmpty {
                    Button {
                        dismissKeyboard()
                        showAllFavorites = true
                    } label: {
                        Text("See All")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(AppTheme.accent)
                    }
                    .buttonStyle(.plain)
                }
            }
            .contentShape(Rectangle())

            if vm.favoriteLinks.isEmpty {
                Text("No favorite videos")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.white.opacity(0.38))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 22)
            } else {
                // صف أفقي بمقاس البوسترات نفسه، بنفس أسلوب "Picks of the Day"
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 14) {
                        ForEach(vm.favoriteLinks) { link in
                            MoviePosterCard(
                                link: link,
                                width: 112,
                                height: 168
                            ) {
                                dismissKeyboard()
                                detailLink = link
                            } onSetThumbnail: { image in
                                vm.setCustomThumbnail(image, for: link)
                            } onClearThumbnail: {
                                vm.clearCustomThumbnail(for: link)
                            } onRename: {
                                renameText = link.title
                                renameTarget = link
                            } onDelete: {
                                vm.deleteSavedLink(link)
                            }
                        }
                    }
                    .padding(.vertical, 2)
                    .padding(.trailing, 4)
                }
            }
        }
    }

    // MARK: - قسم قائمة تشغيل واحدة (نفس أسلوب عرض المفضلة Connectedاماً)

    private func playlistSection(_ playlist: VideoPlaylist) -> some View {
        let links = vm.links(in: playlist)
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "text.badge.plus")
                    .font(.system(size: 17))
                    .foregroundColor(AppTheme.accent)
                Text(playlist.name)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundColor(Color(red: 0.8, green: 0.96, blue: 0.92))
                    .lineLimit(1)
                Spacer()
                if !links.isEmpty {
                    Button {
                        dismissKeyboard()
                        selectedPlaylistForSeeAll = playlist
                    } label: {
                        Text("See All")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(AppTheme.accent)
                    }
                    .buttonStyle(.plain)
                }
            }
            .contentShape(Rectangle())

            if links.isEmpty {
                Text("No videos in this playlist yet")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.white.opacity(0.38))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 22)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 14) {
                        ForEach(links) { link in
                            MoviePosterCard(
                                link: link,
                                width: 112,
                                height: 168
                            ) {
                                dismissKeyboard()
                                detailLink = link
                            } onSetThumbnail: { image in
                                vm.setCustomThumbnail(image, for: link)
                            } onClearThumbnail: {
                                vm.clearCustomThumbnail(for: link)
                            } onRename: {
                                renameText = link.title
                                renameTarget = link
                            } onDelete: {
                                vm.removeLink(link, from: playlist)
                            }
                        }
                    }
                    .padding(.vertical, 2)
                    .padding(.trailing, 4)
                }
            }
        }
    }

    private var librarySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("My Library")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundColor(.white)
                Spacer()
                Text("\(vm.savedLinks.count) saved")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.white.opacity(0.4))
            }

            if vm.savedLinks.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "rectangle.stack.badge.play")
                        .font(.system(size: 40))
                        .foregroundColor(.white.opacity(0.25))
                    Text("No saved links yet")
                        .font(.headline)
                        .foregroundColor(.white.opacity(0.5))
                    Text("Paste any streamable link — it is saved right away.")
                        .font(.footnote)
                        .foregroundColor(.white.opacity(0.35))
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 36)
            } else {
                LazyVGrid(columns: posterColumns, spacing: 18) {
                    ForEach(vm.savedLinks) { link in
                        MoviePosterCard(
                            link: link,
                            width: posterWidth,
                            height: posterHeight
                        ) {
                            dismissKeyboard()
                            detailLink = link
                        } onSetThumbnail: { image in
                            vm.setCustomThumbnail(image, for: link)
                        } onClearThumbnail: {
                            vm.clearCustomThumbnail(for: link)
                        } onRename: {
                            renameText = link.title
                            renameTarget = link
                        } onDelete: {
                            withAnimation {
                                vm.deleteSavedLink(link)
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Actions

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

    private func dismissKeyboard() {
        urlFieldFocused = false
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }

    private var canDownloadEnteredLink: Bool {
        let value = onlineURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, let url = LinkResolver.normalizeToURL(value) else { return false }
        return LinkResolver.isPlayableHTTPURL(url)
    }

    private func pasteLink() {
        // iOS owns the paste permission prompt. Reading only from this explicit
        // user action makes the system remember the user's choice.
        clipboardAccessRequested = true
        guard let text = UIPasteboard.general.string?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            urlError = "Clipboard is empty or paste access was denied"
            return
        }
        onlineURL = text
        urlError = nil
        dismissKeyboard()
    }

    private func downloadEnteredLink() {
        let raw = onlineURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canDownloadEnteredLink else {
            urlError = "Paste a valid http(s) video link"
            return
        }
        dismissKeyboard()
        isResolving = true
        urlError = nil

        Task { @MainActor in
            defer { isResolving = false }
            do {
                let sourceURL: URL
                let title: String
                if LinkResolver.isTwitterStatusURL(raw) {
                    let twitter = try await LinkResolver.resolveTwitterVideo(raw)
                    sourceURL = twitter.url
                    title = twitter.title
                } else if let url = LinkResolver.normalizeToURL(raw) {
                    sourceURL = url
                    let candidate = url.deletingPathExtension().lastPathComponent
                    title = candidate.isEmpty || candidate == "/" ? "Video" : candidate
                } else {
                    throw URLError(.badURL)
                }

                downloadManager.startDownload(
                    url: sourceURL,
                    stableKey: "user-download|\(raw)",
                    title: title,
                    suggestedFileName: title + ".mp4",
                    headers: [:]
                )
                onlineURL = ""
                showDownloadManager = true
            } catch {
                urlError = error.localizedDescription
            }
        }
    }

    private func saveLinkOnly() {
        dismissKeyboard()
        urlError = nil
        let raw = onlineURL
        let kind = LinkResolver.classify(raw)
        if kind == .magnet || kind == .pikpakMagnet {
            if vm.saveDirectLink(raw, source: .pikpak, title: "Magnet link") != nil {
                onlineURL = ""
                showSavedToast("Magnet saved")
            } else {
                urlError = "Could not save magnet"
            }
            return
        }

        if kind == .pikpakShare {
            if vm.saveDirectLink(raw, source: .pikpak, title: "PikPak Share") != nil {
                onlineURL = ""
                showSavedToast("PikPak share saved")
            } else {
                urlError = "Invalid PikPak share link"
            }
            return
        }

        if kind == .pikpakDirect {
            let title = LinkResolver.pikpakDirectDisplayTitle(raw)
            let stream = LinkResolver.resolvePikPakDirectStream(raw)
            if vm.saveDirectLink(raw, resolvedStream: stream, source: .pikpak, title: title) != nil {
                onlineURL = ""
                showSavedToast("PikPak direct saved")
            } else {
                urlError = "Could not save PikPak direct link"
            }
            return
        }

        if vm.saveDirectLink(raw) != nil {
            onlineURL = ""
            showSavedToast("Saved to library")
        } else {
            urlError = "Invalid link. Use http(s), m3u8, PikPak, or magnet."
        }
    }

    private func saveAndPlay() {
        dismissKeyboard()
        urlError = nil
        isResolving = true
        let raw = onlineURL
        Task {
            let err = await vm.openUserLink(raw)
            await MainActor.run {
                isResolving = false
                dismissKeyboard()
                if let err {
                    urlError = err
                } else {
                    onlineURL = ""
                    showSavedToast("Saved · Ready")
                    if vm.nowPlayingURL != nil {
                        showPlayer = true
                    }
                }
            }
        }
    }

    private func showSavedToast(_ text: String) {
        withAnimation {
            saveNotice = text
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
            withAnimation {
                if saveNotice == text { saveNotice = nil }
            }
        }
    }
}

// MARK: - Medium movie poster card

struct MoviePosterCard: View {
    let link: SavedVideoLink
    let width: CGFloat
    let height: CGFloat
    let onPlay: () -> Void
    var onSetThumbnail: ((UIImage) -> Void)? = nil
    var onClearThumbnail: (() -> Void)? = nil
    var onRename: (() -> Void)? = nil
    let onDelete: () -> Void
    @ObservedObject private var downloadManager = VideoDownloadManager.shared
    @State private var selectedThumbnail: PhotosPickerItem?
    @State private var isChoosingThumbnail = false
    @State private var isSearchingForCover = false
    @State private var isSearchingThePornDB = false

    var body: some View {
        Button(action: onPlay) {
            VStack(alignment: .leading, spacing: 8) {
                ZStack(alignment: .topTrailing) {
                    PosterThumbnailView(
                        url: link.url,
                        remotePosterURL: link.remotePosterURL.flatMap { URL(string: $0) },
                        customFileName: link.thumbnailFileName,
                        stableCacheKey: link.favoriteIdentity ?? "saved|\(link.id.uuidString)",
                        title: link.title,
                        badge: link.fileExtension
                    )
                    .frame(width: width, height: height)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(Color.white.opacity(0.08), lineWidth: 1)
                    )
                    .shadow(color: .black.opacity(0.45), radius: 8, y: 4)

                    Image(systemName: "play.circle.fill")
                        .font(.system(size: 28))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, AppTheme.accent.opacity(0.9))
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                        .opacity(0.9)

                    VStack {
                        HStack {
                            Text(link.fileSizeLabel)
                                .font(.system(size: 9, weight: .bold))
                                .foregroundColor(.white)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 3)
                                .background(Color.orange.opacity(0.9), in: Capsule())
                            Spacer()
                            ResolutionBadgeView(tier: link.resolutionTier, compact: true)
                        }
                        .padding(8)
                        Spacer()
                        HStack {
                            Text(link.fileExtension)
                                .font(.system(size: 9, weight: .bold))
                                .foregroundColor(.white)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 3)
                                .background(sourceColor.opacity(0.85), in: Capsule())
                            Spacer()
                        }
                        .padding(8)
                    }

                    if let currentDownload {
                        VideoDownloadStateOverlay(download: currentDownload)
                            .frame(width: width, height: height)
                    }
                }
                .frame(width: width, height: height)

                Text(link.displayTitle)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white)
                    .lineLimit(1)
                    .frame(width: width, alignment: .leading)

                HStack(spacing: 4) {
                    Text(link.hostLabel)
                        .font(.system(size: 10))
                        .foregroundColor(.white.opacity(0.4))
                        .lineLimit(1)
                    if link.hasResumePoint, let pos = link.resumePositionSeconds {
                        Text("· \(formatResume(pos))")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(.orange.opacity(0.9))
                    }
                }
                .frame(width: width, alignment: .leading)
            }
        }
        .frame(width: width, alignment: .leading)
        .contentShape(Rectangle())
        .clipped()
        .buttonStyle(.plain)
        .contextMenu {
            Button { onPlay() } label: {
                Label(link.hasResumePoint ? "Resume" : "Play", systemImage: "play.fill")
            }
            if let onRename {
                Button { onRename() } label: {
                    Label("Rename", systemImage: "pencil")
                }
            }
            if onSetThumbnail != nil {
                Button {
                    isChoosingThumbnail = true
                } label: {
                    Label("Choose Cover Image", systemImage: "photo.on.rectangle")
                }
                Button {
                    isSearchingForCover = true
                } label: {
                    Label("Search Cover Images", systemImage: "magnifyingglass")
                }
                Button {
                    isSearchingThePornDB = true
                } label: {
                    Label("Search ThePornDB", systemImage: "star.fill")
                }
            }
            if link.thumbnailFileName != nil, let onClearThumbnail {
                Button(role: .destructive) { onClearThumbnail() } label: {
                    Label("Remove Cover Image", systemImage: "photo.badge.minus")
                }
            }
            Button(role: .destructive) { onDelete() } label: {
                Label("Delete", systemImage: "trash")
            }
        }
        .photosPicker(isPresented: $isChoosingThumbnail, selection: $selectedThumbnail, matching: .images)
        .sheet(isPresented: $isSearchingForCover) {
            YandexImageSearchView(initialQuery: link.displayTitle) { image in
                onSetThumbnail?(image)
                isSearchingForCover = false
            }
        }
        .sheet(isPresented: $isSearchingThePornDB) {
            ThePornDBSearchView(initialQuery: link.displayTitle) { image in
                onSetThumbnail?(image)
                isSearchingThePornDB = false
            }
        }
        .onChange(of: selectedThumbnail) { item in
            Task {
                guard let item,
                      let data = try? await item.loadTransferable(type: Data.self),
                      let image = UIImage(data: data) else { return }
                await MainActor.run {
                    onSetThumbnail?(image)
                    selectedThumbnail = nil
                }
            }
        }
    }

    private func formatResume(_ seconds: Double) -> String {
        let s = Int(seconds)
        let m = s / 60
        let r = s % 60
        if m >= 60 {
            return String(format: "%d:%02d:%02d", m / 60, m % 60, r)
        }
        return String(format: "%d:%02d", m, r)
    }

    private var currentDownload: ManagedVideoDownload? {
        downloadManager.download(for: link)
    }

    private var sourceColor: Color {
        switch link.source {
        case .pikpak: return .blue
        case .webdav: return .orange
        case .offcloud: return .cyan
        case .hls: return .purple
        case .direct: return .black
        }
    }
}

// MARK: - Favorites "See All" full-screen grid

struct FavoritesAllView: View {
    @ObservedObject var vm: AppViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var detailLink: SavedVideoLink?
    @State private var showPlayer = false
    @State private var detailShowPlayer = false
    @State private var renameTarget: SavedVideoLink?
    @State private var renameText = ""

    /// عمودان بالضبط — كل سطر يعرض بوسترين Connectedامًا كما هو مطلوب
    private let columns: [GridItem] = [
        GridItem(.flexible(), spacing: 16),
        GridItem(.flexible(), spacing: 16)
    ]

    var body: some View {
        NavigationView {
            ScrollView {
                if vm.favoriteLinks.isEmpty {
                    Text("No favorite videos")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.white.opacity(0.4))
                        .padding(.top, 80)
                } else {
                    LazyVGrid(columns: columns, spacing: 22) {
                        ForEach(vm.favoriteLinks) { link in
                            MoviePosterCard(
                                link: link,
                                width: (UIScreen.main.bounds.width - 16 * 2 - 16) / 2,
                                height: ((UIScreen.main.bounds.width - 16 * 2 - 16) / 2) * 1.5
                            ) {
                                detailLink = link
                            } onSetThumbnail: { image in
                                vm.setCustomThumbnail(image, for: link)
                            } onClearThumbnail: {
                                vm.clearCustomThumbnail(for: link)
                            } onRename: {
                                renameText = link.title
                                renameTarget = link
                            } onDelete: {
                                vm.deleteSavedLink(link)
                            }
                        }
                    }
                    .padding(16)
                }
            }
            .background(AppTheme.bg.ignoresSafeArea())
            .navigationTitle("Favorites")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close") { dismiss() }
                        .tint(AppTheme.accent)
                }
            }
        }
        .preferredColorScheme(.dark)
        .fullScreenCover(isPresented: $showPlayer) {
            if let url = vm.nowPlayingURL, let file = vm.nowPlaying {
                RoutedVideoPlayerView(
                    url: url,
                    title: file.name,
                    resumeAt: vm.nowPlayingResumeAt,
                    linkId: vm.nowPlayingLinkId,
                    httpHeaders: vm.nowPlayingHeaders
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
                    onDelete: {
                        withAnimation {
                            vm.deleteSavedLink(link)
                        }
                    },
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
        .alert("Rename", isPresented: Binding(
            get: { renameTarget != nil },
            set: { if !$0 { renameTarget = nil } }
        )) {
            TextField("Title", text: $renameText)
            Button("Cancel", role: .cancel) { renameTarget = nil }
            Button("Save") {
                if let t = renameTarget {
                    vm.renameSavedLink(t, to: renameText)
                }
                renameTarget = nil
            }
        }
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
}

// MARK: - "See All" لقائمة تشغيل واحدة (نفس تصميم شاشة المفضلة Connectedاماً)

struct PlaylistAllView: View {
    @ObservedObject var vm: AppViewModel
    let playlist: VideoPlaylist
    @Environment(\.dismiss) private var dismiss

    @State private var detailLink: SavedVideoLink?
    @State private var showPlayer = false
    @State private var detailShowPlayer = false
    @State private var renameTarget: SavedVideoLink?
    @State private var renameText = ""
    @State private var isRenamingPlaylist = false
    @State private var playlistNameText = ""
    @State private var showDeletePlaylistConfirmation = false

    /// عمودان بالضبط — كل سطر يعرض بوسترين Connectedامًا كما هو مطلوب
    private let columns: [GridItem] = [
        GridItem(.flexible(), spacing: 16),
        GridItem(.flexible(), spacing: 16)
    ]

    private var links: [SavedVideoLink] { vm.links(in: playlist) }

    var body: some View {
        NavigationView {
            ScrollView {
                if links.isEmpty {
                    Text("No videos in this playlist yet")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.white.opacity(0.4))
                        .padding(.top, 80)
                } else {
                    LazyVGrid(columns: columns, spacing: 22) {
                        ForEach(links) { link in
                            MoviePosterCard(
                                link: link,
                                width: (UIScreen.main.bounds.width - 16 * 2 - 16) / 2,
                                height: ((UIScreen.main.bounds.width - 16 * 2 - 16) / 2) * 1.5
                            ) {
                                detailLink = link
                            } onSetThumbnail: { image in
                                vm.setCustomThumbnail(image, for: link)
                            } onClearThumbnail: {
                                vm.clearCustomThumbnail(for: link)
                            } onRename: {
                                renameText = link.title
                                renameTarget = link
                            } onDelete: {
                                vm.removeLink(link, from: playlist)
                            }
                        }
                    }
                    .padding(16)
                }
            }
            .background(AppTheme.bg.ignoresSafeArea())
            .navigationTitle(playlist.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close") { dismiss() }
                        .tint(AppTheme.accent)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            playlistNameText = playlist.name
                            isRenamingPlaylist = true
                        } label: {
                            Label("Rename Playlist", systemImage: "pencil")
                        }
                        Button(role: .destructive) {
                            showDeletePlaylistConfirmation = true
                        } label: {
                            Label("Delete Playlist", systemImage: "trash")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .foregroundColor(AppTheme.accent)
                    }
                }
            }
        }
        .preferredColorScheme(.dark)
        .fullScreenCover(isPresented: $showPlayer) {
            if let url = vm.nowPlayingURL, let file = vm.nowPlaying {
                RoutedVideoPlayerView(
                    url: url,
                    title: file.name,
                    resumeAt: vm.nowPlayingResumeAt,
                    linkId: vm.nowPlayingLinkId,
                    httpHeaders: vm.nowPlayingHeaders
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
                    onDelete: {
                        withAnimation {
                            vm.removeLink(link, from: playlist)
                        }
                    },
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
        .alert("Rename Video", isPresented: Binding(
            get: { renameTarget != nil },
            set: { if !$0 { renameTarget = nil } }
        )) {
            TextField("Title", text: $renameText)
            Button("Cancel", role: .cancel) { renameTarget = nil }
            Button("Save") {
                if let t = renameTarget {
                    vm.renameSavedLink(t, to: renameText)
                }
                renameTarget = nil
            }
        }
        .alert("Rename Playlist", isPresented: $isRenamingPlaylist) {
            TextField("Playlist name", text: $playlistNameText)
            Button("Cancel", role: .cancel) {}
            Button("Save") {
                vm.renamePlaylist(playlist, to: playlistNameText)
            }
        }
        .alert("Delete playlist?", isPresented: $showDeletePlaylistConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                vm.deletePlaylist(playlist)
                dismiss()
            }
        } message: {
            Text("This only deletes the playlist — the videos stay in your library.")
        }
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
}

// MARK: - In-app cover image search

struct CoverImageSearchView: View {
    let onPick: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var query: String
    @State private var results: [CoverSearchResult] = []
    @State private var isSearching = false
    @State private var isSelecting = false
    @State private var message: String?
    @State private var searchTask: Task<Void, Never>?

    init(initialQuery: String, onPick: @escaping (UIImage) -> Void) {
        _query = State(initialValue: initialQuery)
        self.onPick = onPick
    }

    private let columns = [GridItem(.adaptive(minimum: 105), spacing: 10)]

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                HStack(spacing: 8) {
                    TextField("Search images", text: $query)
                        .textFieldStyle(.roundedBorder)
                        .submitLabel(.search)
                        .onSubmit { startSearch() }
                    Button(action: startSearch) {
                        Image(systemName: "magnifyingglass").frame(width: 38, height: 38)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .padding(.horizontal)

                if isSearching {
                    ProgressView("Searching images").frame(maxHeight: .infinity)
                } else if let message {
                    emptySearchState(title: "No images", message: message, icon: "photo")
                } else if results.isEmpty {
                    emptySearchState(title: "Search for a cover", message: nil, icon: "magnifyingglass")
                } else {
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 10) {
                            ForEach(results) { result in
                                Button { select(result) } label: {
                                    YandexPreviewImage(url: result.url)
                                        .frame(height: 150)
                                        .frame(maxWidth: .infinity)
                                        .clipped()
                                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                                }
                                .buttonStyle(.plain)
                                .disabled(isSelecting)
                            }
                        }
                        .padding(.horizontal).padding(.bottom)
                    }
                }
            }
            .navigationTitle("Search cover")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Cancel") { dismiss() } }
                if isSelecting { ToolbarItem(placement: .topBarTrailing) { ProgressView() } }
            }
            .onAppear { startSearch() }
            .onDisappear { searchTask?.cancel() }
        }
    }

    private func startSearch() {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        searchTask?.cancel()
        searchTask = Task { await searchYandex(for: text) }
    }

    private func searchYandex(for text: String) async {
        isSearching = true
        message = nil
        defer { isSearching = false }
        var parts = URLComponents(string: "https://yandex.com/images/search")!
        parts.queryItems = [URLQueryItem(name: "text", value: text)]
        guard let url = parts.url else { return }
        do {
            var request = URLRequest(url: url)
            request.setValue("Mozilla/5.0 (iPhone)", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await HighPriorityNetworkManager.shared.responsiveData(for: request)
            guard !Task.isCancelled else { return }
            guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode,
                  let page = String(data: data, encoding: .utf8) else {
                results = []; message = "Search did not return images."; return
            }
            let patterns = [
                #"(?:original|preview)\"?\s*:\s*(?:\[\s*)?\{?\s*\"?url\"?\s*:\s*\"([^\"]+)\""#,
                #"(https?:(?:\\/|/)[^\"''\\\s<>]+\.(?:jpg|jpeg|png|webp)[^\"''\\\s<>]*)"#
            ]
            var seen = Set<String>()
            var found: [CoverSearchResult] = []
            for pattern in patterns {
                let regex = try NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
                let range = NSRange(page.startIndex..., in: page)
                for match in regex.matches(in: page, range: range) {
                    let capture = match.numberOfRanges > 1 ? match.range(at: 1) : match.range
                    guard let swiftRange = Range(capture, in: page) else { continue }
                    let raw = String(page[swiftRange])
                        .replacingOccurrences(of: "\\/", with: "/")
                        .replacingOccurrences(of: "\\u002F", with: "/")
                        .replacingOccurrences(of: "&amp;", with: "&")
                    guard !raw.contains("yandex.com/images/search"),
                          let imageURL = URL(string: raw), seen.insert(raw).inserted else { continue }
                    found.append(CoverSearchResult(id: raw, url: imageURL))
                    if found.count == 48 { break }
                }
                if found.count == 48 { break }
            }
            results = found
            if results.isEmpty { message = "No images found. Try another name." }
        } catch {
            guard !Task.isCancelled else { return }
            results = []; message = "Could not search now. Check the internet and try again."
        }
    }

    private func select(_ result: CoverSearchResult) {
        isSelecting = true
        Task {
            defer { isSelecting = false }
            let targetSize = ThumbnailPipeline.targetPointSize(for: .large)
            guard let image = await VideoThumbnailLoader.downloadRemoteImage(
                from: result.url,
                maxRetries: 2,
                targetPointSize: targetSize
            ) else { message = "Could not download this image."; return }
            onPick(image)
            dismiss()
        }
    }

    private func emptySearchState(title: String, message: String?, icon: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: icon).font(.system(size: 34)).foregroundColor(.secondary)
            Text(title).font(.headline)
            if let message { Text(message).font(.subheadline).foregroundColor(.secondary).multilineTextAlignment(.center) }
        }.padding(24).frame(maxHeight: .infinity)
    }
}

private struct YandexPreviewImage: View {
    let url: URL
    @State private var image: UIImage?
    @State private var failed = false

    var body: some View {
        GeometryReader { proxy in
            Group {
                if let image { Image(uiImage: image).resizable().scaledToFill() }
                else if failed { Color.gray.opacity(0.25) }
                else { ProgressView() }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .clipped()
            .task(id: "\(url.absoluteString)|\(Int(proxy.size.width))x\(Int(proxy.size.height))") {
                let targetSize = CGSize(
                    width: max(proxy.size.width, 1),
                    height: max(proxy.size.height, 1)
                )
                // Up to 48 of these cells can exist in the results grid; without
                // this gate every visible cell fires its own download the moment
                // it appears — same burst pattern that was crashing PikPak/Offcloud.
                await ThumbnailLoadGate.shared.acquire()
                defer { Task { await ThumbnailLoadGate.shared.release() } }
                guard !Task.isCancelled else { return }
                guard let loaded = await VideoThumbnailLoader.downloadRemoteImage(
                    from: url,
                    maxRetries: 2,
                    targetPointSize: targetSize
                ) else {
                    failed = true
                    return
                }
                image = loaded
            }
        }
    }
}
private struct CoverSearchResult: Identifiable {
    let id: String
    let url: URL
}

private struct PAPISearchResponse: Decodable {
    let results: [Person]

    struct Person: Decodable {
        let slug: String
        let images: [Image]
    }

    struct Image: Decodable {
        let image: String?
        let imageLink: String?

        enum CodingKeys: String, CodingKey {
            case image
            case imageLink = "image_link"
        }
    }
}

private enum CoverSearchKeyStore {
    private static let service = "com.mortaza.minoz.cover-search"
    private static let account = "access-key"

    static func read() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func save(_ value: String) {
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
        let item = query.merging([
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]) { _, new in new }
        SecItemAdd(item as CFDictionary, nil)
    }
}

// MARK: - Yandex image search

struct YandexImageSearchView: View {
    let onPick: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var query: String
    @State private var submittedQuery: String
    @State private var isLoadingImage = false
    @State private var message: String?

    init(initialQuery: String, onPick: @escaping (UIImage) -> Void) {
        _query = State(initialValue: initialQuery)
        _submittedQuery = State(initialValue: initialQuery)
        self.onPick = onPick
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 10) {
                HStack(spacing: 8) {
                    TextField("Search or paste image URL", text: $query)
                        .textFieldStyle(.roundedBorder)
                        .submitLabel(.search)
                        .onSubmit { search() }
                    Button(action: search) {
                        Image(systemName: "magnifyingglass")
                            .frame(width: 38, height: 38)
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding(.horizontal)

                YandexImageWebView(query: submittedQuery) { url in
                    pickImage(from: url)
                }
                .overlay {
                    if isLoadingImage {
                        ProgressView("Loading image…")
                            .padding()
                            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
                    }
                }

                if let message {
                    Text(message)
                        .font(.footnote)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }
            }
            .navigationTitle("Cover Image")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close") { dismiss() }
                }
            }
        }
    }

    private func search() {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        if let url = URL(string: text),
           let scheme = url.scheme?.lowercased(),
           scheme == "http" || scheme == "https" {
            pickImage(from: url)
            return
        }

        message = nil
        submittedQuery = text
    }

    private func pickImage(from url: URL) {
        guard !isLoadingImage else { return }
        isLoadingImage = true
        message = nil
        Task { @MainActor in
            defer { isLoadingImage = false }
            let targetSize = ThumbnailPipeline.targetPointSize(for: .large)
            guard let image = await VideoThumbnailLoader.downloadRemoteImage(
                from: url,
                maxRetries: 2,
                targetPointSize: targetSize
            ) else {
                message = "Could not load this image."
                return
            }
            onPick(image)
            dismiss()
        }
    }
}

private struct YandexImageWebView: UIViewRepresentable {
    let query: String
    let onImageTap: (URL) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onImageTap: onImageTap) }

    func makeUIView(context: Context) -> WKWebView {
        let controller = WKUserContentController()
        controller.add(context.coordinator, name: "coverImage")
        controller.addUserScript(WKUserScript(
            source: """
            document.addEventListener('click', function(event) {
              var image = event.target.closest('img');
              if (!image) return;
              var address = image.currentSrc || image.src;
              if (!address || address.indexOf('data:') === 0) return;
              window.webkit.messageHandlers.coverImage.postMessage(address);
              event.preventDefault();
              event.stopPropagation();
            }, true);
            """,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        ))

        let settings = WKWebViewConfiguration()
        settings.userContentController = controller
        let webView = WKWebView(frame: .zero, configuration: settings)
        webView.allowsBackForwardNavigationGestures = true
        context.coordinator.load(query: query, in: webView)
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.onImageTap = onImageTap
        context.coordinator.load(query: query, in: webView)
    }

    static func dismantleUIView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "coverImage")
    }

    final class Coordinator: NSObject, WKScriptMessageHandler {
        var onImageTap: (URL) -> Void
        private var loadedQuery = ""

        init(onImageTap: @escaping (URL) -> Void) {
            self.onImageTap = onImageTap
        }

        func load(query: String, in webView: WKWebView) {
            guard !query.isEmpty, query != loadedQuery else { return }
            loadedQuery = query
            var parts = URLComponents(string: "https://yandex.com/images/search")!
            parts.queryItems = [URLQueryItem(name: "text", value: query)]
            if let url = parts.url { webView.load(URLRequest(url: url)) }
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.name == "coverImage",
                  let raw = message.body as? String,
                  let url = URL(string: raw),
                  url.scheme == "https" || url.scheme == "http" else { return }
            onImageTap(url)
        }
    }
}

// MARK: - Server row (shared)

struct ServerRow: View {
    let server: WebDAVServer
    @ObservedObject var vm: AppViewModel

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(server.isConnected
                        ? Color(red: 0.04, green: 0.2, blue: 0.08)
                        : Color(red: 0.2, green: 0.1, blue: 0.02))
                    .frame(width: 36, height: 36)
                Image(systemName: "server.rack")
                    .foregroundColor(server.isConnected ? .green : .orange)
                    .font(.system(size: 16))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(server.name)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.white)
                Text(server.displayAddress)
                    .font(.system(size: 11))
                    .foregroundColor(.gray)
            }
            Spacer()
            Text(server.isConnected ? "Connected" : "Offline")
                .font(.system(size: 11))
                .foregroundColor(server.isConnected ? .green : .orange)
        }
        .padding(.vertical, 2)
    }
}

