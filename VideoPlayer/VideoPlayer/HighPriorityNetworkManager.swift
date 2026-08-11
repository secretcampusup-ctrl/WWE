import Foundation
import Network

/// Centralizes foreground networking by traffic type.
/// `.video` tells iOS that sustained throughput and buffering continuity matter for this request.
/// It can improve scheduling inside the iPhone and reduce playback stalls, but it cannot control
/// the router, ISP, remote server, radio conditions, or take bandwidth away from other devices.
final class HighPriorityNetworkManager: @unchecked Sendable {
    static let shared = HighPriorityNetworkManager()

    enum TrafficClass {
        case video
        case responsiveData

        fileprivate var serviceType: URLRequest.NetworkServiceType {
            switch self {
            case .video: return .video
            case .responsiveData: return .responsiveData
            }
        }

        fileprivate var priority: Float {
            switch self {
            case .video: return URLSessionTask.highPriority // 1.0: sustained video/file transfer.
            case .responsiveData: return 0.8 // Fast UI/API response without competing as video traffic.
            }
        }
    }

    private let videoSession: URLSession
    private let responsiveSession: URLSession

    private final class CancellableTaskBox: @unchecked Sendable {
        private let lock = NSLock()
        private var task: URLSessionTask?
        private var cancelled = false

        func install(_ value: URLSessionTask) {
            lock.lock()
            task = value
            let shouldCancel = cancelled
            lock.unlock()
            if shouldCancel { value.cancel() }
        }

        func cancel() {
            lock.lock()
            cancelled = true
            let value = task
            lock.unlock()
            value?.cancel()
        }
    }

    private init() {
        let video = URLSessionConfiguration.default
        video.networkServiceType = .video
        video.waitsForConnectivity = true
        video.allowsCellularAccess = true
        video.allowsExpensiveNetworkAccess = true
        video.allowsConstrainedNetworkAccess = true
        video.httpMaximumConnectionsPerHost = 6
        video.timeoutIntervalForResource = 7 * 24 * 60 * 60
        videoSession = URLSession(configuration: video)

        let api = URLSessionConfiguration.default
        api.networkServiceType = .responsiveData
        api.waitsForConnectivity = true
        api.allowsCellularAccess = true
        api.allowsExpensiveNetworkAccess = true
        api.allowsConstrainedNetworkAccess = true
        api.httpMaximumConnectionsPerHost = 6
        api.timeoutIntervalForRequest = 20
        api.timeoutIntervalForResource = 45
        responsiveSession = URLSession(configuration: api)
    }

    func videoData(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await data(for: request, trafficClass: .video)
    }

    func responsiveData(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await data(for: request, trafficClass: .responsiveData)
    }

    func responsiveData(from url: URL) async throws -> (Data, URLResponse) {
        try await data(for: URLRequest(url: url), trafficClass: .responsiveData)
    }

    func data(for originalRequest: URLRequest, trafficClass: TrafficClass) async throws -> (Data, URLResponse) {
        var request = originalRequest
        request.networkServiceType = trafficClass.serviceType
        let session: URLSession
        switch trafficClass {
        case .video: session = videoSession
        case .responsiveData: session = responsiveSession
        }
        let box = CancellableTaskBox()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let task = session.dataTask(with: request) { data, response, error in
                    if let error { continuation.resume(throwing: error); return }
                    guard let data, let response else { continuation.resume(throwing: URLError(.badServerResponse)); return }
                    continuation.resume(returning: (data, response))
                }
                box.install(task)
                task.priority = trafficClass.priority
                task.resume()
            }
        } onCancel: {
            box.cancel()
        }
    }
}
