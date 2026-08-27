import Foundation

enum MilkieError: LocalizedError {
  case missingKey
  case invalidResponse
  case http(Int)

  var errorDescription: String? {
    switch self {
    case .missingKey:
      return "Add a Milkie API key in Settings."
    case .invalidResponse:
      return "Milkie returned an unreadable response."
    case let .http(code):
      return "Milkie request failed (\(code))."
    }
  }
}

struct MilkieTorrent: Identifiable, Hashable, Sendable {
  let id: String
  let releaseName: String
  let category: Int
  let size: Int64
  let seeders: Int
  let leechers: Int
  let downloaded: Int
  let createdAt: Date?
  let infoHash: String?
  let imdbID: String?
  let tmdbID: Int?

  var displayName: String { releaseName }

  var magnet: String? {
    guard let infoHash, !infoHash.isEmpty else { return nil }
    return MilkieClient.magnet(infoHash: infoHash, name: releaseName)
  }

  var torrentFileURL: URL? {
    MilkieClient.torrentDownloadURL(id: id)
  }
}

enum MilkieClient {
  static let siteURL = URL(string: "https://milkie.cc")!
  static let apiBase = URL(string: "https://milkie.cc/api/v1")!

  enum Category: Int {
    case movies = 1
    case tv = 2
    case music = 3
    case games = 4
    case ebook = 5
    case apps = 6
    case adult = 7
  }

  static func magnet(infoHash: String, name: String) -> String {
    var components = URLComponents()
    components.scheme = "magnet"
    components.queryItems = [
      URLQueryItem(name: "xt", value: "urn:btih:\(infoHash)"),
      URLQueryItem(name: "dn", value: name),
      URLQueryItem(name: "tr", value: "udp://tracker.opentrackr.org:1337/announce"),
      URLQueryItem(name: "tr", value: "udp://open.stealth.si:80/announce"),
      URLQueryItem(name: "tr", value: "udp://tracker.torrent.eu.org:451/announce"),
    ]
    return components.string ?? "magnet:?xt=urn:btih:\(infoHash)"
  }

  static func torrentDownloadURL(id: String) -> URL? {
    let key = MilkieKeyStore.key
    guard !id.isEmpty, !key.isEmpty else { return nil }
    var parts = URLComponents(string: "https://milkie.cc/api/v1/torrents/\(id)/torrent")
    parts?.queryItems = [URLQueryItem(name: "key", value: key)]
    return parts?.url
  }

  static func search(
    query: String,
    categories: [Category] = [],
    pageSize: Int = 100
  ) async throws -> [MilkieTorrent] {
    let key = MilkieKeyStore.key
    guard !key.isEmpty else { throw MilkieError.missingKey }

    var parts = URLComponents(string: "https://milkie.cc/api/v1/torrents")!
    var items = [
      URLQueryItem(name: "ps", value: String(min(max(pageSize, 1), 100))),
    ]
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    if !trimmed.isEmpty {
      items.append(URLQueryItem(name: "query", value: trimmed))
    }
    if !categories.isEmpty {
      items.append(
        URLQueryItem(name: "categories", value: categories.map { String($0.rawValue) }.joined(separator: ","))
      )
    }
    parts.queryItems = items
    guard let url = parts.url else { throw MilkieError.invalidResponse }

    var request = URLRequest(url: url)
    request.timeoutInterval = 30
    request.setValue(key, forHTTPHeaderField: "x-milkie-auth")
    request.setValue("application/json", forHTTPHeaderField: "Accept")

    let (data, response) = try await HighPriorityNetworkManager.shared.responsiveData(for: request)
    guard let http = response as? HTTPURLResponse else { throw MilkieError.invalidResponse }
    guard 200..<300 ~= http.statusCode else { throw MilkieError.http(http.statusCode) }

    let payload = try JSONDecoder().decode(SearchPayload.self, from: data)
    return payload.torrents.map { $0.model }
  }

  static func details(id: String) async throws -> MilkieTorrent {
    let key = MilkieKeyStore.key
    guard !key.isEmpty else { throw MilkieError.missingKey }
    guard let url = URL(string: "https://milkie.cc/api/v1/torrents/\(id)") else {
      throw MilkieError.invalidResponse
    }

    var request = URLRequest(url: url)
    request.timeoutInterval = 20
    request.setValue(key, forHTTPHeaderField: "x-milkie-auth")
    request.setValue("application/json", forHTTPHeaderField: "Accept")

    let (data, response) = try await HighPriorityNetworkManager.shared.responsiveData(for: request)
    guard let http = response as? HTTPURLResponse else { throw MilkieError.invalidResponse }
    guard 200..<300 ~= http.statusCode else { throw MilkieError.http(http.statusCode) }

    let payload = try JSONDecoder().decode(DetailsPayload.self, from: data)
    return payload.torrent.model
  }

  static func hydrateInfoHashes(_ torrents: [MilkieTorrent], limit: Int = 16) async -> [MilkieTorrent] {
    let targets = Array(torrents.prefix(limit))
    return await withTaskGroup(of: (String, MilkieTorrent?).self) { group in
      for torrent in targets {
        if let hash = torrent.infoHash, !hash.isEmpty {
          group.addTask { (torrent.id, torrent) }
          continue
        }
        group.addTask {
          (torrent.id, try? await details(id: torrent.id))
        }
      }
      var byID: [String: MilkieTorrent] = [:]
      for await (id, resolved) in group {
        if let resolved { byID[id] = resolved }
      }
      return torrents.map { byID[$0.id] ?? $0 }
    }
  }
}

private struct SearchPayload: Decodable {
  let torrents: [Row]
}

private struct DetailsPayload: Decodable {
  let torrent: Row
}

private struct Row: Decodable {
  let id: String
  let releaseName: String
  let category: Int?
  let size: FlexibleNumber
  let seeders: FlexibleNumber?
  let leechers: FlexibleNumber?
  let downloaded: FlexibleNumber?
  let createdAt: String?
  let infoHash: String?
  let externals: Externals?

  var model: MilkieTorrent {
    MilkieTorrent(
      id: id,
      releaseName: releaseName,
      category: category ?? 0,
      size: size.int64,
      seeders: seeders?.int ?? 0,
      leechers: leechers?.int ?? 0,
      downloaded: downloaded?.int ?? 0,
      createdAt: Self.parseDate(createdAt),
      infoHash: infoHash?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
      imdbID: externals?.imdb?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
      tmdbID: externals?.tmdb
    )
  }

  private static func parseDate(_ raw: String?) -> Date? {
    guard let raw, !raw.isEmpty else { return nil }
    return ISO8601DateFormatter.milkie.date(from: raw)
      ?? ISO8601DateFormatter.milkieFractional.date(from: raw)
  }
}

private struct Externals: Decodable {
  let imdb: String?
  let tmdb: Int?
}

private struct FlexibleNumber: Decodable {
  let int64: Int64

  var int: Int { Int(clamping: int64) }

  init(from decoder: Decoder) throws {
    let box = try decoder.singleValueContainer()
    if let value = try? box.decode(Int64.self) {
      int64 = value
    } else if let value = try? box.decode(Double.self) {
      int64 = Int64(value)
    } else if let value = try? box.decode(String.self), let parsed = Int64(value) {
      int64 = parsed
    } else {
      int64 = 0
    }
  }
}

private extension String {
  var nilIfEmpty: String? {
    isEmpty ? nil : self
  }
}

private extension ISO8601DateFormatter {
  static let milkie: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return formatter
  }()

  static let milkieFractional: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter
  }()
}
