import Foundation
import BackgroundTasks

/// Watches the connected PikPak WebDAV drive (the same connection used by
/// `PikPakWebDAVView`) and automatically queues any video that hasn't been
/// downloaded yet into `VideoDownloadManager` — no manual tap required.
///
/// This is intentionally independent from `AppViewModel` so it can run a
/// background refresh even when no view is on screen. It reads the saved
/// server list straight from UserDefaults (the same "saved_servers" store
/// AppViewModel persists to) and reuses `WebDAVClient` to list/stream files,
/// which is the same API the rest of the app already uses for PikPak.
@MainActor
final class PikPakAutoSyncManager: ObservableObject {
    static let shared = PikPakAutoSyncManager()
    static let backgroundTaskIdentifier = "com.mortaza.minoz.VideoPlayer.pikpak-autosync"

    // MARK: - Settings (persisted)

    @Published var isEnabled: Bool {
        didSet {
            guard oldValue != isEnabled else { return }
            UserDefaults.standard.set(isEnabled, forKey: Keys.enabled)
            handleEnabledChange()
        }
    }
    /// WebDAV path under the PikPak drive to watch. Empty = drive root.
    @Published var watchPath: String {
        didSet { UserDefaults.standard.set(watchPath, forKey: Keys.path) }
    }
    @Published var pollIntervalMinutes: Int {
        didSet {
            UserDefaults.standard.set(pollIntervalMinutes, forKey: Keys.interval)
            if isEnabled { restartForegroundTimer() }
        }
    }
    /// Skip video files smaller than this. 0 = no minimum.
    @Published var minimumSizeMB: Int {
        didSet { UserDefaults.standard.set(minimumSizeMB, forKey: Keys.minSize) }
    }

    // MARK: - Status (in-memory)

    @Published private(set) var isSyncing = false
    @Published private(set) var lastSyncDate: Date?
    @Published private(set) var lastQueuedCount = 0
    @Published private(set) var lastError: String?

    private enum Keys {
        static let enabled = "pikpak_autosync_enabled_v1"
        static let path = "pikpak_autosync_watch_path_v1"
        static let interval = "pikpak_autosync_interval_minutes_v1"
        static let minSize = "pikpak_autosync_min_size_mb_v1"
        static let serversKey = "saved_servers"
    }

    private var foregroundTimerTask: Task<Void, Never>?
    private let maxFilesPerRun = 500
    private let maxFoldersVisited = 400

    private init() {
        let d = UserDefaults.standard
        isEnabled = d.bool(forKey: Keys.enabled)
        watchPath = d.string(forKey: Keys.path) ?? ""
        let savedInterval = d.integer(forKey: Keys.interval)
        pollIntervalMinutes = savedInterval > 0 ? savedInterval : 30
        minimumSizeMB = d.integer(forKey: Keys.minSize)
    }

    // MARK: - App lifecycle hooks

    /// Must be called before `application(_:didFinishLaunchingWithOptions:)` returns.
    func registerBackgroundTask() {
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: Self.backgroundTaskIdentifier,
            using: nil
        ) { [weak self] task in
            guard let self else {
                task.setTaskCompleted(success: false)
                return
            }
            Task { @MainActor in
                self.handleBackgroundTask(task)
            }
        }
    }

    /// Call once at app startup (after registration).
    func activate() {
        guard isEnabled else { return }
        startForegroundTimer()
        scheduleBackgroundTask()
    }

    private func handleEnabledChange() {
        if isEnabled {
            startForegroundTimer()
            scheduleBackgroundTask()
            Task { await sync() }
        } else {
            foregroundTimerTask?.cancel()
            foregroundTimerTask = nil
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.backgroundTaskIdentifier)
        }
    }

    private func restartForegroundTimer() {
        foregroundTimerTask?.cancel()
        startForegroundTimer()
    }

    private func startForegroundTimer() {
        foregroundTimerTask?.cancel()
        let minutes = max(5, pollIntervalMinutes)
        foregroundTimerTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(minutes) * 60 * 1_000_000_000)
                if Task.isCancelled { break }
                await self?.sync()
            }
        }
    }

    /// Background refresh is opportunistic — iOS decides exactly when (or whether)
    /// it actually runs. The foreground timer above is what keeps this reliable
    /// while the app is open.
    private func scheduleBackgroundTask() {
        let request = BGProcessingTaskRequest(identifier: Self.backgroundTaskIdentifier)
        request.requiresNetworkConnectivity = true
        request.requiresExternalPower = false
        request.earliestBeginDate = Date(timeIntervalSinceNow: TimeInterval(max(15, pollIntervalMinutes)) * 60)
        try? BGTaskScheduler.shared.submit(request)
    }

    private func handleBackgroundTask(_ task: BGTask) {
        scheduleBackgroundTask() // always queue the next attempt
        let work = Task {
            await sync()
            task.setTaskCompleted(success: lastError == nil)
        }
        task.expirationHandler = {
            work.cancel()
        }
    }

    // MARK: - Sync

    func syncNow() async {
        await sync()
    }

    private func sync() async {
        guard !isSyncing else { return }
        guard let server = pikpakServer() else {
            lastError = "No PikPak server configured yet."
            return
        }

        isSyncing = true
        lastError = nil
        defer { isSyncing = false }

        let client = WebDAVClient(server: server)
        do {
            let videos = try await collectVideos(client: client, startingAt: watchPath)
            let headers = client.streamHeaders()
            var queued = 0
            let minBytes = Int64(minimumSizeMB) * 1_024 * 1_024

            for file in videos {
                if queued >= maxFilesPerRun { break }
                if let size = file.size, minBytes > 0, size < minBytes { continue }
                guard let url = client.streamURL(for: file) else { continue }

                let stableKey = stableDownloadKey(server: server, file: file)
                if let existing = VideoDownloadManager.shared.download(forStableKey: stableKey),
                   existing.isActive || existing.state == .completed {
                    continue
                }

                VideoDownloadManager.shared.startDownload(
                    url: url,
                    stableKey: stableKey,
                    title: file.name,
                    suggestedFileName: file.name,
                    headers: headers
                )
                queued += 1
            }
            lastQueuedCount = queued
            lastSyncDate = Date()
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Same key shape as `PikPakWebDAVView.coverKey(for:server:)` so an
    /// auto-queued download is recognized by the rest of the UI (progress
    /// overlays, "already downloaded" checks, etc.) as the same item.
    private func stableDownloadKey(server: WebDAVServer, file: WebDAVFile) -> String {
        server.id.uuidString + "|file|" + file.path + "|" + file.name
    }

    private func collectVideos(client: WebDAVClient, startingAt path: String) async throws -> [WebDAVFile] {
        var pendingPaths = [path]
        var visited = Set<String>()
        var videos: [WebDAVFile] = []
        var foldersVisited = 0

        while let nextPath = pendingPaths.popLast(),
              videos.count < maxFilesPerRun,
              foldersVisited < maxFoldersVisited {
            let normalized = nextPath.trimmingCharacters(in: .whitespacesAndNewlines)
            guard visited.insert(normalized).inserted else { continue }
            foldersVisited += 1

            let contents = try await client.listFiles(at: nextPath)
            for item in contents {
                if Task.isCancelled { return videos }
                if item.isDirectory {
                    pendingPaths.append(item.path)
                } else if item.isVideo {
                    videos.append(item)
                }
            }
        }
        return videos
    }

    /// Reads the saved server list directly from UserDefaults so this manager
    /// doesn't depend on an `AppViewModel` instance being alive.
    private func pikpakServer() -> WebDAVServer? {
        guard let data = UserDefaults.standard.data(forKey: Keys.serversKey),
              let servers = try? JSONDecoder().decode([WebDAVServer].self, from: data) else {
            return nil
        }
        return servers.first { $0.host.lowercased().contains("dav.mypikpak.com") }
    }
}
