import Foundation
import SwiftUI

/// Shared by every provider and library screen so sample-sized files cannot
/// slip into a different section through a separate filtering path.
enum VideoLibraryVisibility {
    static let minimumFileSizeBytes: Int64 = 400 * 1_024 * 1_024

    static func allows(sizeBytes: Int64?) -> Bool {
        guard let sizeBytes else { return true }
        return sizeBytes >= minimumFileSizeBytes
    }
}

enum VideoTitleFormatter {
    private static let seasonEpisodePattern = #"(?i)(?<![A-Z0-9])S(\d{1,3})[\s._-]*E(\d{1,3})(?!\d)"#

    static func episodeComponents(from rawTitle: String) -> (season: Int, episode: Int)? {
        guard let regex = try? NSRegularExpression(pattern: seasonEpisodePattern),
              let match = regex.firstMatch(in: rawTitle, range: NSRange(rawTitle.startIndex..., in: rawTitle)),
              let seasonRange = Range(match.range(at: 1), in: rawTitle),
              let episodeRange = Range(match.range(at: 2), in: rawTitle),
              let season = Int(rawTitle[seasonRange]),
              let episode = Int(rawTitle[episodeRange]) else { return nil }
        return (season, episode)
    }

    static func episodeTitle(from rawTitle: String) -> String {
        var value = rawTitle.removingPercentEncoding ?? rawTitle
        value = value.replacingOccurrences(of: #"(?i)^.*?S\d{1,3}[\s._-]*E\d{1,3}[\s._-]*"#, with: "", options: .regularExpression)
        value = value.replacingOccurrences(of: #"(?i)\.(mp4|mkv|mov|m4v|avi|webm|wmv|flv|ts|m3u8)$"#, with: "", options: .regularExpression)
        value = value.replacingOccurrences(of: #"(?i)\b(2160p|1080p|720p|4K|HDR|WEB[- .]?DL|BluRay|x264|x265|HEVC)\b.*$"#, with: "", options: .regularExpression)
        value = value.replacingOccurrences(of: #"[._-]+"#, with: " ", options: .regularExpression)
        value = value.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? "Episode" : value
    }
    static func seasonEpisode(from rawTitle: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: seasonEpisodePattern),
              let match = regex.firstMatch(
                  in: rawTitle,
                  range: NSRange(rawTitle.startIndex..., in: rawTitle)
              ),
              let seasonRange = Range(match.range(at: 1), in: rawTitle),
              let episodeRange = Range(match.range(at: 2), in: rawTitle),
              let season = Int(rawTitle[seasonRange]),
              let episode = Int(rawTitle[episodeRange]) else { return nil }
        return String(format: "S%02d.E%02d", season, episode)
    }

    static func date(from rawTitle: String) -> String? {
        let p = #"(?i)^(?:19|20)\d{2}[._-]\d{1,2}[._-]\d{1,2}"#
        guard let m = rawTitle.range(of: p, options: .regularExpression) else { return nil }
        return rawTitle[m].replacingOccurrences(of: ".", with: "-").replacingOccurrences(of: "_", with: "-")
    }

    static func dimensions(from rawTitle: String) -> (Int, Int)? {
        switch resolution(from: rawTitle) {
        case "4K": return (3840, 2160)
        case "1080p": return (1920, 1080)
        case "720p": return (1280, 720)
        default: return nil
        }
    }

    static func resolution(from rawTitle: String) -> String? {
        if rawTitle.range(of: #"(?i)(2160p|4k|uhd)"#, options: .regularExpression) != nil { return "4K" }
        if rawTitle.range(of: #"(?i)(1080p|fhd)"#, options: .regularExpression) != nil { return "1080p" }
        if rawTitle.range(of: #"(?i)720p"#, options: .regularExpression) != nil { return "720p" }
        return nil
    }

    /// كلمات مهملة تدل على نهاية العنوان الوصفي: صيغة الملف / مجموعة الرفع
    private static let structuralJunkTokens: Set<String> = [
        "MP4", "WEBRIP", "XXX", "WRB", "NBQ", "VSEX"
    ]

    /// أي دقة شائعة (720p, 1080p, 2160p, 4K, UHD...) تُعتبر أيضاً علامة توقف/مهملة
    private static let resolutionTokenPattern = #"(?i)^\d{3,4}p$|^(?:4k|8k|uhd|fhd|qhd)$"#

    /// يتحقق إن كان الجزء (أو دمج أجزاء بشرطة مثل "XXX-WRB") مهملاً بالكامل
    private static func isStructuralJunkToken(_ token: String) -> Bool {
        let upper = token.uppercased()
        if structuralJunkTokens.contains(upper) { return true }
        if token.range(of: resolutionTokenPattern, options: .regularExpression) != nil { return true }
        let subParts = upper.split(separator: "-").map(String.init)
        return !subParts.isEmpty && subParts.allSatisfy { structuralJunkTokens.contains($0) }
    }

    /// يحاول استخراج العنوان وفق نمط: Studio.YY.MM.DD.Actors.Descriptive.Title.Res.Format.Group
    /// القواعد:
    /// 1) الاستوديو (يُحتفظ به الآن ضمن العنوان — فلتر "إرجاع اسم الاستوديو"): أول جزء قبل أول نقطة.
    /// 2) التاريخ (مهمل، وأي رقم عموماً يُحذف لاحقاً عبر فلتر حذف الأرقام): أجزاء رقمية متتالية مباشرة بعد الاستوديو.
    /// 3) العنوان الوصفي (مطلوب): يسConnectedر حتى ظهور أول علامة مهملة (دقة/صيغة/مجموعة رفع).
    /// يرجّع nil إن لم يكن الشكل مطابقاً فعلياً (لا استوديو+تاريخ)، حتى لا يكسر عناوين من نمط آخر.
    private static func extractStructuredTitle(from value: String) -> String? {
        var parts = value.split(separator: ".", omittingEmptySubsequences: true).map(String.init)
        guard parts.count >= 3 else { return nil }

        // 1) الاستوديو: أول جزء — يبقى في العنوان بدل حذفه
        let studio = parts.removeFirst()

        // 2) التاريخ: أجزاء رقمية متتالية بعد الاستوديو
        var consumedDate = false
        while let first = parts.first, !first.isEmpty, first.allSatisfy({ $0.isNumber }) {
            parts.removeFirst()
            consumedDate = true
        }
        // إن لم يوجد تاريخ رقمي بعد الاستوديو، هذا ليس النمط المتوقع — لا تتدخل
        guard consumedDate else { return nil }

        // 3) العنوان: يسConnectedر حتى أول علامة مهملة
        var titleParts: [String] = [studio]
        for token in parts {
            if isStructuralJunkToken(token) { break }
            titleParts.append(token)
        }
        guard titleParts.count > 1 else { return nil }

        return titleParts.joined(separator: " ")
    }

    static func title(from rawTitle: String) -> String {
        let decoded = rawTitle.removingPercentEncoding ?? rawTitle
        var value = decoded.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return "Video" }

        // خطوة أولى: لو العنوان مطابق لنمط Studio.Date.Actors.Title.Junk، استخرجه مباشرة
        // (اسم الاستوديو يبقى ضمن الناتج الآن — فلتر 1)
        if let structured = extractStructuredTitle(from: value) {
            value = structured
        }

        let leadingDatePattern = #"^\s*(?:19|20)\d{2}[._ -]\d{1,2}[._ -]\d{1,2}(?=\D|$)"#
        let hasLeadingDate = value.range(of: leadingDatePattern, options: .regularExpression) != nil

        if !hasLeadingDate,
           let regex = try? NSRegularExpression(pattern: seasonEpisodePattern),
           let match = regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)),
           let matchRange = Range(match.range, in: value) {
            value = String(value[..<matchRange.lowerBound])
        }

        // امتداد الملف
        value = value.replacingOccurrences(of: #"(?i)\\.(?:ts|mkv|avi|mov|m4v|webm|wmv|flv)\\.(?:mp4|mkv|mov|m4v|avi|webm|wmv|flv)$"#, with: "", options: .regularExpression)
        value = value.replacingOccurrences(
            of: #"(?i)\.(mp4|mkv|mov|m4v|avi|webm|wmv|flv|ts|m3u8)$"#,
            with: "",
            options: .regularExpression
        )

        // فلتر 4: كلمة "com" — لازم تُحذف قبل حذف النقاط، وإلا "site.com" تلتصق بكلمة واحدة
        value = value.replacingOccurrences(of: #"(?i)\bcom\b"#, with: " ", options: .regularExpression)

        // فلتر 3: كل أنواع الأقواس } { ] [ ) ( تُحذف (المحتوى الداخلي يبقى)
        value = value.replacingOccurrences(of: #"[\[\]\(\)\{\}]"#, with: "", options: .regularExpression)

        // الشرطة السفلية تتحول لمسافة (فاصل كلمات كما كان)
        value = value.replacingOccurrences(of: #"_+"#, with: " ", options: .regularExpression)

        // فلتر 5: كل النقاط والفواصل تُحذف (بدون تحويلها لمسافة)
        value = value.replacingOccurrences(of: #"[.,]+"#, with: "", options: .regularExpression)

        // الدقة (1080p, 4K, uhd...) تُحذف كوحدة كاملة قبل حذف الأرقام العام،
        // حتى لا يتبقى حرف يتيم مثل "p" أو "k"
        value = value.replacingOccurrences(
            of: #"(?i)\b(?:4320p|2160p|1440p|1080p|720p|480p|8k|4k|uhd|fhd)\b"#,
            with: " ",
            options: .regularExpression
        )
        value = value.replacingOccurrences(
            of: #"(?i)\bfull\s*hd\b"#,
            with: " ",
            options: .regularExpression
        )

        // فلتر 2: أي رقم موجود (تاريخ أو غيره) يُحذف بالكامل
        value = value.replacingOccurrences(of: #"\d+"#, with: "", options: .regularExpression)

        value = value.replacingOccurrences(
            of: #"(?i)\bdaddys\b"#,
            with: "Daddy",
            options: .regularExpression
        )

        // فلتر 6: كلمة "and" + الكلمتين اللي بعدها تُحذف
        // مثال: "Sara ali and Ahmin Salim playing footbal" → "Sara ali playing footbal"
        value = value.replacingOccurrences(
            of: #"(?i)\band\b(?:\s+\S+){1,2}"#,
            with: "",
            options: .regularExpression
        )

        value = value.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        value = value.trimmingCharacters(in: CharacterSet(charactersIn: " ._-[](){}"))
        return value.isEmpty ? decoded : value
    }
}
// MARK: - Saved media links (auto-persisted library)

struct SavedVideoLink: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    /// Original URL / share string as stored
    var urlString: String
    /// Playable stream URL when different from original (e.g. resolved PikPak)
    var resolvedStreamURL: String?
    /// Display title (filename or custom)
    var title: String

    var displayTitle: String { VideoTitleFormatter.title(from: title) }
    /// When the link was first saved
    var dateAdded: Date = Date()
    /// Last time the user played this link
    var lastPlayed: Date?
    /// Optional local path to a cached poster/thumbnail image
    var thumbnailFileName: String?
    /// Origin of this entry
    var source: LinkSource = .direct
    /// PikPak file id when relevant
    var pikpakFileId: String?
    /// Stable TorBox identifiers. The actual CDN URL is intentionally resolved
    /// only when Play is pressed because TorBox download links expire.
    var torBoxTorrentId: Int?
    var torBoxFileId: Int?
    /// Remote poster URL (PikPak thumbnail)
    var remotePosterURL: String?
    /// Resume position in seconds (exact spot user left off)
    var resumePositionSeconds: Double?
    /// Last known duration in seconds
    var durationSeconds: Double?
    /// Detected stream width / height for badges
    var videoWidth: Int?
    var videoHeight: Int?
    var fileSizeBytes: Int64?
    /// Whether this video is pinned in the Favorites section.
    var isFavorite: Bool = false
    /// Stable identity used when a provider rotates its temporary stream URL.
    var favoriteIdentity: String?

    var isVisibleInLibrary: Bool {
        VideoLibraryVisibility.allows(sizeBytes: fileSizeBytes)
    }

    enum LinkSource: String, Codable, Hashable {
        case direct
        case hls
        case pikpak
        case webdav
        case offcloud
        case torbox
    }

    enum CodingKeys: String, CodingKey {
        case id, urlString, resolvedStreamURL, title, dateAdded, lastPlayed
        case thumbnailFileName, source, pikpakFileId, torBoxTorrentId, torBoxFileId, remotePosterURL
        case resumePositionSeconds, durationSeconds, videoWidth, videoHeight, fileSizeBytes, isFavorite, favoriteIdentity
    }

    init(
        id: UUID = UUID(),
        urlString: String,
        resolvedStreamURL: String? = nil,
        title: String,
        dateAdded: Date = Date(),
        lastPlayed: Date? = nil,
        thumbnailFileName: String? = nil,
        source: LinkSource = .direct,
        pikpakFileId: String? = nil,
        torBoxTorrentId: Int? = nil,
        torBoxFileId: Int? = nil,
        remotePosterURL: String? = nil,
        resumePositionSeconds: Double? = nil,
        durationSeconds: Double? = nil,
        videoWidth: Int? = nil,
        videoHeight: Int? = nil,
        fileSizeBytes: Int64? = nil,
        isFavorite: Bool = false,
        favoriteIdentity: String? = nil
    ) {
        self.id = id
        self.urlString = urlString
        self.resolvedStreamURL = resolvedStreamURL
        self.title = title
        self.dateAdded = dateAdded
        self.lastPlayed = lastPlayed
        self.thumbnailFileName = thumbnailFileName
        self.source = source
        self.pikpakFileId = pikpakFileId
        self.torBoxTorrentId = torBoxTorrentId
        self.torBoxFileId = torBoxFileId
        self.remotePosterURL = remotePosterURL
        self.resumePositionSeconds = resumePositionSeconds
        self.durationSeconds = durationSeconds
        self.videoWidth = videoWidth
        self.videoHeight = videoHeight
        self.fileSizeBytes = fileSizeBytes
        self.isFavorite = isFavorite
        self.favoriteIdentity = favoriteIdentity
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        urlString = try c.decode(String.self, forKey: .urlString)
        resolvedStreamURL = try c.decodeIfPresent(String.self, forKey: .resolvedStreamURL)
        title = try c.decode(String.self, forKey: .title)
        dateAdded = try c.decodeIfPresent(Date.self, forKey: .dateAdded) ?? Date()
        lastPlayed = try c.decodeIfPresent(Date.self, forKey: .lastPlayed)
        thumbnailFileName = try c.decodeIfPresent(String.self, forKey: .thumbnailFileName)
        source = try c.decodeIfPresent(LinkSource.self, forKey: .source) ?? .direct
        pikpakFileId = try c.decodeIfPresent(String.self, forKey: .pikpakFileId)
        torBoxTorrentId = try c.decodeIfPresent(Int.self, forKey: .torBoxTorrentId)
        torBoxFileId = try c.decodeIfPresent(Int.self, forKey: .torBoxFileId)
        remotePosterURL = try c.decodeIfPresent(String.self, forKey: .remotePosterURL)
        resumePositionSeconds = try c.decodeIfPresent(Double.self, forKey: .resumePositionSeconds)
        durationSeconds = try c.decodeIfPresent(Double.self, forKey: .durationSeconds)
        videoWidth = try c.decodeIfPresent(Int.self, forKey: .videoWidth)
        videoHeight = try c.decodeIfPresent(Int.self, forKey: .videoHeight)
        fileSizeBytes = try c.decodeIfPresent(Int64.self, forKey: .fileSizeBytes)
        isFavorite = try c.decodeIfPresent(Bool.self, forKey: .isFavorite) ?? false
        favoriteIdentity = try c.decodeIfPresent(String.self, forKey: .favoriteIdentity)
    }

    var url: URL? {
        if let resolvedStreamURL, let u = URL(string: resolvedStreamURL) { return u }
        return URL(string: urlString)
    }

    var originalURL: URL? { URL(string: urlString) }

    var hostLabel: String {
        switch source {
        case .pikpak: return "PikPak"
        case .webdav: return "WebDAV"
        case .offcloud: return "Offcloud"
        case .torbox: return "TorBox"
        case .hls: return originalURL?.host ?? "HLS"
        case .direct: return originalURL?.host ?? "Stream"
        }
    }

    var fileExtension: String {
        if source == .pikpak { return "PIKPAK" }
        if source == .torbox { return "TORBOX" }
        if source == .hls { return "HLS" }
        let ext = (originalURL?.pathExtension ?? url?.pathExtension ?? "").uppercased()
        return ext.isEmpty ? "STREAM" : ext
    }

    /// Meaningful resume only if > 3s and not near the end.
    var hasResumePoint: Bool {
        guard let pos = resumePositionSeconds, pos > 3 else { return false }
        if let dur = durationSeconds, dur > 0 {
            return pos < dur * 0.95 && (dur - pos) > 5
        }
        return true
    }

    var fileSizeLabel: String {
        guard let fileSizeBytes, fileSizeBytes > 0 else { return "—" }
        let f = ByteCountFormatter()
        f.allowedUnits = [.useMB, .useGB]
        f.countStyle = .file
        return f.string(fromByteCount: fileSizeBytes)
    }

    var resolutionTier: ResolutionTier {
        ResolutionTier.from(width: videoWidth ?? 0, height: videoHeight ?? 0)
    }
}

// MARK: - Resolution tiers / badges

enum ResolutionTier: String, Codable, Hashable {
    case uhd4k   // 3840×2160+
    case fhd     // 1920×1080 class
    case qhd     // 1440p
    case hd      // 720p
    case sd
    case unknown

    static func from(width: Int, height: Int) -> ResolutionTier {
        let w = max(width, 0)
        let h = max(height, 0)
        // 4K / UHD or higher
        if w >= 3800 || h >= 2100 { return .uhd4k }
        // 1440p
        if w >= 2500 || h >= 1400 { return .qhd }
        // Full HD 1080p
        if w >= 1800 || h >= 1000 { return .fhd }
        // 720p
        if w >= 1200 || h >= 700 { return .hd }
        if w > 0 || h > 0 { return .sd }
        return .unknown
    }

    var badgeText: String? {
        switch self {
        case .uhd4k: return "4K"
        case .fhd: return "FHD"
        case .qhd: return "1440p"
        case .hd: return "HD"
        case .sd: return "SD"
        case .unknown: return nil
        }
    }

    /// Primary aesthetic badges requested: 4K and FHD (also show 1440p as QHD).
    var isPrimaryBadge: Bool {
        self == .uhd4k || self == .fhd || self == .qhd
    }
}

struct ResolutionBadgeView: View {
    let tier: ResolutionTier
    var compact: Bool = false

    var body: some View {
        if let text = tier.badgeText {
            Text(text)
                .font(.system(size: compact ? 9 : 10, weight: .heavy))
                .tracking(0.6)
                .foregroundColor(foreground)
                .padding(.horizontal, compact ? 5 : 7)
                .padding(.vertical, compact ? 2 : 3)
                .background(background, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .stroke(border, lineWidth: 0.8)
                )
        }
    }

    private var foreground: Color {
        switch tier {
        case .uhd4k: return Color(red: 1.0, green: 0.92, blue: 0.55)
        case .fhd: return Color(red: 0.75, green: 0.95, blue: 1.0)
        case .qhd: return Color(red: 0.85, green: 0.8, blue: 1.0)
        default: return .white.opacity(0.9)
        }
    }

    private var background: Color {
        switch tier {
        case .uhd4k: return Color(red: 0.35, green: 0.22, blue: 0.02).opacity(0.92)
        case .fhd: return Color(red: 0.05, green: 0.22, blue: 0.38).opacity(0.92)
        case .qhd: return Color(red: 0.18, green: 0.1, blue: 0.35).opacity(0.92)
        default: return Color.black.opacity(0.55)
        }
    }

    private var border: Color {
        switch tier {
        case .uhd4k: return Color.yellow.opacity(0.55)
        case .fhd: return Color.cyan.opacity(0.45)
        case .qhd: return Color.purple.opacity(0.45)
        default: return Color.white.opacity(0.15)
        }
    }
}

// MARK: - WebDAV

struct WebDAVServer: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var name: String
    var host: String
    var port: Int
    var path: String
    var username: String
    var password: String
    var useHTTPS: Bool
    var isConnected: Bool = false

    var baseURL: URL? {
        let scheme = useHTTPS ? "https" : "http"
        var p = path
        if !p.hasPrefix("/") { p = "/" + p }
        let portPart: String = {
            if useHTTPS && (port == 443 || port == 0) { return "" }
            if !useHTTPS && (port == 80 || port == 0) { return "" }
            return ":\(port)"
        }()
        let hostClean = host
            .replacingOccurrences(of: "https://", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "http://", with: "", options: .caseInsensitive)
        let urlString = "\(scheme)://\(hostClean)\(portPart)\(p)"
        return URL(string: urlString)
    }

    var displayAddress: String {
        let scheme = useHTTPS ? "https" : "http"
        let portPart: String = {
            if useHTTPS && (port == 443 || port == 0) { return "" }
            if !useHTTPS && (port == 80 || port == 0) { return "" }
            return ":\(port)"
        }()
        return "\(scheme)://\(host)\(portPart)\(path)"
    }
}

struct WebDAVFile: Identifiable, Codable {
    var id: UUID = UUID()
    var name: String
    var path: String
    var isDirectory: Bool
    var size: Int64?
    var contentType: String?
    var lastModified: Date?

    var isVideo: Bool {
        guard VideoLibraryVisibility.allows(sizeBytes: size) else { return false }
        if let contentType, contentType.lowercased().hasPrefix("video/") { return true }
        return LinkResolver.isVideoFileName(name)
            || LinkResolver.streamExtensions.contains((name as NSString).pathExtension.lowercased())
    }
    var displayName: String {
        isDirectory ? name : VideoTitleFormatter.title(from: name)
    }

    var sizeFormatted: String {
        guard let size = size else { return "" }
        let gb = Double(size) / 1_073_741_824
        let mb = Double(size) / 1_048_576
        if gb >= 1 { return String(format: "%.1f GB", gb) }
        return String(format: "%.0f MB", mb)
    }

    var fileExtension: String {
        let ext = (name as NSString).pathExtension.uppercased()
        return ext.isEmpty ? "FILE" : ext
    }
}







