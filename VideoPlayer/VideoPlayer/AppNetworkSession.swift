import Foundation

/// Dedicated session for small, user-visible API and artwork requests.
/// Keeping these requests out of URLSession.shared prevents a recently closed
/// multi-gigabyte stream from monopolizing or poisoning their connection pool.
enum AppNetworkSession {
    static let shared: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadRevalidatingCacheData
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 30
        configuration.httpMaximumConnectionsPerHost = 8
        configuration.waitsForConnectivity = false
        configuration.networkServiceType = .responsiveData
        return URLSession(configuration: configuration)
    }()
}
