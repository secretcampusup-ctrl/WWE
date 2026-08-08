import SwiftUI
import UIKit
import Kingfisher

struct MainTabView: View {
    @StateObject private var vm = AppViewModel()
    @State private var selectedTab = 0
    @State private var pikPakHomeToken = 0
    @Namespace private var dockSelection

    var body: some View {
        ZStack(alignment: .bottom) {
            ContentView(vm: vm, isActive: selectedTab == 0)
                .opacity(selectedTab == 0 ? 1 : 0).allowsHitTesting(selectedTab == 0)
            OffcloudView(vm: vm)
                .opacity(selectedTab == 1 ? 1 : 0).allowsHitTesting(selectedTab == 1)
            PikPakWebDAVView(vm: vm, homeToken: pikPakHomeToken, isActive: selectedTab == 2)
                .opacity(selectedTab == 2 ? 1 : 0).allowsHitTesting(selectedTab == 2)
            MediaView(vm: vm)
                .opacity(selectedTab == 3 ? 1 : 0).allowsHitTesting(selectedTab == 3)
            PirateBayView(vm: vm)
                .opacity(selectedTab == 4 ? 1 : 0).allowsHitTesting(selectedTab == 4)

            HStack(spacing: 5) {
                dockButton("Library", "play.rectangle.fill", 0)
                dockButton("Offcloud", "cloud.fill", 1)
                dockButton("PikPak", "externaldrive.fill", 2)
                dockButton("Media", "dot.radiowaves.left.and.right", 3)
                dockButton("Torrents", "sailboat.fill", 4)
            }
            .padding(6)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(Capsule().stroke(Color.white.opacity(0.13), lineWidth: 0.7))
            .shadow(color: .black.opacity(0.38), radius: 18, y: 8)
            .padding(.horizontal, 28)
            .padding(.bottom, 1)
        }
        .animation(.easeOut(duration: 0.18), value: selectedTab)
        .ignoresSafeArea(.keyboard, edges: .bottom)
        .tint(.green)
        .preferredColorScheme(.dark)
    }

    private func dockButton(_ title: String, _ icon: String, _ tab: Int) -> some View {
        Button {
            if tab == 2, selectedTab == 2 { pikPakHomeToken &+= 1 }
            withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) { selectedTab = tab }
        } label: {
            VStack(spacing: 3) {
                Image(systemName: icon).font(.system(size: 17, weight: .semibold))
                Text(title).font(.system(size: 9, weight: .semibold))
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
// MARK: - Shared visual tokens

enum AppTheme {
    static let bg = Color(red: 0.04, green: 0.04, blue: 0.05)
    static let card = Color(red: 0.10, green: 0.10, blue: 0.12)
    static let cardElevated = Color(red: 0.13, green: 0.13, blue: 0.15)
    static let accent = Color.green
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

    static let accentGradient = LinearGradient(
        colors: [
            Color.green,
            Color(red: 0.15, green: 0.75, blue: 0.40)
        ],
        startPoint: .leading,
        endPoint: .trailing
    )
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

    var seedCount: Int { Int(seeders) ?? 0 }
    var leechCount: Int { Int(leechers) ?? 0 }
    var byteCount: Int64 { Int64(size) ?? 0 }
    var magnet: String {
        var parts = URLComponents()
        parts.scheme = "magnet"
        parts.queryItems = [
            URLQueryItem(name: "xt", value: "urn:btih:\(infoHash)"),
            URLQueryItem(name: "dn", value: name),
            URLQueryItem(name: "tr", value: "udp://tracker.opentrackr.org:1337/announce"),
            URLQueryItem(name: "tr", value: "udp://open.stealth.si:80/announce"),
            URLQueryItem(name: "tr", value: "udp://tracker.torrent.eu.org:451/announce")
        ]
        return parts.string ?? "magnet:?xt=urn:btih:\(infoHash)"
    }
}

@MainActor
private final class PirateBaySearchModel: ObservableObject {
    @Published var results: [PirateBayResult] = []
    @Published var isLoading = false
    @Published var error: String?

    func search(_ raw: String) async {
        let query = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { results = []; error = nil; return }
        isLoading = true; error = nil
        defer { isLoading = false }
        var parts = URLComponents(string: "https://apibay.org/q.php")!
        parts.queryItems = [URLQueryItem(name: "q", value: query), URLQueryItem(name: "cat", value: "0")]
        guard let url = parts.url else { error = "Invalid search"; return }
        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = 20
            request.cachePolicy = .reloadIgnoringLocalCacheData
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else { throw URLError(.badServerResponse) }
            let decoded = try JSONDecoder().decode([PirateBayResult].self, from: data)
            results = decoded.filter { $0.id != "0" && !$0.infoHash.isEmpty }.sorted { $0.seedCount > $1.seedCount }
            if results.isEmpty { error = "No results found" }
        } catch {
            results = []
            self.error = "Search service is unavailable"
        }
    }
}

private struct PirateBayView: View {
    @ObservedObject var vm: AppViewModel
    @StateObject private var model = PirateBaySearchModel()
    @State private var query = ""
    @State private var notice: String?
    @State private var addingID: String?
    @FocusState private var searchFocused: Bool

    var body: some View {
        NavigationStack {
            ZStack {
                AppTheme.bg.ignoresSafeArea()
                ScrollView {
                    LazyVStack(spacing: 12) {
                        searchBar
                        if model.isLoading { ProgressView().tint(.green).padding(.top, 40) }
                        if let error = model.error, !model.isLoading {
                            Text(error).foregroundStyle(.secondary).padding(.top, 34)
                        }
                        ForEach(model.results) { item in resultCard(item) }
                    }
                    .padding(.horizontal, 14).padding(.top, 10).padding(.bottom, 105)
                }
            }
            .navigationTitle("Torrent Search")
            .navigationBarTitleDisplayMode(.large)
            .overlay(alignment: .top) {
                if let notice { Text(notice).font(.subheadline.bold()).padding(.horizontal, 18).padding(.vertical, 10).background(.ultraThinMaterial, in: Capsule()).padding(.top, 8) }
            }
        }
    }

    private var searchBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search movies, shows, and files", text: $query)
                .textInputAutocapitalization(.never).autocorrectionDisabled().focused($searchFocused)
                .submitLabel(.search).onSubmit { Task { await model.search(query) } }
            if !query.isEmpty { Button { query = ""; model.results = [] } label: { Image(systemName: "xmark.circle.fill") }.foregroundStyle(.secondary) }
            Button { searchFocused = false; Task { await model.search(query) } } label: { Image(systemName: "arrow.right.circle.fill").font(.title2).foregroundStyle(.green) }
        }
        .padding(.horizontal, 14).padding(.vertical, 12).background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 18))
    }

    private func resultCard(_ item: PirateBayResult) -> some View {
        VStack(alignment: .leading, spacing: 11) {
            Text(item.name).font(.headline).foregroundStyle(.white).lineLimit(3)
            HStack(spacing: 12) {
                Label("\(item.seedCount)", systemImage: "arrow.up.circle.fill").foregroundStyle(.green)
                Label("\(item.leechCount)", systemImage: "arrow.down.circle.fill").foregroundStyle(.orange)
                Text(ByteCountFormatter.string(fromByteCount: item.byteCount, countStyle: .file)).foregroundStyle(.secondary)
                Spacer()
            }.font(.caption.bold())
            HStack(spacing: 10) {
                Button {
                    UIPasteboard.general.string = item.magnet; toast("Magnet copied")
                } label: { Label("Copy", systemImage: "doc.on.doc").frame(maxWidth: .infinity) }
                    .buttonStyle(.bordered).tint(.white)
                Button {
                    addingID = item.id
                    Task {
                        let error = await vm.addMagnetToPikPak(item.magnet)
                        addingID = nil; toast(error ?? "Added to PikPak")
                    }
                } label: {
                    if addingID == item.id { ProgressView().frame(maxWidth: .infinity) }
                    else { Label("Add to PikPak", systemImage: "externaldrive.badge.plus").frame(maxWidth: .infinity) }
                }
                .buttonStyle(.borderedProminent).tint(.green).disabled(addingID != nil)
            }
        }
        .padding(15).background(Color.white.opacity(0.065), in: RoundedRectangle(cornerRadius: 20))
        .overlay(RoundedRectangle(cornerRadius: 20).stroke(Color.white.opacity(0.07)))
    }

    private func toast(_ text: String) {
        notice = text
        Task { try? await Task.sleep(nanoseconds: 2_000_000_000); if notice == text { notice = nil } }
    }
}