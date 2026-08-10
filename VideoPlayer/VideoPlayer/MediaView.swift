import SwiftUI
import UIKit

// MARK: - Palette (shared with MediaSettingsView)

enum MediaPalette {
    static let bg = Color(red: 0x09 / 255, green: 0x0B / 255, blue: 0x0E / 255)
    static let card = Color(red: 0x14 / 255, green: 0x16 / 255, blue: 0x1C / 255)
    static let accent = Color(red: 0.18, green: 0.83, blue: 0.75)
    static let muted = Color.white.opacity(0.5)
    static let border = Color.white.opacity(0.08)
}

struct MediaView: View {
    @ObservedObject var vm: AppViewModel

    @State private var searchText = ""
    @State private var selectedCategory: MediaCategory = .allCategories
    @State private var feedSettings = MediaFeedStore.load()

    @State private var items: [MediaItem] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var hasSearched = false

    @State private var showSettings = false
    @State private var showPlayer = false
    @State private var toast: String?
    @State private var sendingItemID: MediaItem.ID?
    @State private var sentItemIDs: Set<MediaItem.ID> = []
    @FocusState private var searchFocused: Bool

    private var currentFeedURL: String { feedSettings.url(for: selectedCategory) }

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                searchBar
                filterRow
                content
            }
            .background(MediaPalette.bg.ignoresSafeArea())
            .navigationTitle("Media")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        showSettings = true
                    } label: {
                        Image(systemName: "gear")
                            .foregroundColor(.white)
                    }
                }
            }
            .sheet(isPresented: $showSettings) {
                MediaSettingsView(settings: feedSettings) { updated in
                    feedSettings = updated
                    MediaFeedStore.save(updated)
                }
            }
            .fullScreenCover(isPresented: $showPlayer) {
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
                }
            }
            .overlay(alignment: .bottom) {
                if let toast {
                    toastView(toast)
                        .padding(.bottom, 24)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: - Search bar

    private var searchBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundColor(MediaPalette.muted)

            TextField("Search RSS...", text: $searchText)
                .textFieldStyle(.plain)
                .foregroundColor(.white)
                .focused($searchFocused)
                .submitLabel(.search)
                .onSubmit { runSearch() }

            if !searchText.isEmpty {
                Button {
                    searchText = ""
                    searchFocused = false
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(MediaPalette.muted)
                }
            }

            Button {
                searchFocused = false
                runSearch()
            } label: {
                Text("Search")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.black)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(MediaPalette.accent, in: Capsule())
            }
        }
        .padding(12)
        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(MediaPalette.border, lineWidth: 1))
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }

    // MARK: - Filters

    private var filterRow: some View {
        HStack(spacing: 8) {
            ForEach(MediaCategory.allCases) { category in
                Button {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                        selectedCategory = category
                    }
                    runSearch()
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: category.icon)
                            .font(.system(size: 11, weight: .semibold))
                        Text(category.shortLabel)
                            .font(.system(size: 13, weight: .semibold))
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(
                        selectedCategory == category ? MediaPalette.accent : Color.white.opacity(0.06)
                    )
                    .foregroundColor(selectedCategory == category ? .black : .white)
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
    }

    // MARK: - Content states

    @ViewBuilder
    private var content: some View {
        if isLoading {
            Spacer()
            ProgressView()
                .tint(MediaPalette.accent)
            Text("Loading feed…")
                .font(.system(size: 13))
                .foregroundColor(MediaPalette.muted)
                .padding(.top, 8)
            Spacer()
        } else if let errorMessage {
            emptyState(
                systemImage: "exclamationmark.triangle",
                title: "Couldn't load feed",
                subtitle: errorMessage,
                showsSettingsButton: currentFeedURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            )
        } else if !hasSearched {
            emptyState(
                systemImage: "dot.radiowaves.left.and.right",
                title: "Search your RSS feeds",
                subtitle: feedSettings.hasAnyFeed
                    ? "Pick a category and search, or leave the box empty to browse the latest items."
                    : "Add your RSS links from the gear icon above to get started.",
                showsSettingsButton: !feedSettings.hasAnyFeed
            )
        } else if items.isEmpty {
            emptyState(
                systemImage: "magnifyingglass",
                title: "No results",
                subtitle: "Nothing matched \"\(searchText)\" in \(selectedCategory.rawValue).",
                showsSettingsButton: false
            )
        } else {
            List {
                ForEach(items) { item in
                    itemRow(item)
                        .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .refreshable { await performSearch() }
        }
    }

    private func emptyState(systemImage: String, title: String, subtitle: String, showsSettingsButton: Bool) -> some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: systemImage)
                .font(.system(size: 46))
                .foregroundColor(MediaPalette.accent.opacity(0.85))
            Text(title)
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(.white)
            Text(subtitle)
                .font(.system(size: 13))
                .foregroundColor(MediaPalette.muted)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            if showsSettingsButton {
                Button {
                    showSettings = true
                } label: {
                    Text("Add RSS Links")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.black)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 10)
                        .background(MediaPalette.accent, in: Capsule())
                }
                .padding(.top, 4)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Item row

    private func itemRow(_ item: MediaItem) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(item.displayTitle)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(.white)
                        .lineLimit(2)

                    HStack(spacing: 6) {
                        if let resolutionLabel = item.resolutionLabel {
                            badge(resolutionLabel, color: MediaPalette.accent)
                        }
                        if let seasonEpisode = item.seasonEpisodeLabel {
                            badge(seasonEpisode, color: .white.opacity(0.7))
                        }
                        if let sizeLabel = item.sizeLabel {
                            badge(sizeLabel, color: .white.opacity(0.7))
                        }
                        if let relativeDate = item.relativeDateLabel {
                            Text(relativeDate)
                                .font(.system(size: 11))
                                .foregroundColor(MediaPalette.muted)
                        }
                    }
                }
                Spacer(minLength: 0)
            }

            HStack(spacing: 10) {
                Button {
                    handlePrimaryAction(item)
                } label: {
                    HStack(spacing: 6) {
                        if sendingItemID == item.id {
                            ProgressView().tint(.black)
                                .frame(width: 14, height: 14)
                        } else if sentItemIDs.contains(item.id) {
                            Image(systemName: "checkmark")
                        } else {
                            Image(systemName: item.isMagnetOrTorrent ? "arrow.down.circle.fill" : "play.fill")
                        }
                        Text(primaryActionLabel(for: item))
                            .font(.system(size: 13, weight: .semibold))
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(sentItemIDs.contains(item.id) ? Color.white.opacity(0.2) : MediaPalette.accent, in: Capsule())
                    .foregroundColor(sentItemIDs.contains(item.id) ? .white : .black)
                }
                .disabled(sendingItemID == item.id)
                .buttonStyle(.plain)

                Button {
                    UIPasteboard.general.string = item.link
                    showToast("Link copied")
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.white)
                        .padding(8)
                        .background(Color.white.opacity(0.08), in: Circle())
                }
                .buttonStyle(.plain)

                Button {
                    openInBrowser(item.link)
                } label: {
                    Image(systemName: "safari")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.white)
                        .padding(8)
                        .background(Color.white.opacity(0.08), in: Circle())
                }
                .buttonStyle(.plain)

                Spacer()
            }
        }
        .padding(14)
        .background(MediaPalette.card, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(MediaPalette.border, lineWidth: 1))
    }

    private func badge(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .bold))
            .foregroundColor(color == MediaPalette.accent ? .black : .white)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color == MediaPalette.accent ? MediaPalette.accent : Color.white.opacity(0.1), in: Capsule())
    }

    private func toastView(_ message: String) -> some View {
        Text(message)
            .font(.system(size: 13, weight: .medium))
            .foregroundColor(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Color.black.opacity(0.85), in: Capsule())
            .overlay(Capsule().stroke(MediaPalette.border, lineWidth: 1))
    }

    // MARK: - Actions

    private func primaryActionLabel(for item: MediaItem) -> String {
        if sendingItemID == item.id { return "Sending…" }
        if sentItemIDs.contains(item.id) { return "Sent" }
        return item.isMagnetOrTorrent ? "Send to Offcloud" : "Play"
    }

    private func handlePrimaryAction(_ item: MediaItem) {
        if item.isMagnetOrTorrent {
            sendToOffcloud(item)
        } else if vm.playOnlineURL(item.link) {
            showPlayer = true
        } else {
            openInBrowser(item.link)
        }
    }

    private func sendToOffcloud(_ item: MediaItem) {
        let apiKey = OffcloudKeyStore.load()
        guard !apiKey.isEmpty else {
            showToast("Add your Offcloud API key in the Offcloud tab first.")
            return
        }
        sendingItemID = item.id
        Task {
            defer { sendingItemID = nil }
            do {
                _ = try await OffcloudClient(apiKey: apiKey).create(url: item.link)
                sentItemIDs.insert(item.id)
                showToast("Sent to Offcloud")
            } catch {
                showToast(error.localizedDescription)
            }
        }
    }

    private func openInBrowser(_ link: String) {
        guard let url = URL(string: link) else { return }
        UIApplication.shared.open(url)
    }

    private func showToast(_ message: String) {
        withAnimation { toast = message }
        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            withAnimation { toast = nil }
        }
    }

    private func runSearch() {
        Task { await performSearch() }
    }

    @MainActor
    private func performSearch() async {
        let feedURL = currentFeedURL
        guard !feedURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            hasSearched = true
            errorMessage = MediaRSSError.missingFeedURL.localizedDescription
            items = []
            return
        }

        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            let results = try await MediaRSSService.fetch(feedTemplate: feedURL, query: searchText)
            items = results
            hasSearched = true
        } catch {
            items = []
            hasSearched = true
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}
