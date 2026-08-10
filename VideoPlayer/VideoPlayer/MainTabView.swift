import SwiftUI
import UIKit
import Kingfisher

struct MainTabView: View {
    @StateObject private var vm = AppViewModel()
    @State private var selectedTab = 0
    @Namespace private var dockSelection

    var body: some View {
        ZStack(alignment: .bottom) {
            ContentView(vm: vm, isActive: selectedTab == 0)
                .opacity(selectedTab == 0 ? 1 : 0).allowsHitTesting(selectedTab == 0)
            UnifiedContentView(vm: vm, isActive: selectedTab == 1)
                .opacity(selectedTab == 1 ? 1 : 0).allowsHitTesting(selectedTab == 1)
            RecentVideosView(vm: vm)
                .opacity(selectedTab == 2 ? 1 : 0).allowsHitTesting(selectedTab == 2)
            PirateBayView(vm: vm)
                .opacity(selectedTab == 3 ? 1 : 0).allowsHitTesting(selectedTab == 3)

            HStack(spacing: 4) {
                dockButton("Home", "house.fill", 0)
                dockButton("Content", "rectangle.stack.fill", 1)
                dockButton("Direct Links", "link", 2)
                dockButton("Discover", "sailboat.fill", 3)
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
    @State private var sending = false; @State private var message: String?; @State private var selectedImage = 0; @State private var showViewer = false
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text(item.name).font(.title2.bold()).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    actionButton("Send to Offcloud", icon: "cloud.fill", busy: sending) { sendToOffcloud() }
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
        let key = OffcloudKeyStore.load(); guard !key.isEmpty else { toast("Add your Offcloud API key first"); return }; sending = true
        Task { do { _ = try await OffcloudClient(apiKey: key).create(url: item.magnet); toast("Sent to Offcloud") } catch { toast(error.localizedDescription) }; sending = false }
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
