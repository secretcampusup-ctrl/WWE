import Foundation
import SwiftUI
import Combine
import AVFoundation
import UIKit
import UserNotifications

struct ManagedVideoDownload: Identifiable, Codable, Equatable {
    enum State: String, Codable {
        case queued
        case downloading
        case paused
        case completed
        case failed
        case cancelled
    }

    let id: UUID
    let stableKey: String
    let sourceURL: String
    let title: String
    let createdAt: Date
    var state: State
    var bytesWritten: Int64
    var totalBytesExpected: Int64
    var destinationFileName: String?
    var errorMessage: String?
    var requiresLoginHost: String?
    var isHLS: Bool = false
    var requestHeaders: [String: String]?
    var suggestedFileName: String?

    var needsLogin: Bool { state == .failed && requiresLoginHost != nil }

    var progress: Double {
        if state == .completed { return 1 }
        guard totalBytesExpected > 0 else { return 0 }
        return min(1, max(0, Double(bytesWritten) / Double(totalBytesExpected)))
    }

    var isActive: Bool {
        state == .queued || state == .downloading
    }
}

final class VideoDownloadManager: NSObject, ObservableObject, URLSessionDownloadDelegate {
    static let shared = VideoDownloadManager()
    static let sessionIdentifier = "com.mortaza.minoz.VideoPlayer.user-downloads.v1"

    @Published private(set) var downloads: [ManagedVideoDownload] = []

    private let persistenceKey = "managed_video_downloads_v1"
    private var backgroundEventsCompletionHandler: (() -> Void)?
    private var lastProgressSave = Date.distantPast
    private var hlsTasks: [UUID: Task<Void, Never>] = [:]
    private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid
    private var lifecycleObservers: [NSObjectProtocol] = []

    private struct TaskDescriptor: Codable {
        let id: UUID
        let stableKey: String
        let sourceURL: String
        let title: String
        let suggestedFileName: String
    }

    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.background(
            withIdentifier: Self.sessionIdentifier
        )
        configuration.sessionSendsLaunchEvents = true
        configuration.networkServiceType = .video // Sustained movie downloads: ask iOS for video-oriented scheduling.
        configuration.isDiscretionary = false
        configuration.waitsForConnectivity = true
        configuration.allowsCellularAccess = true
        configuration.allowsExpensiveNetworkAccess = true
        configuration.allowsConstrainedNetworkAccess = true
        configuration.timeoutIntervalForResource = 7 * 24 * 60 * 60
        configuration.httpMaximumConnectionsPerHost = 3
        configuration.httpCookieStorage = HTTPCookieStorage.shared
        configuration.httpShouldSetCookies = true

        let queue = OperationQueue()
        queue.name = "com.mortaza.minoz.VideoPlayer.user-downloads.delegate"
        queue.maxConcurrentOperationCount = 1
        return URLSession(
            configuration: configuration,
            delegate: self,
            delegateQueue: queue
        )
    }()

    private override init() {
        super.init()
        downloads = loadDownloads()
        try? FileManager.default.createDirectory(
            at: downloadDirectory,
            withIntermediateDirectories: true,
            attributes: nil
        )
        reconcileCompletedFiles()
        installLifecycleObservers()
    }

    var activeCount: Int {
        downloads.filter(\.isActive).count
    }

    var activeDownloads: [ManagedVideoDownload] {
        downloads.filter(\.isActive).sorted { $0.createdAt > $1.createdAt }
    }

    var finishedDownloads: [ManagedVideoDownload] {
        downloads.filter { !$0.isActive && $0.state != .paused }.sorted { $0.createdAt > $1.createdAt }
    }

    func download(forStableKey stableKey: String) -> ManagedVideoDownload? {
        downloads.first { $0.stableKey == stableKey }
    }

    func download(forSourceURL url: URL?) -> ManagedVideoDownload? {
        guard let absolute = url?.absoluteString else { return nil }
        return downloads.first { $0.sourceURL == absolute }
    }

    func download(for link: SavedVideoLink) -> ManagedVideoDownload? {
        let keys = Set([
            link.id.uuidString,
            "saved|\(link.id.uuidString)",
            link.favoriteIdentity ?? ""
        ].filter { !$0.isEmpty })
        if let byKey = downloads.first(where: { keys.contains($0.stableKey) }) {
            return byKey
        }
        let urls = Set([
            link.url?.absoluteString ?? "",
            link.originalURL?.absoluteString ?? "",
            link.resolvedStreamURL ?? "",
            link.urlString
        ].filter { !$0.isEmpty })
        return downloads.first { urls.contains($0.sourceURL) }
    }
    func activate() {
        _ = session
        session.getAllTasks { [weak self] tasks in
            guard let self else { return }
            let restoredTasks = tasks.compactMap { task -> (TaskDescriptor, URLSessionTask)? in
                guard let descriptor = self.descriptor(from: task.taskDescription) else { return nil }
                return (descriptor, task)
            }
            DispatchQueue.main.async {
                let activeIDs = Set(restoredTasks.map { $0.0.id })
                for (descriptor, task) in restoredTasks {
                    if let index = self.downloads.firstIndex(where: { $0.id == descriptor.id }) {
                        self.downloads[index].state = task.state == .suspended ? .paused : .downloading
                        self.downloads[index].bytesWritten = task.countOfBytesReceived
                        self.downloads[index].totalBytesExpected = task.countOfBytesExpectedToReceive
                    } else {
                        self.downloads.append(ManagedVideoDownload(
                            id: descriptor.id, stableKey: descriptor.stableKey,
                            sourceURL: descriptor.sourceURL, title: descriptor.title,
                            createdAt: Date(), state: task.state == .suspended ? .paused : .downloading, bytesWritten: 0,
                            totalBytesExpected: task.countOfBytesExpectedToReceive,
                            destinationFileName: nil, errorMessage: nil, isHLS: false
                        ))
                    }
                }
                // HLS downloads run as in-process Tasks (not URLSession tasks), so a
                // relaunch always interrupts them — mark any that were mid-flight as failed
                // rather than stuck "downloading" forever.
                for index in self.downloads.indices where self.downloads[index].isActive
                    && !activeIDs.contains(self.downloads[index].id)
                    && self.hlsTasks[self.downloads[index].id] == nil {
                    if self.downloads[index].isHLS {
                        self.downloads[index].state = .paused
                        self.downloads[index].errorMessage = "Ready to resume"
                    } else {
                        self.downloads[index].state = .failed
                        self.downloads[index].errorMessage = "Download interrupted"
                    }
                }
                self.sortAndPersist()
                self.resumePausedDownloads()
            }
        }
    }

    private func installLifecycleObservers() {
        let center = NotificationCenter.default
        lifecycleObservers.append(center.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in self?.enteredBackground() })
        lifecycleObservers.append(center.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in self?.enteredForeground() })
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    private func enteredBackground() {
        guard downloads.contains(where: { $0.isHLS && $0.state == .downloading }) else { return }
        guard backgroundTaskID == .invalid else { return }
        backgroundTaskID = UIApplication.shared.beginBackgroundTask(withName: "Finish video download") { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }
                self.pauseHLSForBackgroundExpiration()
                self.endBackgroundProtection()
            }
        }
    }

    private func enteredForeground() {
        endBackgroundProtection()
        resumePausedDownloads()
    }

    private func endBackgroundProtection() {
        guard backgroundTaskID != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTaskID)
        backgroundTaskID = .invalid
    }

    private func pauseHLSForBackgroundExpiration() {
        let targets = downloads.filter { $0.isHLS && $0.state == .downloading }
        guard !targets.isEmpty else { return }
        targets.forEach { pause($0, backgroundExpiration: true) }

        let content = UNMutableNotificationContent()
        content.title = "Downloads paused"
        content.body = targets.count == 1
            ? "Open Murtadha to resume \(targets[0].title)."
            : "Open Murtadha to resume \(targets.count) video downloads."
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(
            identifier: "video-downloads-paused",
            content: content,
            trigger: nil
        ))
    }

    func pause(_ download: ManagedVideoDownload, backgroundExpiration: Bool = false) {
        guard download.state == .downloading || download.state == .queued else { return }
        if let task = hlsTasks[download.id] {
            task.cancel()
            hlsTasks[download.id] = nil
        } else {
            session.getAllTasks { [weak self] tasks in
                for task in tasks where self?.descriptor(from: task.taskDescription)?.id == download.id {
                    task.suspend()
                }
            }
        }
        if let index = downloads.firstIndex(where: { $0.id == download.id }) {
            downloads[index].state = .paused
            downloads[index].errorMessage = backgroundExpiration
                ? "Paused safely when iOS background time ended"
                : "Paused"
            persist()
        }
    }

    func resume(_ download: ManagedVideoDownload) {
        guard download.state == .paused || download.state == .failed || download.state == .cancelled else { return }
        guard let url = URL(string: download.sourceURL) else { return }
        if download.isHLS {
            guard hlsTasks[download.id] == nil else { return }
            if let index = downloads.firstIndex(where: { $0.id == download.id }) {
                downloads[index].state = .downloading
                downloads[index].errorMessage = nil
                downloads[index].bytesWritten = 0
                downloads[index].totalBytesExpected = 0
                persist()
            }
            let headers = download.requestHeaders ?? [:]
            let task = Task { [weak self] in
                guard let self else { return }
                await self.runHLSDownload(id: download.id, url: url, title: download.title, headers: headers)
            }
            hlsTasks[download.id] = task
        } else {
            session.getAllTasks { [weak self] tasks in
                guard let self else { return }
                if let task = tasks.first(where: { self.descriptor(from: $0.taskDescription)?.id == download.id }) {
                    task.resume()
                    DispatchQueue.main.async {
                        if let index = self.downloads.firstIndex(where: { $0.id == download.id }) {
                            self.downloads[index].state = .downloading
                            self.downloads[index].errorMessage = nil
                            self.persist()
                        }
                    }
                } else {
                    DispatchQueue.main.async {
                        self.downloads.removeAll { $0.id == download.id }
                        self.startDownload(
                            url: url,
                            stableKey: download.stableKey,
                            title: download.title,
                            suggestedFileName: download.suggestedFileName ?? download.title,
                            headers: download.requestHeaders ?? [:]
                        )
                    }
                }
            }
        }
    }

    private func resumePausedDownloads() {
        downloads.filter { $0.state == .paused }.forEach(resume)
    }
    func setBackgroundEventsCompletionHandler(_ handler: @escaping () -> Void) {
        backgroundEventsCompletionHandler = handler
    }
    func startDownload(
        url: URL,
        stableKey: String,
        title: String,
        suggestedFileName: String,
        headers: [String: String]
    ) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.startDownload(
                    url: url,
                    stableKey: stableKey,
                    title: title,
                    suggestedFileName: suggestedFileName,
                    headers: headers
                )
            }
            return
        }

        if LinkResolver.classify(url.absoluteString) == .hls {
            startHLSDownload(url: url, stableKey: stableKey, title: title, headers: headers)
            return
        }

        if let existing = download(forStableKey: stableKey) {
            if existing.isActive { return }
            if existing.state == .completed,
               let fileURL = fileURL(for: existing),
               FileManager.default.fileExists(atPath: fileURL.path) {
                return
            }
            downloads.removeAll { $0.id == existing.id }
        }

        let id = UUID()
        let descriptor = TaskDescriptor(
            id: id,
            stableKey: stableKey,
            sourceURL: url.absoluteString,
            title: title,
            suggestedFileName: suggestedFileName
        )
        downloads.insert(
            ManagedVideoDownload(
                id: id,
                stableKey: stableKey,
                sourceURL: url.absoluteString,
                title: title,
                createdAt: Date(),
                state: .queued,
                bytesWritten: 0,
                totalBytesExpected: 0,
                destinationFileName: nil,
                errorMessage: nil,
                requestHeaders: headers,
                suggestedFileName: suggestedFileName
            ),
            at: 0
        )
        persist()

        var request = URLRequest(url: url)
        request.timeoutInterval = 7 * 24 * 60 * 60
        request.networkServiceType = .video // This is a movie file, not an API request.
        for (field, value) in headers {
            request.setValue(value, forHTTPHeaderField: field)
        }

        let task = session.downloadTask(with: request)
        task.taskDescription = encoded(descriptor)
        task.priority = 1.0 // Highest URLSession priority; advisory within iOS, not router/ISP control.
        task.resume()

        if let index = downloads.firstIndex(where: { $0.id == id }) {
            downloads[index].state = .downloading
            persist()
        }
    }

    private func startHLSDownload(url: URL, stableKey: String, title: String, headers: [String: String]) {
        if let existing = download(forStableKey: stableKey) {
            if existing.isActive { return }
            if existing.state == .completed,
               let fileURL = fileURL(for: existing),
               FileManager.default.fileExists(atPath: fileURL.path) { return }
            downloads.removeAll { $0.id == existing.id }
        }

        let id = UUID()
        downloads.insert(ManagedVideoDownload(
            id: id, stableKey: stableKey, sourceURL: url.absoluteString,
            title: title, createdAt: Date(), state: .downloading,
            bytesWritten: 0, totalBytesExpected: 1000,
            destinationFileName: nil, errorMessage: nil, isHLS: true,
            requestHeaders: headers, suggestedFileName: title + ".mp4"
        ), at: 0)
        persist()

        let task = Task { [weak self] in
            guard let self else { return }
            await self.runHLSDownload(id: id, url: url, title: title, headers: headers)
        }
        hlsTasks[id] = task
    }

    // Fetches every HLS segment directly and remuxes them into a real .mp4.
    // AVAssetDownloadTask + AVAssetExportSession (the previous approach) does
    // not work here: Apple's AVAssetExportSession explicitly does not support
    // exporting HLS-sourced assets (local .movpkg included) to another
    // container — every attempt fails with a generic "Operation Stopped"
    // error regardless of preset. Downloading the raw .ts segments ourselves
    // and remuxing that flat file sidesteps the restriction entirely.
    private func runHLSDownload(id: UUID, url: URL, title: String, headers: [String: String]) async {
        do {
            let mp4URL = try await HLSSegmentDownloader.download(masterURL: url, headers: headers) { [weak self] progress in
                guard let self else { return }
                DispatchQueue.main.async {
                    guard let index = self.downloads.firstIndex(where: { $0.id == id }) else { return }
                    self.downloads[index].state = .downloading
                    if progress.bytesWritten > 0 {
                        self.downloads[index].bytesWritten = progress.bytesWritten
                        self.downloads[index].totalBytesExpected = progress.totalBytesExpected
                    } else {
                        self.downloads[index].totalBytesExpected = 1000
                        self.downloads[index].bytesWritten = Int64(progress.fraction * 1000)
                    }
                    if Date().timeIntervalSince(self.lastProgressSave) >= 1 {
                        self.lastProgressSave = Date()
                        self.persist()
                    }
                }
            }

            if Task.isCancelled {
                try? FileManager.default.removeItem(at: mp4URL)
                return
            }

            try FileManager.default.createDirectory(at: downloadDirectory, withIntermediateDirectories: true)
            var name = safeFileName(title, fallbackFileName: "\(title).mp4", fallbackURL: url)
            if (name as NSString).pathExtension.lowercased() != "mp4" {
                name = (name as NSString).deletingPathExtension + ".mp4"
            }
            let destination = uniqueDestination(fileName: name)
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.moveItem(at: mp4URL, to: destination)

            DispatchQueue.main.async {
                guard let index = self.downloads.firstIndex(where: { $0.id == id }) else { return }
                self.downloads[index].state = .completed
                let size = ((try? FileManager.default.attributesOfItem(atPath: destination.path)[.size]) as? NSNumber)?.int64Value ?? 0
                self.downloads[index].bytesWritten = size
                self.downloads[index].totalBytesExpected = size
                self.downloads[index].destinationFileName = destination.lastPathComponent
                self.downloads[index].errorMessage = nil
                self.downloads[index].requiresLoginHost = nil
                self.sortAndPersist()
                self.hlsTasks[id] = nil
            }
        } catch {
            if error is CancellationError {
                DispatchQueue.main.async { self.hlsTasks[id] = nil }
                return
            }
            if let urlError = error as? URLError, urlError.code == .userAuthenticationRequired {
                markLoginRequired(id: id, sourceURL: url.absoluteString)
            } else {
                markFailed(id: id, message: error.localizedDescription)
            }
            DispatchQueue.main.async { self.hlsTasks[id] = nil }
        }
    }

    func cancel(_ download: ManagedVideoDownload) {
        if let task = hlsTasks[download.id] {
            task.cancel()
            hlsTasks[download.id] = nil
        }
        session.getAllTasks { [weak self] tasks in
            guard let self else { return }
            for task in tasks where self.descriptor(from: task.taskDescription)?.id == download.id {
                task.cancel()
            }
        }
        if let index = downloads.firstIndex(where: { $0.id == download.id }) {
            downloads[index].state = .cancelled
            downloads[index].errorMessage = "Cancelled"
            persist()
        }
    }

    func deleteDownloadAndFile(_ download: ManagedVideoDownload) {
        if download.isActive { cancel(download) }
        if let fileURL = fileURL(for: download), FileManager.default.fileExists(atPath: fileURL.path) {
            try? FileManager.default.removeItem(at: fileURL)
        }
        downloads.removeAll { $0.id == download.id }
        persist()
    }
    func removeFromList(_ download: ManagedVideoDownload) {
        if download.isActive { cancel(download) }
        downloads.removeAll { $0.id == download.id }
        persist()
    }

    func clearFinished() {
        downloads.removeAll { !$0.isActive && $0.state != .paused }
        persist()
    }

    func fileURL(for download: ManagedVideoDownload) -> URL? {
        guard let name = download.destinationFileName else { return nil }
        return downloadDirectory.appendingPathComponent(name)
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard let descriptor = descriptor(from: downloadTask.taskDescription) else { return }
        DispatchQueue.main.async {
            guard let index = self.downloads.firstIndex(where: { $0.id == descriptor.id }) else { return }
            self.downloads[index].state = .downloading
            self.downloads[index].bytesWritten = totalBytesWritten
            self.downloads[index].totalBytesExpected = totalBytesExpectedToWrite
            if Date().timeIntervalSince(self.lastProgressSave) >= 1 {
                self.lastProgressSave = Date()
                self.persist()
            }
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        guard let descriptor = descriptor(from: downloadTask.taskDescription) else { return }
        if let response = downloadTask.response as? HTTPURLResponse,
           !(200...299).contains(response.statusCode) {
            try? FileManager.default.removeItem(at: location)
            if response.statusCode == 401 || response.statusCode == 403 {
                markLoginRequired(id: descriptor.id, sourceURL: descriptor.sourceURL)
            } else {
                markFailed(id: descriptor.id, message: "Server error \(response.statusCode)")
            }
            return
        }

        do {
            try FileManager.default.createDirectory(
                at: downloadDirectory,
                withIntermediateDirectories: true,
                attributes: nil
            )
            let responseName = downloadTask.response?.suggestedFilename
            let preferredName = preferredDownloadFileName(
                responseFileName: responseName,
                suggestedFileName: descriptor.suggestedFileName,
                sourceURL: URL(string: descriptor.sourceURL)
            )
            let destination = uniqueDestination(
                fileName: safeFileName(
                    preferredName,
                    fallbackFileName: descriptor.suggestedFileName,
                    fallbackURL: URL(string: descriptor.sourceURL)
                )
            )
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.moveItem(at: location, to: destination)

            DispatchQueue.main.async {
                guard let index = self.downloads.firstIndex(where: { $0.id == descriptor.id }) else { return }
                self.downloads[index].state = .completed
                self.downloads[index].bytesWritten = max(
                    self.downloads[index].bytesWritten,
                    downloadTask.countOfBytesReceived
                )
                if self.downloads[index].totalBytesExpected <= 0 {
                    self.downloads[index].totalBytesExpected = self.downloads[index].bytesWritten
                }
                self.downloads[index].destinationFileName = destination.lastPathComponent
                self.downloads[index].errorMessage = nil
                self.sortAndPersist()
            }
        } catch {
            try? FileManager.default.removeItem(at: location)
            markFailed(id: descriptor.id, message: error.localizedDescription)
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        guard let error,
              let descriptor = descriptor(from: task.taskDescription) else { return }
        if let response = task.response as? HTTPURLResponse,
           response.statusCode == 401 || response.statusCode == 403 {
            markLoginRequired(id: descriptor.id, sourceURL: descriptor.sourceURL)
            return
        }
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain,
           nsError.code == NSURLErrorCancelled {
            return
        }
        markFailed(id: descriptor.id, message: error.localizedDescription)
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        DispatchQueue.main.async {
            let handler = self.backgroundEventsCompletionHandler
            self.backgroundEventsCompletionHandler = nil
            handler?()
        }
    }

    private var downloadDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Downloads", isDirectory: true)
    }

    private func markLoginRequired(id: UUID, sourceURL: String) {
        let signedKeys: Set<String> = [
            "validto", "valid_to", "expire", "expires", "exp", "ip", "hash",
            "sign", "signature", "token", "policy", "keypair-id", "md5"
        ]
        let queryKeys = URLComponents(string: sourceURL)?.queryItems?.reduce(into: Set<String>()) {
            $0.insert($1.name.lowercased())
        } ?? []
        let isTemporarySignedURL = queryKeys.intersection(signedKeys).count >= 2

        DispatchQueue.main.async {
            guard let index = self.downloads.firstIndex(where: { $0.id == id }),
                  self.downloads[index].state != .completed else { return }
            self.downloads[index].state = .failed
            if isTemporarySignedURL {
                self.downloads[index].requiresLoginHost = nil
                self.downloads[index].errorMessage = "\u{627}\u{646}\u{62A}\u{647}\u{62A} \u{635}\u{644}\u{627}\u{62D}\u{64A}\u{629} \u{647}\u{630}\u{627} \u{627}\u{644}\u{631}\u{627}\u{628}\u{637} \u{623}\u{648} \u{623}\u{64F}\u{646}\u{634}\u{626} \u{644}\u{634}\u{628}\u{643}\u{629} \u{645}\u{62E}\u{62A}\u{644}\u{641}\u{629}\u{60C} \u{627}\u{633}\u{62D}\u{628} \u{631}\u{627}\u{628}\u{637}\u{627}\u{64B} \u{62C}\u{62F}\u{64A}\u{62F}\u{627}\u{64B} \u{648}\u{62D}\u{627}\u{648}\u{644} \u{645}\u{62C}\u{62F}\u{62F}\u{627}\u{64B}"
            } else {
                self.downloads[index].requiresLoginHost = URL(string: sourceURL)?.host
                self.downloads[index].errorMessage = "\u{64A}\u{62A}\u{637}\u{644}\u{628} \u{647}\u{630}\u{627} \u{627}\u{644}\u{631}\u{627}\u{628}\u{637} \u{62A}\u{633}\u{62C}\u{64A}\u{644} \u{627}\u{644}\u{62F}\u{62E}\u{648}\u{644}"
            }
            self.persist()
        }
    }

    func retryAfterLogin(_ download: ManagedVideoDownload) {
        guard let url = URL(string: download.sourceURL) else { return }
        downloads.removeAll { $0.id == download.id }
        persist()
        startDownload(
            url: url,
            stableKey: download.stableKey,
            title: download.title,
            suggestedFileName: download.destinationFileName ?? download.title,
            headers: [:]
        )
    }
    private func markFailed(id: UUID, message: String) {
        DispatchQueue.main.async {
            guard let index = self.downloads.firstIndex(where: { $0.id == id }),
                  self.downloads[index].state != .completed else { return }
            self.downloads[index].state = .failed
            self.downloads[index].errorMessage = message
            self.persist()
        }
    }

    private func preferredDownloadFileName(
        responseFileName: String?,
        suggestedFileName: String,
        sourceURL: URL?
    ) -> String {
        let suggested = suggestedFileName.trimmingCharacters(in: .whitespacesAndNewlines)
        let response = responseFileName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        if !suggested.isEmpty, isVideoFileName(suggested) {
            return suggested
        }

        if !response.isEmpty, isVideoFileName(response) {
            return response
        }

        if !suggested.isEmpty {
            return suggested
        }

        if let sourceURL, isVideoFileName(sourceURL.lastPathComponent) {
            return sourceURL.lastPathComponent
        }

        return "video.mp4"
    }

    private func isVideoFileName(_ value: String) -> Bool {
        let ext = (value as NSString).pathExtension.lowercased()
        guard !ext.isEmpty else { return false }
        return isVideoExtension(ext)
    }

    private func isVideoExtension(_ ext: String) -> Bool {
        ["mp4", "m4v", "mov", "mkv", "avi", "webm", "wmv", "flv", "ts", "m3u8", "movpkg"].contains(ext.lowercased())
    }
    private func safeFileName(
        _ proposed: String,
        fallbackFileName: String,
        fallbackURL: URL?
    ) -> String {
        let invalid = CharacterSet(charactersIn: "/?%*|<>:\\")
        var name = proposed
            .components(separatedBy: invalid)
            .joined(separator: "_")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty { name = "video" }

        let currentExtension = (name as NSString).pathExtension.lowercased()
        if currentExtension.isEmpty || !isVideoExtension(currentExtension) {
            let baseName = currentExtension.isEmpty ? name : (name as NSString).deletingPathExtension
            let suggestedExtension = (fallbackFileName as NSString).pathExtension.lowercased()
            let remoteExtension = fallbackURL?.pathExtension.lowercased() ?? ""
            let ext: String
            if isVideoExtension(suggestedExtension) {
                ext = suggestedExtension
            } else if isVideoExtension(remoteExtension) {
                ext = remoteExtension
            } else {
                ext = "mp4"
            }
            name = baseName + ".\(ext)"
        }
        return name
    }

    private func uniqueDestination(fileName: String) -> URL {
        let original = downloadDirectory.appendingPathComponent(fileName)
        guard FileManager.default.fileExists(atPath: original.path) else { return original }

        let base = (fileName as NSString).deletingPathExtension
        let ext = (fileName as NSString).pathExtension
        var number = 2
        while true {
            let candidateName = ext.isEmpty
                ? "\(base) \(number)"
                : "\(base) \(number).\(ext)"
            let candidate = downloadDirectory.appendingPathComponent(candidateName)
            if !FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            number += 1
        }
    }

    private func encoded(_ descriptor: TaskDescriptor) -> String? {
        guard let data = try? JSONEncoder().encode(descriptor) else { return nil }
        return data.base64EncodedString()
    }

    private func descriptor(from value: String?) -> TaskDescriptor? {
        guard let value,
              let data = Data(base64Encoded: value) else { return nil }
        return try? JSONDecoder().decode(TaskDescriptor.self, from: data)
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(downloads) else { return }
        UserDefaults.standard.set(data, forKey: persistenceKey)
    }

    private func sortAndPersist() {
        downloads.sort { lhs, rhs in
            if lhs.isActive != rhs.isActive { return lhs.isActive }
            return lhs.createdAt > rhs.createdAt
        }
        persist()
    }

    private func loadDownloads() -> [ManagedVideoDownload] {
        guard let data = UserDefaults.standard.data(forKey: persistenceKey),
              let decoded = try? JSONDecoder().decode([ManagedVideoDownload].self, from: data) else {
            return []
        }
        return decoded
    }

    private func reconcileCompletedFiles() {
        var changed = false
        for index in downloads.indices where downloads[index].state == .completed {
            guard let fileURL = fileURL(for: downloads[index]),
                  FileManager.default.fileExists(atPath: fileURL.path) else {
                downloads[index].state = .failed
                downloads[index].errorMessage = "File removed from Files"
                downloads[index].destinationFileName = nil
                changed = true
                continue
            }
        }
        if changed { persist() }
    }
}

struct DownloadManagerView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var manager = VideoDownloadManager.shared
    @State private var playback: DownloadPlayback?

    private var current: [ManagedVideoDownload] {
        manager.downloads.filter { $0.isActive || $0.state == .paused }
    }

    private var finished: [ManagedVideoDownload] {
        manager.downloads.filter { !$0.isActive && $0.state != .paused }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 14) {
                    summaryCard
                    if manager.downloads.isEmpty {
                        emptyState
                    } else {
                        downloadSection(title: "CURRENT", items: current)
                        downloadSection(title: "HISTORY", items: finished)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
            }
            .background(
                LinearGradient(
                    colors: [AppTheme.bg, Color.blue.opacity(0.08), AppTheme.bg],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ).ignoresSafeArea()
            )
            .navigationTitle("Downloads")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
                if !finished.isEmpty {
                    ToolbarItem(placement: .primaryAction) {
                        Button("Clear") { manager.clearFinished() }
                    }
                }
            }
        }
        .preferredColorScheme(.dark)
        .fullScreenCover(item: $playback) { item in
            RoutedVideoPlayerView(url: item.url, title: item.title)
        }
    }

    private var summaryCard: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle().fill(Color.blue.opacity(0.18)).frame(width: 50, height: 50)
                Image(systemName: current.isEmpty ? "checkmark.circle.fill" : "arrow.down.circle.fill")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(current.isEmpty ? .green : .blue)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(current.isEmpty ? "All caught up" : "\(current.count) active download\(current.count == 1 ? "" : "s")")
                    .font(.headline)
                Text("Direct files continue in background. HLS pauses safely when iOS time ends.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
        .padding(16)
        .background(Color.white.opacity(0.065), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22).stroke(Color.white.opacity(0.08)))
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "tray.and.arrow.down.fill")
                .font(.system(size: 42, weight: .light))
                .foregroundStyle(.blue)
            Text("No downloads yet").font(.title3.bold())
            Text("Your videos will appear here and in Files / Murtadha / Downloads.")
                .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 54)
    }

    @ViewBuilder
    private func downloadSection(title: String, items: [ManagedVideoDownload]) -> some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text(title).font(.caption.bold()).foregroundStyle(.secondary).padding(.leading, 4)
                ForEach(items) { download in
                    DownloadManagerCard(download: download)
                        .onTapGesture {
                            guard download.state == .completed, let url = manager.fileURL(for: download) else { return }
                            playback = DownloadPlayback(url: url, title: download.title)
                        }
                }
            }
        }
    }
}

private struct DownloadPlayback: Identifiable {
    let id = UUID()
    let url: URL
    let title: String
}

private struct DownloadManagerCard: View {
    @ObservedObject private var manager = VideoDownloadManager.shared
    @State private var showLogin = false
    @State private var showDeleteConfirmation = false
    @State private var swipeOffset: CGFloat = 0
    let download: ManagedVideoDownload

    var body: some View {
        VStack(spacing: 13) {
            HStack(spacing: 13) {
                ZStack {
                    RoundedRectangle(cornerRadius: 15, style: .continuous)
                        .fill(iconColor.opacity(0.16)).frame(width: 52, height: 52)
                    Image(systemName: iconName).font(.system(size: 22, weight: .semibold)).foregroundStyle(iconColor)
                }
                VStack(alignment: .leading, spacing: 5) {
                    Text(VideoTitleFormatter.title(from: download.title))
                        .font(.system(size: 15, weight: .semibold)).lineLimit(2)
                    HStack(spacing: 6) {
                        Text(statusLabel)
                        if download.isHLS { Text("HLS").font(.system(size: 9, weight: .bold)).padding(.horizontal, 6).padding(.vertical, 2).background(Color.purple.opacity(0.2), in: Capsule()).foregroundStyle(.purple) }
                    }
                    .font(.caption).foregroundStyle(download.state == .failed ? .red : .secondary)
                }
                Spacer(minLength: 4)
                actionButton
            }

            if download.isActive || download.state == .paused {
                VStack(spacing: 7) {
                    ProgressView(value: download.progress).tint(download.state == .paused ? .orange : .blue)
                    HStack {
                        Text("\(Int((download.progress * 100).rounded()))%")
                        Spacer()
                        Text(sizeLabel)
                    }
                    .font(.system(size: 11, weight: .medium).monospacedDigit()).foregroundStyle(.secondary)
                }
            }
        }
        .padding(15)
        .background(Color.white.opacity(0.065), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20).stroke(iconColor.opacity(0.14)))
        .sheet(isPresented: $showLogin) {
            if let host = download.requiresLoginHost, let url = URL(string: "https://\(host)") {
                WebLoginView(url: url) { manager.retryAfterLogin(download) }
            }
        }
        .offset(x: swipeOffset)
        .contentShape(Rectangle())
        .simultaneousGesture(
            DragGesture(minimumDistance: 18)
                .onChanged { value in
                    guard abs(value.translation.width) > abs(value.translation.height) else { return }
                    swipeOffset = min(0, max(-110, value.translation.width))
                }
                .onEnded { value in
                    if value.translation.width < -72 {
                        showDeleteConfirmation = true
                    }
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) { swipeOffset = 0 }
                }
        )
        .alert("Delete download?", isPresented: $showDeleteConfirmation) {
            Button("Cancel", role: .cancel) { }
            Button("Delete", role: .destructive) { manager.deleteDownloadAndFile(download) }
        } message: {
            Text(download.state == .completed
                ? "This removes the downloaded file from Files and the download history."
                : "This cancels the download and removes it from the list.")
        }
    }

    @ViewBuilder private var actionButton: some View {
        if download.state == .downloading || download.state == .queued {
            Button { manager.pause(download) } label: { actionIcon("pause.fill", color: .orange) }.buttonStyle(.plain)
        } else if download.state == .paused || download.state == .failed || download.state == .cancelled {
            if download.needsLogin {
                Button { showLogin = true } label: { actionIcon("person.badge.key.fill", color: .orange) }.buttonStyle(.plain)
            } else {
                Button { manager.resume(download) } label: { actionIcon("play.fill", color: .blue) }.buttonStyle(.plain)
            }
        } else if download.state == .completed, let fileURL = manager.fileURL(for: download) {
            ShareLink(item: fileURL) { actionIcon("square.and.arrow.up", color: .blue) }
        }
    }

    private func actionIcon(_ name: String, color: Color) -> some View {
        Image(systemName: name).font(.system(size: 15, weight: .bold)).foregroundStyle(color)
            .frame(width: 38, height: 38).background(color.opacity(0.14), in: Circle())
    }

    private var iconName: String {
        switch download.state {
        case .queued, .downloading: return "arrow.down.circle.fill"
        case .paused: return "pause.circle.fill"
        case .completed: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        case .cancelled: return "xmark.circle.fill"
        }
    }

    private var iconColor: Color {
        switch download.state {
        case .queued, .downloading: return .blue
        case .paused, .cancelled: return .orange
        case .completed: return .green
        case .failed: return .red
        }
    }

    private var statusLabel: String {
        switch download.state {
        case .queued: return "Waiting"
        case .downloading: return download.isHLS ? "Downloading & converting" : "Downloading in background"
        case .paused: return download.errorMessage ?? "Paused — tap play to resume"
        case .completed: return "Saved to Files"
        case .failed: return download.errorMessage ?? "Download failed"
        case .cancelled: return "Cancelled"
        }
    }

    private var sizeLabel: String {
        let written = ByteCountFormatter.string(fromByteCount: download.bytesWritten, countStyle: .file)
        guard download.totalBytesExpected > 0 else { return written }
        let total = ByteCountFormatter.string(fromByteCount: download.totalBytesExpected, countStyle: .file)
        return "\(written) / \(total)"
    }
}
struct VideoDownloadStateOverlay: View {
    let download: ManagedVideoDownload
    var compact: Bool = false

    var body: some View {
        ZStack {
            if download.isActive {
                Color.black.opacity(0.32)
                VStack(spacing: compact ? 5 : 8) {
                    ProgressView(value: download.progress)
                        .tint(.blue)
                        .frame(width: compact ? 48 : 76)
                    Text(progressText)
                        .font(.system(size: compact ? 9 : 11, weight: .bold).monospacedDigit())
                        .foregroundColor(.white)
                }
                .padding(.horizontal, compact ? 8 : 12)
                .padding(.vertical, compact ? 7 : 10)
                .background(Color.black.opacity(0.72), in: Capsule())
            } else if download.state == .completed {
                VStack {
                    HStack {
                        Spacer()
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: compact ? 18 : 22, weight: .bold))
                            .foregroundColor(.green)
                            .padding(compact ? 6 : 8)
                    }
                    Spacer()
                }
            }
        }
        .allowsHitTesting(false)
    }

    private var progressText: String {
        switch download.state {
        case .queued:
            return "Queued"
        case .downloading:
            return "\(Int((download.progress * 100).rounded()))%"
        case .paused:
            return "Paused"
        case .completed:
            return "Done"
        case .failed:
            return "Failed"
        case .cancelled:
            return "Cancelled"
        }
    }
}