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

    private let sessionLock = NSLock()
    private var videoSession: URLSession
    private var responsiveSession: URLSession

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
        videoSession = Self.makeVideoSession()
        responsiveSession = Self.makeResponsiveSession()
    }

    private static func makeVideoSession() -> URLSession {
        let video = URLSessionConfiguration.default
        video.networkServiceType = .video
        video.waitsForConnectivity = true
        video.allowsCellularAccess = true
        video.allowsExpensiveNetworkAccess = true
        video.allowsConstrainedNetworkAccess = true
        video.httpMaximumConnectionsPerHost = 6
        video.timeoutIntervalForResource = 7 * 24 * 60 * 60
        return URLSession(configuration: video)
    }

    private static func makeResponsiveSession() -> URLSession {
        let api = URLSessionConfiguration.default
        api.networkServiceType = .responsiveData
        api.waitsForConnectivity = true
        api.allowsCellularAccess = true
        api.allowsExpensiveNetworkAccess = true
        api.allowsConstrainedNetworkAccess = true
        api.httpMaximumConnectionsPerHost = 6
        api.timeoutIntervalForRequest = 20
        api.timeoutIntervalForResource = 45
        return URLSession(configuration: api)
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

    func resetAfterPlayback() {
        sessionLock.lock()
        let oldVideo = videoSession
        let oldResponsive = responsiveSession
        let newVideo = Self.makeVideoSession()
        let newResponsive = Self.makeResponsiveSession()
        videoSession = newVideo
        responsiveSession = newResponsive
        sessionLock.unlock()

        Self.logTaskCounts(oldVideo, label: "resetAfterPlayback: old video pool")
        Self.logTaskCounts(oldResponsive, label: "resetAfterPlayback: old API pool")

        // Cancel abandoned range, metadata and poster tasks only after the new
        // sessions are installed. New TMDB/Discover calls can therefore start
        // immediately on clean connections while stale playback work is torn down.
        oldVideo.invalidateAndCancel()
        oldResponsive.invalidateAndCancel()

        for delay in [2, 6] {
            DispatchQueue.global().asyncAfter(deadline: .now() + .seconds(delay)) {
                Self.logTaskCounts(newVideo, label: "T+\(delay)s: new video pool")
                Self.logTaskCounts(newResponsive, label: "T+\(delay)s: new API pool")
            }
        }
    }

    private static func logTaskCounts(_ session: URLSession, label: String) {
        session.getAllTasks { tasks in
            let states = tasks.map { "\($0.taskIdentifier):\($0.state.rawValue)" }.joined(separator: ", ")
            VideoThumbnailLoader.logDiagnostic(
                "\(label) — activeTasks=\(tasks.count) [\(states)]",
                level: tasks.isEmpty ? .debug : .warning
            )
        }
    }

    func data(for originalRequest: URLRequest, trafficClass: TrafficClass) async throws -> (Data, URLResponse) {
        var request = originalRequest
        request.networkServiceType = trafficClass.serviceType
        let session: URLSession
        sessionLock.lock()
        switch trafficClass {
        case .video: session = videoSession
        case .responsiveData: session = responsiveSession
        }
        sessionLock.unlock()
        let box = CancellableTaskBox()
        let startedAt = Date()
        let host = request.url?.host ?? "?"
        do {
            let result: (Data, URLResponse) = try await withTaskCancellationHandler {
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
            let elapsed = Date().timeIntervalSince(startedAt)
            if elapsed > 5 {
                // Completed, but slow enough to be a symptom worth having in
                // the log even though it didn't hang outright.
                VideoThumbnailLoader.logDiagnostic(
                    "\(trafficClass) request to \(host) took \(String(format: "%.1f", elapsed))s",
                    level: .warning
                )
            }
            return result
        } catch {
            let elapsed = Date().timeIntervalSince(startedAt)
            VideoThumbnailLoader.logDiagnostic(
                "\(trafficClass) request to \(host) FAILED after \(String(format: "%.1f", elapsed))s — \(error.localizedDescription)",
                level: .error
            )
            throw error
        }
    }
}
