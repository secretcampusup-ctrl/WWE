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
    var icon: String { switch self { case .movies: return "film.stack.fill"; case .tv: return "tv.fill"; case .adult: return "18.circle.fill" } }
    var gradient: [Color] { switch self { case .movies: return [.blue, .purple]; case .tv: return [.cyan, .indigo]; case .adult: return [.pink, .red] } }
    func accepts(_ code: Int) -> Bool {
        switch self {
        case .movies: return [201, 202, 207, 209].contains(code)
        case .tv: return [205, 208].contains(code)
        case .adult: return (500..<600).contains(code)
        }
    }
}

private enum PirateBayQuality: String, CaseIterable, Identifiable {
    case fullHD = "1080p", ultraHD = "2160p"
    var id: String { rawValue }
    var icon: String { self == .fullHD ? "rectangle.inset.filled" : "sparkles.tv.fill" }
    func accepts(_ name: String) -> Bool {
        let value = name.lowercased()
        switch self {
        case .fullHD: return value.contains("1080p") || value.contains("1080i")
        case .ultraHD: return value.contains("2160p") || value.contains("4k") || value.contains("uhd")
        }
    }
}

@MainActor
private final class PirateBayLatestModel: ObservableObject {
    @Published var items: [PirateBayResult] = []
    @Published var isLoading = false
    @Published var error: String?

    func refresh() async {
        isLoading = true; error = nil
        defer { isLoading = false }
        var parts = URLComponents(string: "https://apibay.org/precompiled/data_top100_recent.json")!
        parts.queryItems = [URLQueryItem(name: "refresh", value: String(Int(Date().timeIntervalSince1970 / 60)))]
        do {
            var request = URLRequest(url: parts.url!); request.timeoutInterval = 25; request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else { throw URLError(.badServerResponse) }
            let decoded = try JSONDecoder().decode([PirateBayResult].self, from: data)
            items = decoded.filter { $0.id != "0" }.sorted { $0.addedDate > $1.addedDate }
        } catch { self.error = "Latest releases are unavailable"; items = [] }
    }
}

private struct PirateBayView: View {
    @ObservedObject var vm: AppViewModel
    @StateObject private var model = PirateBayLatestModel()
    @State private var section: PirateBaySection?
    @State private var quality: PirateBayQuality?
    @State private var notice: String?
    @State private var addingID: String?

    var body: some View {
        NavigationStack {
            ZStack {
                LinearGradient(colors: [AppTheme.bg, Color.indigo.opacity(0.12), AppTheme.bg], startPoint: .topLeading, endPoint: .bottomTrailing).ignoresSafeArea()
                Group {
                    if section == nil { sectionPicker }
                    else if quality == nil { qualityPicker }
                    else { resultsView }
                }
                .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity), removal: .move(edge: .leading).combined(with: .opacity)))
            }
            .navigationTitle(quality.map { "\(section?.rawValue ?? "") · \($0.rawValue)" } ?? section?.rawValue ?? "Discover")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                if section != nil {
                    ToolbarItem(placement: .navigationBarLeading) {
                        Button { withAnimation(.spring(response: 0.42, dampingFraction: 0.86)) { if quality != nil { quality = nil } else { section = nil } } } label: {
                            Label("Back", systemImage: "chevron.left").foregroundStyle(.green)
                        }
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) { Button { Task { await model.refresh() } } label: { Image(systemName: "arrow.clockwise").foregroundStyle(.green) } }
            }
            .overlay(alignment: .top) { if let notice { Text(notice).font(.subheadline.bold()).padding(.horizontal, 18).padding(.vertical, 10).background(.ultraThinMaterial, in: Capsule()).padding(.top, 8) } }
            .task { if model.items.isEmpty { await model.refresh() } }
        }
    }

    private var sectionPicker: some View {
        ScrollView {
            VStack(spacing: 18) {
                Text("Choose a library").font(.subheadline.weight(.medium)).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                ForEach(PirateBaySection.allCases) { value in
                    Button { withAnimation(.spring(response: 0.48, dampingFraction: 0.84)) { section = value } } label: {
                        HStack(spacing: 18) {
                            Image(systemName: value.icon).font(.system(size: 31, weight: .semibold)).frame(width: 64, height: 64).background(.white.opacity(0.16), in: RoundedRectangle(cornerRadius: 20))
                            VStack(alignment: .leading, spacing: 5) { Text(value.rawValue).font(.system(size: 27, weight: .black, design: .rounded)); Text("Latest releases").font(.subheadline).opacity(0.72) }
                            Spacer(); Image(systemName: "chevron.right").font(.title3.bold())
                        }
                        .foregroundStyle(.white).padding(22).background(LinearGradient(colors: value.gradient, startPoint: .topLeading, endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: 30))
                        .shadow(color: value.gradient[0].opacity(0.32), radius: 22, y: 12)
                    }.buttonStyle(.plain)
                }
            }.padding(.horizontal, 18).padding(.top, 18).padding(.bottom, 110)
        }
    }

    private var qualityPicker: some View {
        VStack(spacing: 20) {
            Spacer()
            ForEach(PirateBayQuality.allCases) { value in
                Button { withAnimation(.spring(response: 0.45, dampingFraction: 0.85)) { quality = value } } label: {
                    VStack(spacing: 14) {
                        Image(systemName: value.icon).font(.system(size: 38, weight: .semibold))
                        Text(value.rawValue).font(.system(size: 34, weight: .black, design: .rounded))
                        Text(value == .fullHD ? "Full HD" : "Ultra HD · 4K").font(.subheadline).foregroundStyle(.secondary)
                    }
                    .foregroundStyle(.white).frame(maxWidth: .infinity).padding(.vertical, 32).background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 32))
                    .overlay(RoundedRectangle(cornerRadius: 32).stroke(LinearGradient(colors: section?.gradient ?? [.green, .blue], startPoint: .leading, endPoint: .trailing), lineWidth: 2))
                }.buttonStyle(.plain)
            }
            Spacer()
        }.padding(.horizontal, 22).padding(.bottom, 80)
    }

    private var filteredItems: [PirateBayResult] {
        guard let section, let quality else { return [] }
        return model.items.filter { section.accepts(Int($0.category) ?? 0) && quality.accepts($0.name) }
    }

    private var resultsView: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                if model.isLoading { ProgressView().tint(.green).padding(.top, 50) }
                else if let error = model.error { Text(error).foregroundStyle(.secondary).padding(.top, 50) }
                else if filteredItems.isEmpty { Text("No new \(quality?.rawValue ?? "") releases right now").foregroundStyle(.secondary).padding(.top, 50) }
                ForEach(filteredItems) { resultCard($0) }
            }.padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 105)
        }.refreshable { await model.refresh() }
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
                }.buttonStyle(.borderedProminent).tint(.green).disabled(addingID != nil)
            }
        }.padding(15).background(Color.white.opacity(0.065), in: RoundedRectangle(cornerRadius: 20)).overlay(RoundedRectangle(cornerRadius: 20).stroke(Color.white.opacity(0.07)))
    }

    private func toast(_ text: String) {
        notice = text
        Task { try? await Task.sleep(nanoseconds: 2_000_000_000); if notice == text { notice = nil } }
    }
}