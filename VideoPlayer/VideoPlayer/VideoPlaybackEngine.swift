import Foundation
import AVFoundation
import UIKit
import Combine

struct PlayerAudioTrackOption: Identifiable, Equatable {
    let id: String
    let title: String
}

struct PlayerSubtitleTrackOption: Identifiable, Equatable {
    let id: String
    let title: String
}

struct PlayerChapterMarker: Identifiable, Equatable {
    let id: String
    let title: String
    let fraction: Double
}

struct IntroMarker: Codable, Equatable {
    let start: Double
    let end: Double
}

enum IntroMarkerStore {
    private static let defaultsKey = "player.detectedIntroMarkers.v1"

    static func marker(for title: String) -> IntroMarker? {
        load()[seriesKey(for: title)]
    }

    static func save(_ marker: IntroMarker, for title: String) {
        guard marker.end > marker.start, marker.end <= 600 else { return }
        var values = load()
        values[seriesKey(for: title)] = marker
        if let data = try? JSONEncoder().encode(values) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
    }

    private static func load() -> [String: IntroMarker] {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let values = try? JSONDecoder().decode([String: IntroMarker].self, from: data) else { return [:] }
        return values
    }

    private static func seriesKey(for raw: String) -> String {
        var value = raw.removingPercentEncoding ?? raw
        value = value.replacingOccurrences(of: #"(?i)[\s._-]*S\d{1,3}[\s._-]*E\d{1,3}.*$"#, with: "", options: .regularExpression)
        value = value.replacingOccurrences(of: #"(?i)\b(2160p|1080p|720p|4k|hdr|web[- .]?dl|bluray|x26[45]|hevc)\b.*$"#, with: "", options: .regularExpression)
        value = value.replacingOccurrences(of: #"[._-]+"#, with: " ", options: .regularExpression)
        return value.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// High-performance 4K-capable playback core.
/// Uses AVFoundation hardware decode (VideoToolbox), async asset loading,
/// adaptive buffering, and careful main-thread usage for smooth 60fps UI.
@MainActor
final class VideoPlaybackEngine: ObservableObject {

    // MARK: - Published UI state
    @Published private(set) var isPlaying = false
    @Published private(set) var isBuffering = false
    @Published private(set) var progress: Double = 0
    @Published private(set) var currentSeconds: Double = 0
    @Published private(set) var durationSeconds: Double = 0
    @Published private(set) var currentTimeFormatted = "00:00"
    @Published private(set) var durationFormatted = "00:00"
    @Published private(set) var bufferPercent = 0
    @Published private(set) var resolutionLabel = "—"
    @Published private(set) var resolutionWidth: Int = 0
    @Published private(set) var resolutionHeight: Int = 0
    @Published private(set) var resolutionTier: ResolutionTier = .unknown
    @Published private(set) var errorMessage: String?
    @Published private(set) var didReachEnd = false
    @Published private(set) var audioTracks: [PlayerAudioTrackOption] = []
    @Published private(set) var selectedAudioTrackID: String?
    @Published private(set) var introMarker: IntroMarker?
    @Published private(set) var subtitleTracks: [PlayerSubtitleTrackOption] = []
    @Published private(set) var selectedSubtitleTrackID: String?
    @Published private(set) var chapters: [PlayerChapterMarker] = []
    @Published var resetZoomToken = 0

    /// Shared player — AVPlayerLayer attaches to this for GPU composition.
    let player = AVPlayer()

    /// Fired ~4×/s with (seconds, duration, width, height) for resume persistence.
    var onProgressTick: ((Double, Double, Int, Int) -> Void)?

    // MARK: - Private
    private var timeObserver: Any?
    private var itemStatusObserver: NSKeyValueObservation?
    private var itemBufferEmptyObserver: NSKeyValueObservation?
    private var itemBufferKeepUpObserver: NSKeyValueObservation?
    private var itemLoadedRangesObserver: NSKeyValueObservation?
    private var itemPresentationSizeObserver: NSKeyValueObservation?
    private var rateObserver: NSKeyValueObservation?
    private var stallObserver: NSObjectProtocol?
    private var failObserver: NSObjectProtocol?
    private var endObserver: NSObjectProtocol?
    private var thermalObserver: NSObjectProtocol?
    private var memoryObserver: NSObjectProtocol?

    /// Cancels stale async loads when a new URL is opened.
    private var loadGeneration: UInt64 = 0
    private var pendingResumeSeconds: Double = 0
    private var didApplyResume = false
    private var loadedAsset: AVURLAsset?
    private var progressSaveCounter: Int = 0
    /// Keeps the scrubber at the requested spot while AVPlayer buffers the seek.
    private var pendingSeekSeconds: Double?
    /// Prevents a cancelled older seek completion from clearing a newer request.
    private var seekGeneration: UInt64 = 0
    /// True for the duration of a pinch/pan gesture on the video surface.
    /// See setInteracting(_:).
    private var isInteracting = false
    private var audioOptionsByID: [String: AVMediaSelectionOption] = [:]
    private var subtitleOptionsByID: [String: AVMediaSelectionOption] = [:]

    /// Background queue for asset I/O and non-UI work (not main thread).
    private let assetQueue = DispatchQueue(
        label: "com.mortaza.minoz.videoplayer.asset",
        qos: .userInitiated
    )

    /// YouTube-style forward buffer. AVPlayer may lower this automatically
    /// under memory, thermal, or network pressure.
    /// Note: this buffers *compressed* network data, not decoded frames — but at
    /// 8K bitrates (often 80-150+ Mbps) a 300s buffer means several GB of RAM
    /// just for the queue, which is a common cause of stalls/jetsam on 8K content.
    /// Once actual resolution is known, high-res clips are trimmed down to
    /// `highResForwardBufferSeconds` (see the presentationSize observer below).
    private let forwardBufferSeconds: TimeInterval = 60
    /// Cap used once we know a clip is very high resolution (8K-class).
    private let highResForwardBufferSeconds: TimeInterval = 30

    /// Allow high bitrates needed for 4K (0 = no artificial cap).
    private let unlimitedPeakBitRate: Double = 0
    /// Applied only under sustained thermal pressure so decode load can drop
    /// instead of the player stalling outright. 4K-equivalent ceiling.
    private let thermalThrottledMaxResolution = CGSize(width: 3840, height: 2160)
    private let thermalThrottledPeakBitRate: Double = 40_000_000

    init() {
        configurePlayer()
        configureAudioSession()
        observeSystemPressure()
    }

    deinit {
        // Nonisolated cleanup path — tear down observers without MainActor hop.
        // Time observer must be removed on the player; call from cleanup before deinit when possible.
    }

    // MARK: - Public API

    func load(url: URL, title: String = "", resumeAt: Double = 0, httpHeaders: [String: String]? = nil) {
        errorMessage = nil
        didReachEnd = false
        introMarker = title.isEmpty ? nil : IntroMarkerStore.marker(for: title)
        subtitleTracks = []
        selectedSubtitleTrackID = nil
        chapters = []
        isBuffering = true
        pendingResumeSeconds = max(0, resumeAt)
        didApplyResume = false
        progress = 0
        bufferPercent = 0
        currentSeconds = 0
        durationSeconds = 0
        loadGeneration &+= 1
        let generation = loadGeneration

        tearDownItemObservers()
        removeTimeObserver()
        player.pause()
        player.replaceCurrentItem(with: nil)
        loadedAsset = nil

        configureHTTPBasicCredential(for: url, headers: httpHeaders)

        // Progressive / HLS friendly asset options — async decode path preferred.
        var options: [String: Any] = [
            AVURLAssetPreferPreciseDurationAndTimingKey: false,
            AVURLAssetAllowsCellularAccessKey: true,
            AVURLAssetAllowsExpensiveNetworkAccessKey: true,
            AVURLAssetAllowsConstrainedNetworkAccessKey: true
        ]
        // Keep authenticated WebDAV/PikPak MP4 files on Apple's hardware player.
        // Without these headers AVPlayer can fail the first request and fall back
        // to the lower-quality compatibility player.
        if let httpHeaders, !httpHeaders.isEmpty {
            options["AVURLAssetHTTPHeaderFieldsKey"] = httpHeaders
        }
        // Work around a known AVKit limitation: URLs with no recognizable file
        // extension (e.g. PikPak's `/download/?fid=...` direct links) are often
        // rejected as "not playable" even though the bytes are a perfectly
        // normal video — other players just don't rely on the extension.
        if let mimeHint = LinkResolver.mimeTypeHint(for: url) {
            options["AVURLAssetOutOfBandMIMETypeKey"] = mimeHint
        }
        let asset = AVURLAsset(url: url, options: options)
        loadedAsset = asset

        // Load playable keys off the main thread, then attach item on main.
        assetQueue.async { [weak self] in
            // Only gate startup on playability. Duration, tracks, chapters and
            // media-selection metadata are loaded by AVPlayerItem after the first
            // frame path is attached; waiting for them here can require multiple
            // remote Range requests on non-fast-start files.
            let keys = ["playable"]
            asset.loadValuesAsynchronously(forKeys: keys) {
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    guard generation == self.loadGeneration else { return }

                    var error: NSError?
                    let status = asset.statusOfValue(forKey: "playable", error: &error)
                    guard status == .loaded, asset.isPlayable else {
                        self.isBuffering = false
                        self.errorMessage = error?.localizedDescription
                            ?? "This video cannot be played on this device."
                        return
                    }

                    let item = self.makePlayerItem(asset: asset)
                    self.attach(item: item)
                    Task.detached(priority: .utility) {
                        // Remote frame extraction can issue extra Range requests.
                        // Give the playback request exclusive bandwidth at startup.
                        if !url.isFileURL {
                            try? await Task.sleep(nanoseconds: 8_000_000_000)
                        }
                        _ = await VideoThumbnailLoader.cachePoster(from: asset, for: url)
                    }
                    // Resume is applied when item is ready (see status observer)
                    if self.pendingResumeSeconds < 1 {
                        self.player.play()
                        self.isPlaying = true
                    }
                    // Chapter inspection is useful but never startup-critical.
                    // Delay it until playback has had time to deliver initial frames.
                    Task { @MainActor [weak self] in
                        try? await Task.sleep(nanoseconds: 8_000_000_000)
                        guard let self, generation == self.loadGeneration else { return }
                        self.detectIntroChapter(in: asset, title: title)
                    }
                    UIApplication.shared.isIdleTimerDisabled = true
                }
            }
        }
    }

    func cleanup() {
        // Final progress tick before teardown
        if durationSeconds > 0 {
            onProgressTick?(currentSeconds, durationSeconds, resolutionWidth, resolutionHeight)
        }
        loadGeneration &+= 1
        player.pause()
        isPlaying = false
        isBuffering = false
        tearDownItemObservers()
        removeTimeObserver()
        player.currentItem?.cancelPendingSeeks()
        player.currentItem?.videoComposition = nil
        player.replaceCurrentItem(with: nil)
        loadedAsset = nil
        audioTracks = []
        audioOptionsByID = [:]
        selectedAudioTrackID = nil
        subtitleTracks = []
        subtitleOptionsByID = [:]
        selectedSubtitleTrackID = nil
        chapters = []
        onProgressTick = nil
        UIApplication.shared.isIdleTimerDisabled = false
        player.automaticallyWaitsToMinimizeStalling = true
    }

    func formattedTime(forFraction fraction: Double) -> String {
        guard durationSeconds > 0 else { return currentTimeFormatted }
        return Self.format(seconds: durationSeconds * min(1, max(0, fraction)))
    }

    /// Called by the video surface for the entire span of a pinch or pan
    /// (through deceleration). Every @Published write in handleTimeTick()
    /// forces VideoPlayerView.body to re-diff its whole view tree — cheap on
    /// its own, but landing 4x/sec on the exact same main thread that's also
    /// driving a live UIScrollView gesture is what was producing the
    /// remaining small stutter mid-pan. Silencing the tick for the ~0.25s at
    /// most it can be stale during a gesture is imperceptible; the next tick
    /// after the gesture ends catches the UI back up immediately.
    func setInteracting(_ active: Bool) {
        isInteracting = active
    }

    func togglePlayPause() {
        if didReachEnd {
            didReachEnd = false
            seek(to: 0)
        }
        if player.rate > 0 {
            player.pause()
            isPlaying = false
        } else {
            player.play()
            isPlaying = true
        }
    }

    func selectAudioTrack(id: String) {
        guard let item = player.currentItem,
              let group = item.asset.mediaSelectionGroup(forMediaCharacteristic: .audible),
              let option = audioOptionsByID[id] else { return }
        item.select(option, in: group)
        selectedAudioTrackID = id
    }

    private func refreshAudioTracks(for item: AVPlayerItem) {
        guard let group = item.asset.mediaSelectionGroup(forMediaCharacteristic: .audible) else {
            audioTracks = []
            audioOptionsByID = [:]
            selectedAudioTrackID = nil
            return
        }
        var map: [String: AVMediaSelectionOption] = [:]
        let tracks = group.options.enumerated().map { index, option in
            let id = "audio-\(index)"
            map[id] = option
            return PlayerAudioTrackOption(id: id, title: option.displayName)
        }
        audioOptionsByID = map
        audioTracks = tracks
        if let selected = item.currentMediaSelection.selectedMediaOption(in: group),
           let entry = map.first(where: { $0.value === selected }) {
            selectedAudioTrackID = entry.key
        } else {
            selectedAudioTrackID = tracks.first?.id
        }
    }

    func selectSubtitleTrack(id: String?) {
        guard let item = player.currentItem,
              let group = item.asset.mediaSelectionGroup(forMediaCharacteristic: .legible) else { return }
        if let id, let option = subtitleOptionsByID[id] {
            item.select(option, in: group)
            selectedSubtitleTrackID = id
        } else {
            item.select(nil, in: group)
            selectedSubtitleTrackID = nil
        }
    }

    private func refreshSubtitleTracks(for item: AVPlayerItem) {
        guard let group = item.asset.mediaSelectionGroup(forMediaCharacteristic: .legible) else {
            subtitleTracks = []; subtitleOptionsByID = [:]; selectedSubtitleTrackID = nil; return
        }
        var map: [String: AVMediaSelectionOption] = [:]
        subtitleTracks = group.options.enumerated().map { index, option in
            let id = "subtitle-\(index)"; map[id] = option
            return PlayerSubtitleTrackOption(id: id, title: option.displayName)
        }
        subtitleOptionsByID = map
        if let selected = item.currentMediaSelection.selectedMediaOption(in: group),
           let entry = map.first(where: { $0.value === selected }) { selectedSubtitleTrackID = entry.key }
    }

    func setRate(_ rate: Float) {
        // Keep hardware decode path; rate change is handled by AVPlayer.
        if rate > 0 {
            player.rate = rate
            isPlaying = true
        } else {
            player.pause()
            isPlaying = false
        }
    }

    func skipForward(seconds: Double = 15) {
        // Repeated taps must accumulate from the last requested position, not
        // AVPlayer's stale currentTime while the previous seek is buffering.
        let base = pendingSeekSeconds ?? CMTimeGetSeconds(player.currentTime())
        let limit = durationSeconds > 0 ? durationSeconds : .greatestFiniteMagnitude
        seek(toSeconds: min(limit, max(0, base) + seconds))
    }

    func skipBackward(seconds: Double = 15) {
        let base = pendingSeekSeconds ?? CMTimeGetSeconds(player.currentTime())
        seek(toSeconds: max(0, base - seconds))
    }

    func seek(to fraction: Double) {
        didReachEnd = false
        guard let item = player.currentItem else { return }
        let duration = CMTimeGetSeconds(item.duration)
        guard duration.isFinite, duration > 0 else { return }
        seek(toSeconds: duration * fraction)
    }

    /// Returns a small frame for the timeline preview without moving playback.
    func previewImage(at fraction: Double) async -> UIImage? {
        guard let asset = player.currentItem?.asset else { return nil }
        let duration = CMTimeGetSeconds(asset.duration)
        guard duration.isFinite, duration > 0 else { return nil }

        let time = CMTime(
            seconds: duration * min(1, max(0, fraction)),
            preferredTimescale: 600
        )

        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let generator = AVAssetImageGenerator(asset: asset)
                generator.appliesPreferredTrackTransform = true
                generator.maximumSize = CGSize(width: 240, height: 135)
                let frame = try? generator.copyCGImage(at: time, actualTime: nil)
                continuation.resume(returning: frame.map(UIImage.init(cgImage:)))
            }
        }
    }

    // MARK: - Player configuration (hardware path)

    private func detectIntroChapter(in asset: AVAsset, title: String) {
        guard !title.isEmpty else { return }
        let groups = asset.chapterMetadataGroups(bestMatchingPreferredLanguages: Locale.preferredLanguages + ["en"])
        let assetDuration = CMTimeGetSeconds(asset.duration)
        if assetDuration.isFinite, assetDuration > 0 {
            chapters = groups.enumerated().compactMap { index, group in
                let start = CMTimeGetSeconds(group.timeRange.start)
                guard start.isFinite, start > 0, start < assetDuration else { return nil }
                let label = group.items.compactMap { $0.stringValue }.first?.trimmingCharacters(in: .whitespacesAndNewlines)
                return PlayerChapterMarker(id: "chapter-\(index)", title: (label?.isEmpty == false ? label! : "Chapter \(index + 1)"), fraction: start / assetDuration)
            }
        }
        for group in groups {
            let labels = group.items.compactMap { $0.stringValue }.joined(separator: " ").lowercased()
            let isIntro = ["intro", "opening", "opening credits", "theme", "op"].contains { token in
                labels == token || labels.contains("\(token) ") || labels.contains(" \(token)")
            }
            guard isIntro else { continue }
            let start = CMTimeGetSeconds(group.timeRange.start)
            let duration = CMTimeGetSeconds(group.timeRange.duration)
            let end = start + duration
            guard start.isFinite, end.isFinite, duration >= 5, end <= 600 else { continue }
            let marker = IntroMarker(start: max(0, start), end: end)
            introMarker = marker; IntroMarkerStore.save(marker, for: title); break
        }
    }

    private func configurePlayer() {
        // Hardware-accelerated pipeline (VideoToolbox decode + GPU layer composition).
        player.automaticallyWaitsToMinimizeStalling = true
        player.allowsExternalPlayback = true
        player.appliesMediaSelectionCriteriaAutomatically = true
        player.actionAtItemEnd = .pause

        // Prevent silent switch from muting unexpectedly during video.
        // (Audio session also configured below.)
        if #available(iOS 15.0, *) {
            player.audiovisualBackgroundPlaybackPolicy = .pauses
        }

        rateObserver = player.observe(\.rate, options: [.new]) { [weak self] player, _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isPlaying = player.rate > 0
                // A positive playback rate is definitive proof that frames are flowing.
                // Clear stale buffer-empty notifications immediately instead of leaving
                // the branded loading ring spinning until the controls auto-hide.
                if player.rate > 0 { self.isBuffering = false }
            }
        }
    }

    private func configureAudioSession() {
        assetQueue.async {
            let session = AVAudioSession.sharedInstance()
            do {
                try session.setCategory(
                    .playback,
                    mode: .moviePlayback,
                    options: [.allowAirPlay, .allowBluetoothA2DP]
                )
                try session.setActive(true, options: [])
            } catch {
                // Non-fatal; playback still works with default session.
            }
        }
    }

    private func makePlayerItem(asset: AVURLAsset) -> AVPlayerItem {
        let item = AVPlayerItem(asset: asset)

        // Keep several minutes ready ahead for smooth seeking and 4K playback.
        item.preferredForwardBufferDuration = forwardBufferSeconds

        // No artificial bitrate cap → allow full 4K HLS / progressive streams.
        item.preferredPeakBitRate = unlimitedPeakBitRate

        // No resolution cap: use the original source variant, including above 4K when available.
        if #available(iOS 11.0, *) {
            item.preferredMaximumResolution = .zero
        }

        // Continue filling the transient buffer while playback is paused.
        item.canUseNetworkResourcesForLiveStreamingWhilePaused = true

        // Prefer precise video composition off unless needed (saves GPU/CPU).
        item.videoComposition = nil
        item.seekingWaitsForVideoCompositionRendering = false

        // HDR10 / Dolby Vision metadata path when the stream provides it (4K HDR).
        if #available(iOS 15.0, *) {
            item.appliesPerFrameHDRDisplayMetadata = true
        }

        return item
    }

    private func attach(item: AVPlayerItem) {
        observe(item: item)
        installTimeObserver()
        player.replaceCurrentItem(with: item)
        applyThermalPolicyIfNeeded()
    }

    // MARK: - Seeking (smooth, avoids decoder thrash)

    private func seek(toSeconds seconds: Double) {
        guard seconds.isFinite else { return }
        let safeSeconds = max(0, seconds)
        seekGeneration &+= 1
        let generation = seekGeneration
        pendingSeekSeconds = safeSeconds
        currentSeconds = safeSeconds
        if durationSeconds > 0 { progress = min(1, max(0, safeSeconds / durationSeconds)) }
        currentTimeFormatted = Self.format(seconds: safeSeconds)
        // Small tolerance lets the decoder snap to keyframes → fewer stalls on 4K.
        let target = CMTime(seconds: safeSeconds, preferredTimescale: 600)
        let tolerance = CMTime(seconds: 0.05, preferredTimescale: 600)
        player.currentItem?.cancelPendingSeeks()
        isBuffering = true
        player.seek(to: target, toleranceBefore: tolerance, toleranceAfter: tolerance) { [weak self] finished in
            Task { @MainActor [weak self] in
                guard let self, generation == self.seekGeneration else { return }
                if finished, self.isPlaying {
                    self.player.play()
                }
                if !finished { self.pendingSeekSeconds = nil }
                self.isBuffering = false
            }
        }
    }

    // MARK: - Observers

    private func installTimeObserver() {
        removeTimeObserver()
        // ~4 UI updates/sec is enough for scrubber; keeps main thread free under 4K load.
        let interval = CMTime(seconds: 0.25, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: interval,
            queue: .main
        ) { [weak self] time in
            // Already on main queue — update UI directly (no extra hop).
            self?.handleTimeTick(time)
        }
    }

    nonisolated private func handleTimeTick(_ time: CMTime) {
        // Called on main queue from AVPlayer; hop to MainActor for published state.
        Task { @MainActor [weak self] in
            guard let self, let item = self.player.currentItem else { return }
            let current = CMTimeGetSeconds(time)
            let duration = CMTimeGetSeconds(item.duration)
            guard duration.isFinite, duration > 0, current.isFinite else { return }
            guard !self.isInteracting else { return }

            if let pending = self.pendingSeekSeconds {
                if abs(current - pending) > 0.75 { return }
                self.pendingSeekSeconds = nil
            }
            self.currentSeconds = current
            self.durationSeconds = duration
            self.progress = min(1, max(0, current / duration))

            // Persist resume ~once per second (every 4 ticks at 0.25s)
            self.progressSaveCounter += 1
            if self.progressSaveCounter >= 4 {
                self.progressSaveCounter = 0
                self.onProgressTick?(current, duration, self.resolutionWidth, self.resolutionHeight)
            }

            // Formatting "mm:ss" is a few integer ops + String(format:) — cheaper
            // than the two thread-hops (formatQueue.async + Task back to main)
            // it previously took to compute it off-main. Doing it inline here
            // removes that scheduling overhead from the 4×/sec tick.
            self.currentTimeFormatted = Self.format(seconds: current)
            self.durationFormatted = Self.format(seconds: duration)
        }
    }

    private func observe(item: AVPlayerItem) {
        tearDownItemObservers()

        itemStatusObserver = item.observe(\.status, options: [.new, .initial]) { [weak self] item, _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                switch item.status {
                case .readyToPlay:
                    self.isBuffering = false
                    self.errorMessage = nil
                    self.refreshAudioTracks(for: item)
                    self.refreshSubtitleTracks(for: item)
                    // Apply saved resume position once
                    if !self.didApplyResume, self.pendingResumeSeconds > 1 {
                        self.didApplyResume = true
                        let resume = self.pendingResumeSeconds
                        self.pendingResumeSeconds = 0
                        self.seek(toSeconds: resume)
                        self.player.play()
                        self.isPlaying = true
                    } else if !self.didApplyResume {
                        self.didApplyResume = true
                        if self.player.rate == 0 {
                            self.player.play()
                            self.isPlaying = true
                        }
                    }
                case .failed:
                    self.isBuffering = false
                    self.errorMessage = item.error?.localizedDescription ?? "Playback failed"
                default:
                    break
                }
            }
        }

        itemBufferEmptyObserver = item.observe(\.isPlaybackBufferEmpty, options: [.new]) { [weak self] item, _ in
            Task { @MainActor [weak self] in
                if item.isPlaybackBufferEmpty {
                    self?.isBuffering = true
                }
            }
        }

        itemBufferKeepUpObserver = item.observe(\.isPlaybackLikelyToKeepUp, options: [.new]) { [weak self] item, _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if item.isPlaybackLikelyToKeepUp {
                    self.isBuffering = false
                    // Auto-resume after rebuffer if user intended to play.
                    if self.isPlaying, self.player.rate == 0 {
                        self.player.play()
                    }
                } else if item.isPlaybackBufferEmpty {
                    self.isBuffering = true
                }
            }
        }

        itemLoadedRangesObserver = item.observe(\.loadedTimeRanges, options: [.new]) { [weak self] item, _ in
            // Compute buffer % off main, publish on main.
            let duration = CMTimeGetSeconds(item.duration)
            guard duration.isFinite, duration > 0 else { return }
            let end = item.loadedTimeRanges
                .map(\.timeRangeValue)
                .map { CMTimeGetSeconds($0.start) + CMTimeGetSeconds($0.duration) }
                .filter(\.isFinite)
                .max() ?? 0
            let percent = Int(min(100, max(0, (end / duration) * 100)))
            Task { @MainActor [weak self] in
                self?.bufferPercent = percent
            }
        }

        itemPresentationSizeObserver = item.observe(\.presentationSize, options: [.new, .initial]) { [weak self] item, _ in
            let size = item.presentationSize
            Task { @MainActor [weak self] in
                guard let self else { return }
                if size.width > 1, size.height > 1 {
                    let w = Int(size.width)
                    let h = Int(size.height)
                    self.resolutionWidth = w
                    self.resolutionHeight = h
                    let tier = ResolutionTier.from(width: w, height: h)
                    self.resolutionTier = tier
                    let tag = tier.badgeText ?? "SD"
                    self.resolutionLabel = "\(w)×\(h) · \(tag)"

                    // 8K-class content: a 300s network buffer at typical 8K
                    // bitrates can mean several GB queued, which is what was
                    // producing stalls/cut-outs. Trim it once we know the size.
                    if w >= 6000 || h >= 6000 {
                        item.preferredForwardBufferDuration = self.highResForwardBufferSeconds
                    }
                }
            }
        }

        let center = NotificationCenter.default
        stallObserver = center.addObserver(
            forName: .AVPlayerItemPlaybackStalled,
            object: item,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isBuffering = true
                // Brief wait then resume — network rebuffer recovery.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                    guard let self, self.isPlaying else { return }
                    self.player.play()
                }
            }
        }

        failObserver = center.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] note in
            Task { @MainActor [weak self] in
                let err = note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error
                self?.errorMessage = err?.localizedDescription ?? "Playback ended with an error"
                self?.isBuffering = false
            }
        }

        endObserver = center.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isPlaying = false
                self.progress = 1
                self.didReachEnd = true
                // Mark finished so resume clears
                if self.durationSeconds > 0 {
                    self.onProgressTick?(self.durationSeconds, self.durationSeconds, self.resolutionWidth, self.resolutionHeight)
                }
            }
        }
    }

    private func tearDownItemObservers() {
        itemStatusObserver?.invalidate()
        itemBufferEmptyObserver?.invalidate()
        itemBufferKeepUpObserver?.invalidate()
        itemLoadedRangesObserver?.invalidate()
        itemPresentationSizeObserver?.invalidate()
        itemStatusObserver = nil
        itemBufferEmptyObserver = nil
        itemBufferKeepUpObserver = nil
        itemLoadedRangesObserver = nil
        itemPresentationSizeObserver = nil

        let center = NotificationCenter.default
        if let stallObserver { center.removeObserver(stallObserver) }
        if let failObserver { center.removeObserver(failObserver) }
        if let endObserver { center.removeObserver(endObserver) }
        stallObserver = nil
        failObserver = nil
        endObserver = nil
    }

    private func removeTimeObserver() {
        if let timeObserver {
            player.removeTimeObserver(timeObserver)
            self.timeObserver = nil
        }
    }

    // MARK: - System pressure (memory / thermal)

    private func observeSystemPressure() {
        memoryObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleMemoryWarning()
            }
        }

        thermalObserver = NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.applyThermalPolicyIfNeeded()
            }
        }
    }

    private func handleMemoryWarning() {
        // Shrink forward buffer temporarily to free decoded/queued RAM.
        if let item = player.currentItem {
            item.preferredForwardBufferDuration = 4
        }
        // Restore afterwards — but only back to the size appropriate for this
        // clip's resolution, not unconditionally back to 300s. Restoring the
        // full 300s buffer right after a memory warning on an 8K stream is
        // what was reproducing the same pressure a few seconds later.
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
            guard let self, let item = self.player.currentItem else { return }
            let isHighRes = self.resolutionWidth >= 6000 || self.resolutionHeight >= 6000
            item.preferredForwardBufferDuration = isHighRes ? self.highResForwardBufferSeconds : self.forwardBufferSeconds
        }
    }

    /// Lets decode load actually drop under sustained heat instead of forcing
    /// full original quality no matter what. Previously this always reset to
    /// "unlimited" on every thermal-state change (including the *serious*/
    /// *critical* states), so on real hardware playing above the device's
    /// decode ceiling — the common case for true 8K — it could only stall,
    /// never gracefully step down.
    private func applyThermalPolicyIfNeeded() {
        guard let item = player.currentItem else { return }
        let state = ProcessInfo.processInfo.thermalState
        switch state {
        case .serious, .critical:
            item.preferredPeakBitRate = unlimitedPeakBitRate
            if #available(iOS 11.0, *) {
                item.preferredMaximumResolution = .zero
            }
        case .nominal, .fair:
            fallthrough
        @unknown default:
            item.preferredPeakBitRate = unlimitedPeakBitRate
            if #available(iOS 11.0, *) {
                item.preferredMaximumResolution = .zero
            }
        }
    }
    /// AVPlayer uses the shared URL credential store for HTTP Basic challenges.
    /// WebDAV URLs carry the user/password or Authorization header supplied by the server view.
    private func configureHTTPBasicCredential(for url: URL, headers: [String: String]?) {
        guard let host = url.host else { return }

        var username = url.user?.removingPercentEncoding
        var password = url.password?.removingPercentEncoding

        if (username?.isEmpty ?? true), let authorization = headers?["Authorization"],
           authorization.lowercased().hasPrefix("basic ") {
            let encoded = String(authorization.dropFirst(6))
            if let data = Data(base64Encoded: encoded),
               let pair = String(data: data, encoding: .utf8),
               let separator = pair.firstIndex(of: ":") {
                username = String(pair[..<separator])
                password = String(pair[pair.index(after: separator)...])
            }
        }

        guard let username, !username.isEmpty, let password else { return }
        let port = url.port ?? (url.scheme?.lowercased() == "https" ? 443 : 80)
        let space = URLProtectionSpace(
            host: host,
            port: port,
            protocol: url.scheme,
            realm: nil,
            authenticationMethod: NSURLAuthenticationMethodHTTPBasic
        )
        let credential = URLCredential(user: username, password: password, persistence: .forSession)
        URLCredentialStorage.shared.setDefaultCredential(credential, for: space)
    }
    // MARK: - Helpers

    nonisolated private static func format(seconds: Double) -> String {
        guard seconds.isFinite else { return "00:00" }
        let s = Int(seconds.rounded(.down))
        let h = s / 3600
        let m = (s % 3600) / 60
        let sec = s % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, sec)
        }
        return String(format: "%02d:%02d", m, sec)
    }
}
