import SwiftUI
import SceneKit
import CoreMotion
import AVKit
import AVFoundation
import UIKit
import MobileVLCKit
import UniformTypeIdentifiers

// MARK: - Player screen

struct VideoPlayerView: View {
    let url: URL
    let title: String
    var resumeAt: Double = 0
    var linkId: UUID? = nil
    /// Optional HTTP headers (WebDAV Basic Auth, etc.)
    var httpHeaders: [String: String]? = nil
    var onProgress: ((Double, Double, Int, Int) -> Void)? = nil

    @Environment(\.dismiss) var dismiss
    @StateObject private var engine = VideoPlaybackEngine()
    @State private var showControls = true
    @State private var isScrubbing = false
    @State private var scrubProgress: Double = 0
    @State private var hideTask: Task<Void, Never>?
    @State private var isFillMode = false
    @State private var isVR360Mode = false
    /// True once the user has manually tapped the VR toggle for *this* video —
    /// after that we never override their choice with auto-detection.
    @State private var userOverrideVR = false
    /// True once auto-detection has run (either applied or determined not applicable)
    /// for the currently loaded video, so it only ever fires once per video.
    @State private var vrAutoDetected = false
    @State private var isOrientationLocked = false
    @State private var fillModeToken = 0
    @State private var useExtendedPlayer = false
    @State private var showExtendedPlayerPrompt = false
    @State private var mkvFillMode = false
    @State private var mkvResetZoomToken = 0
    @StateObject private var mkvControls = MKVPlaybackControls()
    @State private var showPlaybackSettings = false
    @State private var subtitleSize: Double = 1.0
    @State private var subtitleColor: PlayerSubtitleColor = .white
    @State private var selectedAudioTrack = ""
    @State private var selectedSubtitleTrack = "Off"
    @State private var showSubtitleImporter = false
    @State private var externalSubtitleCues: [ExternalSubtitleCue] = []
    @State private var externalSubtitleFileName: String?
    @State private var selectedQuality = "Auto"
    @State private var nextEpisodeCountdown = 5
    @State private var endCountdownTask: Task<Void, Never>?

    // Temporary test mode: every file uses the main Apple player only.
    // The MKV player remains in the project but is not selected.
    private var usesMKVPlayer: Bool {
        if useExtendedPlayer { return true }
        let ext = url.pathExtension.lowercased()
        return ["mkv", "webm", "avi", "flv", "wmv", "m2ts", "mts", "ts"].contains(ext)
    }
    /// Filename/title hint only — doesn't need the video to have loaded yet.
    private var filenameSuggestsVR360: Bool {
        let label = (title + " " + url.lastPathComponent).lowercased()
        return ["360", "vr", "equirect", "spherical", "sbs", "side-by-side"].contains { label.contains($0) }
    }
    /// Real detection, not a stub. An equirectangular 360° source is ~2:1
    /// (width:height) — a far more reliable signal than filenames, since a
    /// huge share of real VR files never carry a "vr"/"360" hint in their
    /// name at all (re-encoded, downloaded, or renamed along the way). Once
    /// the decoder reports real dimensions we check the ratio; before that
    /// (or for packed formats where ratio alone isn't distinctive) we still
    /// honor the filename hint so detection can fire immediately on appear.
    private var supportsVR360: Bool {
        let width = usesMKVPlayer ? mkvControls.videoWidth : Int(engine.resolutionWidth)
        let height = usesMKVPlayer ? mkvControls.videoHeight : Int(engine.resolutionHeight)
        if width > 0, height > 0 {
            let ratio = Double(width) / Double(height)
            if ratio > 1.85 && ratio < 2.15 { return true }
        }
        return filenameSuggestsVR360
    }
    /// Wires the detection above into the actual toggle. Runs at most once per
    /// loaded video (per `vrAutoDetected`) and only when the user hasn't already
    /// touched the VR button themselves (per `userOverrideVR`) — this was
    /// previously computed but never applied anywhere, so 360°/VR clips never
    /// auto-enabled and the button carried no real signal about the content.
    private func applyAutoVRDetectionIfNeeded() {
        guard !userOverrideVR, !vrAutoDetected else { return }
        if supportsVR360 {
            vrAutoDetected = true
            isVR360Mode = true
        } else if (usesMKVPlayer ? mkvControls.videoWidth : engine.resolutionWidth) > 0 {
            // Resolution is known and doesn't match 360/VR heuristics — stop checking.
            vrAutoDetected = true
        }
    }
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            // Full-bleed video — never reflows when chrome toggles.
            if usesMKVPlayer {
                MKVVideoPlayerView(
                    url: url,
                    controls: mkvControls,
                    resumeAt: resumeAt,
                    isFillMode: mkvFillMode,
                    resetZoomToken: mkvResetZoomToken,
                    isVR360Mode: isVR360Mode
                )
                    .contentShape(Rectangle())
                    .simultaneousGesture(TapGesture().onEnded { toggleMKVControls() })
                    .ignoresSafeArea()
            } else {
            if isVR360Mode {
                VR360PlayerView(player: engine.player) {
                    withAnimation(.easeInOut(duration: 0.2)) { showControls.toggle() }
                    scheduleAutoHide()
                }
                .ignoresSafeArea()
            } else {
                ZoomableVideoView(
                    player: engine.player,
                    resetToken: engine.resetZoomToken,
                    fillModeToken: fillModeToken,
                    isFillMode: isFillMode,
                    videoSize: CGSize(width: engine.resolutionWidth, height: engine.resolutionHeight),
                    onSingleTap: {
                        withAnimation(.easeInOut(duration: 0.2)) { showControls.toggle() }
                        scheduleAutoHide()
                    },
                    onInteractionChange: { engine.setInteracting($0) },
                    onDoubleTap: {
                        withAnimation(.easeInOut(duration: 0.28)) {
                            isFillMode.toggle(); fillModeToken += 1
                        }
                    }
                )
                .equatable()
                .ignoresSafeArea()
            }
            }

            if !usesMKVPlayer, engine.isBuffering {
                ProgressView()
                    .progressViewStyle(.circular)
                    .tint(.white)
                    .padding(18)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .allowsHitTesting(false)
            }

            if !usesMKVPlayer, let error = engine.errorMessage {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.title)
                        .foregroundColor(.yellow)
                    Text(error)
                        .font(.footnote)
                        .foregroundColor(.white)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                    Button("Retry") { engine.load(url: url, resumeAt: resumeAt, httpHeaders: httpHeaders) }
                        .buttonStyle(.borderedProminent)
                        .tint(AppPalette.accent)
                }
                .padding(20)
                .background(Color.black.opacity(0.78), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }

            // Chrome only — empty regions do NOT intercept touches (no full-screen hit target).
            if usesMKVPlayer, showControls {
                VStack {
                    HStack {
                        Button { dismiss() } label: {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 17, weight: .semibold))
                                .foregroundColor(.white)
                                .frame(width: 40, height: 40)
                                .background(.ultraThinMaterial, in: Circle())
                        }
                        PlayerQualityBadge(label: mkvQualityLabel)
                        Spacer()
                        vrToggleButton
                        orientationLockButton

                        Button {
                            mkvFillMode.toggle()
                            scheduleAutoHide()
                        } label: {
                            Image(systemName: mkvFillMode ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundColor(.white)
                                .frame(width: 40, height: 40)
                                .background(.ultraThinMaterial, in: Circle())
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 10)
                    Spacer()
                    VStack(spacing: 12) {
                        cinematicMetadataPanel
                            .padding(.bottom, 12)
                        InstantSeekBar(
                            progress: isScrubbing ? scrubProgress : mkvControls.displayProgress,
                            bufferProgress: mkvControls.displayProgress,
                            currentLabel: isScrubbing
                                ? mkvControls.formattedTime(forFraction: scrubProgress)
                                : mkvControls.currentTimeFormatted,
                            durationLabel: negativeRemaining(current: isScrubbing ? scrubProgress * mkvControls.durationSeconds : mkvControls.currentSeconds, duration: mkvControls.durationSeconds),
                            chapters: playbackChapters,
                            onSeek: { value in
                                mkvControls.seek(to: value)
                                isScrubbing = false
                                scheduleAutoHide()
                            },
                            onScrubbing: { value, active in
                                isScrubbing = active
                                scrubProgress = value
                            }
                        )
                        .frame(height: SeekBarContainerView.preferredHeight)
                    }
                    .padding(.horizontal, 22)
                    .padding(.bottom, 26)
                }
            } else if showControls {
                VStack(spacing: 0) {
                    topOverlay
                    Spacer(minLength: 0)
                        .allowsHitTesting(false)
                    bottomOverlay
                }

            }

            // Intentionally outside the auto-hidden chrome: it remains available
            // throughout the intro window even after every other control fades.
            if showControls && !playbackDidEnd {
                CircularPlaybackButton(
                    progress: usesMKVPlayer ? mkvControls.displayProgress : engine.progress,
                    isPlaying: usesMKVPlayer ? mkvControls.isPlaying : engine.isPlaying,
                    action: {
                        if usesMKVPlayer { mkvControls.togglePlayback() } else { engine.togglePlayPause() }
                        scheduleAutoHide()
                    }
                )
                .transition(.scale(scale: 0.9).combined(with: .opacity))
            }

            if shouldShowSkipIntro && !playbackDidEnd {
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        Button(action: skipIntro) {
                            Label("Skip Intro", systemImage: "forward.end.fill")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundColor(.white)
                                .padding(.horizontal, 18)
                                .frame(height: 44)
                                .background(.ultraThinMaterial, in: Capsule())
                                .overlay(Capsule().stroke(Color.white.opacity(0.32), lineWidth: 1))
                        }
                    }
                    .padding(.trailing, 26)
                    .padding(.bottom, showControls ? 118 : 32)
                }
                .transition(.opacity.combined(with: .move(edge: .trailing)))
            }

            if let cue = activeExternalSubtitle, !playbackDidEnd {
                VStack {
                    Spacer()
                    Text(cue.text)
                        .font(.system(size: 22 * subtitleSize, weight: .semibold))
                        .foregroundColor(subtitleColor.color)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(Color.black.opacity(0.58), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .shadow(color: .black.opacity(0.8), radius: 3)
                        .padding(.horizontal, 34)
                        .padding(.bottom, showControls ? 48 : 24)
                }
                .allowsHitTesting(false)
            }

            if playbackDidEnd {
                PlayerEndScreen(
                    title: VideoTitleFormatter.title(from: title),
                    countdown: nextEpisodeCountdown,
                    onReplay: replayCurrentVideo,
                    onBack: { dismiss() }
                )
                .transition(.opacity)
            }
        }
        .sheet(isPresented: $showPlaybackSettings, onDismiss: { scheduleAutoHide() }) {
            PlayerAdvancedSettingsSheet(
                selectedAudioTrack: $selectedAudioTrack,
                selectedSubtitleTrack: $selectedSubtitleTrack,
                selectedQuality: $selectedQuality,
                subtitleSize: $subtitleSize,
                subtitleColor: $subtitleColor,
                currentQuality: usesMKVPlayer ? mkvQualityLabel : (engine.resolutionTier.badgeText ?? "Auto"),
                audioTracks: usesMKVPlayer ? [] : engine.audioTracks,
                selectedAudioTrackID: usesMKVPlayer ? nil : engine.selectedAudioTrackID,
                subtitleFileName: externalSubtitleFileName,
                onAudioTrackChange: { id in
                    selectedAudioTrack = id
                    engine.selectAudioTrack(id: id)
                },
                onChooseSubtitleFile: {
                    showPlaybackSettings = false
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        showSubtitleImporter = true
                    }
                },
                onDisableSubtitles: {
                    externalSubtitleCues = []
                    externalSubtitleFileName = nil
                    selectedSubtitleTrack = "Off"
                },
                onRateChange: { rate in
                    if usesMKVPlayer { mkvControls.setRate(rate) } else { engine.setRate(rate) }
                }
            )
        }
        .fileImporter(
            isPresented: $showSubtitleImporter,
            allowedContentTypes: subtitleDocumentTypes,
            allowsMultipleSelection: false
        ) { result in
            guard case .success(let urls) = result, let fileURL = urls.first else { return }
            loadExternalSubtitle(from: fileURL)
        }
        .statusBar(hidden: true)
        .navigationBarHidden(true)
        .onAppear {
            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
            // Defensive reset: guarantees a clean VR state for this video even
            // if this view instance is ever reused across plays.
            isVR360Mode = false
            userOverrideVR = false
            vrAutoDetected = false
            engine.onProgressTick = { seconds, duration, w, h in
                onProgress?(seconds, duration, w, h)
            }
            if !usesMKVPlayer {
                engine.load(url: url, resumeAt: resumeAt, httpHeaders: httpHeaders)
            }
            applyAutoVRDetectionIfNeeded()
            scheduleAutoHide()
        }
        .onChange(of: engine.resolutionWidth) { _ in applyAutoVRDetectionIfNeeded() }
        .onChange(of: mkvControls.videoWidth) { _ in applyAutoVRDetectionIfNeeded() }
        .onDisappear {
            hideTask?.cancel()
            ScreenOrientationLock.unlock()
            isOrientationLocked = false
            if !usesMKVPlayer {
                if engine.durationSeconds > 0 {
                    onProgress?(engine.currentSeconds, engine.durationSeconds, engine.resolutionWidth, engine.resolutionHeight)
                }
                engine.cleanup()
            } else if mkvControls.durationSeconds > 0 {
                onProgress?(mkvControls.currentSeconds, mkvControls.durationSeconds, mkvControls.videoWidth, mkvControls.videoHeight)
            }
            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        }
        .onChange(of: engine.errorMessage) { error in
            guard error != nil, !usesMKVPlayer else { return }
            engine.cleanup()
            useExtendedPlayer = true
        }
        .onChange(of: isScrubbing) { scrubbing in
            if scrubbing { hideTask?.cancel() } else { scheduleAutoHide() }
        }
        .onChange(of: playbackDidEnd) { ended in
            if ended { beginEndCountdown() } else { endCountdownTask?.cancel() }
        }
    }

    // MARK: - Top chrome

    private var topOverlay: some View {
        HStack(spacing: 12) {
            Button {
                UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                dismiss()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(width: 40, height: 40)
                    .background(.ultraThinMaterial, in: Circle())
            }

            PlayerQualityBadge(tier: engine.resolutionTier)

            Spacer(minLength: 0)

            vrToggleButton

            orientationLockButton

            Button {
                withAnimation(.easeInOut(duration: 0.28)) {
                    isFillMode.toggle()
                    fillModeToken += 1
                }
                scheduleAutoHide()
            } label: {
                Image(systemName: isFillMode ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(width: 40, height: 40)
                    .background(.ultraThinMaterial, in: Circle())
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 16)
        .background(
            LinearGradient(
                colors: [Color.black.opacity(0.72), Color.black.opacity(0)],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea(edges: .top)
            .allowsHitTesting(false)
        )
    }

    // MARK: - Bottom chrome

    private var bottomOverlay: some View {
        VStack(spacing: 0) {
            cinematicMetadataPanel
                .padding(.horizontal, 18)
                .padding(.top, 8)
                .padding(.bottom, 12)

            // Timeline
            InstantSeekBar(
                progress: isScrubbing ? scrubProgress : engine.progress,
                bufferProgress: Double(engine.bufferPercent) / 100,
                currentLabel: isScrubbing
                    ? engine.formattedTime(forFraction: scrubProgress)
                    : engine.currentTimeFormatted,
                durationLabel: negativeRemaining(current: isScrubbing ? scrubProgress * engine.durationSeconds : engine.currentSeconds, duration: engine.durationSeconds),
                chapters: playbackChapters,
                onSeek: { value in
                    scrubProgress = value
                    isScrubbing = false
                    engine.seek(to: value)
                    scheduleAutoHide()
                },
                onScrubbing: { value, active in
                    isScrubbing = active
                    scrubProgress = value
                }
            )
            .frame(height: SeekBarContainerView.preferredHeight)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 16)
            .padding(.bottom, 18)
        }
        .background(
            LinearGradient(
                colors: [Color.black.opacity(0.82), Color.black.opacity(0)],
                startPoint: .bottom,
                endPoint: .top
            )
            .ignoresSafeArea(edges: .bottom)
            .allowsHitTesting(false)
        )
    }

    private func toggleMKVControls() {
        withAnimation(.easeInOut(duration: 0.2)) {
            showControls.toggle()
        }
        if showControls { scheduleAutoHide() } else { hideTask?.cancel() }
    }

    /// Manual, always-present VR toggle. Auto-detection (filename hint +
    /// aspect-ratio once dimensions load) is only ever a heuristic — it can
    /// miss an oddly-named file, or misfire on an ordinary widescreen clip.
    /// This button is the guaranteed fallback: whatever the detector
    /// decided, the person can flip it themselves in one tap, on every
    /// video, every time. Marking `userOverrideVR` freezes auto-detection
    /// so it never fights the explicit choice for the rest of this playback.
    private var vrToggleButton: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                isVR360Mode.toggle()
            }
            userOverrideVR = true
            vrAutoDetected = true
            scheduleAutoHide()
        } label: {
            Image(systemName: "view.3d")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(isVR360Mode ? AppPalette.accent : .white)
                .frame(width: 40, height: 40)
                .background(.ultraThinMaterial, in: Circle())
        }
        .accessibilityLabel(isVR360Mode ? "Switch to normal view" : "Switch to VR 360° view")
    }

    private var orientationLockButton: some View {
        Button {
            if isOrientationLocked {
                ScreenOrientationLock.unlock()
                isOrientationLocked = false
            } else if ScreenOrientationLock.lockToCurrentOrientation() {
                isOrientationLocked = true
            }
            scheduleAutoHide()
        } label: {
            Image(systemName: isOrientationLocked ? "lock.fill" : "lock.open.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(isOrientationLocked ? .cyan : .white)
                .frame(width: 40, height: 40)
                .background(.ultraThinMaterial, in: Circle())
        }
        .accessibilityLabel(isOrientationLocked ? "Unlock screen rotation" : "Lock screen rotation")
    }

    private var subtitleDocumentTypes: [UTType] {
        var types: [UTType] = [.plainText]
        if let srt = UTType(filenameExtension: "srt") { types.append(srt) }
        if let vtt = UTType(filenameExtension: "vtt") { types.append(vtt) }
        return types
    }

    private var activeExternalSubtitle: ExternalSubtitleCue? {
        externalSubtitleCues.first { currentPlaybackSeconds >= $0.start && currentPlaybackSeconds <= $0.end }
    }

    private func loadExternalSubtitle(from fileURL: URL) {
        let scoped = fileURL.startAccessingSecurityScopedResource()
        defer { if scoped { fileURL.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: fileURL),
              let content = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .utf16) else { return }
        let cues = ExternalSubtitleParser.parse(content)
        guard !cues.isEmpty else { return }
        externalSubtitleCues = cues
        externalSubtitleFileName = fileURL.lastPathComponent
        selectedSubtitleTrack = fileURL.lastPathComponent
    }

    private var seriesDisplayName: String {
        var value = title.removingPercentEncoding ?? title
        if let range = value.range(of: #"(?i)[\s._-]*S\d{1,3}[\s._-]*E\d{1,3}.*$"#, options: .regularExpression) {
            value.removeSubrange(range)
        }
        value = value.replacingOccurrences(of: #"[._]+"#, with: " ", options: .regularExpression)
        value = value.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? VideoTitleFormatter.title(from: title) : value
    }

    private var episodeDisplayLine: String? {
        guard let component = VideoTitleFormatter.episodeComponents(from: title) else { return nil }
        let parsed = VideoTitleFormatter.episodeTitle(from: title)
        let episodeTitle = parsed == "Episode" ? "Episode \(component.episode)" : parsed
        return "S\(component.season)  •  E\(component.episode)  —  \(episodeTitle)"
    }

    private var cinematicMetadataPanel: some View {
        HStack(alignment: .bottom, spacing: 18) {
            VStack(alignment: .leading, spacing: 5) {
                if let episodeDisplayLine {
                    Text(episodeDisplayLine)
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundColor(.white.opacity(0.76))
                        .lineLimit(1)
                }
                Text(seriesDisplayName)
                    .font(.system(size: 23, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
            }
            Spacer(minLength: 8)
            HStack(spacing: 3) {
                Button {
                    showPlaybackSettings = true
                    hideTask?.cancel()
                } label: {
                    Image(systemName: "gearshape.fill")
                        .font(.system(size: 17, weight: .semibold))
                        .frame(width: 43, height: 43)
                }
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "rectangle.stack.fill")
                        .font(.system(size: 17, weight: .semibold))
                        .frame(width: 43, height: 43)
                }
            }
            .foregroundColor(.white)
            .padding(4)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(
                Capsule()
                    .stroke(
                        LinearGradient(colors: [AppPalette.purple.opacity(0.8), AppPalette.blue.opacity(0.8)], startPoint: .leading, endPoint: .trailing),
                        lineWidth: 1
                    )
            )
            .shadow(color: AppPalette.purple.opacity(0.22), radius: 12, y: 5)
        }
    }

    private var currentPlaybackSeconds: Double {
        usesMKVPlayer ? mkvControls.currentSeconds : engine.currentSeconds
    }

    private var playbackDurationSeconds: Double {
        usesMKVPlayer ? mkvControls.durationSeconds : engine.durationSeconds
    }

    private var playbackDidEnd: Bool {
        usesMKVPlayer ? mkvControls.didReachEnd : engine.didReachEnd
    }

    private var isEpisode: Bool {
        VideoTitleFormatter.episodeComponents(from: title) != nil
    }

    private var shouldShowSkipIntro: Bool {
        isEpisode && playbackDurationSeconds > 120 && currentPlaybackSeconds >= 0 && currentPlaybackSeconds < 180
    }

    private var mkvQualityLabel: String {
        if mkvControls.videoWidth >= 3840 || mkvControls.videoHeight >= 2160 { return "4K" }
        if mkvControls.videoWidth >= 1920 || mkvControls.videoHeight >= 1080 { return "1080P" }
        if mkvControls.videoWidth >= 1280 || mkvControls.videoHeight >= 720 { return "720P" }
        return "HD"
    }

    private var playbackChapters: [PlaybackChapter] {
        guard playbackDurationSeconds > 0 else { return [] }
        return [
            PlaybackChapter(title: "Intro", fraction: min(120 / playbackDurationSeconds, 0.2)),
            PlaybackChapter(title: "Chapter 2", fraction: 0.33),
            PlaybackChapter(title: "Chapter 3", fraction: 0.66),
            PlaybackChapter(title: "Finale", fraction: 0.88)
        ]
    }

    private func skipIntro() {
        let fraction = min(1, 120 / max(playbackDurationSeconds, 1))
        if usesMKVPlayer { mkvControls.seek(to: fraction) } else { engine.seek(to: fraction) }
    }

    private func replayCurrentVideo() {
        nextEpisodeCountdown = 5
        if usesMKVPlayer {
            mkvControls.seek(to: 0)
            mkvControls.togglePlayback()
        } else {
            engine.seek(to: 0)
            engine.togglePlayPause()
        }
        scheduleAutoHide()
    }

    private func beginEndCountdown() {
        endCountdownTask?.cancel()
        nextEpisodeCountdown = 5
        endCountdownTask = Task {
            for value in stride(from: 4, through: 0, by: -1) {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard !Task.isCancelled else { return }
                await MainActor.run { nextEpisodeCountdown = value }
            }
            guard !Task.isCancelled else { return }
            await MainActor.run { replayCurrentVideo() }
        }
    }

    private func negativeRemaining(current: Double, duration: Double) -> String {
        let remaining = max(0, duration - current)
        let total = Int(remaining.rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        return hours > 0
            ? String(format: "- %02d:%02d:%02d", hours, minutes, seconds)
            : String(format: "- %02d:%02d", minutes, seconds)
    }

    private func scheduleAutoHide() {
        hideTask?.cancel()
        guard showControls else { return }
        hideTask = Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled, !isScrubbing else { return }
            await MainActor.run {
                withAnimation(.easeInOut(duration: 0.25)) {
                    showControls = false
                }
            }
        }
    }

}

// MARK: - MKV playback

@MainActor
private final class MKVPlaybackControls: ObservableObject {
    @Published var progress: Double = 0
    @Published private(set) var requestedProgress: Double?
    @Published var isPlaying = false
    @Published var currentSeconds: Double = 0
    @Published var durationSeconds: Double = 0
    @Published var videoWidth = 0
    @Published var videoHeight = 0
    @Published var resolutionLabel = "MKV"
    @Published var didReachEnd = false
    weak var surface: MKVPlayerSurface?

    var displayProgress: Double { requestedProgress ?? progress }
    var currentTimeFormatted: String { formatTime(currentSeconds) }
    var durationFormatted: String { formatTime(durationSeconds) }
    func formattedTime(forFraction fraction: Double) -> String {
        formatTime(durationSeconds * min(1, max(0, fraction)))
    }

    func togglePlayback() { surface?.togglePlaybackFromControls() }
    func seek(to fraction: Double) {
        let target = min(1, max(0, fraction))
        didReachEnd = false
        requestedProgress = target
        surface?.seek(to: target)
    }
    func updateProgress(_ value: Double) {
        progress = value
        if let requestedProgress, abs(value - requestedProgress) < 0.025 {
            self.requestedProgress = nil
        }
    }
    func updateTime(current: Double, duration: Double) {
        durationSeconds = max(0, duration)
        // VLC keeps reporting the pre-seek clock while it fills the new buffer.
        // Hold the requested label steady until updateProgress confirms arrival.
        if let requestedProgress, durationSeconds > 0 {
            currentSeconds = requestedProgress * durationSeconds
        } else {
            currentSeconds = max(0, current)
        }
        if durationSeconds > 0, currentSeconds >= durationSeconds - 0.5 {
            didReachEnd = true
            isPlaying = false
        }
    }
    func updateVideoSize(_ size: CGSize) {
        videoWidth = Int(size.width)
        videoHeight = Int(size.height)
    }
    func skip(by seconds: Int) {
        guard durationSeconds > 0 else { surface?.skip(by: seconds); return }
        let base = requestedProgress.map { $0 * durationSeconds } ?? currentSeconds
        let targetSeconds = min(durationSeconds, max(0, base + Double(seconds)))
        let targetProgress = targetSeconds / durationSeconds
        requestedProgress = targetProgress
        currentSeconds = targetSeconds
        surface?.seek(to: targetProgress)
    }
    func setRate(_ rate: Float) { surface?.setRate(rate) }

    private func formatTime(_ seconds: Double) -> String {
        let total = max(0, Int(seconds))
        if total >= 3600 {
            return String(format: "%d:%02d:%02d", total / 3600, (total / 60) % 60, total % 60)
        }
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

private struct VR360PlayerView: UIViewRepresentable {
    let player: AVPlayer
    let onSingleTap: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onSingleTap: onSingleTap) }

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView(frame: .zero)
        view.backgroundColor = .black
        view.scene = SCNScene()
        view.preferredFramesPerSecond = 60
        view.isPlaying = true
        view.rendersContinuously = true

        // An AVPlayerLayer feeding the material — rather than handing the
        // AVPlayer object straight to SceneKit — is the reliable path here.
        // Direct AVPlayer-as-texture is known to silently freeze on the first
        // frame or fail to composite on some devices/OS versions, which
        // presents as "VR mode toggles on but the video looks flat/static" —
        // exactly this bug. The layer needs a real pixel size to have
        // something to rasterize; the actual video's aspect doesn't matter
        // since it's mapped onto a sphere.
        let playerLayer = AVPlayerLayer(player: player)
        playerLayer.frame = CGRect(x: 0, y: 0, width: 2048, height: 1024)
        playerLayer.videoGravity = .resizeAspectFill
        context.coordinator.playerLayer = playerLayer

        let sphere = SCNSphere(radius: 10)
        sphere.segmentCount = 192
        sphere.isGeodesic = false
        let material = SCNMaterial()
        material.diffuse.contents = playerLayer
        material.diffuse.wrapS = .repeat
        material.diffuse.wrapT = .clamp
        material.isDoubleSided = true
        material.lightingModel = .constant
        sphere.firstMaterial = material
        let sphereNode = SCNNode(geometry: sphere)
        sphereNode.scale = SCNVector3(-1, 1, 1)
        view.scene?.rootNode.addChildNode(sphereNode)

        let camera = SCNCamera()
        camera.fieldOfView = 78
        camera.zNear = 0.01
        camera.zFar = 30
        let cameraNode = SCNNode()
        cameraNode.camera = camera
        view.scene?.rootNode.addChildNode(cameraNode)
        view.pointOfView = cameraNode
        context.coordinator.attach(view: view, camera: cameraNode)
        return view
    }

    func updateUIView(_ view: SCNView, context: Context) {
        context.coordinator.onSingleTap = onSingleTap
        if context.coordinator.playerLayer?.player !== player {
            context.coordinator.playerLayer?.player = player
        }
    }

    static func dismantleUIView(_ view: SCNView, coordinator: Coordinator) {
        coordinator.stop()
        coordinator.playerLayer?.player = nil
        view.isPlaying = false
        view.scene = nil
    }

    final class Coordinator: NSObject {
        var onSingleTap: () -> Void
        var playerLayer: AVPlayerLayer?
        private let motion = CMMotionManager()
        private weak var view: SCNView?
        private weak var camera: SCNNode?
        private var dragYaw: Float = 0
        private var dragPitch: Float = 0
        private var gestureStartYaw: Float = 0
        private var gestureStartPitch: Float = 0

        init(onSingleTap: @escaping () -> Void) { self.onSingleTap = onSingleTap }

        func attach(view: SCNView, camera: SCNNode) {
            self.view = view
            self.camera = camera
            let tap = UITapGestureRecognizer(target: self, action: #selector(tapped))
            let pan = UIPanGestureRecognizer(target: self, action: #selector(panned(_:)))
            let pinch = UIPinchGestureRecognizer(target: self, action: #selector(pinched(_:)))
            tap.require(toFail: pan)
            view.addGestureRecognizer(tap)
            view.addGestureRecognizer(pan)
            view.addGestureRecognizer(pinch)
            startMotion()
        }

        private func startMotion() {
            guard motion.isDeviceMotionAvailable else { return }
            motion.deviceMotionUpdateInterval = 1.0 / 60.0
            motion.startDeviceMotionUpdates(using: .xArbitraryZVertical, to: .main) { [weak self] sample, _ in
                guard let self, let attitude = sample?.attitude else { return }
                self.apply(yaw: Float(attitude.yaw) + self.dragYaw, pitch: Float(attitude.pitch) + self.dragPitch)
            }
        }

        private func apply(yaw: Float, pitch: Float) {
            camera?.eulerAngles = SCNVector3(max(-1.45, min(1.45, pitch)), -yaw, 0)
        }

        @objc private func tapped() { onSingleTap() }

        @objc private func panned(_ gesture: UIPanGestureRecognizer) {
            let point = gesture.translation(in: view)
            if gesture.state == .began {
                gestureStartYaw = dragYaw
                gestureStartPitch = dragPitch
            }
            dragYaw = gestureStartYaw + Float(point.x) * 0.004
            dragPitch = max(-1.45, min(1.45, gestureStartPitch + Float(point.y) * 0.004))
            if !motion.isDeviceMotionActive { apply(yaw: dragYaw, pitch: dragPitch) }
        }

        @objc private func pinched(_ gesture: UIPinchGestureRecognizer) {
            guard let camera = camera?.camera else { return }
            camera.fieldOfView = max(42, min(105, camera.fieldOfView / gesture.scale))
            gesture.scale = 1
        }

        func stop() {
            motion.stopDeviceMotionUpdates()
            view?.gestureRecognizers?.forEach { view?.removeGestureRecognizer($0) }
        }
    }
}
private struct MKVVideoPlayerView: UIViewRepresentable {
    let url: URL
    let controls: MKVPlaybackControls
    var resumeAt: Double = 0
    var isFillMode = false
    var resetZoomToken = 0
    var isVR360Mode = false
    var onSingleTap: (() -> Void)? = nil

    func makeUIView(context: Context) -> MKVPlayerSurface {
        let view = MKVPlayerSurface()
        view.controls = controls
        view.onSingleTap = onSingleTap
        view.setFillMode(isFillMode)
        view.setVR360Mode(isVR360Mode)
        view.play(url: url, resumeAt: resumeAt)
        return view
    }

    func updateUIView(_ uiView: MKVPlayerSurface, context: Context) {
        uiView.controls = controls
        uiView.onSingleTap = onSingleTap
        uiView.setFillMode(isFillMode)
        uiView.setVR360Mode(isVR360Mode)
        uiView.resetZoomIfNeeded(token: resetZoomToken)
        uiView.playIfNeeded(url: url)
    }

    static func dismantleUIView(_ uiView: MKVPlayerSurface, coordinator: ()) {
        uiView.stop()
    }
}

private final class MKVPlayerSurface: UIView, UIScrollViewDelegate {
    private let mediaPlayer = VLCMediaPlayer()
    private let motionManager = CMMotionManager()
    private let scrollView = UIScrollView()
    private let videoView = UIView()
    private let loadingIndicator = UIActivityIndicatorView(style: .large)
    private var currentURL: URL?
    private var loadingTimer: Timer?
    private var videoSize: CGSize = .zero
    private var sourceFormat = "Video"
    private var isFillMode = false
    private var resetZoomToken = 0
    private var isVR360Mode = false
    private var vrYaw: Float = 0
    private var vrPitch: Float = 0
    private var vrFOV: Float = 80
    private var vrPanStart = CGPoint.zero
    var onSingleTap: (() -> Void)?
    weak var controls: MKVPlaybackControls? {
        didSet { controls?.surface = self }
    }
    private lazy var tapGesture = UITapGestureRecognizer(target: self, action: #selector(togglePlayback))
    private lazy var doubleTapGesture = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
    private lazy var vrPanGesture = UIPanGestureRecognizer(target: self, action: #selector(handleVRPan(_:)))
    private lazy var vrPinchGesture = UIPinchGestureRecognizer(target: self, action: #selector(handleVRPinch(_:)))

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        clipsToBounds = true

        scrollView.delegate = self
        scrollView.minimumZoomScale = 1
        scrollView.maximumZoomScale = 10
        scrollView.bounces = false
        scrollView.bouncesZoom = false
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.contentInsetAdjustmentBehavior = .never
        addSubview(scrollView)

        videoView.backgroundColor = .black
        videoView.isOpaque = true
        videoView.layer.isOpaque = true
        videoView.layer.shouldRasterize = false
        scrollView.addSubview(videoView)
        doubleTapGesture.numberOfTapsRequired = 2
        tapGesture.require(toFail: doubleTapGesture)
        scrollView.addGestureRecognizer(doubleTapGesture)
        scrollView.addGestureRecognizer(tapGesture)
        addGestureRecognizer(vrPanGesture)
        addGestureRecognizer(vrPinchGesture)
        vrPanGesture.isEnabled = false
        vrPinchGesture.isEnabled = false
        mediaPlayer.drawable = videoView

        loadingIndicator.color = .white
        loadingIndicator.hidesWhenStopped = true
        addSubview(loadingIndicator)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        scrollView.frame = bounds
        loadingIndicator.center = CGPoint(x: bounds.midX, y: bounds.midY)
        // Only recompute the fitted frame (and do the heavier render-scale /
        // clamp work) when the video's un-zoomed size actually changes —
        // e.g. rotation or a new video loading. Contentinset changes made
        // *during* a live pinch/pan also trigger layoutSubviews, and doing
        // this work on every one of those ticks is what caused the
        // shake-while-zooming and lag-while-panning.
        guard scrollView.zoomScale == 1 else { return }
        let fittedSize = fittedVideoSize()
        guard videoView.bounds.size != fittedSize else { return }
        videoView.frame = CGRect(origin: .zero, size: fittedSize)
        scrollView.contentSize = fittedSize
        updateScrollableArea()
        clampOffset()
        updateVideoRenderScale()
    }

    func play(url: URL, resumeAt: Double = 0) {
        currentURL = url
        let extensionName = url.pathExtension.trimmingCharacters(in: .whitespacesAndNewlines)
        sourceFormat = extensionName.isEmpty ? "Video" : extensionName.uppercased()
        loadingIndicator.startAnimating()
        let media = VLCMedia(url: url)
        media.addOption(":avcodec-hw=none")
        if isVR360Mode {
            // MobileVLCKit 3.x uses `projection=2` for 360° sphere. Newer
            // LibVLC builds use `projection-mode=1` for equirectangular input.
            // Supplying both keeps the dedicated VR path working across builds.
            media.addOption(":projection=2")
            media.addOption(":projection-mode=1")
        }
        media.addOption(":network-caching=10000")
        media.addOption(":http-reconnect")
        media.addOption(":file-caching=1500")
        media.addOption(":drop-late-frames")
        mediaPlayer.drawable = videoView
        mediaPlayer.media = media
        mediaPlayer.play()
        if resumeAt > 3 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                self?.mediaPlayer.time = VLCTime(int: Int32(resumeAt * 1000))
            }
        }
        loadingTimer?.invalidate()
        loadingTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            self.controls?.isPlaying = self.mediaPlayer.isPlaying
            self.controls?.updateProgress(min(1, max(0, Double(self.mediaPlayer.position))))
            // MobileVLCKit: `time` is non-optional VLCTime in current versions.
            let currentTime = Double(self.mediaPlayer.time.intValue) / 1000
            let duration = Double(self.mediaPlayer.media?.length.intValue ?? 0) / 1000
            self.controls?.updateTime(current: currentTime, duration: duration)
            let size = self.mediaPlayer.videoSize
            if size.width > 1, size.height > 1 {
                self.controls?.resolutionLabel = "\(Int(size.width))×\(Int(size.height)) · \(self.sourceFormat)"
                self.controls?.updateVideoSize(size)
            }
            if size.width > 1, size.height > 1 {
                let nextSize = CGSize(width: size.width, height: size.height)
                if self.videoSize != nextSize {
                    self.videoSize = nextSize
                    self.setNeedsLayout()
                }
            }
            if self.isVR360Mode {
                _ = self.mediaPlayer.updateViewpoint(self.vrYaw, pitch: self.vrPitch, roll: 0, fov: self.vrFOV, absolute: true)
            }
            if self.mediaPlayer.isPlaying {
                self.loadingIndicator.stopAnimating()
            }
        }
    }

    func playIfNeeded(url: URL) {
        guard currentURL != url else { return }
        play(url: url)
    }

    func stop() {
        motionManager.stopDeviceMotionUpdates()
        mediaPlayer.stop()
        mediaPlayer.drawable = nil
        loadingTimer?.invalidate()
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? {
        videoView
    }

    // NOTE: contentOffset/contentInset must never be forced while the user's
    // pinch or pan gesture is actively driving the scroll view — doing so
    // fights UIKit's own live gesture tracking and is what produced the
    // shaking on zoom and the stutter/lag on pan. `updateScrollableArea()`
    // is cheap (arithmetic only) and safe to run live for centering;
    // `clampOffset()` and `updateVideoRenderScale()` are deferred to
    // gesture-end, since the latter rebuilds VLC's drawable and is expensive.

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        updateScrollableArea()
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        // Intentionally empty: with bounces = false and a correctly sized
        // content area, UIScrollView already keeps offsets in bounds while
        // the user is actively dragging.
    }

    func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
        updateScrollableArea()
        clampOffset()
        updateVideoRenderScale()
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate {
            clampOffset()
            updateVideoRenderScale()
        }
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        clampOffset()
        updateVideoRenderScale()
    }

    private func fittedVideoSize() -> CGSize {
        guard videoSize.width > 0, videoSize.height > 0, bounds.width > 0, bounds.height > 0 else { return bounds.size }
        let scale = isFillMode
            ? max(bounds.width / videoSize.width, bounds.height / videoSize.height)
            : min(bounds.width / videoSize.width, bounds.height / videoSize.height)
        return CGSize(width: videoSize.width * scale, height: videoSize.height * scale)
    }

    func setFillMode(_ fill: Bool) {
        guard isFillMode != fill else { return }
        isFillMode = fill
        scrollView.setZoomScale(1, animated: false)
        setNeedsLayout()
    }

    func setVR360Mode(_ enabled: Bool) {
        guard isVR360Mode != enabled else { return }
        isVR360Mode = enabled
        scrollView.isScrollEnabled = !enabled
        vrPanGesture.isEnabled = enabled
        vrPinchGesture.isEnabled = enabled
        if enabled {
            scrollView.setZoomScale(1, animated: false)
            startVRMotion()
            _ = mediaPlayer.updateViewpoint(vrYaw, pitch: vrPitch, roll: 0, fov: vrFOV, absolute: true)
        } else {
            motionManager.stopDeviceMotionUpdates()
        }
        if let restartURL = currentURL, mediaPlayer.media != nil {
            let resume = max(0, Double(mediaPlayer.time.intValue) / 1000)
            mediaPlayer.stop()
            currentURL = nil
            play(url: restartURL, resumeAt: resume)
        }
    }

    private func startVRMotion() {
        guard motionManager.isDeviceMotionAvailable, !motionManager.isDeviceMotionActive else { return }
        motionManager.deviceMotionUpdateInterval = 1.0 / 60.0
        motionManager.startDeviceMotionUpdates(using: .xArbitraryZVertical, to: .main) { [weak self] motion, _ in
            guard let self, self.isVR360Mode, let attitude = motion?.attitude else { return }
            let yaw = self.vrYaw + Float(attitude.yaw * 180 / .pi)
            let pitch = self.vrPitch + Float(attitude.pitch * 180 / .pi)
            _ = self.mediaPlayer.updateViewpoint(yaw, pitch: max(-89, min(89, pitch)), roll: 0, fov: self.vrFOV, absolute: true)
        }
    }

    @objc private func handleVRPan(_ gesture: UIPanGestureRecognizer) {
        guard isVR360Mode else { return }
        let translation = gesture.translation(in: self)
        if gesture.state == .began { vrPanStart = CGPoint(x: CGFloat(vrYaw), y: CGFloat(vrPitch)) }
        vrYaw = Float(vrPanStart.x - translation.x * 0.18)
        vrPitch = max(-89, min(89, Float(vrPanStart.y + translation.y * 0.18)))
        _ = mediaPlayer.updateViewpoint(vrYaw, pitch: vrPitch, roll: 0, fov: vrFOV, absolute: true)
    }

    @objc private func handleVRPinch(_ gesture: UIPinchGestureRecognizer) {
        guard isVR360Mode else { return }
        vrFOV = max(35, min(115, vrFOV / Float(gesture.scale)))
        gesture.scale = 1
        _ = mediaPlayer.updateViewpoint(vrYaw, pitch: vrPitch, roll: 0, fov: vrFOV, absolute: true)
    }
    func resetZoomIfNeeded(token: Int) {
        guard token != resetZoomToken else { return }
        resetZoomToken = token
        scrollView.setZoomScale(1, animated: false)
        scrollView.contentOffset = .zero
        setNeedsLayout()
    }

    /// Keep VLC's drawable at the highest useful pixel density while zooming.
    /// The cap is the source-video density, so this never invents or compresses pixels.
    private func updateVideoRenderScale() {
        guard videoSize.width > 0, videoSize.height > 0,
              videoView.bounds.width > 0, videoView.bounds.height > 0 else { return }

        let sourceDensity = min(
            videoSize.width / videoView.bounds.width,
            videoSize.height / videoView.bounds.height
        )
        let screenDensity = UIScreen.main.nativeScale
        let desiredDensity = max(screenDensity, min(sourceDensity, screenDensity * scrollView.zoomScale))
        if abs(videoView.contentScaleFactor - desiredDensity) > 0.05 {
            videoView.contentScaleFactor = desiredDensity
            videoView.layer.contentsScale = desiredDensity
            // Keep the drawable attached during 8K playback.
        }
    }
    private func updateScrollableArea() {
        let scale = scrollView.zoomScale
        scrollView.contentSize = CGSize(width: videoView.bounds.width * scale, height: videoView.bounds.height * scale)
        let insetX = max(0, (scrollView.bounds.width - scrollView.contentSize.width) / 2)
        let insetY = max(0, (scrollView.bounds.height - scrollView.contentSize.height) / 2)
        scrollView.contentInset = UIEdgeInsets(top: insetY, left: insetX, bottom: insetY, right: insetX)
    }

    private func clampOffset() {
        let inset = scrollView.adjustedContentInset
        let minX = -inset.left
        let minY = -inset.top
        let maxX = max(minX, scrollView.contentSize.width - scrollView.bounds.width + inset.right)
        let maxY = max(minY, scrollView.contentSize.height - scrollView.bounds.height + inset.bottom)
        let fixed = CGPoint(x: scrollView.contentSize.width <= scrollView.bounds.width ? minX : min(maxX, max(minX, scrollView.contentOffset.x)), y: scrollView.contentSize.height <= scrollView.bounds.height ? minY : min(maxY, max(minY, scrollView.contentOffset.y)))
        if abs(fixed.x - scrollView.contentOffset.x) > 0.5 || abs(fixed.y - scrollView.contentOffset.y) > 0.5 { scrollView.contentOffset = fixed }
    }

    @objc private func togglePlayback() {
        onSingleTap?()
    }

    @objc private func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
        if scrollView.zoomScale > 1.05 {
            scrollView.setZoomScale(1, animated: true)
            return
        }
        let point = gesture.location(in: videoView)
        let size = CGSize(width: scrollView.bounds.width / 2, height: scrollView.bounds.height / 2)
        scrollView.zoom(to: CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2, width: size.width, height: size.height), animated: true)
    }

    private func togglePlaybackState() {
        if mediaPlayer.isPlaying {
            mediaPlayer.pause()
        } else {
            mediaPlayer.play()
        }
    }

    func togglePlaybackFromControls() { togglePlaybackState() }

    func seek(to fraction: Double) {
        mediaPlayer.position = Float(min(1, max(0, fraction)))
    }

    func setRate(_ rate: Float) { mediaPlayer.rate = rate }

    func skip(by seconds: Int) {
        if seconds >= 0 {
            mediaPlayer.jumpForward(Int32(seconds))
        } else {
            mediaPlayer.jumpBackward(Int32(-seconds))
        }
    }
}

// MARK: - Timeline

private final class SeekBarContainerView: UIView {
    static let preferredHeight: CGFloat = 34
}


private struct ExternalSubtitleCue: Identifiable {
    let id = UUID()
    let start: Double
    let end: Double
    let text: String
}

private enum ExternalSubtitleParser {
    static func parse(_ source: String) -> [ExternalSubtitleCue] {
        let normalized = source
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        return normalized.components(separatedBy: "\n\n").compactMap { block in
            let lines = block.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            guard let timingIndex = lines.firstIndex(where: { $0.contains("-->") }) else { return nil }
            let times = lines[timingIndex].components(separatedBy: "-->")
            guard times.count == 2,
                  let start = time(times[0]),
                  let end = time(times[1]) else { return nil }
            let text = lines.dropFirst(timingIndex + 1)
                .joined(separator: "\n")
                .replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return ExternalSubtitleCue(start: start, end: end, text: text)
        }
        .sorted { $0.start < $1.start }
    }

    private static func time(_ raw: String) -> Double? {
        let clean = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .whitespaces).first ?? raw
        let parts = clean.replacingOccurrences(of: ",", with: ".").split(separator: ":")
        guard parts.count >= 2 else { return nil }
        let seconds = Double(parts.last ?? "") ?? 0
        let minutes = Double(parts[parts.count - 2]) ?? 0
        let hours = parts.count > 2 ? (Double(parts[parts.count - 3]) ?? 0) : 0
        return hours * 3600 + minutes * 60 + seconds
    }
}

private struct CircularPlaybackButton: View {
    let progress: Double
    let isPlaying: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(.ultraThinMaterial)
                    .overlay(Circle().fill(Color.black.opacity(0.12)))
                    .overlay(Circle().stroke(Color.white.opacity(0.18), lineWidth: 1))
                Circle()
                    .stroke(Color.white.opacity(0.16), lineWidth: 3)
                    .padding(5)
                Circle()
                    .trim(from: 0, to: max(0.018, min(1, progress)))
                    .stroke(
                        AppPalette.gradient,
                        style: StrokeStyle(lineWidth: 4, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
                    .padding(5)
                    .shadow(color: AppPalette.blue.opacity(0.55), radius: 7)
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 34, weight: .bold))
                    .foregroundColor(.white)
                    .offset(x: isPlaying ? 0 : 2)
            }
            .frame(width: 94, height: 94)
            .shadow(color: .black.opacity(0.42), radius: 20, y: 8)
        }
        .buttonStyle(PremiumPressButtonStyle())
        .accessibilityLabel(isPlaying ? "Pause" : "Play")
    }
}

private struct PlaybackChapter: Identifiable {
    let id = UUID()
    let title: String
    let fraction: Double
}

private struct PlayerQualityBadge: View {
    var tier: ResolutionTier? = nil
    var label: String? = nil

    var body: some View {
        Text(label ?? tier?.badgeText ?? "HD")
            .font(.system(size: 10, weight: .black, design: .rounded))
            .foregroundColor(Color.black.opacity(0.88))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                LinearGradient(colors: [Color(red: 1, green: 0.86, blue: 0.25), .orange], startPoint: .topLeading, endPoint: .bottomTrailing),
                in: Capsule()
            )
            .overlay(Capsule().stroke(Color.white.opacity(0.3), lineWidth: 0.5))
            .shadow(color: .orange.opacity(0.25), radius: 6)
    }
}

private enum PlayerSubtitleColor: String, CaseIterable, Identifiable {
    case white = "White"
    case yellow = "Yellow"
    case cyan = "Cyan"
    var id: String { rawValue }
    var color: Color {
        switch self { case .white: return .white; case .yellow: return .yellow; case .cyan: return .cyan }
    }
}

private struct PlayerAdvancedSettingsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var selectedAudioTrack: String
    @Binding var selectedSubtitleTrack: String
    @Binding var selectedQuality: String
    @Binding var subtitleSize: Double
    @Binding var subtitleColor: PlayerSubtitleColor
    let currentQuality: String
    let audioTracks: [PlayerAudioTrackOption]
    let selectedAudioTrackID: String?
    let subtitleFileName: String?
    let onAudioTrackChange: (String) -> Void
    let onChooseSubtitleFile: () -> Void
    let onDisableSubtitles: () -> Void
    let onRateChange: (Float) -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    settingsCard(title: "Audio Tracks", icon: "waveform") {
                        if audioTracks.count > 1 {
                            VStack(spacing: 8) {
                                ForEach(audioTracks) { track in
                                    Button {
                                        selectedAudioTrack = track.id
                                        onAudioTrackChange(track.id)
                                    } label: {
                                        HStack {
                                            Text(track.title).lineLimit(1)
                                            Spacer()
                                            if (selectedAudioTrack.isEmpty ? selectedAudioTrackID : selectedAudioTrack) == track.id {
                                                Image(systemName: "checkmark.circle.fill").foregroundColor(AppPalette.accent)
                                            }
                                        }
                                        .foregroundColor(.primary)
                                        .padding(.vertical, 6)
                                    }
                                }
                            }
                        } else {
                            Text("This video has one audio track")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        }
                    }
                    settingsCard(title: "Subtitles", icon: "captions.bubble.fill") {
                        Button(action: onChooseSubtitleFile) {
                            HStack {
                                Image(systemName: "folder.fill")
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Choose Subtitle File")
                                    if let subtitleFileName {
                                        Text(subtitleFileName).font(.caption).foregroundColor(.secondary).lineLimit(1)
                                    }
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                            }
                            .foregroundColor(.primary)
                        }
                        if subtitleFileName != nil {
                            Button("Turn Subtitles Off", role: .destructive, action: onDisableSubtitles)
                        }
                        HStack {
                            Text("Size")
                            Slider(value: $subtitleSize, in: 0.75...1.75, step: 0.25)
                            Text("\(Int(subtitleSize * 100))%")
                                .foregroundColor(.secondary)
                                .frame(width: 48)
                        }
                        HStack {
                            Text("Color")
                            Spacer()
                            ForEach(PlayerSubtitleColor.allCases) { option in
                                Button { subtitleColor = option } label: {
                                    Circle().fill(option.color).frame(width: 25, height: 25)
                                        .overlay(Circle().stroke(AppPalette.accent, lineWidth: subtitleColor == option ? 3 : 0))
                                }
                            }
                        }
                    }
                    settingsCard(title: "Video Quality", icon: "4k.tv.fill") {
                        Picker("Quality", selection: $selectedQuality) {
                            Text("Auto").tag("Auto")
                            Text(currentQuality).tag(currentQuality)
                            Text("1080p").tag("1080p")
                            Text("720p").tag("720p")
                        }.pickerStyle(.segmented)
                    }
                    settingsCard(title: "Playback Speed", icon: "speedometer") {
                        HStack(spacing: 8) {
                            ForEach([0.5, 1.0, 1.5, 2.0], id: \.self) { speed in
                                Button("\(speed, specifier: "%g")×") { onRateChange(Float(speed)) }
                                    .buttonStyle(.bordered)
                                    .tint(AppPalette.accent)
                            }
                        }
                    }
                }
                .padding(18)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("Playback Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private func settingsCard<Content: View>(title: String, icon: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: icon)
                .font(.headline)
                .foregroundColor(AppPalette.accent)
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

private struct PlayerEndScreen: View {
    let title: String
    let countdown: Int
    let onReplay: () -> Void
    let onBack: () -> Void

    var body: some View {
        ZStack {
            LinearGradient(colors: [.black.opacity(0.96), .black.opacity(0.72)], startPoint: .bottom, endPoint: .top)
                .ignoresSafeArea()
            VStack(spacing: 18) {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(AppPalette.diagonalGradient)
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .frame(maxWidth: 360)
                    .overlay(
                        VStack(spacing: 8) {
                            Image(systemName: "play.tv.fill").font(.system(size: 38))
                            Text(title).font(.headline).lineLimit(2)
                        }.foregroundColor(.white)
                    )
                Text("Up Next")
                    .font(.title2.bold())
                    .foregroundColor(.white)
                Button(action: onReplay) {
                    Label("Play Next Episode  \(countdown)", systemImage: "play.fill")
                        .font(.headline)
                        .foregroundColor(.white)
                        .frame(maxWidth: 340)
                        .frame(height: 52)
                        .background(AppPalette.gradient, in: Capsule())
                }
                Button("Back to Series") { onBack() }
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(.white.opacity(0.86))
            }
            .padding(28)
        }
    }
}

private struct InstantSeekBar: View {
    let progress: Double
    let bufferProgress: Double
    let currentLabel: String
    let durationLabel: String
    var chapters: [PlaybackChapter] = []
    let onSeek: (Double) -> Void
    let onScrubbing: (Double, Bool) -> Void
    @State private var draggedValue: Double?

    private func nearestChapter(to progress: Double) -> PlaybackChapter? {
        chapters
            .filter { abs($0.fraction - progress) <= 0.035 }
            .min { abs($0.fraction - progress) < abs($1.fraction - progress) }
    }

    var body: some View {
        HStack(spacing: 10) {
            Text(currentLabel).font(.caption2.monospacedDigit()).foregroundColor(.white)
            GeometryReader { geometry in
                let value = min(1, max(0, draggedValue ?? progress))
                let bufferedValue = min(1, max(value, bufferProgress))
                let thumbSize: CGFloat = 18
                let usableWidth = max(1, geometry.size.width - thumbSize)
                let crystalSky = LinearGradient(
                    colors: [
                        Color.white.opacity(0.96),
                        Color(red: 0.76, green: 0.91, blue: 1.0),
                        Color(red: 0.34, green: 0.73, blue: 0.97)
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )

                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(.ultraThinMaterial)
                        .frame(height: 12)
                        .overlay(
                            Capsule()
                                .stroke(Color.white.opacity(0.30), lineWidth: 1)
                        )
                    Capsule()
                        .fill(Color.white.opacity(0.34))
                        .frame(
                            width: thumbSize / 2 + usableWidth * bufferedValue,
                            height: 7
                        )
                    Capsule()
                        .fill(crystalSky)
                        .frame(width: thumbSize / 2 + usableWidth * value, height: 7)
                        .shadow(color: Color(red: 0.45, green: 0.80, blue: 1.0).opacity(0.28), radius: 4)
                    ForEach(chapters) { chapter in
                        Capsule()
                            .fill(Color.white.opacity(0.92))
                            .frame(width: 2, height: 14)
                            .offset(x: thumbSize / 2 + usableWidth * chapter.fraction)
                    }
                    if draggedValue != nil, let chapter = nearestChapter(to: value) {
                        Text(chapter.title)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(.ultraThinMaterial, in: Capsule())
                            .offset(x: max(0, min(usableWidth - 68, usableWidth * chapter.fraction - 34)), y: -25)
                    }
                    Circle()
                        .fill(.ultraThinMaterial)
                        .frame(width: thumbSize, height: thumbSize)
                        .overlay(Circle().fill(crystalSky).padding(3))
                        .overlay(Circle().stroke(Color.white.opacity(0.72), lineWidth: 1))
                        .shadow(color: Color(red: 0.45, green: 0.80, blue: 1.0).opacity(0.38), radius: 5)
                        .offset(x: usableWidth * value)
                }
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { gesture in
                            let next = min(1, max(0, gesture.location.x / max(1, geometry.size.width)))
                            draggedValue = next
                            onScrubbing(next, true)
                        }
                        .onEnded { gesture in
                            let selected = min(1, max(0, gesture.location.x / max(1, geometry.size.width)))
                            draggedValue = nil
                            onScrubbing(selected, false)
                            onSeek(selected)
                        }
                )
            }
            .frame(height: 28)
            Text(durationLabel).font(.caption2.monospacedDigit()).foregroundColor(.white)
        }
    }

}

// MARK: - Zoomable video

private struct ZoomableVideoView: UIViewRepresentable, Equatable {
    let player: AVPlayer
    var resetToken: Int = 0
    var fillModeToken: Int = 0
    var isFillMode = false
    var videoSize: CGSize = .zero
    var onSingleTap: (() -> Void)?
    var onInteractionChange: ((Bool) -> Void)?
    var onDoubleTap: (() -> Void)?

    // engine.progress/currentSeconds/bufferPercent tick ~4x/sec and force
    // VideoPlayerView.body to re-evaluate. Without this, SwiftUI would call
    // updateUIView on every one of those ticks — poking the UIKit surface on
    // the main thread at the exact moments it's also driving a live pinch/pan
    // gesture. Equatable + .equatable() at the call site lets SwiftUI skip
    // updateUIView entirely when none of these actually changed.
    // onSingleTap is a closure (not Equatable) and is intentionally excluded:
    // it closes over @State bindings whose storage is shared across view
    // generations, so an "older" copy still reads/writes current state correctly.
    static func == (lhs: ZoomableVideoView, rhs: ZoomableVideoView) -> Bool {
        lhs.player === rhs.player &&
        lhs.resetToken == rhs.resetToken &&
        lhs.fillModeToken == rhs.fillModeToken &&
        lhs.isFillMode == rhs.isFillMode &&
        lhs.videoSize == rhs.videoSize
    }

    func makeUIView(context: Context) -> ZoomablePlayerSurface {
        let view = ZoomablePlayerSurface(player: player)
        view.onSingleTap = onSingleTap
        view.onInteractionChange = onInteractionChange
        view.onDoubleTap = onDoubleTap
        view.updateVideoSize(videoSize)
        view.setFillMode(isFillMode)
        return view
    }

    func updateUIView(_ view: ZoomablePlayerSurface, context: Context) {
        view.updatePlayer(player)
        view.onSingleTap = onSingleTap
        view.onInteractionChange = onInteractionChange
        view.onDoubleTap = onDoubleTap
        view.updateVideoSize(videoSize)
        if context.coordinator.resetToken != resetToken {
            context.coordinator.resetToken = resetToken
            view.resetZoom()
        }
        if context.coordinator.fillToken != fillModeToken {
            context.coordinator.fillToken = fillModeToken
            view.setFillMode(isFillMode)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Coordinator { var resetToken = 0; var fillToken = 0 }

    // Without this, switching to VR mode (which swaps this view out for
    // VR360PlayerView) could leave ZoomablePlayerSurface's AVPlayerLayer still
    // attached to the shared AVPlayer for a brief window before ARC tears it
    // down. Two consumers pulling video output from the same AVPlayer at once
    // is exactly what produced "VR mode looks identical to the flat player" —
    // detaching immediately guarantees only the sphere is ever consuming frames.
    static func dismantleUIView(_ view: ZoomablePlayerSurface, coordinator: Coordinator) {
        view.detachPlayer()
    }
}

private final class ZoomablePlayerSurface: UIView, UIScrollViewDelegate {
    var onSingleTap: (() -> Void)?
    /// Reports true for the entire span of a pinch or pan (through
    /// deceleration), false once fully settled. Wired to
    /// VideoPlaybackEngine.setInteracting so it can silence its periodic
    /// UI publishes while a gesture is live — see the call site for why.
    var onInteractionChange: ((Bool) -> Void)?
    /// Fired on double-tap. Now toggles fill-screen mode (see
    /// handleDoubleTap) instead of driving a local pinch-style zoom.
    var onDoubleTap: (() -> Void)?
    private let scrollView = UIScrollView()
    private let contentView = UIView()
    private let playerLayer = AVPlayerLayer()
    private var doubleTap: UITapGestureRecognizer!
    private var singleTap: UITapGestureRecognizer!
    private var videoSize: CGSize = .zero
    private var isFillMode = false
    private var lastRenderScaleZoomScale: CGFloat = -1
    private var isZooming = false { didSet { reportInteractionIfNeeded() } }
    private var isPanning = false { didSet { reportInteractionIfNeeded() } }
    private var reportedInteracting = false

    private func reportInteractionIfNeeded() {
        let active = isZooming || isPanning
        guard active != reportedInteracting else { return }
        reportedInteracting = active
        onInteractionChange?(active)
    }

    init(player: AVPlayer) {
        super.init(frame: .zero)
        backgroundColor = .black
        clipsToBounds = true

        scrollView.delegate = self
        scrollView.minimumZoomScale = 1
        scrollView.maximumZoomScale = 10
        scrollView.bounces = false
        scrollView.bouncesZoom = false
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.contentInsetAdjustmentBehavior = .never
        addSubview(scrollView)

        contentView.backgroundColor = .black
        contentView.clipsToBounds = true
        scrollView.addSubview(contentView)

        playerLayer.player = player
        playerLayer.videoGravity = .resizeAspect
        contentView.layer.addSublayer(playerLayer)

        doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap))
        doubleTap.numberOfTapsRequired = 2
        singleTap = UITapGestureRecognizer(target: self, action: #selector(handleSingleTap))
        singleTap.require(toFail: doubleTap)
        scrollView.addGestureRecognizer(doubleTap)
        scrollView.addGestureRecognizer(singleTap)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        scrollView.frame = bounds
        // contentView always spans the full surface bounds. Letterboxing for
        // a video whose aspect ratio doesn't match the screen's is handled
        // entirely by AVPlayerLayer's own aspect-fit rendering inside this
        // fixed-size layer — contentView itself is never resized down to the
        // video's own fitted dimensions. That resizing is what used to leave
        // contentInset permanently nonzero (computed once at zoomScale 1 and
        // only ever resynced at gesture-end); as zoomScale changed mid-
        // gesture that stale inset no longer matched, which is what dragged
        // both pinch-zoom and double-tap-zoom toward one edge instead of
        // staying centered. With contentView always == bounds, contentInset
        // is always exactly zero — there's nothing left to go stale.
        //
        // Only redo the heavier render-scale/clamp work when the surface's
        // own bounds actually change. contentInset changes made during a
        // live pinch/pan also trigger layoutSubviews, and running this work
        // on every one of those ticks caused the shake-while-zooming and
        // lag-while-panning.
        guard contentView.bounds.size != bounds.size else {
            playerLayer.frame = contentView.bounds
            return
        }
        let zoom = scrollView.zoomScale
        scrollView.zoomScale = 1
        contentView.frame = CGRect(origin: .zero, size: bounds.size)
        scrollView.contentSize = bounds.size
        playerLayer.frame = contentView.bounds
        scrollView.zoomScale = zoom
        updateScrollableArea()
        clampOffset()
        updateVideoRenderScale()
        lastRenderScaleZoomScale = scrollView.zoomScale
        // Fill mode's baseline ("cover") zoom depends on the container's own
        // aspect ratio (see applyZoomBounds), so a rotation can leave the
        // old baseline no longer covering the screen. Re-pin it here; this
        // only runs when bounds actually changed (we're inside that guard)
        // and only touches anything when fill mode is active, so it doesn't
        // affect the fit-mode/pinch-zoom path at all.
        if isFillMode {
            let cover = coverZoomScale()
            scrollView.minimumZoomScale = cover
            if scrollView.zoomScale < cover {
                scrollView.setZoomScale(cover, animated: false)
                updateScrollableArea()
                clampOffset()
            }
        }
    }

    func updatePlayer(_ player: AVPlayer) {
        if playerLayer.player !== player { playerLayer.player = player }
    }

    /// Called when this surface is swapped out (e.g. for VR360PlayerView).
    /// Detaches from the AVPlayer immediately rather than waiting on ARC/dealloc
    /// timing, so the shared player never has two active visual consumers.
    func detachPlayer() {
        playerLayer.player = nil
    }

    func updateVideoSize(_ size: CGSize) {
        guard size.width > 0, size.height > 0, size != videoSize else { return }
        videoSize = size
        setNeedsLayout()
    }

    func setFillMode(_ fill: Bool) {
        // Fill mode used to just switch playerLayer.videoGravity to
        // .resizeAspectFill — AVPlayerLayer then crops to a fixed, centered
        // rect with no way to pan it, which is why "fill" couldn't be
        // panned left/right. Instead, gravity always stays .resizeAspect,
        // and "fill" is implemented as zooming to the "cover" scale (see
        // coverZoomScale()) — that's the smallest zoom at which the video's
        // own fitted rect, scaled up, has no letterbox margin left on
        // either axis. Because the fitted rect already matches the
        // container exactly on one axis, cover-scale zoom only needs to
        // grow the other axis to close its margin — so that axis now
        // overflows the screen, and the existing clamp/pan machinery
        // (clampOffset, already scoped to the video's own scaled rect)
        // lets the user slide across that overflow same as any other zoom.
        guard isFillMode != fill else { return }
        isFillMode = fill
        applyZoomBounds(animated: true)
    }

    func resetZoom() {
        applyZoomBounds(animated: false)
    }

    /// Recomputes the zoom range for the current mode (fit: baseline 1,
    /// fill: baseline coverZoomScale()) and snaps to that baseline,
    /// centered. Used by both setFillMode and resetZoom so both land on the
    /// same well-defined resting position.
    private func applyZoomBounds(animated: Bool) {
        let baseline = isFillMode ? coverZoomScale() : 1
        scrollView.minimumZoomScale = baseline
        scrollView.maximumZoomScale = max(10, baseline)
        scrollView.setZoomScale(baseline, animated: animated)
        updateScrollableArea()
        scrollView.contentOffset = centeredOffset()
        clampOffset()
        updateVideoRenderScaleIfNeeded()
    }

    /// The zoom scale at which the video's fitted (letterboxed) rect,
    /// scaled up, exactly covers the container on both axes — i.e. the
    /// scale fill mode zooms to. 1 if video size isn't known yet.
    private func coverZoomScale() -> CGFloat {
        let displayed = displayedVideoSize()
        let container = contentView.bounds.size
        guard displayed.width > 0, displayed.height > 0,
              container.width > 0, container.height > 0 else { return 1 }
        return max(container.width / displayed.width, container.height / displayed.height)
    }

    /// The offset that centers the video's scaled rect in the viewport —
    /// on an axis where the rect is smaller than the viewport this is the
    /// same centering clampOffset already falls back to; on an axis where
    /// it overflows (fill mode's cropped axis) this centers the crop
    /// instead of resting at whichever edge contentOffset happened to be.
    private func centeredOffset() -> CGPoint {
        let zoom = scrollView.zoomScale
        let displayed = displayedVideoSize()
        let boundsSize = scrollView.bounds.size
        let marginX = max(0, (contentView.bounds.width - displayed.width) / 2) * zoom
        let marginY = max(0, (contentView.bounds.height - displayed.height) / 2) * zoom
        let scaledW = displayed.width * zoom
        let scaledH = displayed.height * zoom
        return CGPoint(x: marginX + (scaledW - boundsSize.width) / 2,
                       y: marginY + (scaledH - boundsSize.height) / 2)
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { contentView }

    // NOTE: contentOffset/contentInset must never be forced while the user's
    // pinch or pan gesture is actively driving the scroll view — doing so
    // fights UIKit's own live gesture tracking. `clampOffset()` and the
    // render-scale bump are deferred to gesture-end for that reason.
    //
    // scrollViewDidZoom still fires on every frame of a live pinch, though,
    // and reassigning scrollView.contentInset/contentSize there (as this
    // used to do via updateScrollableArea()) forces UIScrollView to redo its
    // internal scroll-metric bookkeeping every single tick — that's what was
    // actually producing the lag/shake while pinching. Repositioning the
    // content view's own frame keeps it centered just as well and is
    // effectively free per frame — the same technique Apple's PhotoScroller
    // sample uses.

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        centerContentView()
    }

    private func centerContentView() {
        let boundsSize = scrollView.bounds.size
        var frame = contentView.frame
        frame.origin.x = frame.width < boundsSize.width ? (boundsSize.width - frame.width) / 2 : 0
        frame.origin.y = frame.height < boundsSize.height ? (boundsSize.height - frame.height) / 2 : 0
        contentView.frame = frame
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        // Hard-stop panning exactly at the video's edge instead of letting the
        // drag overshoot into the letterbox and snap back on release. Only
        // does this for a live pan (not zoom) — clamping every frame of a
        // pinch is what previously caused the shake described in the comment
        // on updateScrollableArea()/centerContentView(), so pinch stays on
        // its existing deferred-to-gesture-end path, untouched.
        guard isPanning, !isZooming else { return }
        clampOffset()
    }

    func scrollViewWillBeginZooming(_ scrollView: UIScrollView, with view: UIView?) {
        isZooming = true
    }

    func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
        updateScrollableArea()
        clampOffset()
        updateVideoRenderScaleIfNeeded()
        isZooming = false
    }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        isPanning = true
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate {
            clampOffset()
            updateVideoRenderScaleIfNeeded()
            isPanning = false
        }
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        clampOffset()
        updateVideoRenderScaleIfNeeded()
        isPanning = false
    }

    /// The video image's own fitted (letterboxed) size within contentView,
    /// at zoomScale 1 — the same rect AVPlayerLayer's .resizeAspect gravity
    /// draws. Fill mode no longer switches gravity (see setFillMode); it
    /// zooms this same fitted rect up to cover(), so this stays the single
    /// source of truth for the video's own bounds at any zoom level.
    private func displayedVideoSize() -> CGSize {
        let container = contentView.bounds.size
        guard videoSize.width > 0, videoSize.height > 0,
              container.width > 0, container.height > 0 else { return container }
        let scale = min(container.width / videoSize.width, container.height / videoSize.height)
        return CGSize(width: videoSize.width * scale, height: videoSize.height * scale)
    }

    /// Only recompute the render scale when zoomScale has moved enough to matter —
    /// avoids doing this work on every throttled scroll/zoom tick while panning.
    private func updateVideoRenderScaleIfNeeded() {
        let currentZoom = scrollView.zoomScale
        guard abs(currentZoom - lastRenderScaleZoomScale) > 0.05 else { return }
        lastRenderScaleZoomScale = currentZoom
        // Push this to the next run-loop turn so it happens *after* UIKit has
        // finished settling the scroll view from the gesture that just ended,
        // instead of competing with it on the same frame — that overlap is
        // what read as a hitch right at the moment of lifting a finger.
        DispatchQueue.main.async { [weak self] in
            self?.updateVideoRenderScale()
        }
    }

    /// UIScrollView scales the view for pinch zoom. Raise only the video layer's
    /// render density as it zooms, capped at the source frame's real pixels.
    private func updateVideoRenderScale() {
        guard videoSize.width > 0, videoSize.height > 0 else { return }
        let displayed = displayedVideoSize()
        guard displayed.width > 0, displayed.height > 0 else { return }

        let sourceDensity = min(
            videoSize.width / displayed.width,
            videoSize.height / displayed.height
        )
        let targetDensity = min(sourceDensity, UIScreen.main.nativeScale * scrollView.zoomScale)
        let density = max(1, targetDensity)
        guard abs(playerLayer.contentsScale - density) > 0.05 else { return }
        // AVPlayerLayer keeps rendering video frames on its own display link;
        // setNeedsDisplay() has no effect on it and was dead weight. What
        // does matter is that changing contentsScale on a layer that's
        // actively showing content triggers an implicit Core Animation fade
        // by default — disabling actions here removes that extra visible
        // flicker/stutter.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerLayer.contentsScale = density
        CATransaction.commit()
    }
    private func updateScrollableArea() {
        let scale = scrollView.zoomScale
        scrollView.contentSize = CGSize(
            width: contentView.bounds.width * scale,
            height: contentView.bounds.height * scale
        )
        let insetX = max(0, (scrollView.bounds.width - scrollView.contentSize.width) / 2)
        let insetY = max(0, (scrollView.bounds.height - scrollView.contentSize.height) / 2)
        scrollView.contentInset = UIEdgeInsets(top: insetY, left: insetX, bottom: insetY, right: insetX)
    }

    /// Clamps panning to the actual video image, not the full contentView.
    /// contentView always spans the full surface bounds while the video
    /// itself is fitted and centered inside it (displayedVideoSize()),
    /// leaving black margins on whichever axis doesn't match the screen's
    /// aspect ratio. Clamping against contentSize/bounds directly (the old
    /// behavior) only bounded panning to those full, letterbox-inclusive
    /// dimensions — so once zoomed in, a drag could keep going past the
    /// video's real edge into empty black space. This instead computes the
    /// video's own scaled rect within contentView and keeps the viewport's
    /// offset inside that rect — panning stops exactly at the video frame.
    /// This is also what lets fill mode be pannable at all: fill zooms in
    /// to coverZoomScale() (see setFillMode), which makes displayedVideoSize
    /// scaled up overflow the container on one axis — the same clamp then
    /// naturally allows sliding across that overflow instead of locking it.
    private func clampOffset() {
        let zoom = scrollView.zoomScale
        let displayed = displayedVideoSize()
        let boundsSize = scrollView.bounds.size
        let marginX = max(0, (contentView.bounds.width - displayed.width) / 2) * zoom
        let marginY = max(0, (contentView.bounds.height - displayed.height) / 2) * zoom
        let scaledVideoWidth = displayed.width * zoom
        let scaledVideoHeight = displayed.height * zoom

        let x: CGFloat
        if scaledVideoWidth <= boundsSize.width {
            x = marginX - (boundsSize.width - scaledVideoWidth) / 2
        } else {
            let minX = marginX
            let maxX = marginX + scaledVideoWidth - boundsSize.width
            x = min(maxX, max(minX, scrollView.contentOffset.x))
        }

        let y: CGFloat
        if scaledVideoHeight <= boundsSize.height {
            y = marginY - (boundsSize.height - scaledVideoHeight) / 2
        } else {
            let minY = marginY
            let maxY = marginY + scaledVideoHeight - boundsSize.height
            y = min(maxY, max(minY, scrollView.contentOffset.y))
        }

        let fixed = CGPoint(x: x, y: y)
        if abs(fixed.x - scrollView.contentOffset.x) > 0.5 || abs(fixed.y - scrollView.contentOffset.y) > 0.5 {
            scrollView.contentOffset = fixed
        }
    }

    @objc private func handleSingleTap() { onSingleTap?() }

    @objc private func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
        // Double-tap now toggles fill-screen mode instead of doing a local
        // 2x pinch-style zoom to the tap point. The toggle is owned by
        // SwiftUI (isFillMode/fillModeToken) — onDoubleTap routes there, and
        // the resulting setFillMode(_:) call (via updateUIView) already
        // resets any active pinch zoom on its own, so no local zoom handling
        // is needed here.
        onDoubleTap?()
    }

}


struct RoutedVideoPlayerView: View {
    let url: URL
    let title: String
    var resumeAt: Double = 0
    var linkId: UUID? = nil
    var httpHeaders: [String: String]? = nil
    var onProgress: ((Double, Double, Int, Int) -> Void)? = nil

    private let forceVR: Bool

    init(url: URL, title: String, resumeAt: Double = 0, linkId: UUID? = nil, httpHeaders: [String: String]? = nil, forceVR: Bool = false, onProgress: ((Double, Double, Int, Int) -> Void)? = nil) {
        self.url = url; self.title = title; self.resumeAt = resumeAt; self.linkId = linkId
        self.httpHeaders = httpHeaders; self.onProgress = onProgress
        self.forceVR = forceVR
    }

    var body: some View {
        if forceVR || Self.isVRVideo(url: url, title: title) {
            DedicatedVRPlayerView(url: url, title: title, resumeAt: resumeAt, httpHeaders: httpHeaders, onProgress: onProgress)
        } else {
            VideoPlayerView(url: url, title: title, resumeAt: resumeAt, linkId: linkId, httpHeaders: httpHeaders, onProgress: onProgress)
        }
    }

    private static func isVRVideo(url: URL, title: String) -> Bool {
        let raw = (title + " " + url.lastPathComponent).lowercased()
        let normalized = raw.replacingOccurrences(of: ".", with: " ").replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: "-", with: " ")
        let tokens = Set(normalized.split { !$0.isLetter && !$0.isNumber }.map(String.init))
        let vrTokens: Set<String> = [
            "vr", "360", "360vr", "vr360", "equirectangular", "equirect", "spherical",
            "sbs", "ou", "tb", "180vr", "vr180", "3dh", "3dv", "oculus", "quest",
            "fisheye", "monoscopic", "stereoscopic", "psvr", "gearvr", "skybox",
            "insta360", "theta", "180", "8k180", "6k180", "5k180"
        ]
        if !tokens.isDisjoint(with: vrTokens) { return true }
        if raw.contains("side-by-side") || raw.contains("top-bottom") || raw.contains("projection=360")
            || raw.contains("360°") || raw.contains("360 degree") { return true }
        // Resolution tags ("5760x2880", "7680x3840", ...) show up in real
        // filenames far more often than the word "vr" or "360" ever does.
        // Instead of matching a short fixed list, catch any WxH-looking
        // token and flag it when its ratio lands on the ~2:1 equirectangular
        // band — this is what makes detection work on files whose names
        // were never hand-tagged as VR in the first place.
        if let regex = try? NSRegularExpression(pattern: "(\\d{3,5})x(\\d{3,5})") {
            let fullRange = NSRange(raw.startIndex..., in: raw)
            for match in regex.matches(in: raw, range: fullRange) {
                guard let wRange = Range(match.range(at: 1), in: raw),
                      let hRange = Range(match.range(at: 2), in: raw),
                      let w = Double(raw[wRange]), let h = Double(raw[hRange]), h > 0 else { continue }
                let ratio = w / h
                if ratio > 1.85 && ratio < 2.15 { return true }
            }
        }
        return false
    }
}

private struct DedicatedVRPlayerView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var controller = DedicatedVRController()
    @State private var showControls = true
    @State private var hideTask: Task<Void, Never>?

    let url: URL
    let title: String
    let resumeAt: Double
    let httpHeaders: [String: String]?
    let onProgress: ((Double, Double, Int, Int) -> Void)?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            DedicatedVRSurface(controller: controller, url: url, resumeAt: resumeAt, httpHeaders: httpHeaders) {
                withAnimation(.easeInOut(duration: 0.18)) { showControls.toggle() }
                scheduleHide()
            }
            .ignoresSafeArea()

            if controller.isBuffering {
                ProgressView().tint(.white).padding(18).background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
                    .allowsHitTesting(false)
            }

            if showControls {
                VStack {
                    HStack(spacing: 12) {
                        Button { dismiss() } label: {
                            Image(systemName: "chevron.left").font(.system(size: 17, weight: .semibold))
                                .frame(width: 42, height: 42).background(.ultraThinMaterial, in: Circle())
                        }
                        VStack(alignment: .leading, spacing: 3) {
                            Text(VideoTitleFormatter.title(from: title)).font(.headline).lineLimit(1)
                            Text("VR 360 · \(controller.resolutionLabel)").font(.caption).foregroundStyle(AppPalette.accent)
                        }
                        Spacer()
                        Image(systemName: "view.3d").font(.system(size: 17, weight: .semibold)).foregroundStyle(AppPalette.accent)
                            .frame(width: 42, height: 42).background(.ultraThinMaterial, in: Circle())
                    }
                    .foregroundStyle(.white).padding(.horizontal, 16).padding(.top, 10)

                    Spacer()

                    VStack(spacing: 12) {
                        HStack(spacing: 36) {
                            Button { controller.skip(-15) } label: { Image(systemName: "gobackward.15").font(.title2) }
                            Button { controller.toggle() } label: {
                                Image(systemName: controller.isPlaying ? "pause.fill" : "play.fill")
                                    .font(.title2).foregroundStyle(.black).frame(width: 58, height: 58).background(.white, in: Circle())
                            }
                            Button { controller.skip(15) } label: { Image(systemName: "goforward.15").font(.title2) }
                        }
                        Slider(value: Binding(get: { controller.progress }, set: { controller.seek($0) }), in: 0...1).tint(AppPalette.accent)
                        HStack {
                            Text(controller.currentLabel)
                            Spacer()
                            Text(controller.durationLabel)
                        }.font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    .foregroundStyle(.white).padding(.horizontal, 24).padding(.bottom, 28)
                }
                .transition(.opacity)
            }
        }
        .statusBar(hidden: true)
        .preferredColorScheme(.dark)
        .onAppear { scheduleHide() }
        .onDisappear {
            hideTask?.cancel()
            onProgress?(controller.currentSeconds, controller.durationSeconds, controller.videoWidth, controller.videoHeight)
            controller.stop()
        }
    }

    private func scheduleHide() {
        hideTask?.cancel()
        guard showControls else { return }
        hideTask = Task {
            try? await Task.sleep(nanoseconds: 3_500_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run { withAnimation(.easeOut(duration: 0.2)) { showControls = false } }
        }
    }
}

@MainActor
private final class DedicatedVRController: ObservableObject {
    @Published var isPlaying = false
    @Published var isBuffering = true
    @Published var progress = 0.0
    @Published var currentSeconds = 0.0
    @Published var durationSeconds = 0.0
    @Published var videoWidth = 0
    @Published var videoHeight = 0
    weak var surface: DedicatedVRSurfaceView?
    private var pendingSeekSeconds: Double?

    var resolutionLabel: String { videoWidth > 0 ? "\(videoWidth)×\(videoHeight)" : "Loading" }
    var currentLabel: String { Self.time(currentSeconds) }
    var durationLabel: String { Self.time(durationSeconds) }
    func toggle() { surface?.toggle() }
    func skip(_ seconds: Double) {
        guard durationSeconds > 0 else { surface?.skip(seconds); return }
        let target = min(durationSeconds, max(0, (pendingSeekSeconds ?? currentSeconds) + seconds))
        pendingSeekSeconds = target
        currentSeconds = target
        progress = target / durationSeconds
        surface?.seek(toSeconds: target)
    }
    func seek(_ value: Double) {
        guard durationSeconds > 0 else { surface?.seek(value); return }
        let target = min(1, max(0, value)) * durationSeconds
        pendingSeekSeconds = target
        currentSeconds = target
        progress = target / durationSeconds
        surface?.seek(toSeconds: target)
    }
    func stop() { surface?.stop() }

    func update(playing: Bool, buffering: Bool, position: Double, current: Double, duration: Double, size: CGSize) {
        isPlaying = playing; isBuffering = buffering; durationSeconds = duration
        if let pendingSeekSeconds {
            if abs(current - pendingSeekSeconds) <= 0.75 {
                self.pendingSeekSeconds = nil
                progress = min(1, max(0, position)); currentSeconds = current
            } else {
                currentSeconds = pendingSeekSeconds
                if duration > 0 { progress = min(1, max(0, pendingSeekSeconds / duration)) }
            }
        } else {
            progress = min(1, max(0, position)); currentSeconds = current
        }
        if size.width > 1 { videoWidth = Int(size.width); videoHeight = Int(size.height) }
    }

    private static func time(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "00:00" }
        let total = Int(seconds); return String(format: "%02d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
    }
}

private struct DedicatedVRSurface: UIViewRepresentable {
    let controller: DedicatedVRController
    let url: URL
    let resumeAt: Double
    let httpHeaders: [String: String]?
    let onTap: () -> Void

    func makeUIView(context: Context) -> DedicatedVRSurfaceView {
        let view = DedicatedVRSurfaceView()
        view.controller = controller; controller.surface = view; view.onTap = onTap
        view.play(url: url, resumeAt: resumeAt, headers: httpHeaders)
        return view
    }
    func updateUIView(_ view: DedicatedVRSurfaceView, context: Context) { view.onTap = onTap }
    static func dismantleUIView(_ view: DedicatedVRSurfaceView, coordinator: ()) { view.stop() }
}

private final class DedicatedVRSurfaceView: UIView {
    private let player = VLCMediaPlayer()
    private let videoView = UIView()
    private let motion = CMMotionManager()
    private var timer: Timer?
    private var yaw: Float = 0
    private var pitch: Float = 0
    private var fov: Float = 82
    private var panStart = CGPoint.zero
    private var currentURL: URL?
    weak var controller: DedicatedVRController?
    var onTap: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        videoView.backgroundColor = .black; videoView.isOpaque = true
        // VLCKit installs its rendering view inside this container. Disabling
        // hit-testing here guarantees the parent surface receives taps/pans.
        videoView.isUserInteractionEnabled = false
        isUserInteractionEnabled = true
        addSubview(videoView)
        let tap = UITapGestureRecognizer(target: self, action: #selector(tapped))
        let pan = UIPanGestureRecognizer(target: self, action: #selector(panned(_:)))
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(pinched(_:)))
        tap.cancelsTouchesInView = false
        pan.cancelsTouchesInView = false
        pinch.cancelsTouchesInView = false
        tap.require(toFail: pan)
        addGestureRecognizer(tap); addGestureRecognizer(pan); addGestureRecognizer(pinch)
        player.drawable = videoView
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layoutSubviews() { super.layoutSubviews(); videoView.frame = bounds; player.drawable = videoView }

    func play(url: URL, resumeAt: Double, headers: [String: String]?) {
        guard currentURL != url else { return }
        currentURL = url
        let media = VLCMedia(url: url)
        // Force spherical rendering even when downloaded files have lost their
        // GSpherical metadata. VLCKit 3.x and LibVLC 4 use different option names.
        media.addOption(":projection=2")
        media.addOption(":projection-mode=1")
        media.addOption(":avcodec-hw=none")
        media.addOption(":network-caching=10000")
        media.addOption(":http-reconnect")
        media.addOption(":file-caching=1500")
        if let agent = headers?["User-Agent"] { media.addOption(":http-user-agent=\(agent)") }
        if let referer = headers?["Referer"] ?? headers?["Referrer"] { media.addOption(":http-referrer=\(referer)") }
        if let cookie = headers?["Cookie"] { media.addOption(":http-cookie=\(cookie)") }
        player.drawable = videoView; player.media = media
        _ = player.updateViewpoint(0, pitch: 0, roll: 0, fov: fov, absolute: true)
        player.play(); startMotion()
        if resumeAt > 2 { DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in self?.player.time = VLCTime(int: Int32(resumeAt * 1000)) } }
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in self?.tick() }
    }

    private func tick() {
        let current = Double(player.time.intValue) / 1000
        let duration = Double(player.media?.length.intValue ?? 0) / 1000
        let size = player.videoSize
        _ = player.updateViewpoint(yaw, pitch: pitch, roll: 0, fov: fov, absolute: true)
        controller?.update(playing: player.isPlaying, buffering: !player.isPlaying && current < 1, position: Double(player.position), current: current, duration: duration, size: size)
    }

    private func startMotion() {
        guard motion.isDeviceMotionAvailable else { return }
        motion.deviceMotionUpdateInterval = 1 / 60
        motion.startDeviceMotionUpdates(using: .xArbitraryZVertical, to: .main) { [weak self] sample, _ in
            guard let self, let attitude = sample?.attitude else { return }
            let deviceYaw = Float(attitude.yaw * 180 / .pi)
            let devicePitch = Float(attitude.pitch * 180 / .pi)
            _ = self.player.updateViewpoint(self.yaw + deviceYaw, pitch: max(-89, min(89, self.pitch + devicePitch)), roll: 0, fov: self.fov, absolute: true)
        }
    }

    @objc private func tapped() { onTap?() }
    @objc private func panned(_ gesture: UIPanGestureRecognizer) {
        let value = gesture.translation(in: self)
        if gesture.state == .began { panStart = CGPoint(x: CGFloat(yaw), y: CGFloat(pitch)) }
        yaw = Float(panStart.x - value.x * 0.18); pitch = max(-89, min(89, Float(panStart.y + value.y * 0.18)))
        _ = player.updateViewpoint(yaw, pitch: pitch, roll: 0, fov: fov, absolute: true)
    }
    @objc private func pinched(_ gesture: UIPinchGestureRecognizer) {
        fov = max(35, min(115, fov / Float(gesture.scale))); gesture.scale = 1
        _ = player.updateViewpoint(yaw, pitch: pitch, roll: 0, fov: fov, absolute: true)
    }
    func toggle() { player.isPlaying ? player.pause() : player.play() }
    func skip(_ seconds: Double) { player.time = VLCTime(int: Int32(max(0, Double(player.time.intValue) + seconds * 1000))) }
    func seek(_ value: Double) { player.position = Float(min(1, max(0, value))) }
    func seek(toSeconds seconds: Double) { player.time = VLCTime(int: Int32(max(0, seconds * 1000))) }
    func stop() { motion.stopDeviceMotionUpdates(); timer?.invalidate(); player.stop(); player.drawable = nil }
}
