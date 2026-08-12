import Foundation
import AVFoundation
import UIKit
import SwiftUI
import Combine
import CryptoKit
import Kingfisher
import KingfisherWebP

// MARK: - Active playback guard

/// Tracks the URL that's currently streaming to the player, so on-demand
/// thumbnail generation never opens a second connection to that same URL
/// while it's live. Some CDNs (e.g. PikPak) throttle a signed URL as soon as
/// they see two concurrent connections to it, which stalls the real playback
/// request — and since it's the same URL, waiting instead of skipping would
/// just recreate the problem the moment the probe fires. AppViewModel updates
/// this whenever `nowPlayingURL` changes.
enum ActivePlaybackGuard {
    private static let lock = NSLock()
    private static var _url: URL?

    static var currentURL: URL? {
        get { lock.lock(); defer { lock.unlock() }; return _url }
        set { lock.lock(); _url = newValue; lock.unlock() }
    }

    static func isActive(_ url: URL) -> Bool {
        currentURL?.absoluteString == url.absoluteString
    }
}

// MARK: - Diagnostic Logger

/// In-memory logging system for thumbnail diagnostics
struct ThumbnailLogEntry: Identifiable {
    let id = UUID()
    let timestamp: Date
    let message: String
    let level: LogLevel
    let fileID: String?
}

enum LogLevel: String, CaseIterable {
    case debug = "DEBUG"
    case info = "INFO"
    case warning = "WARNING"
    case error = "ERROR"
}

class ThumbnailDiagnosticLogger {
    static let shared = ThumbnailDiagnosticLogger()
    
    private let maxEntries = 500
    private var logs: [ThumbnailLogEntry] = []
    private let lock = NSLock()

    // MARK: - Disk persistence
    // In-memory-only logging loses everything the instant the app crashes —
    // which is exactly the moment we most need it. Every entry is appended to
    // a small rotating file on disk immediately, so the freeze/crash sequence
    // survives even a hard kill and can be pulled after relaunch.
    private let diskQueue = DispatchQueue(label: "com.mortaza.minoz.diag.log.disk")
    private let maxDiskBytes = 2 * 1024 * 1024 // 2 MB, then rotate.
    private static var logFileURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("diagnostic_log.txt")
    }
    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withFullDate, .withTime, .withFractionalSeconds]
        return f
    }()

    private init() {
        loadPersistedLogsIntoMemory()
    }
    
    func log(_ message: String, level: LogLevel = .info, fileID: String? = nil) {
        let entry = ThumbnailLogEntry(
            timestamp: Date(),
            message: message,
            level: level,
            fileID: fileID
        )
        lock.withLock {
            logs.append(entry)
            if logs.count > maxEntries {
                logs.removeFirst(logs.count - maxEntries)
            }
        }
        appendToDisk(entry)
    }

    private func appendToDisk(_ entry: ThumbnailLogEntry) {
        let timeStr = Self.isoFormatter.string(from: entry.timestamp)
        let fileIDPart = entry.fileID.map { " [\($0)]" } ?? ""
        let line = "[\(entry.level.rawValue)] \(timeStr)\(fileIDPart) \(entry.message)\n"
        guard let data = line.data(using: .utf8) else { return }
        diskQueue.async {
            let url = Self.logFileURL
            let fm = FileManager.default
            if !fm.fileExists(atPath: url.path) {
                fm.createFile(atPath: url.path, contents: nil)
            }
            guard let handle = try? FileHandle(forWritingTo: url) else { return }
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            handle.write(data)
            // Rotate once the file grows past the cap so this never becomes
            // an unbounded write on a device that's already struggling.
            if let size = try? fm.attributesOfItem(atPath: url.path)[.size] as? Int,
               size > self.maxDiskBytes {
                if let content = try? String(contentsOf: url, encoding: .utf8) {
                    let trimmed = String(content.suffix(self.maxDiskBytes / 2))
                    try? trimmed.write(to: url, atomically: true, encoding: .utf8)
                }
            }
        }
    }

    private func loadPersistedLogsIntoMemory() {
        guard let content = try? String(contentsOf: Self.logFileURL, encoding: .utf8) else { return }
        let lines = content.split(separator: "\n").suffix(maxEntries)
        for line in lines {
            logs.append(ThumbnailLogEntry(timestamp: Date(), message: String(line), level: .info, fileID: nil))
        }
    }

    /// Raw persisted log text — includes entries from before the last crash/kill.
    func exportPersistedLogFile() -> String {
        (try? String(contentsOf: Self.logFileURL, encoding: .utf8)) ?? "(no persisted log file yet)"
    }
    
    func getLogs(filter: LogLevel? = nil, searchTerm: String? = nil) -> [ThumbnailLogEntry] {
        return lock.withLock {
            logs.filter { entry in
                if let filter, entry.level != filter {
                    return false
                }
                if let searchTerm, !entry.message.contains(searchTerm) {
                    return false
                }
                return true
            }
        }
    }
    
    func clear() {
        lock.withLock {
            logs.removeAll()
        }
        diskQueue.async {
            try? FileManager.default.removeItem(at: Self.logFileURL)
        }
    }
    
    func exportLogs() -> String {
        return lock.withLock {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withFullDate, .withTime, .withFractionalSeconds]
            
            return logs.map { entry in
                let timeStr = formatter.string(from: entry.timestamp)
                return "[\(entry.level.rawValue)] \(timeStr) \(entry.message)"
            }.joined(separator: "\n")
        }
    }
}

extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}

extension HTTPURLResponse {
    var responseHeaders: [String: String] {
        (allHeaderFields as? [String: String]) ?? [:]
    }
}

// MARK: - Notification Names

extension Notification.Name {
    static let stablePosterDidUpdate = Notification.Name("stablePosterDidUpdate")
    static let posterPrefetchDidFinish = Notification.Name("posterPrefetchDidFinish")
}

enum ThumbnailSizeTier: String {
    case small
    case medium
    case large
}

// MARK: - App-wide thumbnail concurrency gate

/// Bounds how many thumbnail/poster fetches (network + image decode) can run
/// at the same instant, no matter which call site triggered them —
/// `schedulePrefetchPosters` below, or a grid cell's own `.task` (e.g.
/// `PikPakFilePoster` in PikPakWebDAVView.swift). Without this, a screen with
/// many videos can fire dozens of simultaneous ThePornDB/network requests the
/// moment it appears, which is what was causing the app to get killed for
/// memory pressure. Requests still queue and run — nothing is dropped —
/// they just run a few at a time instead of all at once.
actor ThumbnailLoadGate {
    static let shared = ThumbnailLoadGate()

    /// 1 = strictly sequential (one thumbnail fetch at a time, app-wide) — the
    /// bounded-parallelism version (3) still wasn't enough given how many
    /// screens fire requests independently, so this is now a hard one-at-a-time
    /// queue across every section (PikPak, Offcloud, Recent, etc.).
    private let maxConcurrent = 6
    private var running = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    private init() {}

    func acquire() async {
        if running < maxConcurrent {
            running += 1
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
        running += 1
    }

    func release() {
        running -= 1
        if !waiters.isEmpty {
            waiters.removeFirst().resume()
        }
    }
}

struct ProtectedDownsamplingImageProcessor: ImageProcessor {
    let targetSize: CGSize
    let maximumSourceBytes: Int

    var identifier: String {
        "com.murtadha.thumbnail.downsample.\(Int(targetSize.width))x\(Int(targetSize.height)).max\(maximumSourceBytes)"
    }

    func process(item: ImageProcessItem, options: KingfisherParsedOptionsInfo) -> KFCrossPlatformImage? {
        if case .data(let data) = item, data.count > maximumSourceBytes {
            return nil
        }
        return DownsamplingImageProcessor(size: targetSize).process(item: item, options: options)
    }
}

struct StrictWebPThumbnailSerializer: CacheSerializer {
    let maximumBytes: Int

    func data(with image: KFCrossPlatformImage, original: Data?) -> Data? {
        ThumbnailPipeline.webPData(for: image, maximumBytes: maximumBytes)
    }

    func image(with data: Data, options: KingfisherParsedOptionsInfo) -> KFCrossPlatformImage? {
        guard ThumbnailPipeline.isWebP(data), data.count <= maximumBytes else { return nil }
        return WebPProcessor.default.process(item: .data(data), options: options)
    }
}

enum ThumbnailPipeline {
    static let gridMaximumBytes = 200 * 1_024
    static let largeMaximumBytes = 900 * 1_024
    static let sourceHardLimitBytes = 1 * 1_024 * 1_024

    private static var configured = false
    private static var memoryWarningObserver: NSObjectProtocol?

    static func configure() {
        guard !configured else { return }
        configured = true

        let cache = ImageCache.default
        cache.diskStorage.config.sizeLimit = 180 * 1_024 * 1_024
        cache.memoryStorage.config.totalCostLimit = 32 * 1_024 * 1_024
        cache.memoryStorage.config.countLimit = 120

        let modifier = AnyModifier { request in
            var request = request
            request.setValue("image/webp", forHTTPHeaderField: "Accept")
            if request.value(forHTTPHeaderField: "User-Agent") == nil {
                request.setValue(
                    "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15",
                    forHTTPHeaderField: "User-Agent"
                )
            }
            return request
        }
        KingfisherManager.shared.defaultOptions.append(.requestModifier(modifier))

        memoryWarningObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: .main
        ) { _ in
            ImageCache.default.clearMemoryCache()
            VideoThumbnailLoader.clearMemoryCache()
        }

        removeLegacyRasterCaches()
    }

    static func tier(for targetPointSize: CGSize, scale: CGFloat = UIScreen.main.scale) -> ThumbnailSizeTier {
        let pixelWidth = targetPointSize.width * scale
        if pixelWidth <= 300 { return .small }
        if pixelWidth <= 600 { return .medium }
        return .large
    }

    static func targetPointSize(for tier: ThumbnailSizeTier, aspectRatio: CGFloat = 16.0 / 9.0) -> CGSize {
        let pixelWidth: CGFloat
        switch tier {
        case .small: pixelWidth = 240
        case .medium: pixelWidth = 600
        case .large: pixelWidth = 1_200
        }
        let pointWidth = pixelWidth / max(UIScreen.main.scale, 1)
        return CGSize(width: pointWidth, height: pointWidth / aspectRatio)
    }

    static func sizedURL(from url: URL, tier: ThumbnailSizeTier) -> URL {
        if url.absoluteString.contains("{size}") {
            return URL(string: url.absoluteString.replacingOccurrences(of: "{size}", with: tier.rawValue)) ?? url
        }
        guard url.path.contains("/thumbnails/") else { return url }
        var parts = URLComponents(url: url, resolvingAgainstBaseURL: false)
        var items = parts?.queryItems ?? []
        items.removeAll { $0.name == "size" }
        items.append(URLQueryItem(name: "size", value: tier.rawValue))
        parts?.queryItems = items
        return parts?.url ?? url
    }

    static func isWebP(_ data: Data) -> Bool {
        guard data.count >= 12 else { return false }
        let bytes = Array(data.prefix(12))
        return bytes[0...3].elementsEqual([0x52, 0x49, 0x46, 0x46])
            && bytes[8...11].elementsEqual([0x57, 0x45, 0x42, 0x50])
    }
    static func webPData(for image: KFCrossPlatformImage, maximumBytes: Int, preferredBytes: Int? = nil) -> Data? {
        let preferredBytes = min(maximumBytes, preferredBytes ?? (80 * 1_024))
        var smallestFallback: Data?
        for quality: Float in [82, 72, 62, 52, 42, 32, 24, 18] {
            guard let data = image.kf.webpRepresentation(isLossy: true, quality: quality) else { continue }
            if data.count <= preferredBytes { return data }
            if data.count <= maximumBytes { smallestFallback = data }
        }
        return smallestFallback
    }

    private static func removeLegacyRasterCaches() {
        guard let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return }
        let directory = base.appendingPathComponent("VideoPostersV3", isDirectory: true)
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return }
        for file in files where ["jpg", "jpeg", "png"].contains(file.pathExtension.lowercased()) {
            try? FileManager.default.removeItem(at: file)
        }
    }
}
// MARK: - VideoThumbnailLoader

/// Loads and caches medium-sized video poster frames off the main thread.
enum VideoThumbnailLoader {

    // MARK: - Automatic download kill switch
    //
    // Master switch for AUTOMATIC (non-user-initiated) network activity: background
    // prefetching of grid posters, extracting a frame from a remote video just because
    // a screen appeared, and downloading remote poster URLs on appear.
    //
    // This does NOT affect:
    //   - Manual actions the user explicitly triggers (Yandex cover search, ThePornDB
    //     search screen, picking a custom poster from Photos, "Download All Thumbnails",
    //     "Generate IMG from Video").
    //   - Reading locally cached images already on disk.
    //   - Generating a poster from a video that's already playing (no extra network use).
    //   - Automatic ThePornDB metadata lookup (see `fetchThePornDBMetadata`), which is a
    //     deliberate, separate exception and always runs regardless of this switch.
    //
    // Set to `false` so opening the app / browsing lists never starts a silent download.
    static let isAutomaticDownloadEnabled = false

    private static let cacheFolderName = "VideoPostersV3"
    private static let maxPixelSize: CGFloat = 600
    private static let maximumDiskCacheBytes: Int64 = 300 * 1_024 * 1_024

    /// Small compatibility cache; Kingfisher owns the main 50 MB memory cache.
    private static let memoryCache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 30
        cache.totalCostLimit = 8 * 1024 * 1024
        return cache
    }()


    static func clearMemoryCache() {
        memoryCache.removeAllObjects()
    }
    /// In-flight requests coordinator to prevent duplicate concurrent requests for the same URL
    private static let requestCoordinator = ThumbnailRequestCoordinator()

    /// Cache namespace for account-specific invalidation (no sensitive data)
    private static var cacheNamespace: String = ""

    /// Previous cache folder names to clean up
    private static let oldCacheFolderNames = ["VideoPosters", "VideoPostersV2"]

    private static var cacheDirectory: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent(cacheFolderName, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Generate cache key with optional namespace (no sensitive data)
    private static func cacheKey(for remote: URL) -> String {
        let digest = SHA256.hash(data: Data(remote.absoluteString.utf8))
        let key = digest.map { String(format: "%02x", $0) }.joined()
        if !cacheNamespace.isEmpty {
            return "\(cacheNamespace)|\(key)"
        }
        return key
    }

    /// Use SHA256 hash for cache keys to avoid collisions (especially for PikPak URLs)
    static func cacheFileURL(forRemoteURL remote: URL) -> URL {
        let key = cacheKey(for: remote)
        return cacheDirectory.appendingPathComponent("\(key).webp")
    }

    // MARK: - Notifications

    static let stablePosterDidUpdateNotification = Notification.Name.stablePosterDidUpdate
    static let posterPrefetchDidFinishNotification = Notification.Name.posterPrefetchDidFinish

    /// One poster identity shared by Details, Favorites, Recent and every provider list.
    static func canonicalPosterCacheKey(for title: String) -> String {
        let normalized = VideoTitleFormatter.title(from: title)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return "canonical-poster|\(normalized)"
    }

    // MARK: - Cache API (for stable keys)

    private static func stableCacheFileURL(for key: String) -> URL {
        let digest = SHA256.hash(data: Data(key.utf8))
        let name = digest.map { String(format: "%02x", $0) }.joined()
        return cacheDirectory.appendingPathComponent("stable-\(name).webp")
    }

    /// Get cached image using a stable key from memory or persistent disk cache.
    static func cachedImage(forStableKey key: String) -> UIImage? {
        if let image = memoryCache.object(forKey: key as NSString) { return image }
        let fileURL = stableCacheFileURL(for: key)
        guard let data = try? Data(contentsOf: fileURL),
              let image = UIImage(data: data) else { return nil }
        let pixelWidth = image.cgImage?.width ?? Int(image.size.width)
        let pixelHeight = image.cgImage?.height ?? Int(image.size.height)
        memoryCache.setObject(image, forKey: key as NSString, cost: pixelWidth * pixelHeight * 4)
        return image
    }

    private static let suppressedStableKeysDefaultsKey = "suppressedStablePosterKeys"

    /// Cache a lightweight image with a stable key in memory and on disk.
    static func cacheImage(_ image: UIImage, forStableKey key: String, maximumBytes: Int = ThumbnailPipeline.gridMaximumBytes) {
        setStableImageSuppressed(false, forKey: key)
        storeStableImage(image, forKey: key, maxSide: maxPixelSize, quality: 0.72, maximumBytes: maximumBytes)
    }

    /// Cache a high-quality folder cover while keeping a bounded disk cache.
    static func cacheHighQualityImage(_ image: UIImage, forStableKey key: String, maximumBytes: Int = ThumbnailPipeline.gridMaximumBytes) {
        setStableImageSuppressed(false, forKey: key)
        storeStableImage(
            image,
            forKey: key,
            maxSide: 1_200,
            quality: 0.75,
            maximumBytes: maximumBytes,
            preferredBytes: maximumBytes
        )
    }

    /// Remove a selected/search cover and prevent automatic regeneration until a new cover is chosen.
    static func removeCachedImage(forStableKey key: String) {
        setStableImageSuppressed(true, forKey: key)
        memoryCache.removeObject(forKey: key as NSString)
        try? FileManager.default.removeItem(at: stableCacheFileURL(for: key))
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: stablePosterDidUpdateNotification, object: key)
        }
    }

    static func isStableImageSuppressed(forKey key: String) -> Bool {
        Set(UserDefaults.standard.stringArray(forKey: suppressedStableKeysDefaultsKey) ?? []).contains(key)
    }

    private static func setStableImageSuppressed(_ suppressed: Bool, forKey key: String) {
        var keys = Set(UserDefaults.standard.stringArray(forKey: suppressedStableKeysDefaultsKey) ?? [])
        if suppressed { keys.insert(key) } else { keys.remove(key) }
        UserDefaults.standard.set(Array(keys), forKey: suppressedStableKeysDefaultsKey)
    }

    private static func storeStableImage(
        _ image: UIImage,
        forKey key: String,
        maxSide: CGFloat,
        quality: CGFloat,
        maximumBytes: Int = ThumbnailPipeline.gridMaximumBytes,
        preferredBytes: Int? = nil
    ) {
        let resized = resizeImage(image, maxSide: maxSide)
        let pixelWidth = resized.cgImage?.width ?? Int(resized.size.width)
        let pixelHeight = resized.cgImage?.height ?? Int(resized.size.height)
        memoryCache.setObject(resized, forKey: key as NSString, cost: pixelWidth * pixelHeight * 4)
        if let data = ThumbnailPipeline.webPData(for: resized, maximumBytes: maximumBytes, preferredBytes: preferredBytes) {
            try? data.write(to: stableCacheFileURL(for: key), options: .atomic)
            trimDiskCacheIfNeeded()
        }
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: stablePosterDidUpdateNotification, object: key)
        }
    }

    /// Returns a cached UIImage from memory (thread-safe, no MainActor needed).
    static func cachedImage(for remote: URL) -> UIImage? {
        let key = cacheKey(for: remote)
        let shortFileID = String(key.prefix(8))
        let result = memoryCache.object(forKey: key as NSString)
        if result != nil {
            logDiagnostic("[PikPakThumbnail] file=\(shortFileID) stage=memoryCache result=hit", level: .debug, fileID: shortFileID)
            print("[PikPakThumbnail] file=\(shortFileID) stage=memoryCache result=hit")
        } else {
            logDiagnostic("[PikPakThumbnail] file=\(shortFileID) stage=memoryCache result=miss", level: .debug, fileID: shortFileID)
            print("[PikPakThumbnail] file=\(shortFileID) stage=memoryCache result=miss")
            // Check disk cache if memory miss (PikPak only)
            if let diskImage = diskCachedImage(forKey: key) {
                logDiagnostic("[PikPakThumbnail] file=\(shortFileID) stage=diskCache result=hit", level: .debug, fileID: shortFileID)
                print("[PikPakThumbnail] file=\(shortFileID) stage=diskCache result=hit")
                return diskImage
            } else {
                logDiagnostic("[PikPakThumbnail] file=\(shortFileID) stage=diskCache result=miss", level: .debug, fileID: shortFileID)
                print("[PikPakThumbnail] file=\(shortFileID) stage=diskCache result=miss")
            }
        }
        return result
    }

    /// Reads and decodes a stable cached poster away from the main thread.
    static func cachedImageAsync(forStableKey key: String) async -> UIImage? {
        if let memoryImage = memoryCache.object(forKey: key as NSString) { return memoryImage }
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: cachedImage(forStableKey: key))
            }
        }
    }

    /// Load image from disk cache
    private static func diskCachedImage(forKey key: String) -> UIImage? {
        let fileURL = cacheDirectory.appendingPathComponent("\(key).webp")
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return UIImage(data: data)
    }

    // MARK: - Download and Cache

    /// Download and downsample a remote thumbnail with Kingfisher.
    static func downloadRemoteImage(
        from url: URL,
        headers: [String: String] = [:],
        stableKey: String? = nil,
        maxRetries: Int = 2,
        targetPointSize: CGSize? = nil
    ) async -> UIImage? {
        guard !Task.isCancelled else { return nil }
        let requestedSize = targetPointSize ?? ThumbnailPipeline.targetPointSize(for: .medium)
        let tier = ThumbnailPipeline.tier(for: requestedSize)
        let sourceURL = ThumbnailPipeline.sizedURL(from: url, tier: tier)
        let requestKey = stableKey ?? cacheKey(for: sourceURL)
        let resourceURL = sourceURL
        let processor = ProtectedDownsamplingImageProcessor(
            targetSize: requestedSize,
            maximumSourceBytes: ThumbnailPipeline.sourceHardLimitBytes
        )
        let maximumCacheBytes = tier == .large
            ? ThumbnailPipeline.largeMaximumBytes
            : ThumbnailPipeline.gridMaximumBytes
        let serializer = StrictWebPThumbnailSerializer(maximumBytes: maximumCacheBytes)
        let modifier = AnyModifier { request in
            var request = request
            request.timeoutInterval = 20
            request.setValue("image/webp", forHTTPHeaderField: "Accept")
            for (key, value) in headers {
                request.setValue(value, forHTTPHeaderField: key)
            }
            if request.value(forHTTPHeaderField: "User-Agent") == nil {
                request.setValue(
                    "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15",
                    forHTTPHeaderField: "User-Agent"
                )
            }
            return request
        }
        let options: KingfisherOptionsInfo = [
            .processor(processor),
            .cacheSerializer(serializer),
            .requestModifier(modifier),
            .scaleFactor(1.0),
            .loadDiskFileSynchronously
        ]

        return await withCheckedContinuation { continuation in
            KingfisherManager.shared.retrieveImage(with: resourceURL, options: options) { result in
                switch result {
                case .success(let value):
                    if let stableKey { cacheImage(value.image, forStableKey: stableKey) }
                    continuation.resume(returning: value.image)
                case .failure:
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    /// Generate a poster frame asynchronously with improved frame selection.
    /// Loads video duration first, then picks optimal frame time dynamically.
    static func loadPoster(
        for remote: URL,
        headers: [String: String] = [:],
        stableKey: String? = nil,
        targetPointSize: CGSize? = nil
    ) async -> UIImage? {
        let cacheKeyStr = stableKey ?? remote.absoluteString
        let pointSize = targetPointSize ?? ThumbnailPipeline.targetPointSize(for: .medium)
        let screenScale = await MainActor.run { UIScreen.main.scale }
        let targetPixelSize = CGSize(
            width: max(pointSize.width * screenScale, 1),
            height: max(pointSize.height * screenScale, 1)
        )
        let targetMaxSide = max(targetPixelSize.width, targetPixelSize.height)

        let cacheIdentityURL = thumbnailCacheIdentityURL(
            for: remote,
            pixelSize: targetPixelSize
        )
        if let cached = cachedImage(for: cacheIdentityURL) {
            return cached
        }

        // Nothing cached yet — generating a poster from here on means reading (and, for a
        // remote URL, downloading) video bytes automatically. Skip unless the caller is a
        // manual, user-initiated action.
        guard isAutomaticDownloadEnabled else { return nil }

        // Never open a second connection to the exact URL that's actively streaming —
        // see ActivePlaybackGuard. The Recent list re-renders this item's cell the
        // instant playback starts, and without this check it would race the real
        // player connection for the same signed CDN URL.
        guard !ActivePlaybackGuard.isActive(remote) else { return nil }

        return await requestCoordinator.image(for: "\(cacheKeyStr)|\(Int(targetPixelSize.width))x\(Int(targetPixelSize.height))") { [remote, headers] in
            let image: UIImage?
            if targetPixelSize.width <= 360 {
                image = await generateFastListThumbnail(
                    url: remote,
                    headers: headers,
                    maximumPixelSize: targetPixelSize
                )
            } else {
                image = await generateThumbnail(
                    url: remote,
                    headers: headers,
                    maximumPixelSize: targetPixelSize
                )
            }

            guard let image else { return nil }
            let resized = image.size.width > targetMaxSide || image.size.height > targetMaxSide
                ? resizeImage(image, maxSide: targetMaxSide)
                : image
            let finalCost = Int(resized.size.width * resized.size.height * 4)
            if let stableKey { cacheImage(resized, forStableKey: stableKey) }

            if let data = ThumbnailPipeline.webPData(for: resized, maximumBytes: ThumbnailPipeline.gridMaximumBytes) {
                do {
                    try data.write(to: cacheFileURL(forRemoteURL: cacheIdentityURL), options: Data.WritingOptions.atomic)
                    trimDiskCacheIfNeeded()
                } catch {
                    print("Failed to write thumbnail to disk: \(error)")
                }
            }

            let key = cacheKey(for: cacheIdentityURL) as NSString
            memoryCache.setObject(resized, forKey: key, cost: finalCost)
            return resized
        }
    }

    private static func thumbnailCacheIdentityURL(for remote: URL, pixelSize: CGSize) -> URL {
        var parts = URLComponents(url: remote, resolvingAgainstBaseURL: false)
        var items = parts?.queryItems ?? []
        items.removeAll { $0.name == "thumbnail_px" }
        items.append(URLQueryItem(
            name: "thumbnail_px",
            value: "\(Int(pixelSize.width))x\(Int(pixelSize.height))"
        ))
        parts?.queryItems = items
        return parts?.url ?? remote
    }
    /// Resize image to fit max side while preserving aspect ratio
    private static func resizeImage(_ image: UIImage, maxSide: CGFloat) -> UIImage {
        let w = image.size.width
        let h = image.size.height
        let longest = max(w, h)
        guard longest > maxSide else { return image }
        let scale = maxSide / longest
        let newSize = CGSize(width: w * scale, height: h * scale)
        let renderer = UIGraphicsImageRenderer(size: newSize)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: newSize))
        }
    }

    /// Fast path for list cells: avoid loading duration and request a keyframe
    /// near the beginning with broad tolerance, eliminating an extra network round-trip.
    private static func generateFastListThumbnail(
        url: URL,
        headers: [String: String] = [:],
        maximumPixelSize: CGSize
    ) async -> UIImage? {
        var options: [String: Any] = [
            AVURLAssetPreferPreciseDurationAndTimingKey: false
        ]
        if !headers.isEmpty {
            options["AVURLAssetHTTPHeaderFieldsKey"] = headers
        }

        let asset = AVURLAsset(url: url, options: options)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = maximumPixelSize
        generator.requestedTimeToleranceBefore = .positiveInfinity
        generator.requestedTimeToleranceAfter = .positiveInfinity

        // Prefer 40s with broad keyframe tolerance (cheap). One fallback only —
        // multiple sequential seeks stall the main scroll when many cells load.
        for seconds in [40.0, 1.0] {
            guard !Task.isCancelled else { return nil }
            do {
                let time = CMTime(seconds: seconds, preferredTimescale: 600)
                return UIImage(cgImage: try generator.copyCGImage(at: time, actualTime: nil))
            } catch {
                continue
            }
        }
        return nil
    }
    /// Generate a poster frame from video URL
    private static func generateThumbnail(
        url: URL,
        headers: [String: String] = [:],
        maximumPixelSize: CGSize
    ) async -> UIImage? {
        var options: [String: Any] = [
            AVURLAssetPreferPreciseDurationAndTimingKey: false
        ]
        if !headers.isEmpty {
            options["AVURLAssetHTTPHeaderFieldsKey"] = headers
        }

        let asset = AVURLAsset(url: url, options: options)

        // Load duration asynchronously using async/await
        let duration = await withCheckedContinuation { continuation in
            asset.loadValuesAsynchronously(forKeys: ["duration"]) {
                let status = asset.statusOfValue(forKey: "duration", error: nil)
                if status == .loaded {
                    let d = CMTimeGetSeconds(asset.duration)
                    if d.isFinite && d > 0 {
                        continuation.resume(returning: d)
                        return
                    }
                }
                continuation.resume(returning: 30.0)
            }
        }

        // Dynamic frame selection based on video duration
        let targetSeconds: Double
        if duration < 5 {
            targetSeconds = duration * 0.3  // First 30% for very short videos
        } else if duration < 15 {
            targetSeconds = duration * 0.5  // Middle for short videos
        } else if duration < 60 {
            targetSeconds = min(10.0, duration * 0.5)  // Up to 10s for medium videos
        } else {
            targetSeconds = 10.0  // Consistent 10s for long videos
        }

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = maximumPixelSize
        generator.requestedTimeToleranceBefore = CMTime(seconds: 1.0, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 1.0, preferredTimescale: 600)

        // Try multiple times
        let times: [CMTime] = [
            CMTime(seconds: targetSeconds, preferredTimescale: 600),
            CMTime(seconds: 0.0, preferredTimescale: 600),
            CMTime(seconds: min(1.0, duration), preferredTimescale: 600)
        ]

        for time in times {
            guard !Task.isCancelled else { return nil }

            do {
                let cg = try generator.copyCGImage(at: time, actualTime: nil)
                // We use requestedTimeToleranceBefore/After for timing tolerance
                // No need to check actualTime - the generator will return the closest frame
                return UIImage(cgImage: cg)
            } catch {
                continue
            }
        }
        return nil
    }

    /// Capture a single high-resolution frame between 0:30 and 1:00 (clamped to the
    /// video's actual duration) for use by bulk thumbnail generation. Only one frame
    /// is decoded; both the cell and detail sizes are derived from it.
    private static func captureBulkFrame(url: URL, headers: [String: String] = [:]) async -> UIImage? {
        var options: [String: Any] = [AVURLAssetPreferPreciseDurationAndTimingKey: false]
        if !headers.isEmpty { options["AVURLAssetHTTPHeaderFieldsKey"] = headers }
        let asset = AVURLAsset(url: url, options: options)

        let duration = await withCheckedContinuation { (continuation: CheckedContinuation<Double, Never>) in
            asset.loadValuesAsynchronously(forKeys: ["duration"]) {
                let status = asset.statusOfValue(forKey: "duration", error: nil)
                if status == .loaded {
                    let seconds = CMTimeGetSeconds(asset.duration)
                    if seconds.isFinite, seconds > 0 {
                        continuation.resume(returning: seconds)
                        return
                    }
                }
                continuation.resume(returning: 60.0)
            }
        }

        // Fixed poster time: 40s (or mid-point when the video is shorter).
        let targetSeconds: Double = duration > 40 ? 40.0 : max(0, duration * 0.5)
        let lowerBound = targetSeconds
        let upperBound = targetSeconds

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 1_200, height: 1_200)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 1, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 1, preferredTimescale: 600)

        for seconds in [targetSeconds, lowerBound, 0] {
            guard !Task.isCancelled else { return nil }
            if let cg = try? generator.copyCGImage(at: CMTime(seconds: seconds, preferredTimescale: 600), actualTime: nil) {
                return UIImage(cgImage: cg)
            }
        }
        return nil
    }

    /// The stable key used for the higher-resolution poster shown on the video
    /// detail screen. Matches the `|detail` convention `VideoDetailsView` already
    /// looks for when resolving `posterCacheKey`.
    static func detailStableKey(for stableKey: String) -> String {
        "\(stableKey)|detail"
    }

    /// Generate and cache both thumbnail sizes for one video under `stableKey`,
    /// used by "Download All Thumbnails". Skips work entirely if a cell thumbnail
    /// already exists for this key. Cell (<=80KB) is stored under `stableKey` so
    /// it appears immediately in every grid/poster view that already reads that
    /// key; detail (<=350KB, higher resolution) is stored under the `|detail` key
    /// so `VideoDetailsView` picks it up automatically.
    @discardableResult
    static func generateAndCacheBulkThumbnails(
        for url: URL,
        stableKey: String,
        headers: [String: String] = [:]
    ) async -> Bool {
        guard cachedImage(forStableKey: stableKey) == nil else { return true }
        guard let frame = await captureBulkFrame(url: url, headers: headers) else { return false }

        cacheImage(frame, forStableKey: stableKey, maximumBytes: 80 * 1_024)
        cacheHighQualityImage(frame, forStableKey: detailStableKey(for: stableKey), maximumBytes: 350 * 1_024)
        return true
    }

    /// Generate a poster frame at 40 seconds (for Offcloud)
    static func generatePosterAt15Seconds(
        for url: URL,
        headers: [String: String] = [:],
        stableKey: String? = nil,
        preferredFileExtension: String = ""
    ) async -> UIImage? {
        let cacheKeyStr = stableKey ?? url.absoluteString

        // Check in-memory cache first
        if let stableKey, let cached = cachedImage(forStableKey: stableKey) {
            return cached
        }

        return await requestCoordinator.image(for: cacheKeyStr) { [url, headers] in
            let image = await generateThumbnailAt40Seconds(url: url, headers: headers)

            if let image {
                // Downsample if too large
                let maxSize: CGFloat = maxPixelSize
                let resized = image.size.width > maxSize || image.size.height > maxSize
                    ? resizeImage(image, maxSide: maxSize)
                    : image

                // Cache with stable key if provided
                if let stableKey {
                    let finalCost = Int(resized.size.width * resized.size.height * 4)

                    memoryCache.setObject(resized, forKey: stableKey as NSString, cost: finalCost)
                }

                // Also cache to disk for long-term storage
                if let data = ThumbnailPipeline.webPData(for: resized, maximumBytes: ThumbnailPipeline.gridMaximumBytes) {
                    let fileURL = cacheFileURL(forRemoteURL: url)
                    do {
                        try data.write(to: fileURL, options: Data.WritingOptions.atomic)
                        trimDiskCacheIfNeeded()
                    } catch {
                        print("Failed to write thumbnail to disk: \(error)")
                    }
                }
            }

            return image
        }
    }

    /// Generate a poster frame specifically at 40 seconds
    private static func generateThumbnailAt40Seconds(url: URL, headers: [String: String] = [:]) async -> UIImage? {
        var options: [String: Any] = [
            AVURLAssetPreferPreciseDurationAndTimingKey: false
        ]
        if !headers.isEmpty {
            options["AVURLAssetHTTPHeaderFieldsKey"] = headers
        }

        let asset = AVURLAsset(url: url, options: options)

        // Load duration
        let duration = await withCheckedContinuation { continuation in
            asset.loadValuesAsynchronously(forKeys: ["duration"]) {
                let status = asset.statusOfValue(forKey: "duration", error: nil)
                if status == .loaded {
                    let d = CMTimeGetSeconds(asset.duration)
                    if d.isFinite && d > 0 {
                        continuation.resume(returning: d)
                        return
                    }
                }
                continuation.resume(returning: 30.0)
            }
        }

        // Prefer 40 seconds; clamp when the video is shorter.
        let targetSeconds = duration > 40 ? 40.0 : max(0.0, duration * 0.5)
        let safeTime = max(0.0, min(targetSeconds, max(duration - 0.5, 0)))

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxPixelSize, height: maxPixelSize)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.5, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.5, preferredTimescale: 600)

        let time = CMTime(seconds: safeTime, preferredTimescale: 600)

        do {
            let cg = try generator.copyCGImage(at: time, actualTime: nil)
            return UIImage(cgImage: cg)
        } catch {
            // Try fallback time
            let fallbackTime = CMTime(seconds: min(5.0, duration / 2), preferredTimescale: 600)
            do {
                let cg = try generator.copyCGImage(at: fallbackTime, actualTime: nil)
                return UIImage(cgImage: cg)
            } catch {
                return nil
            }
        }
    }

    /// Load series poster by name (for automatic series poster matching)
    static func loadSeriesPoster(named seriesTitle: String) async -> UIImage? {
        let shortTitle = String(seriesTitle.prefix(8))
        logDiagnostic("[PikPakThumbnail] series=\(shortTitle) stage=poster_fetch", level: .info, fileID: shortTitle)
        
        // Try to find a matching poster online (placeholder implementation)
        // In the original, this would search for posters online
        return nil
    }

    /// Cache poster from AVAsset (for VideoPlaybackEngine)
    static func cachePoster(from asset: AVAsset, for url: URL) async -> UIImage? {
        let image = await generateThumbnail(url: url, maximumPixelSize: CGSize(width: maxPixelSize, height: maxPixelSize))

        if let image {
            let cost = Int(image.size.width * image.size.height * 4)
            let maxSize: CGFloat = maxPixelSize
            let resized = image.size.width > maxSize || image.size.height > maxSize
                ? resizeImage(image, maxSide: maxSize)
                : image

            let finalCost = Int(resized.size.width * resized.size.height * 4)
            

            if let data = ThumbnailPipeline.webPData(for: resized, maximumBytes: ThumbnailPipeline.gridMaximumBytes) {
                do {
                    try data.write(to: cacheFileURL(forRemoteURL: url), options: Data.WritingOptions.atomic)
                    trimDiskCacheIfNeeded()
                } catch {
                    print("Failed to write thumbnail to disk: \(error)")
                }
            }

            let key = cacheKey(for: url) as NSString
            memoryCache.setObject(resized, forKey: key, cost: finalCost)

            return resized
        }

        return nil
    }

    /// Combined metadata pulled from ThePornDB for a video: whichever of a scene or a
    /// performer matched first, plus the cover image already downloaded.
    struct ThePornDBMetadata {
        enum Source { case scene, performer }
        let source: Source
        let title: String?
        let performers: [String]
        let tags: [String]
        let date: String?
        let siteName: String?
        let coverImage: UIImage?
    }

    /// Automatic ThePornDB metadata lookup — this is intentionally NOT gated by
    /// `isAutomaticDownloadEnabled`. Every other automatic network fetch in this file
    /// stays off by default; ThePornDB enrichment is the one deliberate exception and
    /// runs everywhere the app shows a video (details screen, folder covers, etc).
    ///
    /// يجلب بيانات (غلاف + عنوان + ممثلين + تاغز + تاريخ) من ThePornDB اعتماداً على
    /// النص المفلتر (العنوان النظيف للفيديو). يبحث أولاً في المشاهد (scenes)، وإذا ما
    /// كانت هناك نتائج يتحول للبحث في الممثلين (performers) — ويختار أول نتيجة دائماً
    /// في الحالتين.
    static func fetchThePornDBMetadata(for query: String) async -> ThePornDBMetadata? {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, ThePornDBSettings.hasValidAPIKey else { return nil }

        // 1) Scenes first.
        do {
            let limit = ThePornDBSettings.SceneSearch.defaultLimit
            var year: Int?
            if ThePornDBSettings.SceneSearch.filterByYear {
                year = ThePornDBSettings.SceneSearch.year
            }
            let response = try await ThePornDBAPIService.shared.searchScenes(
                query: text,
                limit: limit,
                year: year
            )
            if let scene = response.list.first {
                var cover: UIImage?
                if let imageURL = scene.bestImage {
                    cover = try? await ThePornDBAPIService.shared.downloadImage(from: imageURL)
                }
                return ThePornDBMetadata(
                    source: .scene,
                    title: scene.title,
                    performers: (scene.performers ?? []).compactMap { $0.name },
                    tags: scene.tagNames,
                    date: scene.date,
                    siteName: scene.site,
                    coverImage: cover
                )
            }
        } catch {
            logDiagnostic("[ThePornDB] scene search failed for query=\"\(text)\" error=\(error.localizedDescription)", level: .warning)
        }

        // 2) No scene matched — fall back to performers, always taking the first result.
        do {
            let response = try await ThePornDBAPIService.shared.searchPerformers(query: text, limit: 1)
            if let performer = response.list.first {
                var cover: UIImage?
                if let imageURL = performer.bestImage {
                    cover = try? await ThePornDBAPIService.shared.downloadImage(from: imageURL)
                }
                if cover != nil {
                    return ThePornDBMetadata(
                        source: .performer,
                        title: performer.name,
                        performers: [performer.name].compactMap { $0 },
                        tags: performer.extras?.aliases ?? [],
                        date: performer.extras?.birthday,
                        siteName: performer.extras?.nationality,
                        coverImage: cover
                    )
                }
            }
        } catch {
            logDiagnostic("[ThePornDB] performer fallback failed for query=\"\(text)\" error=\(error.localizedDescription)", level: .warning)
        }

        // 3) لا صورة لحد الآن — فلتر 7: أعد البحث في قسم الممثلات بأول كلمتين فقط من العنوان.
        let firstTwoWords = text.split(separator: " ").prefix(2).joined(separator: " ")
        guard !firstTwoWords.isEmpty, firstTwoWords != text else { return nil }
        do {
            let response = try await ThePornDBAPIService.shared.searchPerformers(query: firstTwoWords, limit: 1)
            guard let performer = response.list.first else { return nil }
            var cover: UIImage?
            if let imageURL = performer.bestImage {
                cover = try? await ThePornDBAPIService.shared.downloadImage(from: imageURL)
            }
            return ThePornDBMetadata(
                source: .performer,
                title: performer.name,
                performers: [performer.name].compactMap { $0 },
                tags: performer.extras?.aliases ?? [],
                date: performer.extras?.birthday,
                siteName: performer.extras?.nationality,
                coverImage: cover
            )
        } catch {
            logDiagnostic("[ThePornDB] two-word performer fallback failed for query=\"\(firstTwoWords)\" error=\(error.localizedDescription)", level: .warning)
            return nil
        }
    }

    /// Cover-only convenience wrapper around `fetchThePornDBMetadata`, kept for call
    /// sites that only need the image (e.g. folder covers).
    static func downloadThePornDBCoverImage(for query: String) async -> UIImage? {
        await fetchThePornDBMetadata(for: query)?.coverImage
    }

    // MARK: - Prefetch


    /// Prefetch posters for saved links. A ready remote poster always wins;
    /// extracting a frame from the video is only the fallback.
    static func schedulePrefetchSavedLinks(_ links: [SavedVideoLink]) {
        guard isAutomaticDownloadEnabled else { return }
        guard !links.isEmpty else { return }
        let requests = links.compactMap { link -> PrefetchRequest? in
            guard link.thumbnailFileName == nil, let url = link.url else { return nil }
            return PrefetchRequest(
                url: url,
                remotePosterURL: link.remotePosterURL.flatMap(URL.init(string:)),
                stableKey: link.favoriteIdentity ?? "saved|\(link.id.uuidString)",
                headers: [:],
                fileExtension: link.fileExtension,
                searchQuery: VideoTitleFormatter.title(from: link.title)
            )
        }
        schedulePrefetchPosters(requests)
    }

    /// Prefetches small list thumbnails. Existing stable cache entries are
    /// never downloaded again, including after refresh. Actual parallelism is
    /// bounded by `ThumbnailLoadGate`, shared with every other call site
    /// (e.g. grid cells fetching their own poster directly), so the total
    /// number of simultaneous network+decode operations across the whole app
    /// stays capped — even though every request here is queued up front.
    static func schedulePrefetchPosters(_ requests: [PrefetchRequest]) {
        guard isAutomaticDownloadEnabled else { return }
        let missing = Array(requests.filter {
            cachedImage(forStableKey: $0.stableKey) == nil &&
            !isStableImageSuppressed(forKey: $0.stableKey)
        }.prefix(12))
        guard !missing.isEmpty else { return }

        Task.detached(priority: .utility) {
            await withTaskGroup(of: Void.self) { group in
                for request in missing {
                    group.addTask {
                        guard !Task.isCancelled else { return }
                        await ThumbnailLoadGate.shared.acquire()
                        defer { Task { await ThumbnailLoadGate.shared.release() } }
                        await VideoThumbnailLoader.prefetchPoster(request)
                    }
                }
            }
        }
    }

    private static func prefetchPoster(_ request: PrefetchRequest) async {
        guard cachedImage(forStableKey: request.stableKey) == nil else { return }
        let target = ThumbnailPipeline.targetPointSize(for: .small)
        var image: UIImage?
        if let posterURL = request.remotePosterURL {
            image = await downloadRemoteImage(
                from: posterURL,
                headers: request.headers,
                stableKey: request.stableKey,
                maxRetries: 1,
                targetPointSize: target
            )
        } else {
            image = await loadPoster(
                for: request.url,
                headers: request.headers,
                stableKey: request.stableKey,
                targetPointSize: target
            )
        }

        // خطوة أخيرة: لو فشلت الصورة البعيدة واستخراج إطار الفيديو، جرّب
        // جلب غلاف تلقائيًا من ThePornDB باستخدام عنوان الرابط.
        if image == nil, let query = request.searchQuery, !query.isEmpty {
            image = await downloadThePornDBCoverImage(for: query)
        }

        if let image, cachedImage(forStableKey: request.stableKey) == nil {
            cacheImage(image, forStableKey: request.stableKey)
        }
    }
    // MARK: - File Management
    private static func trimDiskCacheIfNeeded() {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: cacheDirectory,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        ) else { return }

        var cachedFiles: [(url: URL, size: Int64, date: Date)] = []
        var totalBytes: Int64 = 0

        for url in urls where url.pathExtension.lowercased() == "webp" {
            guard let values = try? url.resourceValues(forKeys: keys),
                  values.isRegularFile == true else { continue }
            let size = Int64(values.fileSize ?? 0)
            totalBytes += size
            cachedFiles.append((url, size, values.contentModificationDate ?? .distantPast))
        }

        guard totalBytes > maximumDiskCacheBytes else { return }
        for file in cachedFiles.sorted(by: { $0.date < $1.date }) {
            try? FileManager.default.removeItem(at: file.url)
            totalBytes -= file.size
            if totalBytes <= maximumDiskCacheBytes { break }
        }
    }

    static func deleteCache(for remote: URL) {
        let key = cacheKey(for: remote) as NSString
        memoryCache.removeObject(forKey: key)
        let file = cacheFileURL(forRemoteURL: remote)
        try? FileManager.default.removeItem(at: file)
    }

    // MARK: - Custom gallery covers

    private static var customDirectory: URL {
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent("CustomPosters", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @discardableResult
    static func saveCustomPoster(_ image: UIImage, for id: UUID) -> String? {
        let fileName = "\(id.uuidString)-\(UUID().uuidString).webp"
        let url = customDirectory.appendingPathComponent(fileName)
        let maxSide: CGFloat = 720
        let resized = image.resized(maxSide: maxSide) ?? image
        guard let data = ThumbnailPipeline.webPData(for: resized, maximumBytes: ThumbnailPipeline.gridMaximumBytes) else { return nil }
        do {
            try data.write(to: url, options: Data.WritingOptions.atomic)
            return fileName
        } catch {
            return nil
        }
    }

    static func loadCustomPoster(fileName: String) -> UIImage? {
        let url = customDirectory.appendingPathComponent(fileName)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return UIImage(data: data)
    }

    static func deleteCustomPoster(fileName: String) {
        let url = customDirectory.appendingPathComponent(fileName)
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - Account management

    /// Set cache namespace for current account (no sensitive data)
    static func setAccountNamespace(_ identifier: String) {
        // Hash the identifier to avoid storing raw account IDs
        let digest = SHA256.hash(data: Data(identifier.utf8))
        cacheNamespace = digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Clear account-specific cache and reset namespace
    static func clearAccountCache() {
        if !cacheNamespace.isEmpty {
            clearCache(for: cacheNamespace)
            cacheNamespace = ""
        }
    }

    // MARK: - Migration / Cleanup

    /// Clean up old cache folders from previous versions
    static func cleanupOldCaches() {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!

        for oldName in oldCacheFolderNames {
            let oldDir = base.appendingPathComponent(oldName, isDirectory: true)
            if FileManager.default.fileExists(atPath: oldDir.path) {
                try? FileManager.default.removeItem(at: oldDir)
            }
        }
    }

    /// Clear cache for specific URLs or namespace
    static func clearCache(for namespace: String? = nil, urls: [URL]? = nil) {
        if let namespace, !namespace.isEmpty {
            // Clear all cache for this namespace (account-specific)
            let oldNamespace = cacheNamespace
            cacheNamespace = namespace

            // Remove from memory - NSCache doesn't have .keys, so iterate keys manually
            let prefix = "\(namespace)|"
            // Get all keys from cache by iterating
            var keysToRemove: [NSString] = []
            // We need to track keys ourselves since NSCache doesn't expose them
            // For now, we'll just clear all cache for this namespace by using a different approach
            // We'll track namespace-prefixed keys in a separate set

            // For the current implementation, we'll clear memory cache entirely if namespace is set
            // since we can't efficiently iterate NSCache keys
            memoryCache.removeAllObjects()

            // Remove from disk (delete entire folder for namespace)
            // We use the cacheNamespace to identify the correct cache files
            let currentDiskNamespace = cacheNamespace
            cacheNamespace = oldNamespace  // Restore to original for directory access
            let currentDir = cacheDirectory

            // Clean up namespace-specific files on disk
            if let fileEnumerator = FileManager.default.enumerator(at: currentDir, includingPropertiesForKeys: nil) {
                for case let fileURL as URL in fileEnumerator {
                    guard fileURL.pathExtension == "webp" else { continue }
                    let key = fileURL.deletingPathExtension().lastPathComponent
                    if !key.isEmpty, key.hasPrefix(currentDiskNamespace + "|") {
                        try? FileManager.default.removeItem(at: fileURL)
                    }
                }
            }

            cacheNamespace = oldNamespace
        } else if let urls {
            // Clear specific URLs
            for url in urls {
                deleteCache(for: url)
            }
        } else {
            // Clear all cache
            memoryCache.removeAllObjects()
            try? FileManager.default.removeItem(at: cacheDirectory)
            try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        }
    }

    // MARK: - Diagnostic API

    /// Get diagnostic logs
    static func getDiagnosticLogs(filter: LogLevel? = nil, searchTerm: String? = nil) -> [ThumbnailLogEntry] {
        ThumbnailDiagnosticLogger.shared.getLogs(filter: filter, searchTerm: searchTerm)
    }

    /// Clear diagnostic logs
    static func clearDiagnosticLogs() {
        ThumbnailDiagnosticLogger.shared.clear()
    }

    /// Export logs as string
    static func exportDiagnosticLogs() -> String {
        ThumbnailDiagnosticLogger.shared.exportLogs()
    }

    /// Export the disk-persisted log — survives a crash or force-quit, unlike
    /// the in-memory list above which is lost the instant the process dies.
    static func exportPersistedDiagnosticLog() -> String {
        ThumbnailDiagnosticLogger.shared.exportPersistedLogFile()
    }

    /// Log a diagnostic message
    static func logDiagnostic(_ message: String, level: LogLevel = .info, fileID: String? = nil) {
        ThumbnailDiagnosticLogger.shared.log(message, level: level, fileID: fileID)
    }

    // MARK: - Prefetch Request

    /// Request structure for poster prefetch
    public struct PrefetchRequest: Equatable, Sendable {
        let url: URL
        let remotePosterURL: URL?
        let stableKey: String
        let headers: [String: String]
        let fileExtension: String
        /// عنوان نصي اختياري يُستخدم كخطوة أخيرة لجلب غلاف تلقائيًا من ThePornDB
        /// إن فشلت الصورة البعيدة واستخراج إطار الفيديو معًا.
        let searchQuery: String?

        init(
            url: URL,
            remotePosterURL: URL? = nil,
            stableKey: String,
            headers: [String: String],
            fileExtension: String,
            searchQuery: String? = nil
        ) {
            self.url = url
            self.remotePosterURL = remotePosterURL
            self.stableKey = stableKey
            self.headers = headers
            self.fileExtension = fileExtension
            self.searchQuery = searchQuery
        }
    }
}
/// Actor for in-flight request deduplication
/// Prevents duplicate concurrent requests for the same URL while ensuring cancellation
/// of individual views doesn't cancel shared requests for other views.
private actor ThumbnailRequestCoordinator {
    private var tasks: [String: Task<UIImage?, Never>] = [:]

    /// Execute image operation only if no other request for the same key is running.
    /// If a request is already running, wait for its result.
    /// When the task completes (success, failure, or cancellation), remove it from the dictionary.
    func image(for key: String, operation: @escaping @Sendable () async -> UIImage?) async -> UIImage? {
        // Check if already running
        if let existingTask = tasks[key] {
            // Wait for existing task
            let result = await existingTask.value
            return result
        }

        // Create new task
        let task = Task<UIImage?, Never> {
            do {
                let result = await operation()
                return result
            } catch {
                // Return nil on error (including cancellation)
                return nil
            }
        }

        // Store the task before awaiting
        tasks[key] = task

        // Wait for result
        let result = await task.value

        // Clean up the task from dictionary (use defer for safety)
        tasks[key] = nil

        return result
    }
}

private extension UIImage {
    func resized(maxSide: CGFloat) -> UIImage? {
        let w = size.width
        let h = size.height
        let longest = max(w, h)
        guard longest > maxSide else { return self }
        let scale = maxSide / longest
        let newSize = CGSize(width: w * scale, height: h * scale)
        let renderer = UIGraphicsImageRenderer(size: newSize)
        return renderer.image { _ in
            draw(in: CGRect(origin: .zero, size: newSize))
        }
    }
}

// MARK: - SwiftUI poster image

struct PosterThumbnailView: View {
    let url: URL?
    var remotePosterURL: URL? = nil
    var remotePosterHeaders: [String: String] = [:]
    var customFileName: String? = nil
    var stableCacheKey: String? = nil
    var title: String = ""
    var badge: String = "VIDEO"
    var preferredTier: ThumbnailSizeTier? = nil

    @State private var image: UIImage?
    @State private var isLoading = false
    @State private var lastTargetPointSize = CGSize(width: 200, height: 112.5)

    var body: some View {
        GeometryReader { proxy in
            let targetSize = CGSize(
                width: max(proxy.size.width, 1),
                height: max(proxy.size.height, 1)
            )

            ZStack {
                LinearGradient(
                    colors: [
                        Color(red: 0.12, green: 0.10, blue: 0.22),
                        Color(red: 0.05, green: 0.08, blue: 0.14)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )

                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .clipped()
                } else {
                    VStack(spacing: 10) {
                        if isLoading {
                            ProgressView()
                                .tint(.white.opacity(0.8))
                        } else {
                            Image(systemName: "film.fill")
                                .font(.system(size: 36))
                                .foregroundColor(.white.opacity(0.55))
                        }
                        Text(badge)
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(.white.opacity(0.45))
                            .tracking(1.2)
                    }
                }

                VStack {
                    Spacer()
                    LinearGradient(
                        colors: [.clear, .black.opacity(0.85)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .frame(height: min(72, proxy.size.height * 0.42))
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .clipped()
            .task(id: "\(calculateTaskId())|\(Int(targetSize.width))x\(Int(targetSize.height))") {
                lastTargetPointSize = targetSize
                await load(targetPointSize: preferredTier.map { ThumbnailPipeline.targetPointSize(for: $0) } ?? targetSize)
            }
            .onReceive(NotificationCenter.default.publisher(for: VideoThumbnailLoader.stablePosterDidUpdateNotification)) { notification in
                let updatedKey = notification.object as? String
                let canonicalKey = VideoThumbnailLoader.canonicalPosterCacheKey(for: title)
                guard updatedKey == stableCacheKey || updatedKey == canonicalKey else { return }
                Task { await load(targetPointSize: lastTargetPointSize) }
            }
        }
    }
    /// Generate stable task ID to prevent duplicate loads
    private func calculateTaskId() -> String {
        if let key = stableCacheKey {
            // Include customFileName so picking/clearing a cover image
            // (via gallery or search) restarts the task and refreshes
            // the poster immediately, instead of only after the view
            // is recreated (e.g. switching tabs and back).
            return "\(key)|\(customFileName ?? "")"
        }
        // Fallback to original ID
        return "\(url?.absoluteString ?? "")|\(remotePosterURL?.absoluteString ?? "")|\(customFileName ?? "")|\(remotePosterHeaders.count)"
    }

    private func load(targetPointSize: CGSize) async {
        // Generate short file ID for logging
        let targetURL = remotePosterURL ?? url
        let fileID = targetURL.map { 
            let digest = SHA256.hash(data: Data($0.absoluteString.utf8))
            return String(digest.prefix(8).map { String(format: "%02x", $0) }.joined())
        } ?? "unknown"
        
        // Extract host safely for logging
        let safeHost = targetURL?.host ?? "none"
        
        // Avoid logging every cell while scrolling — was a measurable main-thread cost.
        // Keep the previous image visible while refreshing; never blank a cached thumbnail.
        isLoading = false

        // Determine stable cache key using a local constant (not mutating the property)
        let resolvedStableCacheKey: String?
        if let stableCacheKey {
            resolvedStableCacheKey = stableCacheKey
        } else if let targetURL {
            let digest = SHA256.hash(data: Data(targetURL.absoluteString.utf8))
            resolvedStableCacheKey = digest.map { String(format: "%02x", $0) }.joined()
        } else {
            resolvedStableCacheKey = nil
        }

        // 1) A user-picked Library/Recent cover always overrides an
        // automatically generated stable thumbnail.
        if let customFileName,
           let custom = VideoThumbnailLoader.loadCustomPoster(fileName: customFileName) {
            image = custom
            return
        }

        // Every screen resolves the same title-based key before its provider-specific key.
        let canonicalKey = VideoThumbnailLoader.canonicalPosterCacheKey(for: title)
        if let canonical = VideoThumbnailLoader.cachedImage(forStableKey: canonicalKey) {
            image = canonical
            if let stableCacheKey {
                VideoThumbnailLoader.cacheImage(canonical, forStableKey: stableCacheKey)
            }
            return
        }

        // Favorites and Recent resolve TMDB themselves; opening Details is not
        // required to populate the shared poster cache.
        if !title.isEmpty, TMDBSettings.isConfigured {
            await ThumbnailLoadGate.shared.acquire()
            let details = await TMDBService.shared.details(for: title)
            var tmdbPoster: UIImage?
            if let posterURL = details?.posterURL,
               let (data, _) = try? await HighPriorityNetworkManager.shared.responsiveData(from: posterURL) {
                tmdbPoster = UIImage(data: data)
            }
            await ThumbnailLoadGate.shared.release()
            if let tmdbPoster {
                image = tmdbPoster
                VideoThumbnailLoader.cacheImage(tmdbPoster, forStableKey: canonicalKey)
                if let resolvedStableCacheKey {
                    VideoThumbnailLoader.cacheImage(tmdbPoster, forStableKey: resolvedStableCacheKey)
                }
                return
            }
        }

        // Provider-specific artwork is the fallback after the shared TMDB poster.
        if let stableCacheKey,
           let stable = VideoThumbnailLoader.cachedImage(forStableKey: stableCacheKey) {
            image = stable
            VideoThumbnailLoader.cacheImage(stable, forStableKey: canonicalKey)
            return
        }

        // 3) Remote poster (e.g. PikPak thumbnail_link) — this is a genuine automatic
        // network fetch just because the cell appeared, so it's gated like the rest.
        if let remote = remotePosterURL, VideoThumbnailLoader.isAutomaticDownloadEnabled {
            VideoThumbnailLoader.logDiagnostic("[PikPakThumbnail] file=\(fileID) stage=remotePosterCheck", level: .debug, fileID: fileID)
            print("[PikPakThumbnail] file=\(fileID) stage=remotePosterCheck")
            isLoading = true
            defer { isLoading = false }

                // Download with in-flight deduplication
            let downloaded = await VideoThumbnailLoader.downloadRemoteImage(
                from: remote,
                headers: remotePosterHeaders,
                stableKey: resolvedStableCacheKey,
                maxRetries: 2,
                targetPointSize: targetPointSize
            )

            if let downloaded {
                image = downloaded
                VideoThumbnailLoader.cacheImage(downloaded, forStableKey: canonicalKey)
                VideoThumbnailLoader.logDiagnostic("[PikPakThumbnail] file=\(fileID) stage=remotePoster result=success", level: .info, fileID: fileID)
                print("[PikPakThumbnail] file=\(fileID) stage=remotePoster result=success")
                return
            } else {
                VideoThumbnailLoader.logDiagnostic("[PikPakThumbnail] file=\(fileID) stage=remotePoster result=failure fallback_to_video", level: .warning, fileID: fileID)
                print("[PikPakThumbnail] file=\(fileID) stage=remotePoster result=failure fallback_to_video")
            }
        }

        // 3) Fallback: extract frame from video stream
        guard let videoURL = url else {
            VideoThumbnailLoader.logDiagnostic("[PikPakThumbnail] file=\(fileID) stage=fallback result=no_video_url", level: .warning, fileID: fileID)
            print("[PikPakThumbnail] file=\(fileID) stage=fallback result=no_video_url")
            return
        }

        VideoThumbnailLoader.logDiagnostic("[PikPakThumbnail] file=\(fileID) stage=videoFrameFallback", level: .debug, fileID: fileID)
        print("[PikPakThumbnail] file=\(fileID) stage=videoFrameFallback")
        isLoading = true
        defer { isLoading = false }

        // Load poster with headers if provided
        let frame = await VideoThumbnailLoader.loadPoster(
            for: videoURL,
            headers: remotePosterHeaders,
            stableKey: resolvedStableCacheKey,
            targetPointSize: targetPointSize
        )

        if let frame {
            image = frame
            VideoThumbnailLoader.cacheImage(frame, forStableKey: canonicalKey)
            VideoThumbnailLoader.logDiagnostic("[PikPakThumbnail] file=\(fileID) stage=videoFrame result=success", level: .info, fileID: fileID)
            print("[PikPakThumbnail] file=\(fileID) stage=videoFrame result=success")
            return
        }
        VideoThumbnailLoader.logDiagnostic("[PikPakThumbnail] file=\(fileID) stage=videoFrame result=failure", level: .error, fileID: fileID)
        print("[PikPakThumbnail] file=\(fileID) stage=videoFrame result=failure")

        // 4) Last resort, and the one automatic network call that's always allowed:
        // look the (filtered) title up on ThePornDB — scenes first, performers next.
        // Gated: this runs from every grid/list cell across the app (Offcloud,
        // Recent, Media, PikPak) via this same shared view, so without a shared
        // cap a screen with many un-cached items fires one request per cell at
        // once — that's what was spiking memory and getting the app killed,
        // including just opening a tab with a long history.
        guard !title.isEmpty else { return }
        let query = VideoTitleFormatter.title(from: title)
        await ThumbnailLoadGate.shared.acquire()
        defer { Task { await ThumbnailLoadGate.shared.release() } }
        guard !Task.isCancelled else { return }
        if let metadata = await VideoThumbnailLoader.fetchThePornDBMetadata(for: query),
           let cover = metadata.coverImage {
            image = cover
            VideoThumbnailLoader.cacheImage(cover, forStableKey: canonicalKey)
            if let resolvedStableCacheKey {
                VideoThumbnailLoader.cacheImage(cover, forStableKey: resolvedStableCacheKey)
            }
            VideoThumbnailLoader.logDiagnostic("[PikPakThumbnail] file=\(fileID) stage=thePornDBFallback result=success", level: .info, fileID: fileID)
        }
    }
}
