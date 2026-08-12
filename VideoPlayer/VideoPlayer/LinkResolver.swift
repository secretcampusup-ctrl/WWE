import Foundation

/// Accepts and classifies streamable / cloud links — not limited to .mp4.
enum LinkKind: String, Codable, Hashable {
    case directStream
    case hls          // m3u8
    case dash         // mpd
    case pikpakShare
    case pikpakDirect // tokenized CDN / download URLs (fid, sign, userid, …)
    case pikpakMagnet
    case magnet
    case webdav
    case unknown
}

enum LinkResolver {
    struct TwitterVideoResult {
        let url: URL
        let title: String
        let fileSize: Int64?
    }

    private struct FxTwitterResponse: Decodable {
        let code: Int
        let status: Status?
        struct Status: Decodable { let text: String?; let author: Author?; let media: Media? }
        struct Author: Decodable { let name: String? }
        struct Media: Decodable { let videos: [Video]? }
        struct Video: Decodable { let url: String?; let filesize: Int64?; let formats: [Format]? }
        struct Format: Decodable { let container: String?; let bitrate: Int?; let url: String; let size: Int64? }
    }

    static func isTwitterStatusURL(_ raw: String) -> Bool {
        guard let url = normalizeToURL(raw) else { return false }
        let host = (url.host ?? "").lowercased()
        return (host == "x.com" || host.hasSuffix(".x.com") || host == "twitter.com" || host.hasSuffix(".twitter.com"))
            && twitterStatusID(from: url) != nil
    }

    static func resolveTwitterVideo(_ raw: String) async throws -> TwitterVideoResult {
        guard let sourceURL = normalizeToURL(raw), let id = twitterStatusID(from: sourceURL),
              let apiURL = URL(string: "https://api.fxtwitter.com/2/status/\(id)") else {
            throw NSError(domain: "TwitterVideo", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid Twitter/X status link"])
        }
        var request = URLRequest(url: apiURL)
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await HighPriorityNetworkManager.shared.responsiveData(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw NSError(domain: "TwitterVideo", code: 2, userInfo: [NSLocalizedDescriptionKey: "Twitter video service is unavailable"])
        }
        let payload = try JSONDecoder().decode(FxTwitterResponse.self, from: data)
        guard payload.code == 200, let status = payload.status else {
            throw NSError(domain: "TwitterVideo", code: 3, userInfo: [NSLocalizedDescriptionKey: "The post could not be loaded"])
        }
        let formats = status.media?.videos?.flatMap { $0.formats ?? [] } ?? []
        let best = formats.filter { ($0.container ?? "mp4").lowercased() == "mp4" }
            .max { ($0.bitrate ?? 0) < ($1.bitrate ?? 0) }
        let fallback = status.media?.videos?.compactMap { video -> (URL, Int64?)? in
            guard let value = video.url, let url = URL(string: value) else { return nil }
            return (url, video.filesize)
        }.first
        let resolvedURL = best.flatMap { URL(string: $0.url) } ?? fallback?.0
        guard let resolvedURL else {
            throw NSError(domain: "TwitterVideo", code: 4, userInfo: [NSLocalizedDescriptionKey: "This post does not contain a downloadable video"])
        }
        let author = status.author?.name?.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = status.text?.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = [author, body].compactMap { value -> String? in
            guard let value, !value.isEmpty else { return nil }
            return value
        }.joined(separator: " — ")
        return TwitterVideoResult(url: resolvedURL, title: title.isEmpty ? "Twitter Video \(id)" : title, fileSize: best?.size ?? fallback?.1)
    }

    private static func twitterStatusID(from url: URL) -> String? {
        let parts = url.path.split(separator: "/").map(String.init)
        guard let index = parts.firstIndex(where: { $0.lowercased() == "status" }),
              parts.indices.contains(index + 1) else { return nil }
        let id = parts[index + 1].prefix { $0.isNumber }
        return id.count >= 2 ? String(id) : nil
    }

    /// Extensions commonly playable by AVPlayer or progressive HTTP.
    static let streamExtensions: Set<String> = [
        "mp4", "m4v", "mov", "qt", "mkv", "webm", "avi", "flv", "f4v",
        "wmv", "asf", "mpg", "mpeg", "m2v", "m2ts", "mts", "ts", "vob",
        "3gp", "3g2", "ogv", "rm", "rmvb", "divx", "xvid",
        "m3u8", "m3u", "mpd",
        "mp3", "m4a", "aac", "flac", "wav", "ogg"
    ]

    /// Query keys seen on PikPak signed direct-download / stream URLs.
    static let pikpakDirectQueryKeys: Set<String> = [
        "fid", "g", "sign", "userid", "user_id", "category", "sha1",
        "expire", "exp", "token", "auth_key", "filename", "fsize",
        "f_type", "file_type", "mime_type", "s", "e", "h", "v"
    ]

    static func isPlayableHTTPURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        guard scheme == "http" || scheme == "https" else { return false }
        guard let host = url.host, !host.isEmpty else { return false }
        return true
    }

    static func classify(_ raw: String) -> LinkKind {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()

        if lower.hasPrefix("magnet:") { return .magnet }

        // Tokenized PikPak direct download / stream (must run before generic mypikpak checks)
        if isPikPakDirectDownload(trimmed) {
            return .pikpakDirect
        }

        if isPikPakShareURL(trimmed) { return .pikpakShare }

        // Generic mypikpak host without /s/ → treat as direct if http
        if lower.contains("mypikpak.com") || lower.contains("pikpak.com") {
            if isPikPakShareURL(trimmed) { return .pikpakShare }
            if normalizeToURL(trimmed) != nil { return .pikpakDirect }
        }

        guard let url = normalizeToURL(trimmed) else { return .unknown }
        let ext = url.pathExtension.lowercased()
        if ext == "m3u8" || ext == "m3u" { return .hls }
        if ext == "mpd" { return .dash }
        if isPlayableHTTPURL(url) { return .directStream }
        return .unknown
    }

    /// True for complex tokenized PikPak download URLs, e.g.:
    /// `https://…mypikpak.com/…?fid=…&g=…&sign=…&userid=…&category=original`
    static func isPikPakDirectDownload(_ raw: String) -> Bool {
        guard let url = normalizeToURL(raw) else { return false }
        let host = (url.host ?? "").lowercased()
        let path = url.path.lowercased()

        // Share pages are not direct streams
        if path.contains("/s/") { return false }

        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let names = Set(items.compactMap { $0.name.lowercased() })

        let tokenHits = names.intersection(pikpakDirectQueryKeys)
        let hasStrongTokens =
            names.contains("fid")
            || names.contains("sign")
            || (names.contains("userid") || names.contains("user_id"))
            || (names.contains("g") && names.contains("category"))

        if hasStrongTokens { return true }

        // CDN / download hosts under PikPak
        let downloadHosts = ["download", "working", "dl-", "dl.", "stream", "media", "file"]
        let isPikHost = host.contains("mypikpak.com")
            || host.contains("pikpak.com")
            || host.contains("mypikpak.net")
            || host.hasSuffix("pikpak.io")
        if isPikHost {
            if downloadHosts.contains(where: { host.contains($0) }) { return true }
            if tokenHits.count >= 2 { return true }
            // category=original is a strong signal
            if let cat = items.first(where: { $0.name.lowercased() == "category" })?.value?.lowercased(),
               cat == "original" || cat == "video" {
                return true
            }
        }

        // Non-PikPak host but clearly a signed PikPak-style query blob
        if hasStrongTokens && names.contains("fid") && names.contains("sign") {
            return true
        }
        return false
    }

    /// Normalize a PikPak direct URL for AVPlayer — preserve every query parameter.
    static func resolvePikPakDirectStream(_ raw: String) -> URL? {
        guard let url = normalizeToURL(raw) else { return nil }
        // PikPak signs the exact query text. Rebuilding query items can alter
        // encoding and invalidate a valid temporary download link.
        return url
    }

    /// Extract useful display metadata from a tokenized PikPak URL.
    static func pikpakDirectDisplayTitle(_ raw: String) -> String {
        guard let url = normalizeToURL(raw) else { return "PikPak Stream" }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        if let name = items.first(where: {
            let n = $0.name.lowercased()
            return n == "filename" || n == "name" || n == "file_name"
        })?.value, !name.isEmpty {
            return name.removingPercentEncoding ?? name
        }
        if let fid = items.first(where: { $0.name.lowercased() == "fid" })?.value, !fid.isEmpty {
            let short = fid.count > 10 ? String(fid.prefix(8)) + "…" : fid
            return "PikPak \(short)"
        }
        let last = url.lastPathComponent.removingPercentEncoding ?? url.lastPathComponent
        if !last.isEmpty, last != "/", !last.contains("?") {
            return last
        }
        return "PikPak Stream"
    }

    static func normalizeToURL(_ raw: String) -> URL? {
        var trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if trimmed.lowercased().hasPrefix("magnet:") {
            return URL(string: trimmed)
        }

        if (trimmed.hasPrefix("\"") && trimmed.hasSuffix("\"")) ||
            (trimmed.hasPrefix("'") && trimmed.hasSuffix("'")) ||
            (trimmed.hasPrefix("<") && trimmed.hasSuffix(">")) {
            trimmed = String(trimmed.dropFirst().dropLast())
        }

        trimmed = trimmed.replacingOccurrences(of: "\n", with: "")
            .replacingOccurrences(of: "\r", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let lower = trimmed.lowercased()
        if !lower.hasPrefix("http://"),
           !lower.hasPrefix("https://"),
           !lower.hasPrefix("magnet:") {
            if trimmed.hasPrefix("//") {
                trimmed = "https:" + trimmed
            } else {
                trimmed = "https://" + trimmed
            }
        }

        if let url = URL(string: trimmed) {
            return isPlayableHTTPURL(url) || url.scheme?.lowercased() == "magnet" ? url : nil
        }

        // Preserve query string when encoding
        if let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed),
           let url = URL(string: encoded),
           isPlayableHTTPURL(url) {
            return url
        }
        return nil
    }

    static func isPikPakShareURL(_ raw: String) -> Bool {
        let lower = raw.lowercased()
        if lower.contains("mypikpak.com/s/") || lower.contains("pikpak.com/s/") {
            return true
        }
        if lower.contains("mypikpak.com") && lower.contains("/s/") {
            return true
        }
        return false
    }

    static func parsePikPakShare(_ raw: String) -> (shareId: String, password: String?)? {
        guard let url = normalizeToURL(raw) else {
            return extractShareIdFromString(raw)
        }
        let path = url.path
        if let range = path.range(of: "/s/", options: .caseInsensitive) {
            var idPart = String(path[range.upperBound...])
            if let slash = idPart.firstIndex(of: "/") {
                idPart = String(idPart[..<slash])
            }
            idPart = idPart.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard !idPart.isEmpty else { return nil }

            var password: String?
            if let pwd = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: {
                    let n = $0.name.lowercased()
                    return n == "pwd" || n == "pass_code" || n == "password"
                })?.value {
                password = pwd
            }
            if password == nil, let frag = url.fragment, !frag.isEmpty, frag.count <= 8 {
                password = frag
            }
            return (idPart, password)
        }
        return extractShareIdFromString(raw)
    }

    private static func extractShareIdFromString(_ raw: String) -> (shareId: String, password: String?)? {
        guard let r = raw.range(of: "/s/", options: .caseInsensitive) else { return nil }
        var rest = String(raw[r.upperBound...])
        if let q = rest.firstIndex(of: "?") { rest = String(rest[..<q]) }
        if let h = rest.firstIndex(of: "#") {
            let frag = String(rest[rest.index(after: h)...])
            rest = String(rest[..<h])
            let id = rest.split(separator: "/").first.map(String.init) ?? rest
            return id.isEmpty ? nil : (id, frag.isEmpty ? nil : frag)
        }
        let id = rest.split(separator: "/").first.map(String.init) ?? rest
        return id.isEmpty ? nil : (id, nil)
    }

    static func displayTitle(for url: URL) -> String {
        var name = url.lastPathComponent.removingPercentEncoding ?? url.lastPathComponent
        if let q = name.range(of: "?") { name = String(name[..<q.lowerBound]) }
        if name.isEmpty || name == "/" {
            name = url.host ?? "Stream"
        }
        return name.isEmpty ? "Stream" : name
    }

    static func formatBadge(for url: URL, kind: LinkKind) -> String {
        switch kind {
        case .hls: return "HLS"
        case .dash: return "DASH"
        case .pikpakShare, .pikpakMagnet, .pikpakDirect: return "PIKPAK"
        case .magnet: return "MAGNET"
        default:
            let ext = url.pathExtension.uppercased()
            return ext.isEmpty ? "STREAM" : ext
        }
    }

    static func isVideoFileName(_ name: String) -> Bool {
        let ext = (name as NSString).pathExtension.lowercased()
        return streamExtensions.contains(ext)
    }

    /// Known audiovisual MIME types per extension (subset AVPlayer understands).
    private static let mimeByExtension: [String: String] = [
        "mp4": "video/mp4", "m4v": "video/mp4", "mov": "video/quicktime", "qt": "video/quicktime",
        "mkv": "video/x-matroska", "webm": "video/webm", "avi": "video/avi",
        "3gp": "video/3gpp", "3g2": "video/3gpp2",
        "m3u8": "application/x-mpegURL", "m3u": "application/x-mpegURL", "mpd": "application/dash+xml",
        "mp3": "audio/mpeg", "m4a": "audio/mp4", "aac": "audio/aac", "flac": "audio/flac",
        "wav": "audio/wav", "ogg": "audio/ogg"
    ]

    /// AVPlayer/AVKit has a known limitation: it often refuses to treat a URL as
    /// playable when the URL has no recognizable file extension and the server's
    /// Content-Type isn't a video MIME type it trusts (common for CDN "download"
    /// endpoints like PikPak's `/download/?fid=...` links, which have no extension
    /// in the path). Passing an explicit `AVURLAssetOutOfBandMIMETypeKey` works
    /// around this. Returns nil when the URL's own extension should already be
    /// enough for AVPlayer to figure it out.
    static func mimeTypeHint(for url: URL) -> String? {
        let ext = url.pathExtension.lowercased()
        if !ext.isEmpty, let known = mimeByExtension[ext] {
            // WebDAV can report a generic type; give AVPlayer the real video type.
            return known
        }
        // No usable extension — PikPak direct/download links and similar
        // tokenized CDN URLs land here. "category=original" downloads are
        // almost always progressive MP4/MOV containers.
        let lower = url.absoluteString.lowercased()
        if lower.contains("mypikpak.com") || lower.contains("pikpak.com") || lower.contains("pikpak.net") {
            return "video/mp4"
        }
        return nil
    }
}
