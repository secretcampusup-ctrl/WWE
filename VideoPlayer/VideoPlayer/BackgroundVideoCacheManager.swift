import Foundation
import CryptoKit

/// Hidden temporary cache backed by a system background download session.
/// It never appears in Files and old entries are removed automatically.
final class BackgroundVideoCacheManager: NSObject, URLSessionDownloadDelegate {
    static let shared = BackgroundVideoCacheManager()
    static let didFinishCaching = Notification.Name("BackgroundVideoCacheDidFinish")

    private static let sessionIdentifier =
        "com.mortaza.minoz.VideoPlayer.background-cache.v1"
    private let maximumCacheBytes: Int64 = 750 * 1_024 * 1_024
    private let stateQueue = DispatchQueue(
        label: "com.mortaza.minoz.VideoPlayer.background-cache.state"
    )
    private var activeKeys = Set<String>()
    private var eventsCompletionHandler: (() -> Void)?

    private struct Descriptor: Codable {
        let key: String
        let fileExtension: String
        var fileName: String { "\(key).\(fileExtension)" }
    }

    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.background(
            withIdentifier: Self.sessionIdentifier
        )
        configuration.sessionSendsLaunchEvents = true
        configuration.isDiscretionary = false
        configuration.waitsForConnectivity = true
        configuration.allowsCellularAccess = true
        configuration.allowsExpensiveNetworkAccess = true
        configuration.allowsConstrainedNetworkAccess = true
        configuration.timeoutIntervalForResource = 7 * 24 * 60 * 60
        configuration.httpMaximumConnectionsPerHost = 3
        configuration.networkServiceType = .video // Prefetching video benefits from sustained throughput and fewer buffer stalls.

        let queue = OperationQueue()
        queue.name = "com.mortaza.minoz.VideoPlayer.background-cache.delegate"
        queue.maxConcurrentOperationCount = 1
        return URLSession(
            configuration: configuration,
            delegate: self,
            delegateQueue: queue
        )
    }()

    private override init() {
        super.init()
        try? FileManager.default.createDirectory(
            at: cacheDirectory,
            withIntermediateDirectories: true
        )
        activate()
    }

    /// Reconnect to transfers restored by iOS after the app is relaunched.
    func activate() {
        session.getAllTasks { [weak self] tasks in
            guard let self else { return }
            let keys = tasks.compactMap {
                self.descriptor(from: $0.taskDescription)?.key
            }
            self.stateQueue.async {
                self.activeKeys.formUnion(keys)
            }
        }
    }

    /// Stops obsolete hidden prefetches without touching user-visible downloads.
    func cancelAllPrefetches() {
        session.getAllTasks { [weak self] tasks in
            tasks.forEach { $0.cancel() }
            self?.stateQueue.async {
                self?.activeKeys.removeAll()
            }
        }
    }

    func setBackgroundEventsCompletionHandler(_ handler: @escaping () -> Void) {
        stateQueue.async {
            self.eventsCompletionHandler = handler
        }
    }

    /// Uses a finished cache file when available. Otherwise starts a hidden
    /// low-priority transfer and returns the remote URL immediately.
    func playbackURL(
        for remoteURL: URL,
        stableKey: String,
        suggestedFileName: String,
        headers: [String: String]
    ) -> URL {
        guard let descriptor = makeDescriptor(
            remoteURL: remoteURL,
            stableKey: stableKey,
            suggestedFileName: suggestedFileName
        ) else { return remoteURL }

        let destination = cacheDirectory.appendingPathComponent(descriptor.fileName)
        if FileManager.default.fileExists(atPath: destination.path) {
            touch(destination)
            return destination
        }

        beginDownload(
            remoteURL: remoteURL,
            descriptor: descriptor,
            headers: headers
        )
        return remoteURL
    }

    func removeCachedVideo(
        remoteURL: URL?,
        stableKey: String,
        suggestedFileName: String
    ) {
        guard let remoteURL,
              let descriptor = makeDescriptor(
                remoteURL: remoteURL,
                stableKey: stableKey,
                suggestedFileName: suggestedFileName
              ) else { return }

        session.getAllTasks { [weak self] tasks in
            guard let self else { return }
            for task in tasks where
                self.descriptor(from: task.taskDescription)?.key == descriptor.key {
                task.cancel()
            }
            let destination = self.cacheDirectory
                .appendingPathComponent(descriptor.fileName)
            try? FileManager.default.removeItem(at: destination)
            self.stateQueue.async {
                self.activeKeys.remove(descriptor.key)
            }
        }
    }

    private func beginDownload(
        remoteURL: URL,
        descriptor: Descriptor,
        headers: [String: String]
    ) {
        let shouldInspectTasks = stateQueue.sync { () -> Bool in
            guard !activeKeys.contains(descriptor.key) else { return false }
            activeKeys.insert(descriptor.key)
            return true
        }
        guard shouldInspectTasks else { return }

        session.getAllTasks { [weak self] tasks in
            guard let self else { return }
            if tasks.contains(where: {
                self.descriptor(from: $0.taskDescription)?.key == descriptor.key
            }) {
                return
            }

            let destination = self.cacheDirectory
                .appendingPathComponent(descriptor.fileName)
            guard !FileManager.default.fileExists(atPath: destination.path) else {
                self.stateQueue.async {
                    self.activeKeys.remove(descriptor.key)
                }
                return
            }

            var request = URLRequest(url: remoteURL)
            request.timeoutInterval = 7 * 24 * 60 * 60
            request.networkServiceType = .video // Cache payload is video; priority applies only inside iOS scheduling.
            for (field, value) in headers {
                request.setValue(value, forHTTPHeaderField: field)
            }

            self.pruneCache()

            let task = self.session.downloadTask(with: request)
            task.taskDescription = self.encoded(descriptor)
            task.priority = 1.0 // Highest task priority; it does not control the external router or server.
            task.resume()
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        if totalBytesWritten > maximumCacheBytes ||
            totalBytesExpectedToWrite > maximumCacheBytes {
            downloadTask.cancel()
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        guard let descriptor = descriptor(
            from: downloadTask.taskDescription
        ) else { return }
        if let response = downloadTask.response as? HTTPURLResponse,
           !(200...299).contains(response.statusCode) {
            try? FileManager.default.removeItem(at: location)
            stateQueue.async {
                self.activeKeys.remove(descriptor.key)
            }
            return
        }

        let destination = cacheDirectory.appendingPathComponent(descriptor.fileName)
        do {
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.moveItem(at: location, to: destination)
            touch(destination)
            pruneCache(keeping: destination)
            NotificationCenter.default.post(
                name: Self.didFinishCaching,
                object: destination,
                userInfo: ["key": descriptor.key]
            )
        } catch {
            try? FileManager.default.removeItem(at: location)
        }

        stateQueue.async {
            self.activeKeys.remove(descriptor.key)
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        guard error != nil,
              let descriptor = descriptor(from: task.taskDescription) else {
            return
        }
        stateQueue.async {
            self.activeKeys.remove(descriptor.key)
        }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        stateQueue.async {
            let handler = self.eventsCompletionHandler
            self.eventsCompletionHandler = nil
            DispatchQueue.main.async {
                handler?()
            }
        }
    }

    private var cacheDirectory: URL {
        FileManager.default.urls(
            for: .cachesDirectory,
            in: .userDomainMask
        )[0].appendingPathComponent(
            "BackgroundVideoCacheV1",
            isDirectory: true
        )
    }

    private func makeDescriptor(
        remoteURL: URL,
        stableKey: String,
        suggestedFileName: String
    ) -> Descriptor? {
        guard ["http", "https"].contains(
            remoteURL.scheme?.lowercased() ?? ""
        ) else { return nil }

        let suggestedExtension =
            (suggestedFileName as NSString).pathExtension.lowercased()
        let remoteExtension = remoteURL.pathExtension.lowercased()
        var ext = suggestedExtension.isEmpty
            ? remoteExtension
            : suggestedExtension
        ext = ext.filter { $0.isLetter || $0.isNumber }

        // HLS keeps using the player's segmented transient cache.
        if ext == "m3u8" { return nil }
        if ext.isEmpty || ext.count > 8 { ext = "mp4" }

        let digest = SHA256.hash(data: Data(stableKey.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return Descriptor(key: digest, fileExtension: ext)
    }

    private func encoded(_ descriptor: Descriptor) -> String? {
        guard let data = try? JSONEncoder().encode(descriptor) else {
            return nil
        }
        return data.base64EncodedString()
    }

    private func descriptor(from value: String?) -> Descriptor? {
        guard let value,
              let data = Data(base64Encoded: value) else {
            return nil
        }
        return try? JSONDecoder().decode(Descriptor.self, from: data)
    }

    private func touch(_ url: URL) {
        try? FileManager.default.setAttributes(
            [.modificationDate: Date()],
            ofItemAtPath: url.path
        )
    }

    private func pruneCache(keeping protectedURL: URL? = nil) {
        let keys: Set<URLResourceKey> = [
            .isRegularFileKey,
            .fileSizeKey,
            .contentModificationDateKey
        ]
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: cacheDirectory,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        ) else { return }

        var entries: [(url: URL, size: Int64, date: Date)] = []
        var total: Int64 = 0
        for file in files {
            guard let values = try? file.resourceValues(forKeys: keys),
                  values.isRegularFile == true else {
                continue
            }
            let size = Int64(values.fileSize ?? 0)
            entries.append((
                file,
                size,
                values.contentModificationDate ?? .distantPast
            ))
            total += size
        }

        guard total > maximumCacheBytes else { return }
        for entry in entries.sorted(by: { $0.date < $1.date })
            where entry.url != protectedURL {
            try? FileManager.default.removeItem(at: entry.url)
            total -= entry.size
            if total <= maximumCacheBytes { break }
        }
    }
}
