import Foundation

// MARK: - Category

/// The four fixed RSS "slots" the user asked for.
enum MediaCategory: String, CaseIterable, Identifiable, Codable {
    case allCategories = "All Categories"
    case p1080 = "1080p"
    case p2160 = "2160p"
    case pack = "Pack"

    var id: String { rawValue }

    var shortLabel: String {
        switch self {
        case .allCategories: return "All"
        case .p1080: return "1080p"
        case .p2160: return "2160p"
        case .pack: return "Pack"
        }
    }

    var icon: String {
        switch self {
        case .allCategories: return "square.grid.2x2"
        case .p1080: return "tv"
        case .p2160: return "4k.tv"
        case .pack: return "shippingbox"
        }
    }
}

// MARK: - Persisted feed URLs (one RSS link per category)

struct MediaFeedSettings: Codable, Equatable {
    var urls: [String: String] = [:]

    func url(for category: MediaCategory) -> String {
        urls[category.rawValue] ?? ""
    }

    mutating func setURL(_ value: String, for category: MediaCategory) {
        urls[category.rawValue] = value
    }

    var hasAnyFeed: Bool {
        urls.values.contains { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }
}

enum MediaFeedStore {
    private static let key = "media_rss_feed_settings_v1"

    static func load() -> MediaFeedSettings {
        guard let data = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode(MediaFeedSettings.self, from: data) else {
            return MediaFeedSettings()
        }
        return decoded
    }

    static func save(_ settings: MediaFeedSettings) {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}

// MARK: - A single RSS result

struct MediaItem: Identifiable, Hashable {
    let id = UUID()
    let rawTitle: String
    let link: String
    let pubDate: String?
    let summary: String?
    let sizeBytes: Int64?

    var displayTitle: String {
        VideoTitleFormatter.title(from: rawTitle)
    }

    var resolutionLabel: String? {
        VideoTitleFormatter.resolution(from: rawTitle)
    }

    var seasonEpisodeLabel: String? {
        VideoTitleFormatter.seasonEpisode(from: rawTitle)
    }

    var sizeLabel: String? {
        guard let sizeBytes, sizeBytes > 0 else { return nil }
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: sizeBytes)
    }

    var relativeDateLabel: String? {
        guard let pubDate, let date = MediaItem.parseDate(pubDate) else { return nil }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    var isMagnetOrTorrent: Bool {
        let lower = link.lowercased()
        return lower.hasPrefix("magnet:") || lower.hasSuffix(".torrent")
    }

    private static let dateFormatters: [DateFormatter] = {
        let patterns = [
            "EEE, dd MMM yyyy HH:mm:ss Z",
            "EEE, dd MMM yyyy HH:mm:ss zzz",
            "yyyy-MM-dd'T'HH:mm:ssZ",
            "yyyy-MM-dd'T'HH:mm:ss"
        ]
        return patterns.map { pattern in
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = pattern
            return formatter
        }
    }()

    static func parseDate(_ raw: String) -> Date? {
        for formatter in dateFormatters {
            if let date = formatter.date(from: raw) { return date }
        }
        return ISO8601DateFormatter().date(from: raw)
    }
}
