import Foundation
import UIKit
import ImageIO

actor ThePornDBAPIService {

    static let shared = ThePornDBAPIService()
    private init() {}

    private var cache: [String: (data: Data, timestamp: Date)] = [:]
    private let cacheDuration: TimeInterval = 900

    private func createRequest(endpoint: String, method: String = "GET", parameters: [String: String]? = nil) -> URLRequest? {
        let apiKey = ThePornDBSettings.apiKey
        guard !apiKey.isEmpty else { return nil }

        guard var urlComponents = URLComponents(string: ThePornDBSettings.baseURL + endpoint) else { return nil }
        if let parameters = parameters {
            urlComponents.queryItems = parameters.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        guard let url = urlComponents.url else { return nil }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 60
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return request
    }

    private func performRequest<T: Decodable>(
        endpoint: String,
        method: String = "GET",
        parameters: [String: String]? = nil,
        useCache: Bool = true
    ) async throws -> T {
        guard ThePornDBSettings.hasValidAPIKey else {
            throw ThePornDBError.missingAPIKey
        }

        let cacheKey = generateCacheKey(endpoint: endpoint, parameters: parameters)
        if useCache, let cached = getCachedData(key: cacheKey) {
            do {
                return try JSONDecoder().decode(T.self, from: cached)
            } catch {
                cache.removeValue(forKey: cacheKey)
            }
        }

        guard let request = createRequest(endpoint: endpoint, method: method, parameters: parameters) else {
            throw ThePornDBError.invalidURL
        }

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await AppNetworkSession.shared.data(for: request)
        } catch let error as URLError {
            throw ThePornDBError.networkError(error)
        } catch {
            throw ThePornDBError.networkError(error)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw ThePornDBError.invalidResponse
        }

        switch httpResponse.statusCode {
        case 200...299: break
        case 401: throw ThePornDBError.unauthorized
        case 429: throw ThePornDBError.serverError(httpResponse.statusCode)
        default:
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let errorMsg = json["error"] as? String ?? json["message"] as? String {
                throw ThePornDBError.apiError(errorMsg)
            }
            throw ThePornDBError.serverError(httpResponse.statusCode)
        }

        // التحقق من وجود خطأ في JSON قبل محاولة فك الترميز
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let errorMsg = json["error"] as? String ?? json["message"] as? String {
                throw ThePornDBError.apiError(errorMsg)
            }
        }

        do {
            let decoded = try JSONDecoder().decode(T.self, from: data)
            if useCache { cacheData(data, key: cacheKey) }
            return decoded
        } catch {
            // محاولة استخراج مصفوفة من الحقول المعروفة
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                let raw = String(data: data, encoding: .utf8) ?? "(Unable to read response as text)"
                throw ThePornDBError.decodingErrorWithRaw(error, raw: raw)
            }
            let knownKeys = ["data", "performers", "results", "scenes"]
            for key in knownKeys {
                if let array = json[key] as? [Any] {
                    let wrapper: [String: [Any]] = [key: array]
                    let wrapperData = try JSONSerialization.data(withJSONObject: wrapper)
                    do {
                        let decoded = try JSONDecoder().decode(T.self, from: wrapperData)
                        if useCache { cacheData(wrapperData, key: cacheKey) }
                        return decoded
                    } catch {
                        continue
                    }
                }
            }
            // إذا كانت المصفوفة مباشرة
            if let array = try? JSONSerialization.jsonObject(with: data) as? [Any] {
                if T.self == ThePornDBPerformersResponse.self {
                    let wrapper: [String: [Any]] = ["data": array]
                    let wrapperData = try JSONSerialization.data(withJSONObject: wrapper)
                    let decoded = try JSONDecoder().decode(T.self, from: wrapperData)
                    if useCache { cacheData(wrapperData, key: cacheKey) }
                    return decoded
                } else if T.self == ThePornDBScenesResponse.self {
                    let wrapper: [String: [Any]] = ["data": array]
                    let wrapperData = try JSONSerialization.data(withJSONObject: wrapper)
                    let decoded = try JSONDecoder().decode(T.self, from: wrapperData)
                    if useCache { cacheData(wrapperData, key: cacheKey) }
                    return decoded
                }
            }
            let raw = String(data: data, encoding: .utf8) ?? "(Unable to read response as text)"
            throw ThePornDBError.decodingErrorWithRaw(error, raw: raw)
        }
    }

    private func generateCacheKey(endpoint: String, parameters: [String: String]?) -> String {
        var key = endpoint
        if let params = parameters {
            let sorted = params.sorted { $0.key < $1.key }
            key += sorted.map { "\($0.key)=\($0.value)" }.joined(separator: "&")
        }
        return key
    }

    private func getCachedData(key: String) -> Data? {
        guard let cached = cache[key] else { return nil }
        if Date().timeIntervalSince(cached.timestamp) > cacheDuration {
            cache.removeValue(forKey: key)
            return nil
        }
        return cached.data
    }

    private func cacheData(_ data: Data, key: String) {
        cache[key] = (data: data, timestamp: Date())
        if cache.count > 50 {
            let oldest = cache.min { $0.value.timestamp < $1.value.timestamp }?.key
            if let key = oldest { cache.removeValue(forKey: key) }
        }
    }

    func searchPerformers(query: String, limit: Int = 20) async throws -> ThePornDBPerformersResponse {
        let parameters = ["q": query, "per_page": String(limit)]
        return try await performRequest(endpoint: "/performers", parameters: parameters)
    }

    func searchScenes(query: String, limit: Int = 20, year: Int? = nil) async throws -> ThePornDBScenesResponse {
        var parameters = ["q": query, "per_page": String(limit)]
        if let year = year { parameters["year"] = String(year) }
        return try await performRequest(endpoint: "/scenes", parameters: parameters)
    }

    /// Searches ThePornDB's dedicated JAV catalogue. Its free-text index resolves
    /// catalogue identifiers such as `JUR-174`; SKU remains a secondary fallback
    /// because not every JAV record exposes its catalogue code in the SKU field.
    func searchJav(query: String, limit: Int = 20) async throws -> ThePornDBScenesResponse {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let identifier = VideoTitleFormatter.catalogIdentifier(from: trimmed) ?? trimmed
        let pageSize = String(limit)
        let uppercasedIdentifier = identifier.uppercased()

        // File/folder names commonly append a release variant (`-U`, `-UC`, `-C`),
        // while ThePornDB indexes the base catalogue code. Keep the original title
        // untouched for display and remove the suffix only from the search candidate.
        let baseIdentifier = uppercasedIdentifier.replacingOccurrences(
            of: #"(?<=\d)[-_][A-Z]{1,4}$"#,
            with: "",
            options: .regularExpression
        )
        var candidates = [baseIdentifier]
        if uppercasedIdentifier != baseIdentifier { candidates.append(uppercasedIdentifier) }

        var lastEmpty = ThePornDBScenesResponse(data: [], scenes: nil, results: nil)
        for candidate in candidates {
            let matched: ThePornDBScenesResponse = try await performRequest(
                endpoint: "/jav",
                parameters: ["q": candidate, "per_page": pageSize]
            )
            if !matched.list.isEmpty { return matched }
            lastEmpty = matched
        }

        for candidate in candidates {
            let matched: ThePornDBScenesResponse = try await performRequest(
                endpoint: "/jav",
                parameters: ["sku": candidate, "per_page": pageSize]
            )
            if !matched.list.isEmpty { return matched }
            lastEmpty = matched
        }
        return lastEmpty
    }

    func downloadImage(from urlString: String) async throws -> UIImage {
        guard let url = URL(string: urlString) else { throw ThePornDBError.invalidURL }
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        let (data, response) = try await AppNetworkSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw ThePornDBError.serverError((response as? HTTPURLResponse)?.statusCode ?? 500)
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 1_200,
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw ThePornDBError.decodingError(NSError(domain: "ThePornDB", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to create image"]))
        }
        return UIImage(cgImage: cgImage)
    }
}
