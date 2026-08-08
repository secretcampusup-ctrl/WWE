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
            PirateBayView(vm: vm)
                .opacity(selectedTab == 3 ? 1 : 0).allowsHitTesting(selectedTab == 3)

            HStack(spacing: 5) {
                dockButton("Library", "play.rectangle.fill", 0)
                dockButton("Offcloud", "cloud.fill", 1)
                dockButton("PikPak", "externaldrive.fill", 2)
                dockButton("Discover", "sailboat.fill", 3)
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
            var parts = URLComponents(string: "https://apibay.org/precompiled/data_top100_\(category).json")!
            parts.queryItems = [URLQueryItem(name: "refresh", value: String(Int(Date().timeIntervalSince1970 / 60)))]
            url = parts.url
        } else {
            var parts = URLComponents(string: "https://apibay.org/q.php")!
            parts.queryItems = [URLQueryItem(name: "q", value: query), URLQueryItem(name: "cat", value: String(category))]
            url = parts.url
        }
        guard let url else { error = "Invalid request"; return }
        do {
            var request = URLRequest(url: url); request.timeoutInterval = 25; request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
            let (data, response) = try await URLSession.shared.data(for: request)
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
                        ForEach(model.items) { resultCard($0) }
                    }
                    .padding(.horizontal, 14).padding(.top, 8).padding(.bottom, 105)
                }
                .refreshable { await reload() }
            }
            .navigationTitle("Discover")
            .navigationBarTitleDisplayMode(.large)
            .toolbar { ToolbarItem(placement: .navigationBarTrailing) { Button { Task { await reload() } } label: { Image(systemName: "arrow.clockwise").foregroundStyle(.green) } } }
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

    @ViewBuilder private var statusArea: some View {
        if model.isLoading { ProgressView().tint(section.tint).padding(.top, 35) }
        else if let error = model.error { Text(error).foregroundStyle(.secondary).padding(.top, 35) }
        else {
            HStack { Text("LATEST \(section.rawValue.uppercased()) · \(quality.rawValue)").font(.caption.bold()).tracking(0.8).foregroundStyle(.secondary); Spacer(); Text("\(model.items.count)").font(.caption.monospacedDigit()).foregroundStyle(section.tint) }
                .padding(.horizontal, 3).padding(.top, 3)
        }
    }

    private func resultCard(_ item: PirateBayResult) -> some View {
        VStack(alignment: .leading, spacing: 11) {
            Text(item.name).font(.headline).foregroundStyle(.white).lineLimit(3)
            HStack(spacing: 12) {
                Label("\(item.seedCount)", systemImage: "arrow.up.circle.fill").foregroundStyle(.green)
                Label("\(item.leechCount)", systemImage: "arrow.down.circle.fill").foregroundStyle(.orange)
                Text(ByteCountFormatter.string(fromByteCount: item.byteCount, countStyle: .file)).foregroundStyle(.secondary); Spacer()
            }.font(.caption.bold())
            HStack(spacing: 10) {
                Button { UIPasteboard.general.string = item.magnet; toast("Magnet copied") } label: { Label("Copy", systemImage: "doc.on.doc").frame(maxWidth: .infinity) }.buttonStyle(.bordered)
                Button {
                    addingID = item.id
                    Task { let error = await vm.addMagnetToPikPak(item.magnet); addingID = nil; toast(error ?? "Added to PikPak") }
                } label: {
                    if addingID == item.id { ProgressView().frame(maxWidth: .infinity) } else { Label("Add to PikPak", systemImage: "externaldrive.badge.plus").frame(maxWidth: .infinity) }
                }.buttonStyle(.borderedProminent).tint(section.tint).disabled(addingID != nil)
            }
        }.padding(15).background(Color.white.opacity(0.065), in: RoundedRectangle(cornerRadius: 20)).overlay(RoundedRectangle(cornerRadius: 20).stroke(Color.white.opacity(0.07)))
    }

    private func reload() async { await model.load(section: section, quality: quality, query: query) }
    private func toast(_ text: String) {
        notice = text
        Task { try? await Task.sleep(nanoseconds: 2_000_000_000); if notice == text { notice = nil } }
    }
}