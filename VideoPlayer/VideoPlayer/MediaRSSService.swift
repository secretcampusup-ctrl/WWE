import Foundation

enum MediaRSSError: LocalizedError {
    case missingFeedURL
    case invalidURL
    case badResponse(Int)
    case network(Error)
    case emptyFeed

    var errorDescription: String? {
        switch self {
        case .missingFeedURL:
            return "No RSS link is set for this category yet. Add one from Settings."
        case .invalidURL:
            return "That RSS link doesn't look valid."
        case .badResponse(let code):
            return "The feed server returned an error (\(code))."
        case .network(let error):
            return error.localizedDescription
        case .emptyFeed:
            return "No results in this feed."
        }
    }
}

/// Builds the request URL for a feed template + free-text search query.
///
/// Templates may contain a literal `{query}` placeholder, which is replaced by
/// the percent-encoded search text (private trackers commonly expose RSS search
/// like `https://site/rss?search={query}&cat=1080p`). If the template has no
/// placeholder, the query is appended as a `search` parameter automatically,
/// and if there is no query at all the template is used as-is (a plain browse/latest feed).
enum MediaRSSQueryBuilder {
    static func buildURL(template: String, query: String) -> URL? {
        let trimmedTemplate = template.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTemplate.isEmpty else { return nil }

        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let encodedQuery = trimmedQuery.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""

        if trimmedTemplate.contains("{query}") {
            let replaced = trimmedTemplate.replacingOccurrences(of: "{query}", with: encodedQuery)
            return URL(string: replaced)
        }

        guard !trimmedQuery.isEmpty else {
            return URL(string: trimmedTemplate)
        }

        let separator = trimmedTemplate.contains("?") ? "&" : "?"
        return URL(string: "\(trimmedTemplate)\(separator)search=\(encodedQuery)")
    }
}

enum MediaRSSService {
    static func fetch(feedTemplate: String, query: String) async throws -> [MediaItem] {
        let trimmed = feedTemplate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw MediaRSSError.missingFeedURL }
        guard let url = MediaRSSQueryBuilder.buildURL(template: trimmed, query: query) else {
            throw MediaRSSError.invalidURL
        }

        var request = URLRequest(url: url)
        request.setValue("VideoPlayer/1.0 (RSS reader)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 20

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await AppNetworkSession.shared.data(for: request)
        } catch {
            throw MediaRSSError.network(error)
        }

        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw MediaRSSError.badResponse(http.statusCode)
        }

        let parser = RSSFeedParser()
        let items = parser.parse(data: data)
        return items
    }
}

/// Minimal, tolerant RSS 2.0 parser: pulls title / link / pubDate / description
/// and, when present, an `<enclosure length="…">` byte size. Namespaced /
/// extra tags used by torrent trackers are simply ignored.
final class RSSFeedParser: NSObject, XMLParserDelegate {
    private var items: [MediaItem] = []

    private var currentElement = ""
    private var insideItem = false

    private var title = ""
    private var link = ""
    private var pubDate = ""
    private var itemDescription = ""
    private var enclosureLength: Int64?

    func parse(data: Data) -> [MediaItem] {
        items = []
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.parse()
        return items
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        let name = elementName.lowercased()
        currentElement = name

        if name == "item" || name == "entry" {
            insideItem = true
            title = ""
            link = ""
            pubDate = ""
            itemDescription = ""
            enclosureLength = nil
        }

        guard insideItem else { return }

        if name == "enclosure", let lengthString = attributeDict["length"] {
            enclosureLength = Int64(lengthString)
            if let href = attributeDict["url"], link.isEmpty {
                link = href
            }
        }

        // Atom-style <link href="…"/>
        if name == "link", let href = attributeDict["href"], !href.isEmpty {
            link = href
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard insideItem else { return }
        switch currentElement {
        case "title":
            title += string
        case "link":
            link += string
        case "pubdate", "published", "updated", "dc:date":
            pubDate += string
        case "description", "summary", "content":
            itemDescription += string
        default:
            break
        }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        let name = elementName.lowercased()
        if name == "item" || name == "entry" {
            let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
            let cleanLink = link.trimmingCharacters(in: .whitespacesAndNewlines)
            if !cleanTitle.isEmpty && !cleanLink.isEmpty {
                items.append(
                    MediaItem(
                        rawTitle: cleanTitle,
                        link: cleanLink,
                        pubDate: pubDate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            ? nil : pubDate.trimmingCharacters(in: .whitespacesAndNewlines),
                        summary: itemDescription.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            ? nil : itemDescription.trimmingCharacters(in: .whitespacesAndNewlines),
                        sizeBytes: enclosureLength
                    )
                )
            }
            insideItem = false
        }
        currentElement = ""
    }
}
