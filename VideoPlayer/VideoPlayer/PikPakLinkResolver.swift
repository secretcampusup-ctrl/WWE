import Foundation

struct PikPakShareFile: Identifiable, Codable, Hashable {
    var id: String
    var parentID: String?
    var name: String
    var path: String
    var isFolder: Bool
    var sizeBytes: Int64?
    var mimeType: String?
    var fileExtension: String
    var thumbnailURL: String?
    var iconURL: String?
    var downloadURL: String?
    var webContentLink: String?
    var createdTime: Date?
    var modifiedTime: Date?

    var badge: String {
        if isFolder { return "FOLDER" }
        let ext = fileExtension.trimmingCharacters(in: .whitespacesAndNewlines)
        return ext.isEmpty ? "PIKPAK" : ext.uppercased().replacingOccurrences(of: ".", with: "")
    }

    var displayTitle: String { VideoTitleFormatter.title(from: name) }
    var displaySizeLabel: String {
        guard let sizeBytes, sizeBytes > 0 else { return "—" }
        let f = ByteCountFormatter()
        f.allowedUnits = [.useMB, .useGB]
        f.countStyle = .file
        return f.string(fromByteCount: sizeBytes)
    }
}

struct PikPakShareFolder: Identifiable, Codable, Hashable {
    var id: String
    var shareURL: String
    var title: String
    var fileCount: Int
    var thumbnailURL: String?
    var iconURL: String?
    var shareStatusText: String?
    var files: [PikPakShareFile]
    var dateAdded: Date = Date()

    var displayTitle: String { VideoTitleFormatter.title(from: title) }
    var isFolder: Bool { fileCount != 1 || files.first?.isFolder == true }
    var totalSizeBytes: Int64 {
        files.compactMap { $0.sizeBytes }.reduce(0, +)
    }
}

enum PikPakLinkResolver {
    static func isShareURL(_ raw: String) -> Bool {
        return LinkResolver.isPikPakShareURL(raw)
    }

    static func isDirectURL(_ raw: String) -> Bool {
        return LinkResolver.isPikPakDirectDownload(raw)
    }

    static func resolveShare(from raw: String) async throws -> PikPakShareFolder {
        guard let url = LinkResolver.normalizeToURL(raw), LinkResolver.isPikPakShareURL(raw) else {
            throw NSError(domain: "PikPak", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid PikPak share link"])
        }

        let (data, response) = try await HighPriorityNetworkManager.shared.responsiveData(from: url)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw NSError(domain: "PikPak", code: 2, userInfo: [NSLocalizedDescriptionKey: "PikPak share page could not be loaded"])
        }
        guard let html = String(data: data, encoding: .utf8) else {
            throw NSError(domain: "PikPak", code: 3, userInfo: [NSLocalizedDescriptionKey: "PikPak share page is not readable"])
        }

        let nuxtJSON = try extractNuxtPayload(from: html)
        guard let root = try JSONSerialization.jsonObject(with: Data(nuxtJSON.utf8)) as? [Any] else {
            throw NSError(domain: "PikPak", code: 4, userInfo: [NSLocalizedDescriptionKey: "PikPak payload is invalid"])
        }

        let shareState = firstDictionary(in: root) { dict in
            dict["files"] is [Any] && dict["share_status"] != nil
        } ?? [:]
        let summary = firstDictionary(in: root) { dict in
            dict["title"] != nil && dict["thumbnail_link"] != nil && dict["file_num"] != nil
        } ?? [:]

        let files = (shareState["files"] as? [Any] ?? []).compactMap { item -> PikPakShareFile? in
            guard let dict = item as? [String: Any] else { return nil }
            return mapFile(dict)
        }

        let shareID = stringValue(from: summary["share_id"]) ?? stringValue(from: shareState["share_id"]) ?? url.lastPathComponent
        let title = stringValue(from: summary["title"]) ?? stringValue(from: shareState["title"]) ?? "PikPak"
        let fileCount = intValue(from: summary["file_num"]) ?? 0
        let thumb = stringValue(from: summary["thumbnail_link"]) ?? stringValue(from: shareState["thumbnail_link"])
        let icon = stringValue(from: summary["icon_link"]) ?? stringValue(from: shareState["icon_link"])
        let statusText = stringValue(from: shareState["share_status_text"]) ?? stringValue(from: summary["share_status_text"])

        return PikPakShareFolder(
            id: shareID,
            shareURL: url.absoluteString,
            title: title,
            fileCount: Int(fileCount),
            thumbnailURL: thumb,
            iconURL: icon,
            shareStatusText: statusText,
            files: files
        )
    }

    private static func extractNuxtPayload(from html: String) throws -> String {
        let patterns = [
            #"(?s)<script[^>]*id="__NUXT_DATA__"[^>]*>(.*?)</script>"#,
            #"(?s)<script[^>]*data-nuxt-data="nuxt-app"[^>]*id="__NUXT_DATA__"[^>]*>(.*?)</script>"#
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
                  let range = Range(match.range(at: 1), in: html) else { continue }
            return String(html[range])
        }
        throw NSError(domain: "PikPak", code: 5, userInfo: [NSLocalizedDescriptionKey: "PikPak payload was not found"])
    }

    private static func firstDictionary(in value: Any, where predicate: ([String: Any]) -> Bool) -> [String: Any]? {
        if let dict = value as? [String: Any] {
            if predicate(dict) { return dict }
            for child in dict.values {
                if let found = firstDictionary(in: child, where: predicate) { return found }
            }
            return nil
        }
        if let array = value as? [Any] {
            for child in array {
                if let found = firstDictionary(in: child, where: predicate) { return found }
            }
        }
        return nil
    }

    private static func mapFile(_ dict: [String: Any]) -> PikPakShareFile {
        let id = stringValue(from: dict["id"]) ?? UUID().uuidString
        let parentID = stringValue(from: dict["parent_id"])
        let name = stringValue(from: dict["name"]) ?? "Untitled"
        let path = stringValue(from: dict["path"]) ?? name
        let kind = stringValue(from: dict["kind"])?.lowercased() ?? ""
        let folderType = stringValue(from: dict["folder_type"])?.uppercased() ?? ""
        let mimeType = stringValue(from: dict["mime_type"]) ?? stringValue(from: dict["mimeType"])
        let fileExtension = stringValue(from: dict["file_extension"]) ?? URL(fileURLWithPath: name).pathExtension
        let thumbnailURL = stringValue(from: dict["thumbnail_link"]) ?? stringValue(from: nestedValue(in: dict, key: "small_thumbnail"))
        let iconURL = stringValue(from: dict["icon_link"]) ?? stringValue(from: nestedValue(in: dict, key: "platform_icon"))
        let downloadURL = firstURLString(in: dict["links"])
            ?? stringValue(from: dict["download_url"])
            ?? stringValue(from: dict["web_content_link"])
            ?? stringValue(from: dict["url"])
        let sizeBytes = intValue(from: dict["size"])
        let created = dateValue(from: dict["created_time"])
        let modified = dateValue(from: dict["modified_time"])
        let isFolder = kind.contains("folder") || folderType == "FOLDER"

        return PikPakShareFile(
            id: id,
            parentID: parentID,
            name: name,
            path: path,
            isFolder: isFolder,
            sizeBytes: sizeBytes,
            mimeType: mimeType,
            fileExtension: fileExtension,
            thumbnailURL: thumbnailURL,
            iconURL: iconURL,
            downloadURL: downloadURL,
            webContentLink: stringValue(from: dict["web_content_link"]),
            createdTime: created,
            modifiedTime: modified
        )
    }

    private static func stringValue(from any: Any?) -> String? {
        switch any {
        case let value as String:
            return value
        case let value as NSNumber:
            return value.stringValue
        case let value as Int:
            return String(value)
        case let value as Int64:
            return String(value)
        case let value as Double:
            if value.rounded() == value { return String(Int64(value)) }
            return String(value)
        default:
            return nil
        }
    }

    private static func intValue(from any: Any?) -> Int64? {
        switch any {
        case let value as Int64:
            return value
        case let value as Int:
            return Int64(value)
        case let value as Double:
            return Int64(value)
        case let value as String:
            return Int64(value)
        case let value as NSNumber:
            return value.int64Value
        default:
            return nil
        }
    }

    private static func dateValue(from any: Any?) -> Date? {
        guard let raw = stringValue(from: any), !raw.isEmpty else { return nil }
        if let seconds = Double(raw) {
            return Date(timeIntervalSince1970: seconds)
        }
        let iso = ISO8601DateFormatter()
        if let date = iso.date(from: raw) { return date }
        return nil
    }

    private static func nestedValue(in dict: [String: Any], key: String) -> Any? {
        if let value = dict[key] { return value }
        for value in dict.values {
            if let child = value as? [String: Any], let nested = nestedValue(in: child, key: key) { return nested }
            if let array = value as? [Any] {
                for item in array {
                    if let child = item as? [String: Any], let nested = nestedValue(in: child, key: key) { return nested }
                }
            }
        }
        return nil
    }

    private static func firstURLString(in value: Any?) -> String? {
        if let string = value as? String, string.lowercased().hasPrefix("http") { return string }
        if let dict = value as? [String: Any] {
            for candidate in dict.values {
                if let string = firstURLString(in: candidate) { return string }
            }
        }
        if let array = value as? [Any] {
            for candidate in array {
                if let string = firstURLString(in: candidate) { return string }
            }
        }
        return nil
    }
}
