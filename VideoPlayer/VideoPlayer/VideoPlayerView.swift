import SwiftUI
import AVKit
import AVFoundation
import UIKit
import MobileVLCKit
import CoreFoundation
import UniformTypeIdentifiers

private enum SubtitleFileImportError: LocalizedError {
    case unreadableText

    var errorDescription: String? {
        "This file does not contain a supported text subtitle."
    }
}

// MARK: - Player screen

struct VideoPlayerView: View {
    let url: URL
    let title: String
    var subtitleMediaContext: SubtitleMediaContext? = nil
    var resumeAt: Double = 0
    var linkId: UUID? = nil
    /// Optional HTTP headers (WebDAV Basic Auth, etc.)
    var httpHeaders: [String: String]? = nil
    var episodeOptions: [PlayerEpisodeOption] = []
    var onSelectEpisode: ((String) -> Void)? = nil
    var onProgress: ((Double, Double, Int, Int) -> Void)? = nil

    @Environment(\.dismiss) var dismiss
    @StateObject private var engine = VideoPlaybackEngine()
    @State private var showControls = true
    @State private var isScrubbing = false
    @State private var scrubProgress: Double = 0
    @State private var hideTask: Task<Void, Never>?
    @State private var isFillMode = false
    /// True once the user has manually tapped the VR toggle for *this* video —
    /// after that we never override their choice with auto-detection.
    /// True once auto-detection has run (either applied or determined not applicable)
    /// for the currently loaded video, so it only ever fires once per video.
    @State private var fillModeToken = 0
    @State private var useExtendedPlayer = false
    @State private var showExtendedPlayerPrompt = false
    @State private var mkvFillMode = false
    @State private var mkvResetZoomToken = 0
    @StateObject private var mkvControls = MKVPlaybackControls()
    @State private var showPlaybackSettings = false
    @State private var showQuickSettings = false
    @State private var showSubtitleSearch = false
    @State private var showSubtitleFileImporter = false
    @State private var subtitleImportError: String?
    @State private var showEpisodePicker = false
    @State private var playbackRate: Float = 1
    @State private var subtitleSize: Double = UserDefaults.standard.object(forKey: SubtitlePreferenceKeys.size) as? Double ?? 24
    @State private var subtitleColor: PlayerSubtitleColor = PlayerSubtitleColor(rawValue: UserDefaults.standard.string(forKey: SubtitlePreferenceKeys.color) ?? "") ?? .white
    @State private var selectedAudioTrack = ""
    @State private var selectedSubtitleTrack = "Off"
    @State private var externalSubtitleCues: [ExternalSubtitleCue] = []
    @State private var externalSubtitleFileName: String?
    @State private var embeddedMKVSubtitleTracks: [MatroskaTextSubtitleTrack] = []
    @State private var selectedEmbeddedMKVSubtitleTrackID: String?
    @State private var mkvSubtitleExtractionTask: Task<Void, Never>?
    @State private var automaticSubtitleTask: Task<Void, Never>?
    @State private var automaticSubtitleStartTask: Task<Void, Never>?
    @State private var didAttemptAutomaticSubtitle = false
    @State private var subtitleSelectionWasUserDriven = false
    @State private var screenBrightness: Double = 0.5
    @State private var subtitleDelay: Double = UserDefaults.standard.object(forKey: SubtitlePreferenceKeys.delay) as? Double ?? 0
    @State private var subtitleHeight: Double = UserDefaults.standard.object(forKey: SubtitlePreferenceKeys.height) as? Double ?? 0
    @State private var subtitleShadow = UserDefaults.standard.object(forKey: SubtitlePreferenceKeys.shadow) as? Bool ?? true
    @State private var subtitleBackground = UserDefaults.standard.object(forKey: SubtitlePreferenceKeys.background) as? Bool ?? true
    @State private var subtitleFont: PlayerSubtitleFont = PlayerSubtitleFont(rawValue: UserDefaults.standard.string(forKey: SubtitlePreferenceKeys.font) ?? "") ?? .rounded
    @State private var nextEpisodeCountdown = 5
    @State private var endCountdownTask: Task<Void, Never>?
    @State private var didTearDownPlayback = false
    @State private var didResetNetworkAfterPlayback = false
    // Playback opens in the app's normal portrait orientation. Rotation is
    // exclusively controlled by the in-player button.
    @State private var isPlayerLandscape = false
    @State private var isClosingPlayer = false

    // Keep formats Apple handles well on AVPlayer; route MKV and other extended
    // containers through MobileVLCKit.
    private var usesMKVPlayer: Bool {
        let decoded = ((title.removingPercentEncoding ?? title) + " " + (url.lastPathComponent.removingPercentEncoding ?? url.lastPathComponent)).lowercased()
        let explicitExtension = url.pathExtension.lowercased()

        if explicitExtension == "mp4" || decoded.range(of: #"(?i)\.mp4(?:$|[?\s])"#, options: .regularExpression) != nil {
            return false
        }
        if explicitExtension == "mkv" || decoded.range(of: #"(?i)\.mkv(?:$|[?\s])"#, options: .regularExpression) != nil {
            return true
        }
        // Extensionless PikPak download URLs do not reveal their container. VLC
        // remains the safe fallback only when neither the URL nor title says MP4.
        if explicitExtension.isEmpty,
           LinkResolver.isPikPakDirectDownload(url.absoluteString) {
            return true
        }
        if useExtendedPlayer { return true }
        return ["webm", "avi", "flv", "wmv", "m2ts", "mts", "ts"].contains(explicitExtension)
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
                    httpHeaders: httpHeaders,
                    subtitleSize: effectiveSubtitlePointSize,
                    subtitleFontName: effectiveEmbeddedSubtitleVLCFontName,
                    subtitleColorValue: subtitleColor.vlcColorValue,
                    subtitleBackground: subtitleBackground,
                    subtitleShadow: subtitleShadow,
                    subtitleHeight: Int(subtitleHeight),
                    subtitleDelay: subtitleDelay,
                    anchorEmbeddedSubtitlesToViewport: false
                )
                    .contentShape(Rectangle())
                    .simultaneousGesture(TapGesture().onEnded { toggleMKVControls() })
                    .ignoresSafeArea()
            } else {
                ZoomableVideoView(
                    player: engine.player,
                    resetToken: engine.resetZoomToken,
                    fillModeToken: fillModeToken,
                    isFillMode: isFillMode,
                    videoSize: CGSize(width: engine.resolutionWidth, height: engine.resolutionHeight),
                    // AVFoundation captions are emitted as timed text and drawn
                    // by the fixed overlay below, outside this zoomable surface.
                    anchorEmbeddedSubtitlesToViewport: false,
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
                    Button("Retry") { engine.load(url: url, title: title, resumeAt: resumeAt, httpHeaders: httpHeaders) }
                        .buttonStyle(.borderedProminent)
                        .tint(AppPalette.accent)
                }
                .padding(20)
                .background(Color.black.opacity(0.78), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }

            // Concept 05 — Edge Controls. AVPlayer and VLC now share one chrome.
            if showControls {
                ZStack {
                    playerChromeShade
                    VStack(spacing: 0) {
                        topOverlay
                        Spacer(minLength: 0).allowsHitTesting(false)
                        bottomOverlay
                    }
                    edgeControlsOverlay
                }
            }

            if showQuickSettings {
                ZStack {
                    Color.black.opacity(0.24)
                        .ignoresSafeArea()
                        .contentShape(Rectangle())
                        .onTapGesture {
                            withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                                showQuickSettings = false
                            }
                        }

                    PlayerQuickSettingsPanel(
                        audioTracks: usesMKVPlayer ? mkvControls.audioTracks : engine.audioTracks,
                        selectedAudioTrackID: usesMKVPlayer ? mkvControls.selectedAudioTrackID : engine.selectedAudioTrackID,
                        subtitleFileName: externalSubtitleFileName,
                        selectedSpeed: $playbackRate,
                        onRateChange: { rate in
                            if usesMKVPlayer { mkvControls.setRate(rate) }
                            else { engine.setRate(rate) }
                        },
                        onAudioTrackChange: { id in
                            if usesMKVPlayer { mkvControls.selectAudioTrack(id: id) }
                            else { engine.selectAudioTrack(id: id) }
                        },
                        onSearchSubtitles: {
                            withAnimation(.easeOut(duration: 0.16)) {
                                showQuickSettings = false
                            }
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
                                showSubtitleSearch = true
                                hideTask?.cancel()
                                hideTask = nil
                            }
                        },
                        onChooseSubtitleFile: {
                            withAnimation(.easeOut(duration: 0.16)) {
                                showQuickSettings = false
                            }
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
                                showSubtitleFileImporter = true
                                hideTask?.cancel()
                                hideTask = nil
                            }
                        },
                        onAdvanced: {
                            withAnimation(.easeOut(duration: 0.16)) {
                                showQuickSettings = false
                            }
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
                                showPlaybackSettings = true
                            }
                        }
                    )
                    .transition(.scale(scale: 0.9).combined(with: .opacity))
                }
                .zIndex(80)
            }

            if !playbackDidEnd {
                PlayerLoadingReadout(
                    isLoading: playbackIsBuffering,
                    bytesPerSecond: usesMKVPlayer
                        ? mkvControls.networkSpeedBytesPerSecond
                        : engine.networkSpeedBytesPerSecond
                )
                .zIndex(20)
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
                    .padding(.bottom, showControls ? 205 : 34)
                }
                .transition(.opacity.combined(with: .move(edge: .trailing)))
            }

            if let subtitleText = activeViewportSubtitleText, !playbackDidEnd {
                GeometryReader { proxy in
                    VStack(spacing: 0) {
                        Spacer(minLength: 0)
                        Text(subtitleText)
                            .font(externalSubtitleFont(for: subtitleText, viewport: proxy.size))
                            .foregroundColor(subtitleColor.color)
                            .multilineTextAlignment(.center)
                            .lineLimit(nil)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: subtitleScreenMaxWidth(for: proxy), alignment: .center)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(subtitleBackground ? Color.black.opacity(0.58) : Color.clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .shadow(color: subtitleShadow ? .black.opacity(0.9) : .clear, radius: subtitleShadow ? 4 : 0)
                            .padding(.bottom, subtitleScreenBottomInset(for: proxy))
                    }
                    .frame(width: proxy.size.width, height: proxy.size.height, alignment: .bottom)
                }
                .ignoresSafeArea()
                .allowsHitTesting(false)
                .zIndex(50)
            }

            if playbackDidEnd {
                PlayerEndScreen(
                    title: VideoTitleFormatter.title(from: title),
                    countdown: nextEpisodeCountdown,
                    onReplay: replayCurrentVideo,
                    onBack: { closePlayer() }
                )
                .transition(.opacity)
            }

            if isClosingPlayer {
                Color.black
                    .ignoresSafeArea()
                    .transition(.opacity)
                    .zIndex(1_000)
            }

        }
        .fullScreenCover(isPresented: $showPlaybackSettings, onDismiss: {
            applySubtitlePreferences()
            scheduleAutoHide()
        }) {
            PlayerAdvancedSettingsSheet(
                selectedAudioTrack: $selectedAudioTrack,
                subtitleSize: $subtitleSize,
                subtitleColor: $subtitleColor,
                subtitleDelay: $subtitleDelay,
                subtitleHeight: $subtitleHeight,
                subtitleShadow: $subtitleShadow,
                subtitleBackground: $subtitleBackground,
                subtitleFont: $subtitleFont,
                brightness: $screenBrightness,
                mediaTitle: title,
                mediaContext: subtitleMediaContext,
                audioTracks: usesMKVPlayer ? mkvControls.audioTracks : engine.audioTracks,
                selectedAudioTrackID: usesMKVPlayer ? mkvControls.selectedAudioTrackID : engine.selectedAudioTrackID,
                isFillMode: usesMKVPlayer ? mkvFillMode : isFillMode,
                onAspectRatioToggle: {
                    if usesMKVPlayer { mkvFillMode.toggle() }
                    else { isFillMode.toggle(); fillModeToken += 1 }
                },
                onBrightnessChange: { value in
                    screenBrightness = value
                    UIScreen.main.brightness = CGFloat(value)
                },
                onAudioTrackChange: { id in
                            if usesMKVPlayer { mkvControls.selectAudioTrack(id: id) }
                            else { engine.selectAudioTrack(id: id) }
                        },
                onRateChange: { rate in
                    playbackRate = rate
                    if usesMKVPlayer { mkvControls.setRate(rate) } else { engine.setRate(rate) }
                },
                onSubtitleSelected: { subtitle in
                    return loadExternalSubtitle(data: subtitle.data, fileName: subtitle.fileName)
                }
            )
        }
        .fullScreenCover(isPresented: $showSubtitleSearch, onDismiss: {
            scheduleAutoHide()
        }) {
            SubtitleSearchView(
                mediaTitle: title,
                mediaContext: subtitleMediaContext,
                onSubtitleSelected: { subtitle in
                    let applied = loadExternalSubtitle(data: subtitle.data, fileName: subtitle.fileName)
                    if applied { showSubtitleSearch = false }
                    return applied
                }
            )
        }
        .fileImporter(
            isPresented: $showSubtitleFileImporter,
            allowedContentTypes: subtitleDocumentTypes,
            allowsMultipleSelection: false,
            onCompletion: importSubtitleFile
        )
        .alert("Subtitle File", isPresented: Binding(
            get: { subtitleImportError != nil },
            set: { if !$0 { subtitleImportError = nil } }
        )) {
            Button("OK", role: .cancel) { scheduleAutoHide() }
        } message: {
            Text(subtitleImportError ?? "The subtitle file could not be opened.")
        }
        .statusBar(hidden: true)
        .navigationBarHidden(true)
        .onAppear {
            didTearDownPlayback = false
            didResetNetworkAfterPlayback = false
            if LinkResolver.isPikPakDirectDownload(url.absoluteString) {
                let titleExtension = (title as NSString).pathExtension.lowercased()
                DiagnosticLogger.log(
                    "[PikPakPlayback] engine=\(usesMKVPlayer ? "VLC" : "AVPlayer") titleExtension=\(titleExtension.isEmpty ? "none" : titleExtension) host=\(url.host ?? "unknown")"
                )
            }
            screenBrightness = Double(UIScreen.main.brightness)
            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
            // Defensive reset: guarantees a clean VR state for this video even
            // if this view instance is ever reused across plays.
            engine.onProgressTick = { seconds, duration, w, h in
                onProgress?(seconds, duration, w, h)
            }
            if !usesMKVPlayer {
                engine.load(url: url, title: title, resumeAt: resumeAt, httpHeaders: httpHeaders)
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 700_000_000)
                    guard !Task.isCancelled else { return }
                    engine.applySubtitleStyle(
                        fontSize: subtitleSize,
                        fontFamily: effectiveEmbeddedSubtitleAppleFontFamily,
                        color: subtitleColor.uiColor,
                        background: subtitleBackground
                    )
                }
            } else {
                // Embedded MKV/VLC subtitles are disabled by design. Online
                // downloads use the independent viewport overlay below.
                mkvControls.selectSubtitleTrack(id: nil)
            }
            scheduleAutoHide()
        }
        .onDisappear {
            ScreenOrientationLock.setPlayerLandscape(false)
            tearDownPlayback()
            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        }
        .onChange(of: engine.errorMessage) { error in
            guard error != nil, !usesMKVPlayer else { return }
            let nativeExtension = url.pathExtension.lowercased()
            guard nativeExtension != "mp4" && nativeExtension != "mov" && nativeExtension != "m4v" else { return }
            engine.cleanup()
            useExtendedPlayer = true
        }
        .onChange(of: engine.isPlaying) { playing in
            guard !usesMKVPlayer else { return }
            playbackRunningChanged(playing)
        }
        .onChange(of: mkvControls.isPlaying) { playing in
            guard usesMKVPlayer else { return }
            playbackRunningChanged(playing)
        }
        .onChange(of: engine.isBuffering) { buffering in
            guard !usesMKVPlayer, buffering else { return }
            hideTask?.cancel()
            showControls = true
        }
        .onChange(of: mkvControls.isBuffering) { buffering in
            guard usesMKVPlayer, buffering else { return }
            hideTask?.cancel()
            showControls = true
        }
        .onChange(of: showControls) { visible in
            if !visible {
                showQuickSettings = false
                showEpisodePicker = false
            }
        }
        .onChange(of: showPlaybackSettings) { presented in
            if presented {
                hideTask?.cancel()
                hideTask = nil
                showControls = true
            }
        }
        .onChange(of: showQuickSettings) { presented in
            if presented { hideTask?.cancel(); hideTask = nil }
            else if !showPlaybackSettings { scheduleAutoHide() }
        }
        .onChange(of: showEpisodePicker) { presented in
            if presented { hideTask?.cancel(); hideTask = nil }
            else if !showPlaybackSettings { scheduleAutoHide() }
        }
        .onChange(of: isScrubbing) { scrubbing in
            if scrubbing { hideTask?.cancel() } else { scheduleAutoHide() }
        }
        .onChange(of: subtitleSize) { _ in applySubtitlePreferences() }
        .onChange(of: subtitleColor) { _ in applySubtitlePreferences() }
        .onChange(of: subtitleDelay) { _ in applySubtitlePreferences() }
        .onChange(of: subtitleHeight) { _ in applySubtitlePreferences() }
        .onChange(of: subtitleShadow) { _ in applySubtitlePreferences() }
        .onChange(of: subtitleBackground) { _ in applySubtitlePreferences() }
        .onChange(of: subtitleFont) { _ in applySubtitlePreferences() }
        .onChange(of: engine.selectedSubtitleTrackID) { _ in applySubtitlePreferences() }
        .onChange(of: engine.subtitleTracks) { _ in
            engine.selectSubtitleTrack(id: nil)
        }
        .onChange(of: mkvControls.selectedSubtitleTrackID) { _ in applySubtitlePreferences() }
        .onChange(of: mkvControls.subtitleTracks) { _ in
            mkvControls.selectSubtitleTrack(id: nil)
        }
        .onChange(of: playbackDidEnd) { ended in
            if ended { beginEndCountdown() } else { endCountdownTask?.cancel() }
        }
    }

    // MARK: - Top chrome

    private func closePlayer() {
        guard !isClosingPlayer else { return }

        // When the player is landscape, dismissing immediately exposes the
        // portrait details screen while iOS is still animating its rotation.
        // Keep the player presentation covered until the scene is portrait,
        // then dismiss so the underlying page is never shown sideways.
        guard isPlayerLandscape || !ScreenOrientationLock.isInterfacePortrait else {
            ScreenOrientationLock.setPlayerLandscape(false)
            tearDownPlayback()
            dismiss()
            return
        }

        // Make the cover opaque before asking UIKit to rotate. Animating the
        // cover and the interface at the same time can expose triangular
        // corners of the details page during the rotation snapshot.
        isClosingPlayer = true
        showControls = false
        hideTask?.cancel()
        hideTask = nil
        if usesMKVPlayer { mkvControls.pause() }
        else { engine.player.pause() }

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 60_000_000)
            ScreenOrientationLock.setPlayerLandscape(false)
            for _ in 0..<20 {
                if ScreenOrientationLock.isInterfacePortrait { break }
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            // `interfaceOrientation` changes just before the system's visual
            // rotation finishes; leave the opaque cover up through that tail.
            try? await Task.sleep(nanoseconds: 180_000_000)
            tearDownPlayback()
            dismiss()
        }
    }

    /// Both the close button and SwiftUI's dismissal callback reach this path.
    /// Keep teardown strictly one-shot: MobileVLCKit in particular is not safe
    /// when `stop`, `media = nil`, and `drawable = nil` race or run repeatedly.
    private func tearDownPlayback() {
        guard !didTearDownPlayback else { return }
        didTearDownPlayback = true
        hideTask?.cancel()
        hideTask = nil
        endCountdownTask?.cancel()
        endCountdownTask = nil
        mkvSubtitleExtractionTask?.cancel()
        mkvSubtitleExtractionTask = nil
        automaticSubtitleTask?.cancel()
        automaticSubtitleTask = nil
        automaticSubtitleStartTask?.cancel()
        automaticSubtitleStartTask = nil

        if usesMKVPlayer {
            if mkvControls.durationSeconds > 0 {
                onProgress?(mkvControls.currentSeconds, mkvControls.durationSeconds, mkvControls.videoWidth, mkvControls.videoHeight)
            }
            mkvControls.stop()
        } else {
            // VideoPlaybackEngine sends its final progress tick before releasing
            // AVPlayerItem, observers, pending seeks, and asset loading.
            engine.cleanup()
        }

        BackgroundVideoCacheManager.shared.cancelAllPrefetches()
        // Tear the media asset down first, then rotate only the video request
        // pool. Doing this in the opposite order can leave a range request alive.
        resetNetworkAfterPlaybackIfNeeded()
    }

    private func resetNetworkAfterPlaybackIfNeeded() {
        guard !didResetNetworkAfterPlayback else { return }
        didResetNetworkAfterPlayback = true
        HighPriorityNetworkManager.shared.resetAfterPlayback()
    }

    private var topOverlay: some View {
        HStack(spacing: 12) {
            AppAnimatedBackButton(size: 40) {
                UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                closePlayer()
            }

            PlayerQualityBadge(
                width: usesMKVPlayer ? mkvControls.videoWidth : engine.resolutionWidth,
                height: usesMKVPlayer ? mkvControls.videoHeight : engine.resolutionHeight,
                fallbackLabel: usesMKVPlayer ? mkvQualityLabel : engine.resolutionTier.badgeText
            )

            Spacer(minLength: 0)

            playerOrientationButton

            Button {
                withAnimation(.easeInOut(duration: 0.28)) {
                    if usesMKVPlayer {
                        mkvFillMode.toggle()
                    } else {
                        isFillMode.toggle()
                        fillModeToken += 1
                    }
                }
                scheduleAutoHide()
            } label: {
                Image(systemName: (usesMKVPlayer ? mkvFillMode : isFillMode) ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(width: 40, height: 40)
                    .background(.ultraThinMaterial, in: Circle())
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 16)
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
                progress: isScrubbing ? scrubProgress : (usesMKVPlayer ? mkvControls.displayProgress : engine.progress),
                bufferProgress: usesMKVPlayer ? mkvControls.displayProgress : Double(engine.bufferPercent) / 100,
                currentLabel: isScrubbing
                    ? (usesMKVPlayer ? mkvControls.formattedTime(forFraction: scrubProgress) : engine.formattedTime(forFraction: scrubProgress))
                    : (usesMKVPlayer ? mkvControls.currentTimeFormatted : engine.currentTimeFormatted),
                durationLabel: negativeRemaining(
                    current: isScrubbing ? scrubProgress * playbackDurationSeconds : currentPlaybackSeconds,
                    duration: playbackDurationSeconds
                ),
                chapters: playbackChapters,
                onSeek: { value in
                    scrubProgress = value
                    isScrubbing = false
                    if usesMKVPlayer { mkvControls.seek(to: value) }
                    else { engine.seek(to: value) }
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
    }

    /// Chrome shading belongs to the complete player viewport, not the safe
    /// area-sized control stacks. Keeping it here removes the two vertical seams
    /// that appeared beside the video in landscape/fill mode on notched iPhones.
    /// The video surfaces continue to calculate fit/fill from each file's real
    /// presentation size; this layer only supplies consistent edge contrast.
    private var playerChromeShade: some View {
        GeometryReader { proxy in
            VStack(spacing: 0) {
                LinearGradient(
                    colors: [Color.black.opacity(0.72), Color.black.opacity(0)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: min(170, max(96, proxy.size.height * 0.22)))

                Spacer(minLength: 0)

                LinearGradient(
                    colors: [Color.black.opacity(0), Color.black.opacity(0.84)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: min(340, max(210, proxy.size.height * 0.43)))
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    private func toggleMKVControls() {
        withAnimation(.easeInOut(duration: 0.2)) {
            showControls.toggle()
        }
        if showControls { scheduleAutoHide() } else { hideTask?.cancel() }
    }

    private var activeExternalSubtitle: ExternalSubtitleCue? {
        externalSubtitleCues.first {
            let adjustedTime = currentPlaybackSeconds - subtitleDelay
            return adjustedTime >= $0.start && adjustedTime <= $0.end
        }
    }

    /// A single viewport-level subtitle source. External files and successfully
    /// extracted text tracks share the exact same fixed rendering path.
    private var activeViewportSubtitleText: String? {
        activeExternalSubtitle?.text
    }

    private var playerSubtitleTracks: [PlayerSubtitleTrackOption] {
        []
    }

    private var playerSelectedSubtitleTrackID: String? {
        nil
    }

    private var selectedEmbeddedSubtitle: PlayerSubtitleTrackOption? {
        guard let selectedID = playerSelectedSubtitleTrackID else { return nil }
        return playerSubtitleTracks.first { $0.id == selectedID }
    }

    private var effectiveSubtitlePointSize: Double {
        PlayerSubtitleSizing.pointSize(base: subtitleSize)
    }

    private var effectiveEmbeddedSubtitleAppleFontFamily: String {
        selectedEmbeddedSubtitle?.isEnglish == true
            ? PlayerSubtitleTypeface.englishFamilyName
            : subtitleFont.appleFontFamily
    }

    private var effectiveEmbeddedSubtitleVLCFontName: String {
        selectedEmbeddedSubtitle?.isEnglish == true
            ? PlayerSubtitleTypeface.englishVLCFontName
            : subtitleFont.vlcFontName
    }

    private func externalSubtitleFont(for text: String, viewport: CGSize) -> Font {
        let pointSize = PlayerSubtitleSizing.pointSize(base: subtitleSize, viewport: viewport)
        if SubtitleLanguageDetector.isPredominantlyLatin(text) {
            return .custom(PlayerSubtitleTypeface.englishPostScriptName, fixedSize: CGFloat(pointSize))
        }
        return .system(size: pointSize, weight: .semibold, design: subtitleFont.design)
    }

    private func subtitleScreenBottomInset(for proxy: GeometryProxy) -> CGFloat {
        // Subtitle placement belongs to the device viewport, never to the
        // fitted/cropped video rectangle. Keep it clear of the home indicator
        // and lift it slightly while playback chrome is visible.
        max(20, proxy.safeAreaInsets.bottom + 10)
            + subtitleHeight
            + (showControls ? 34 : 0)
    }

    private func subtitleScreenMaxWidth(for proxy: GeometryProxy) -> CGFloat {
        max(
            120,
            proxy.size.width
                - proxy.safeAreaInsets.leading
                - proxy.safeAreaInsets.trailing
                - 64
        )
    }

    private var edgeControlsOverlay: some View {
        HStack {
            VStack(spacing: 10) {
                edgeControlButton("sun.max.fill") {
                    let next = screenBrightness >= 0.95 ? 0.25 : min(1, screenBrightness + 0.18)
                    screenBrightness = next
                    UIScreen.main.brightness = CGFloat(next)
                    scheduleAutoHide()
                }
            }

            Spacer(minLength: 0)

            VStack(spacing: 10) {
                edgeControlButton("captions.bubble.fill") {
                    hideTask?.cancel()
                    hideTask = nil
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.84)) {
                        showQuickSettings = true
                    }
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.bottom, 50)
    }

    private func edgeControlButton(_ systemName: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(.white)
                .frame(width: 40, height: 40)
                .background(Color.black.opacity(0.38), in: Circle())
                .background(.ultraThinMaterial, in: Circle())
                .overlay(Circle().stroke(Color.white.opacity(0.2), lineWidth: 0.8))
                .shadow(color: .black.opacity(0.42), radius: 8, y: 3)
        }
        .buttonStyle(PremiumPressButtonStyle())
    }

    @discardableResult
    private func loadExternalSubtitle(data: Data, fileName: String) -> Bool {
        guard let content = decodeSubtitleText(data) else {
            subtitleImportError = "The downloaded file is not readable subtitle text."
            return false
        }
        let cues = ExternalSubtitleParser.parse(content)
        guard !cues.isEmpty else {
            subtitleImportError = "The downloaded file has no supported subtitle cues."
            return false
        }
        mkvSubtitleExtractionTask?.cancel()
        mkvSubtitleExtractionTask = nil
        externalSubtitleCues = cues
        externalSubtitleFileName = fileName
        selectedEmbeddedMKVSubtitleTrackID = nil
        subtitleSelectionWasUserDriven = true
        selectedSubtitleTrack = fileName
        if usesMKVPlayer { mkvControls.selectSubtitleTrack(id: nil) }
        else { engine.selectSubtitleTrack(id: nil) }
        return true
    }

    private var subtitleDocumentTypes: [UTType] {
        let extensions = ["srt", "vtt", "ass", "ssa", "txt"]
        let detected = extensions.compactMap { UTType(filenameExtension: $0) }
        return detected.isEmpty ? [.plainText, .data] : detected
    }

    private func importSubtitleFile(_ result: Result<[URL], Error>) {
        defer { scheduleAutoHide() }
        do {
            guard let fileURL = try result.get().first else { return }
            let accessed = fileURL.startAccessingSecurityScopedResource()
            defer { if accessed { fileURL.stopAccessingSecurityScopedResource() } }
            let data = try Data(contentsOf: fileURL, options: [.mappedIfSafe])
            guard let content = decodeSubtitleText(data),
                  !ExternalSubtitleParser.parse(content).isEmpty else {
                throw SubtitleFileImportError.unreadableText
            }
            loadExternalSubtitle(data: data, fileName: fileURL.lastPathComponent)
        } catch let error as CocoaError where error.code == .userCancelled {
            return
        } catch {
            subtitleImportError = error.localizedDescription
        }
    }

    private func beginAutomaticSubtitleDownloadIfNeeded() {
        guard SubtitlePreferences.automaticDownloadEnabled,
              !didAttemptAutomaticSubtitle else { return }
        didAttemptAutomaticSubtitle = true
        automaticSubtitleTask?.cancel()
        let mediaTitle = title
        automaticSubtitleTask = Task {
            do {
                guard let subtitle = try await SubDLSubtitleService.automaticDownload(
                    mediaTitle: mediaTitle,
                    mediaContext: subtitleMediaContext
                ),
                      !Task.isCancelled,
                      !subtitleSelectionWasUserDriven else { return }
                loadExternalSubtitle(data: subtitle.data, fileName: subtitle.fileName)
            } catch is CancellationError {
                return
            } catch {
                DiagnosticLogger.log("Automatic subtitles: \(error.localizedDescription)")
            }
        }
    }

    /// Start the online subtitle request after one continuous second of real
    /// playback. This gives the video stream first use of the connection and
    /// avoids firing while the player is merely presented or still buffering.
    private func scheduleAutomaticSubtitleAfterFirstPlaybackSecond() {
        guard SubtitlePreferences.automaticDownloadEnabled,
              !didAttemptAutomaticSubtitle,
              automaticSubtitleStartTask == nil else { return }
        automaticSubtitleStartTask = Task { @MainActor in
            do {
                try await Task.sleep(nanoseconds: 1_000_000_000)
            } catch {
                automaticSubtitleStartTask = nil
                return
            }
            guard playbackIsActuallyRunning, !Task.isCancelled else {
                automaticSubtitleStartTask = nil
                return
            }
            automaticSubtitleStartTask = nil
            beginAutomaticSubtitleDownloadIfNeeded()
        }
    }

    private func selectPreferredAppleSubtitleIfNeeded(from tracks: [PlayerSubtitleTrackOption]) {
        guard !usesMKVPlayer,
              externalSubtitleFileName == nil,
              !subtitleSelectionWasUserDriven,
              let preferred = tracks.first(where: {
                  SubtitlePreferences.languageMatches(code: $0.languageCode, title: $0.title)
              }) else { return }
        engine.selectSubtitleTrack(id: preferred.id)
        selectedSubtitleTrack = preferred.title
    }

    private func beginEmbeddedMKVSubtitleExtraction() {
        mkvSubtitleExtractionTask?.cancel()
        embeddedMKVSubtitleTracks = []
        selectedEmbeddedMKVSubtitleTrackID = nil
        subtitleSelectionWasUserDriven = false

        let mediaURL = url
        let headers = httpHeaders
        mkvSubtitleExtractionTask = Task {
            do {
                let tracks = try await MatroskaSubtitleExtractor.extract(
                    from: mediaURL,
                    httpHeaders: headers,
                    preferredTrackOnly: true,
                    preferredLanguageCode: SubtitlePreferences.preferredLanguageCode,
                    priorityTime: resumeAt
                ) { track in
                    guard !Task.isCancelled else { return }
                    acceptExtractedMKVSubtitleTrack(track)
                }
                guard !Task.isCancelled else { return }
                embeddedMKVSubtitleTracks = tracks
                DiagnosticLogger.log("MKV subtitles: extracted \(tracks.count) text track(s) from \(mediaURL.lastPathComponent)")

                if externalSubtitleFileName == nil, !subtitleSelectionWasUserDriven {
                    // If VLC already selected a track, preserve the user's
                    // intent by mapping its list position to the extracted text
                    // list. Otherwise honor Forced/Default metadata.
                    let nativeIndex = mkvControls.selectedSubtitleTrackID.flatMap { selectedID in
                        mkvControls.subtitleTracks.firstIndex(where: { $0.id == selectedID })
                    }
                    let mapped = nativeIndex.flatMap { selectedIndex in
                        tracks.first(where: { $0.containerSubtitleIndex == selectedIndex })
                    }
                    let preferred = mapped
                        ?? tracks.first(where: { $0.isForced })
                        ?? tracks.first(where: { $0.isDefault })
                    if let preferred, selectedEmbeddedMKVSubtitleTrackID != preferred.id {
                        selectEmbeddedMKVSubtitleTrack(id: preferred.id, userDriven: false)
                    }
                }
            } catch is CancellationError {
                return
            } catch {
                DiagnosticLogger.log("MKV subtitles: extraction failed: \(error.localizedDescription)")
            }
        }
    }

    private func acceptExtractedMKVSubtitleTrack(_ track: MatroskaTextSubtitleTrack) {
        if let index = embeddedMKVSubtitleTracks.firstIndex(where: { $0.id == track.id }) {
            embeddedMKVSubtitleTracks[index] = track
        } else {
            embeddedMKVSubtitleTracks.append(track)
        }
        if selectedEmbeddedMKVSubtitleTrackID == track.id {
            // Progressive extraction publishes growing cue batches. Refresh
            // the fixed overlay without toggling or restarting playback.
            externalSubtitleCues = track.cues.map {
                ExternalSubtitleCue(start: $0.start, end: $0.end, text: $0.text)
            }
        }
        guard externalSubtitleFileName == nil,
              !subtitleSelectionWasUserDriven else { return }

        let nativeIndex = mkvControls.selectedSubtitleTrackID.flatMap { selectedID in
            mkvControls.subtitleTracks.firstIndex(where: { $0.id == selectedID })
        }
        if let nativeIndex,
           let matchingTrack = embeddedMKVSubtitleTracks.first(where: {
               $0.containerSubtitleIndex == nativeIndex
           }) {
            // The user/default VLC choice has now reached the incremental
            // extractor; switch it immediately to the fixed text overlay.
            if selectedEmbeddedMKVSubtitleTrackID != matchingTrack.id {
                selectEmbeddedMKVSubtitleTrack(id: matchingTrack.id, userDriven: false)
            }
        } else if selectedEmbeddedMKVSubtitleTrackID == nil,
                  track.isForced || track.isDefault {
            selectEmbeddedMKVSubtitleTrack(id: track.id, userDriven: false)
        }
    }

    private func selectEmbeddedMKVSubtitleTrack(id: String, userDriven: Bool = true) {
        guard let track = embeddedMKVSubtitleTracks.first(where: { $0.id == id }) else { return }
        selectedEmbeddedMKVSubtitleTrackID = id
        externalSubtitleFileName = nil
        subtitleSelectionWasUserDriven = userDriven
        externalSubtitleCues = track.cues.map {
            ExternalSubtitleCue(start: $0.start, end: $0.end, text: $0.text)
        }
        selectedSubtitleTrack = track.title
        // Text came from Matroska itself; VLC must remain video/audio-only.
        mkvControls.selectSubtitleTrack(id: nil)
    }

    private func selectMKVSubtitleTrack(id: String) {
        if id.hasPrefix("mkv-text:") {
            mkvSubtitleExtractionTask?.cancel()
            mkvSubtitleExtractionTask = nil
            selectEmbeddedMKVSubtitleTrack(id: id)
            return
        }
        // Fallback for PGS/VobSub and for servers where range extraction is
        // unavailable: let VLC render the embedded track instead of hiding it.
        externalSubtitleCues = []
        externalSubtitleFileName = nil
        selectedEmbeddedMKVSubtitleTrackID = nil
        subtitleSelectionWasUserDriven = true
        mkvControls.selectSubtitleTrack(id: id)
        selectedSubtitleTrack = mkvControls.subtitleTracks.first(where: { $0.id == id })?.title ?? "On"

        // Try to promote a VLC textual track to the fixed viewport overlay on
        // demand. Bitmap tracks simply fail extraction and continue in VLC.
        if let nativeIndex = mkvControls.subtitleTracks.firstIndex(where: { $0.id == id }) {
            extractSelectedMKVSubtitleTrack(at: nativeIndex)
        }
    }

    private func extractSelectedMKVSubtitleTrack(at subtitleIndex: Int) {
        mkvSubtitleExtractionTask?.cancel()
        let mediaURL = url
        let headers = httpHeaders
        mkvSubtitleExtractionTask = Task {
            do {
                let tracks = try await MatroskaSubtitleExtractor.extract(
                    from: mediaURL,
                    httpHeaders: headers,
                    subtitleIndices: [subtitleIndex],
                    priorityTime: currentPlaybackSeconds
                ) { track in
                    guard !Task.isCancelled else { return }
                    acceptExtractedMKVSubtitleTrack(track)
                }
                guard !Task.isCancelled,
                      let track = tracks.first(where: { $0.containerSubtitleIndex == subtitleIndex }) else { return }
                if !embeddedMKVSubtitleTracks.contains(where: { $0.id == track.id }) {
                    embeddedMKVSubtitleTracks.append(track)
                }
                selectEmbeddedMKVSubtitleTrack(id: track.id, userDriven: true)
            } catch is CancellationError {
                return
            } catch {
                // PGS/VobSub, encrypted text, or a server without Range support
                // remains selected and rendered by VLC as the safe fallback.
                DiagnosticLogger.log("MKV subtitles: native fallback for track \(subtitleIndex): \(error.localizedDescription)")
            }
        }
    }

    private func disableAllSubtitles() {
        mkvSubtitleExtractionTask?.cancel()
        mkvSubtitleExtractionTask = nil
        externalSubtitleCues = []
        externalSubtitleFileName = nil
        selectedEmbeddedMKVSubtitleTrackID = nil
        subtitleSelectionWasUserDriven = true
        if usesMKVPlayer { mkvControls.selectSubtitleTrack(id: nil) }
        else { engine.selectSubtitleTrack(id: nil) }
    }

    private func decodeSubtitleText(_ data: Data) -> String? {
        // Most Arabic subtitle files are UTF-8, UTF-16, or legacy Windows-1256.
        // Trying the exact encodings avoids mojibake and replacement symbols.
        let windowsArabic = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
            CFStringConvertWindowsCodepageToEncoding(1256)
        ))
        let hasUTF16BOM = data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF])
        let encodings: [String.Encoding] = hasUTF16BOM
            ? [.utf16, .utf16LittleEndian, .utf16BigEndian, .utf8, windowsArabic]
            : [.utf8, windowsArabic, .utf16, .utf16LittleEndian, .utf16BigEndian]
        for encoding in encodings {
            if let value = String(data: data, encoding: encoding),
               !value.isEmpty,
               !value.contains("\u{FFFD}") {
                return value.replacingOccurrences(of: "\r\n", with: "\n")
            }
        }
        return nil
    }

    private func applySubtitlePreferences() {
        let defaults = UserDefaults.standard
        defaults.set(subtitleSize, forKey: SubtitlePreferenceKeys.size)
        defaults.set(subtitleColor.rawValue, forKey: SubtitlePreferenceKeys.color)
        defaults.set(subtitleDelay, forKey: SubtitlePreferenceKeys.delay)
        defaults.set(subtitleHeight, forKey: SubtitlePreferenceKeys.height)
        defaults.set(subtitleShadow, forKey: SubtitlePreferenceKeys.shadow)
        defaults.set(subtitleBackground, forKey: SubtitlePreferenceKeys.background)
        defaults.set(subtitleFont.rawValue, forKey: SubtitlePreferenceKeys.font)

        engine.applySubtitleStyle(
            fontSize: subtitleSize,
            fontFamily: effectiveEmbeddedSubtitleAppleFontFamily,
            color: subtitleColor.uiColor,
            background: subtitleBackground
        )
        mkvControls.applySubtitleStyle(
            fontSize: effectiveSubtitlePointSize,
            fontName: effectiveEmbeddedSubtitleVLCFontName,
            color: subtitleColor.vlcColorValue,
            background: subtitleBackground,
            shadow: subtitleShadow,
            margin: Int(subtitleHeight),
            delay: subtitleDelay
        )
    }

    private var playerOrientationButton: some View {
        Button {
            let landscape = !isPlayerLandscape
            isPlayerLandscape = landscape
            ScreenOrientationLock.setPlayerLandscape(landscape)
            showControls = true
            scheduleAutoHide()
        } label: {
            Image(systemName: isPlayerLandscape ? "rotate.left" : "rotate.right")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.white)
                .frame(width: 40, height: 40)
                .background(.ultraThinMaterial, in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isPlayerLandscape ? "Return to portrait" : "Rotate to landscape")
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
        HStack(alignment: .center, spacing: 14) {
            Button {
                if usesMKVPlayer { mkvControls.togglePlayback() }
                else { engine.togglePlayPause() }
                scheduleAutoHide()
            } label: {
                Image(systemName: playbackIsActuallyRunning ? "pause.fill" : "play.fill")
                    .font(.system(size: 18, weight: .black))
                    .foregroundColor(.black)
                    .frame(width: 46, height: 46)
                    .background(Color.white.opacity(0.94), in: RoundedRectangle(cornerRadius: 15, style: .continuous))
            }
            .buttonStyle(PremiumPressButtonStyle())

            VStack(alignment: .leading, spacing: 5) {
                if let episodeDisplayLine {
                    Text(episodeDisplayLine)
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundColor(.white.opacity(0.76))
                        .lineLimit(1)
                }
                Text(seriesDisplayName)
                    .font(.custom("HiRollivBold", fixedSize: 23))
                    .foregroundColor(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.68)
            }
            Spacer(minLength: 4)

            HStack(spacing: 8) {
                compactTransportButton("gobackward.10") { skipPlayback(by: -10) }
                compactTransportButton("goforward.10") { skipPlayback(by: 10) }
                if !episodeOptions.isEmpty {
                    Button {
                        showEpisodePicker = true
                        hideTask?.cancel()
                        hideTask = nil
                    } label: {
                        Image(systemName: "rectangle.stack.fill")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(.white)
                            .frame(width: 38, height: 38)
                            .background(Color.white.opacity(0.11), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.14), lineWidth: 0.7))
                    }
                    .buttonStyle(PremiumPressButtonStyle())
                    .popover(isPresented: $showEpisodePicker, arrowEdge: .bottom) {
                        PlayerEpisodePicker(options: episodeOptions, onSelect: { id in
                            showEpisodePicker = false; onSelectEpisode?(id)
                        }).playerPopoverAdaptation()
                    }
                }
            }
        }
    }

    private func compactTransportButton(_ systemName: String, action: @escaping () -> Void) -> some View {
        Button {
            action()
            scheduleAutoHide()
        } label: {
            Image(systemName: systemName)
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(.white)
                .frame(width: 38, height: 38)
                .background(Color.white.opacity(0.11), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.14), lineWidth: 0.7))
        }
        .buttonStyle(PremiumPressButtonStyle())
    }

    private func skipPlayback(by seconds: Double) {
        if usesMKVPlayer {
            mkvControls.skip(by: Int(seconds))
        } else if seconds < 0 {
            engine.skipBackward(seconds: abs(seconds))
        } else {
            engine.skipForward(seconds: seconds)
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

    private var detectedIntroMarker: IntroMarker? {
        engine.introMarker ?? IntroMarkerStore.marker(for: title)
    }

    private var shouldShowSkipIntro: Bool {
        guard let marker = detectedIntroMarker else { return false }
        return currentPlaybackSeconds >= marker.start && currentPlaybackSeconds < marker.end
    }

    private var mkvQualityLabel: String {
        if mkvControls.videoWidth >= 3840 || mkvControls.videoHeight >= 2160 { return "4K" }
        if mkvControls.videoWidth >= 1920 || mkvControls.videoHeight >= 1080 { return "1080P" }
        if mkvControls.videoWidth >= 1280 || mkvControls.videoHeight >= 720 { return "720P" }
        return "HD"
    }

    private var playbackChapters: [PlayerChapterMarker] {
        usesMKVPlayer ? [] : engine.chapters
    }

    private func skipIntro() {
        guard let marker = detectedIntroMarker, playbackDurationSeconds > 0 else { return }
        let fraction = min(1, max(0, marker.end / playbackDurationSeconds))
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

    private var playbackIsActuallyRunning: Bool {
        usesMKVPlayer ? mkvControls.isPlaying : engine.isPlaying
    }

    private var playbackIsBuffering: Bool {
        usesMKVPlayer ? mkvControls.isBuffering : engine.isBuffering
    }

    private func playbackRunningChanged(_ running: Bool) {
        hideTask?.cancel()
        if running {
            scheduleAutomaticSubtitleAfterFirstPlaybackSecond()
            // Start the eight-second chrome timeout from the first real playback
            // frame/rate, never from the moment the player screen was presented.
            showControls = true
            scheduleAutoHide()
        } else {
            // Pausing/buffering before the first full second cancels the arm
            // timer. Resuming starts a fresh continuous playback second.
            automaticSubtitleStartTask?.cancel()
            automaticSubtitleStartTask = nil
        }
        if !running, (usesMKVPlayer ? mkvControls.isBuffering : engine.isBuffering) {
            // Keep the controls available while a stream is still opening.
            showControls = true
        }
    }

    private func scheduleAutoHide() {
        hideTask?.cancel()
        guard !showPlaybackSettings, !showQuickSettings, !showEpisodePicker else {
            hideTask = nil
            return
        }
        guard showControls, playbackIsActuallyRunning else {
            // Before playback begins there is no auto-hide timer. This keeps the
            // controls available for as long as the stream is still opening.
            if (usesMKVPlayer ? mkvControls.isBuffering : engine.isBuffering) {
                showControls = true
            }
            return
        }
        hideTask = Task {
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            guard !Task.isCancelled, !isScrubbing,
                  !showPlaybackSettings, !showQuickSettings, !showEpisodePicker else { return }
            await MainActor.run {
                guard playbackIsActuallyRunning,
                      !showPlaybackSettings, !showQuickSettings, !showEpisodePicker else {
                    showControls = true
                    return
                }
                withAnimation(.easeInOut(duration: 0.25)) {
                    showControls = false
                    showQuickSettings = false
                    showEpisodePicker = false
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
    @Published var isBuffering = true
    @Published var networkSpeedBytesPerSecond: Double = 0
    @Published var audioTracks: [PlayerAudioTrackOption] = []
    @Published var subtitleTracks: [PlayerSubtitleTrackOption] = []
    @Published var selectedAudioTrackID: String?
    @Published var selectedSubtitleTrackID: String?
    weak var surface: MKVPlayerSurface?

    var displayProgress: Double { requestedProgress ?? progress }
    var currentTimeFormatted: String { formatTime(currentSeconds) }
    var durationFormatted: String { formatTime(durationSeconds) }
    func formattedTime(forFraction fraction: Double) -> String {
        formatTime(durationSeconds * min(1, max(0, fraction)))
    }

    func togglePlayback() { surface?.togglePlaybackFromControls() }
    func pause() { surface?.pauseForDismissal() }
    func seek(to fraction: Double) {
        let target = min(1, max(0, fraction))
        didReachEnd = false
        requestedProgress = target
        surface?.seek(to: target)
    }
    func updateProgress(_ value: Double) {
        progress = value
        if value > 0 { isBuffering = false }
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
    func updateNetworkSpeed(_ bytesPerSecond: Double) {
        networkSpeedBytesPerSecond = max(0, bytesPerSecond)
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
    func setMuted(_ muted: Bool) { surface?.setMuted(muted) }
    func selectAudioTrack(id: String) { surface?.selectAudioTrack(id: id) }
    func selectSubtitleTrack(id: String?) { surface?.selectSubtitleTrack(id: id) }
    func stop() { surface?.stop() }
    func applySubtitleStyle(fontSize: Double, fontName: String, color: Int, background: Bool, shadow: Bool, margin: Int, delay: Double) {
        surface?.applySubtitleStyle(fontSize: fontSize, fontName: fontName, color: color, background: background, shadow: shadow, margin: margin, delay: delay)
    }
    func updateEmbeddedTracks(
        audio: [PlayerAudioTrackOption],
        subtitles: [PlayerSubtitleTrackOption],
        selectedAudio: String?,
        selectedSubtitle: String?
    ) {
        audioTracks = audio
        subtitleTracks = subtitles
        selectedAudioTrackID = selectedAudio
        selectedSubtitleTrackID = selectedSubtitle
    }

    private func formatTime(_ seconds: Double) -> String {
        let total = max(0, Int(seconds))
        if total >= 3600 {
            return String(format: "%d:%02d:%02d", total / 3600, (total / 60) % 60, total % 60)
        }
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

private struct MKVVideoPlayerView: UIViewRepresentable {
    let url: URL
    let controls: MKVPlaybackControls
    var resumeAt: Double = 0
    var isFillMode = false
    var resetZoomToken = 0
    var httpHeaders: [String: String]? = nil
    let subtitleSize: Double
    let subtitleFontName: String
    let subtitleColorValue: Int
    let subtitleBackground: Bool
    let subtitleShadow: Bool
    let subtitleHeight: Int
    let subtitleDelay: Double
    let anchorEmbeddedSubtitlesToViewport: Bool
    var onSingleTap: (() -> Void)? = nil

    func makeUIView(context: Context) -> MKVPlayerSurface {
        let view = MKVPlayerSurface()
        view.controls = controls
        view.onSingleTap = onSingleTap
        view.setFillMode(isFillMode)
        view.setEmbeddedSubtitleViewportAnchoring(anchorEmbeddedSubtitlesToViewport)
        view.configureInitialSubtitleStyle(fontSize: subtitleSize, fontName: subtitleFontName, color: subtitleColorValue, background: subtitleBackground, shadow: subtitleShadow, margin: subtitleHeight, delay: subtitleDelay)
        view.play(url: url, resumeAt: resumeAt, httpHeaders: httpHeaders)
        return view
    }

    func updateUIView(_ uiView: MKVPlayerSurface, context: Context) {
        uiView.controls = controls
        uiView.onSingleTap = onSingleTap
        uiView.setFillMode(isFillMode)
        uiView.setEmbeddedSubtitleViewportAnchoring(anchorEmbeddedSubtitlesToViewport)
        uiView.resetZoomIfNeeded(token: resetZoomToken)
        uiView.applySubtitleStyle(
            fontSize: subtitleSize,
            fontName: subtitleFontName,
            color: subtitleColorValue,
            background: subtitleBackground,
            shadow: subtitleShadow,
            margin: subtitleHeight,
            delay: subtitleDelay
        )
        uiView.playIfNeeded(url: url, httpHeaders: httpHeaders)
    }

    static func dismantleUIView(_ uiView: MKVPlayerSurface, coordinator: ()) {
        uiView.stop()
    }
}

private final class MKVPlayerSurface: UIView, UIScrollViewDelegate {
    private let mediaPlayer = VLCMediaPlayer()
    private let scrollView = UIScrollView()
    private let videoView = UIView()
    private var currentURL: URL?
    private var currentHTTPHeaders: [String: String]?
    private var subtitleStyle = (fontSize: 24.0, fontName: "Helvetica Neue", color: 0xFFFFFF, background: true, shadow: true, margin: 0, delay: 0.0)
    private var loadingTimer: Timer?
    private var lastStatisticsBytes: Double?
    private var lastStatisticsSampleTime: TimeInterval?
    private var videoSize: CGSize = .zero
    private var sourceFormat = "Video"
    private var isFillMode = false
    private var anchorsEmbeddedSubtitlesToViewport = false
    private var resetZoomToken = 0
    private var embeddedTrackRefreshAttempts = 0
    private var didLoadEmbeddedTracks = false
    private var isStopped = true
    private var playbackGeneration: UInt64 = 0
    var onSingleTap: (() -> Void)?
    weak var controls: MKVPlaybackControls? {
        didSet { controls?.surface = self }
    }
    private lazy var tapGesture = UITapGestureRecognizer(target: self, action: #selector(togglePlayback))
    private lazy var doubleTapGesture = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))

    func configureInitialSubtitleStyle(fontSize: Double, fontName: String, color: Int, background: Bool, shadow: Bool, margin: Int, delay: Double) {
        subtitleStyle = (fontSize: fontSize, fontName: fontName, color: color, background: background, shadow: shadow, margin: margin, delay: delay)
    }

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
        mediaPlayer.drawable = videoView

    }

    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        scrollView.frame = bounds
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
        anchorEmbeddedSubtitlesIfNeeded()
        updateVideoRenderScale()
    }

    func play(url: URL, resumeAt: Double = 0, httpHeaders: [String: String]? = nil) {
        // Episode changes can reuse this UIView. Fully release the old VLC
        // drawable before replacing its media so the decoder/render thread can
        // never keep drawing into a surface whose media is being destroyed.
        if !isStopped {
            loadingTimer?.invalidate()
            loadingTimer = nil
            mediaPlayer.drawable = nil
            mediaPlayer.stop()
            mediaPlayer.media = nil
        }
        playbackGeneration &+= 1
        let generation = playbackGeneration
        isStopped = false
        currentURL = url
        currentHTTPHeaders = httpHeaders
        let extensionName = url.pathExtension.trimmingCharacters(in: .whitespacesAndNewlines)
        sourceFormat = extensionName.isEmpty ? "Video" : extensionName.uppercased()
        controls?.isBuffering = true
        controls?.updateNetworkSpeed(0)
        lastStatisticsBytes = nil
        lastStatisticsSampleTime = nil
        embeddedTrackRefreshAttempts = 0
        didLoadEmbeddedTracks = false
        controls?.updateEmbeddedTracks(audio: [], subtitles: [], selectedAudio: nil, selectedSubtitle: nil)
        let media = VLCMedia(url: url)
        if let authorization = httpHeaders?["Authorization"], authorization.lowercased().hasPrefix("basic ") {
            let encoded = String(authorization.dropFirst(6))
            if let data = Data(base64Encoded: encoded),
               let credentials = String(data: data, encoding: .utf8),
               let separator = credentials.firstIndex(of: ":") {
                media.addOption(":http-user=\(credentials[..<separator])")
                media.addOption(":http-pwd=\(credentials[credentials.index(after: separator)...])")
            }
        }
        if let userAgent = httpHeaders?["User-Agent"] { media.addOption(":http-user-agent=\(userAgent)") }
        if let referer = httpHeaders?["Referer"] ?? httpHeaders?["Referrer"] { media.addOption(":http-referrer=\(referer)") }
        let isPikPakStream = LinkResolver.isPikPakDirectDownload(url.absoluteString)
        // One second was too shallow for signed cloud URLs, especially 4K MKV
        // remuxes where every Range request pays CDN latency. Keep a larger
        // read-ahead for PikPak while retaining responsive startup elsewhere.
        media.addOption(":network-caching=\(isPikPakStream ? 6000 : 2500)")
        media.addOption(":http-reconnect")
        media.addOption(":file-caching=1000")
        media.addOption(":drop-late-frames")
        media.addOption(":freetype-font=\(subtitleStyle.fontName)")
        media.addOption(":sub-text-scale=\(vlcTextScale(for: subtitleStyle.fontSize))")
        media.addOption(":freetype-color=\(subtitleStyle.color)")
        media.addOption(":freetype-background-opacity=\(subtitleStyle.background ? 155 : 0)")
        media.addOption(":freetype-shadow-opacity=\(subtitleStyle.shadow ? 255 : 0)")
        media.addOption(":sub-margin=\(subtitleStyle.margin)")
        media.addOption(":spu-delay=\(Int(subtitleStyle.delay * 1_000_000))")
        media.addOption(":no-spu")
        mediaPlayer.drawable = videoView
        mediaPlayer.media = media
        mediaPlayer.play()
        mediaPlayer.currentVideoSubTitleIndex = -1
        applyCurrentSubtitleStyleToRenderer()
        if resumeAt > 3 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                guard let self, !self.isStopped, self.playbackGeneration == generation else { return }
                self.mediaPlayer.time = VLCTime(int: Int32(resumeAt * 1000))
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
            self.updateNetworkTelemetry()
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
            if self.mediaPlayer.isPlaying || currentTime > 0 || (size.width > 1 && size.height > 1) {
                self.controls?.isBuffering = false
                if !self.didLoadEmbeddedTracks && self.embeddedTrackRefreshAttempts < 30 {
                    self.embeddedTrackRefreshAttempts += 1
                    self.refreshEmbeddedTracks()
                }
            }
        }
    }

    private func updateNetworkTelemetry() {
        guard let media = mediaPlayer.media else { return }
        // MobileVLCKit 3.4.1b13 exposes the input byte counter directly. Newer
        // VLCKit headers wrap it in `statistics`, but that API is not present in
        // the binary version used by this project.
        let totalBytes = Double(max(0, media.numberOfReadBytesOnInput))
        let now = ProcessInfo.processInfo.systemUptime
        if let previousBytes = lastStatisticsBytes,
           let previousTime = lastStatisticsSampleTime,
           now > previousTime,
           totalBytes >= previousBytes {
            controls?.updateNetworkSpeed((totalBytes - previousBytes) / (now - previousTime))
        }
        lastStatisticsBytes = totalBytes
        lastStatisticsSampleTime = now
    }

    private func refreshEmbeddedTracks() {
        let audioNames = mediaPlayer.audioTrackNames.compactMap { $0 as? String }
        let audioIndexes = mediaPlayer.audioTrackIndexes.compactMap { ($0 as? NSNumber)?.int32Value }
        let audio = zip(audioIndexes, audioNames).map {
            PlayerAudioTrackOption(id: String($0.0), title: $0.1)
        }
        mediaPlayer.currentVideoSubTitleIndex = -1
        guard !audio.isEmpty else { return }
        didLoadEmbeddedTracks = true
        controls?.updateEmbeddedTracks(
            audio: audio,
            subtitles: [],
            selectedAudio: String(mediaPlayer.currentAudioTrackIndex),
            selectedSubtitle: nil
        )
    }

    func selectAudioTrack(id: String) {
        guard let index = Int32(id) else { return }
        mediaPlayer.currentAudioTrackIndex = index
        controls?.selectedAudioTrackID = id
    }

    func selectSubtitleTrack(id _: String?) {
        mediaPlayer.currentVideoSubTitleIndex = -1
        controls?.selectedSubtitleTrackID = nil
    }

    func applySubtitleStyle(fontSize: Double, fontName: String, color: Int, background: Bool, shadow: Bool, margin: Int, delay: Double) {
        let unchanged = subtitleStyle.fontSize == fontSize
            && subtitleStyle.fontName == fontName
            && subtitleStyle.color == color
            && subtitleStyle.background == background
            && subtitleStyle.shadow == shadow
            && subtitleStyle.margin == margin
            && subtitleStyle.delay == delay
        guard !unchanged else { return }

        subtitleStyle = (fontSize: fontSize, fontName: fontName, color: color, background: background, shadow: shadow, margin: margin, delay: delay)

        applyCurrentSubtitleStyleToRenderer()
    }

    private func applyCurrentSubtitleStyleToRenderer() {
        // VLCKit exposes these renderer setters at runtime on iOS. Applying
        // them to the existing media player changes the active subtitles in
        // place; restarting `play(url:)` here used to reopen the remote media,
        // rebuffer it and briefly lose the selected subtitle/audio tracks.
        performTextRendererSelector("setTextRendererFont:", value: subtitleStyle.fontName as NSString)
        performTextRendererSelector(
            "setTextRendererFontSize:",
            value: NSNumber(value: vlcTextScale(for: subtitleStyle.fontSize))
        )
        performTextRendererSelector("setTextRendererFontColor:", value: NSNumber(value: subtitleStyle.color))
        performTextRendererSelector("setTextRendererFontForceBold:", value: NSNumber(value: true))

        // This is a public live property and is measured in microseconds.
        mediaPlayer.currentVideoSubTitleDelay = Int(subtitleStyle.delay * 1_000_000)
    }

    /// MobileVLCKit expects the live subtitle size as a percentage where
    /// 100 is normal. Sending point values such as 24 or an inverse value
    /// such as 50 makes even the largest preset render at a tiny scale.
    private func vlcTextScale(for pointSize: Double) -> Int {
        let scale = pointSize / 24 * 100
        return Int(min(180, max(70, scale)).rounded())
    }

    private func performTextRendererSelector(_ name: String, value: AnyObject) {
        let selector = NSSelectorFromString(name)
        guard mediaPlayer.responds(to: selector) else { return }
        _ = mediaPlayer.perform(selector, with: value)
    }

    func playIfNeeded(url: URL, httpHeaders: [String: String]? = nil) {
        guard currentURL != url else { return }
        play(url: url, httpHeaders: httpHeaders)
    }

    func stop() {
        guard !isStopped else { return }
        isStopped = true
        playbackGeneration &+= 1
        loadingTimer?.invalidate()
        loadingTimer = nil
        onSingleTap = nil
        controls?.isBuffering = false
        controls?.isPlaying = false
        controls?.updateNetworkSpeed(0)
        if controls?.surface === self {
            controls?.surface = nil
        }
        controls = nil
        // Detach first. libVLC may still deliver a final video frame while stop()
        // tears down its decoder, so leaving the UIView attached here is a crash
        // window during SwiftUI dismissal/dismantling.
        mediaPlayer.drawable = nil
        mediaPlayer.stop()
        mediaPlayer.media = nil
        currentURL = nil
        currentHTTPHeaders = nil
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

    func setEmbeddedSubtitleViewportAnchoring(_ enabled: Bool) {
        guard anchorsEmbeddedSubtitlesToViewport != enabled else { return }
        anchorsEmbeddedSubtitlesToViewport = enabled
        guard enabled, isFillMode else { return }
        layoutIfNeeded()
        anchorEmbeddedSubtitlesIfNeeded()
    }

    private func anchorEmbeddedSubtitlesIfNeeded() {
        guard anchorsEmbeddedSubtitlesToViewport, isFillMode else { return }
        let inset = scrollView.adjustedContentInset
        let minY = -inset.top
        let maxY = max(minY, scrollView.contentSize.height - scrollView.bounds.height + inset.bottom)
        guard maxY > minY else { return }
        scrollView.contentOffset.y = maxY
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

    func pauseForDismissal() {
        guard mediaPlayer.isPlaying else { return }
        mediaPlayer.pause()
        controls?.isPlaying = false
    }

    func seek(to fraction: Double) {
        mediaPlayer.position = Float(min(1, max(0, fraction)))
    }

    func setRate(_ rate: Float) { mediaPlayer.rate = rate }

    func setMuted(_ muted: Bool) {
        mediaPlayer.audio?.isMuted = muted
    }

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
        if normalized.split(separator: "\n").contains(where: {
            $0.trimmingCharacters(in: .whitespaces).lowercased().hasPrefix("dialogue:")
        }) {
            return parseASS(normalized)
        }
        return parseTimedText(normalized)
    }

    private static func parseTimedText(_ source: String) -> [ExternalSubtitleCue] {
        source.components(separatedBy: "\n\n").compactMap { block in
            let lines = block.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            guard let timingIndex = lines.firstIndex(where: { $0.contains("-->") }) else { return nil }
            let times = lines[timingIndex].components(separatedBy: "-->")
            guard times.count == 2,
                  let start = time(times[0]),
                  let end = time(times[1]) else { return nil }
            let text = cleanText(lines.dropFirst(timingIndex + 1).joined(separator: "\n"))
            guard !text.isEmpty else { return nil }
            return ExternalSubtitleCue(start: start, end: end, text: text)
        }
        .sorted { $0.start < $1.start }
    }

    private static func parseASS(_ source: String) -> [ExternalSubtitleCue] {
        source.components(separatedBy: "\n").compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.lowercased().hasPrefix("dialogue:"),
                  let colon = trimmed.firstIndex(of: ":") else { return nil }
            let payload = trimmed[trimmed.index(after: colon)...]
            let fields = payload.split(separator: ",", maxSplits: 9, omittingEmptySubsequences: false)
            guard fields.count == 10,
                  let start = time(String(fields[1])),
                  let end = time(String(fields[2])) else { return nil }
            let text = cleanText(String(fields[9]))
            guard !text.isEmpty else { return nil }
            return ExternalSubtitleCue(start: start, end: end, text: text)
        }
        .sorted { $0.start < $1.start }
    }

    private static func cleanText(_ raw: String) -> String {
        raw
            .replacingOccurrences(of: #"\{[^}]*\}"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\N"#, with: "\n")
            .replacingOccurrences(of: #"\n"#, with: "\n")
            .replacingOccurrences(of: #"\h"#, with: " ")
            .replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
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

private struct PlayerLoadingReadout: View {
    let isLoading: Bool
    let bytesPerSecond: Double
    @State private var percent = 3
    @State private var isVisible = false
    @State private var countingTask: Task<Void, Never>?

    private var speedText: String {
        let speed = max(0, bytesPerSecond)
        if speed >= 1_000_000 { return String(format: "%.1f MB/s", speed / 1_000_000) }
        if speed >= 1_000 { return String(format: "%.0f KB/s", speed / 1_000) }
        return "0 KB/s"
    }

    var body: some View {
        HStack(spacing: 14) {
            Text(speedText)
                .font(.system(size: 18, weight: .bold, design: .rounded))
                .monospacedDigit()

            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                .fill(AppPalette.gradient)
                .frame(width: 7, height: 7)
                .rotationEffect(.degrees(45))
                .shadow(color: AppPalette.accent.opacity(0.75), radius: 5)

            Text("\(percent)%")
                .font(.system(size: 17, weight: .heavy, design: .rounded))
                .monospacedDigit()
        }
        .foregroundColor(.white)
        .shadow(color: .black.opacity(0.95), radius: 4, y: 2)
        .shadow(color: .black.opacity(0.72), radius: 12, y: 5)
        .opacity(isVisible ? 1 : 0)
        .scaleEffect(isVisible ? 1 : 0.94)
        .allowsHitTesting(false)
        .animation(.easeInOut(duration: 0.2), value: isVisible)
        .onAppear { updateLoadingState(isLoading) }
        .onChange(of: isLoading) { updateLoadingState($0) }
        .onDisappear { countingTask?.cancel() }
    }

    private func updateLoadingState(_ loading: Bool) {
        countingTask?.cancel()
        if loading {
            percent = 3
            isVisible = true
            countingTask = Task { @MainActor in
                while !Task.isCancelled, percent < 96 {
                    try? await Task.sleep(nanoseconds: 180_000_000)
                    guard !Task.isCancelled else { return }
                    percent = min(96, percent + max(1, (100 - percent) / 10))
                }
            }
        } else if isVisible {
            percent = 100
            countingTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 320_000_000)
                guard !Task.isCancelled else { return }
                isVisible = false
            }
        }
    }
}

private struct PlayerQualityBadge: View {
    let width: Int
    let height: Int
    var fallbackLabel: String? = nil

    private var badge: (resolution: String, className: String) {
        let longEdge = max(width, height)
        let shortEdge = min(width, height)

        if longEdge >= 7600 || shortEdge >= 4200 { return ("8K", "ULTRA HD") }
        if longEdge >= 5000 || shortEdge >= 2800 { return ("5K", "ULTRA HD") }
        if longEdge >= 3800 || shortEdge >= 2100 { return ("4K", "ULTRA HD") }
        if longEdge >= 2500 || shortEdge >= 1400 { return ("1440p", "QUAD HD") }
        if longEdge >= 1800 || shortEdge >= 1000 { return ("1080p", "FULL HD") }
        if longEdge >= 1200 || shortEdge >= 700 { return ("720p", "HD") }
        if longEdge >= 800 || shortEdge >= 460 { return ("480p", "HD") }
        if longEdge > 0 || shortEdge > 0 { return ("360p", "HD") }

        switch fallbackLabel?.uppercased() {
        case "4K": return ("4K", "ULTRA HD")
        case "FHD", "1080P": return ("1080p", "FULL HD")
        case "1440P", "QHD": return ("1440p", "QUAD HD")
        case "720P": return ("720p", "HD")
        default: return ("HD", "VIDEO")
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            Text(badge.resolution)
                .font(.custom("HiRollivBold", fixedSize: 11))
                .foregroundColor(.black)
                .padding(.horizontal, 7)
                .frame(height: 25)
                .background(Color.white.opacity(0.82))

            Text(badge.className)
                .font(.custom("HiRollivBold", fixedSize: 10))
                .tracking(0.35)
                .foregroundColor(.white)
                .padding(.horizontal, 8)
                .frame(height: 25)
                .background(Color.black.opacity(0.58))
        }
        .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .stroke(Color.white.opacity(0.68), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.42), radius: 6, y: 2)
        .accessibilityLabel("\(badge.resolution), \(badge.className)")
    }
}

enum PlayerSubtitleColor: String, CaseIterable, Identifiable {
    case white = "White"
    case yellow = "Yellow"
    case cyan = "Cyan"
    var id: String { rawValue }
    var color: Color {
        switch self { case .white: return .white; case .yellow: return .yellow; case .cyan: return .cyan }
    }
    var uiColor: UIColor {
        switch self { case .white: return .white; case .yellow: return .yellow; case .cyan: return .cyan }
    }
    var vlcColorValue: Int {
        switch self { case .white: return 0xFFFFFF; case .yellow: return 0xFFFF00; case .cyan: return 0x00FFFF }
    }
}

enum PlayerSubtitleFont: String, CaseIterable, Identifiable {
    case rounded = "Rounded"
    case standard = "Standard"
    case monospaced = "Monospaced"
    var id: String { rawValue }
    var design: Font.Design {
        switch self { case .rounded: return .rounded; case .standard: return .default; case .monospaced: return .monospaced }
    }
    var appleFontFamily: String {
        switch self { case .rounded: return "Arial Rounded MT Bold"; case .standard: return "Helvetica Neue"; case .monospaced: return "Menlo" }
    }
    var vlcFontName: String { appleFontFamily }
}

enum PlayerSubtitleTypeface {
    static let englishPostScriptName = "NunitoSans-SemiBold"
    static let englishFamilyName = "Nunito Sans"
    static let englishVLCFontName = "Nunito Sans SemiBold"
}

enum PlayerSubtitleSizing {
    /// 390 pt is the common modern iPhone width. Scaling from the viewport's
    /// short side keeps subtitle sizing stable in portrait and landscape.
    private static let referenceWidth: CGFloat = 390
    private static let minimumScale: CGFloat = 0.96
    private static let maximumScale: CGFloat = 1.13

    static func pointSize(base: Double, viewport: CGSize = UIScreen.main.bounds.size) -> Double {
        let shortSide = max(320, min(viewport.width, viewport.height))
        let screenScale = min(max(shortSide / referenceWidth, minimumScale), maximumScale)
        return base * Double(screenScale)
    }
}

private enum SubtitleLanguageDetector {
    static func isPredominantlyLatin(_ text: String) -> Bool {
        var latinLetters = 0
        var otherLetters = 0

        for scalar in text.unicodeScalars where CharacterSet.letters.contains(scalar) {
            switch scalar.value {
            case 0x0041...0x024F, 0x1E00...0x1EFF:
                latinLetters += 1
            default:
                otherLetters += 1
            }
        }

        return latinLetters > 0 && latinLetters >= otherLetters * 2
    }
}

private enum QuickSettingsPage { case main, speed, audio, subtitles }

struct PlayerEpisodeOption: Identifiable, Equatable {
    let id: String
    let title: String
    let subtitle: String
}

private struct PlayerEpisodePicker: View {
    let options: [PlayerEpisodeOption]
    let onSelect: (String) -> Void
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                Text("Episodes").font(.headline).padding(.bottom, 5)
                if options.isEmpty {
                    Text("No episodes available").font(.subheadline).foregroundColor(.secondary).padding(.vertical, 14)
                } else {
                    ForEach(options) { option in
                        Button { onSelect(option.id) } label: {
                            HStack { VStack(alignment: .leading, spacing: 2) { Text(option.title).font(.subheadline.bold()); Text(option.subtitle).font(.caption).foregroundColor(.secondary) }; Spacer(); Image(systemName: "play.fill") }
                                .foregroundColor(.primary).padding(9)
                        }
                    }
                }
            }.padding(10)
        }.frame(width: 230).frame(maxHeight: 310)
    }
}

private extension View {
    @ViewBuilder
    func playerPopoverAdaptation() -> some View {
        if #available(iOS 16.4, *) {
            self.presentationCompactAdaptation(.popover)
        } else {
            self
        }
    }
}

private struct PlayerQuickSettingsPanel: View {
    let audioTracks: [PlayerAudioTrackOption]
    let selectedAudioTrackID: String?
    let subtitleFileName: String?
    @Binding var selectedSpeed: Float
    let onRateChange: (Float) -> Void
    let onAudioTrackChange: (String) -> Void
    let onSearchSubtitles: () -> Void
    let onChooseSubtitleFile: () -> Void
    let onAdvanced: () -> Void
    @State private var page: QuickSettingsPage = .main

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(AppPalette.accent)
                    .frame(width: 34, height: 34)
                    .background(Color.white.opacity(0.09), in: Circle())

                VStack(alignment: .leading, spacing: 2) {
                    Text(page == .main ? "Playback Controls" : pageTitle)
                        .font(.system(size: 17, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                    Text(page == .main ? "Video and audio options" : "Choose an option")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(Color.white.opacity(0.55))
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 7)
            .padding(.bottom, 11)

            Divider().overlay(Color.white.opacity(0.12))
                .padding(.bottom, 5)

            if page == .main {
                mainMenu
            } else {
                submenu
                    .frame(maxHeight: submenuHeight, alignment: .top)
            }
        }
        .frame(width: min(330, UIScreen.main.bounds.width - 54))
        .padding(13)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 25, style: .continuous))
        .background(Color.black.opacity(0.54), in: RoundedRectangle(cornerRadius: 25, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 25, style: .continuous)
                .stroke(Color.white.opacity(0.18), lineWidth: 0.8)
        }
        .shadow(color: .black.opacity(0.65), radius: 30, y: 14)
    }

    private var submenuHeight: CGFloat {
        min(330, max(190, UIScreen.main.bounds.height * 0.48))
    }

    private var pageTitle: String {
        switch page {
        case .speed: return "Playback Speed"
        case .audio: return "Audio Track"
        case .subtitles: return "Subtitles"
        case .main: return "Playback Controls"
        }
    }

    private var mainMenu: some View {
        VStack(spacing: 0) {
            row("Playback Speed", icon: "speedometer", value: selectedSpeed == 1 ? "Normal" : "\(selectedSpeed)×") { page = .speed }
            row("Audio", icon: "music.note", value: selectedAudioTitle) { page = .audio }
            row("Subtitles", icon: "captions.bubble.fill", value: selectedSubtitleTitle) { page = .subtitles }
            Divider().overlay(Color.white.opacity(0.12)).padding(.vertical, 5)
            row("Advanced Options", icon: "gearshape.fill", value: nil, action: onAdvanced)
        }
    }

    @ViewBuilder private var submenu: some View {
        VStack(alignment: .leading, spacing: 5) {
            Button { page = .main } label: {
                Label("Back", systemImage: "chevron.left")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white)
            }
            .padding(.bottom, 5)
            Divider().overlay(Color.white.opacity(0.12))
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 5) {
                    submenuChoices
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 2)
            }
        }
    }

    @ViewBuilder private var submenuChoices: some View {
        switch page {
        case .speed:
            ForEach([0.25, 0.5, 0.75, 1, 1.25, 1.5, 1.75, 2], id: \.self) { value in
                choice(value == 1 ? "Normal" : String(format: "%g×", value), selected: selectedSpeed == Float(value)) {
                    selectedSpeed = Float(value); onRateChange(Float(value))
                }
            }
        case .audio:
            if audioTracks.count > 1 {
                ForEach(audioTracks) { track in
                    choice(track.title, selected: selectedAudioTrackID == track.id) { onAudioTrackChange(track.id) }
                }
            } else {
                Text("One audio track").foregroundColor(Color.white.opacity(0.58)).padding(10)
            }
        case .subtitles:
            submenuAction(
                "Search Online",
                subtitle: "Find a subtitle using this video's metadata",
                icon: "magnifyingglass",
                action: onSearchSubtitles
            )
            submenuAction(
                "Choose File",
                subtitle: "Open a subtitle stored on this device",
                icon: "doc.badge.plus",
                action: onChooseSubtitleFile
            )
        case .main:
            EmptyView()
        }
    }

    private var selectedAudioTitle: String {
        audioTracks.first(where: { $0.id == selectedAudioTrackID })?.title ?? "Original"
    }

    private var selectedSubtitleTitle: String {
        subtitleFileName ?? "Search or choose file"
    }

    private func row(_ title: String, icon: String, value: String?, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 34, height: 34)
                    .foregroundColor(AppPalette.accent)
                    .background(Color.white.opacity(0.075), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                Text(title).font(.system(size: 14, weight: .semibold)).foregroundColor(.white)
                Spacer()
                if let value {
                    Text(value)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundColor(Color.white.opacity(0.5))
                        .lineLimit(1)
                        .frame(maxWidth: 105, alignment: .trailing)
                }
                Image(systemName: "chevron.right")
                    .font(.caption.bold())
                    .foregroundColor(Color.white.opacity(0.38))
            }
            .padding(.horizontal, 7)
            .frame(height: 47)
            .contentShape(Rectangle())
        }
        .buttonStyle(PremiumPressButtonStyle())
    }

    private func choice(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 11) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selected ? AppPalette.accent : Color.white.opacity(0.24))
                    .frame(width: 20)
                Text(title).lineLimit(1)
                Spacer()
            }
            .font(.system(size: 13.5, weight: selected ? .semibold : .medium))
            .foregroundColor(.white)
            .padding(.horizontal, 8)
            .frame(height: 39)
            .background(selected ? Color.white.opacity(0.08) : Color.clear, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(PremiumPressButtonStyle())
    }

    private func submenuAction(
        _ title: String,
        subtitle: String,
        icon: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(AppPalette.accent)
                    .frame(width: 38, height: 38)
                    .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 11, style: .continuous))

                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                    Text(subtitle)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(Color.white.opacity(0.5))
                        .lineLimit(1)
                }

                Spacer(minLength: 4)
                Image(systemName: "chevron.right")
                    .font(.caption.bold())
                    .foregroundStyle(Color.white.opacity(0.38))
            }
            .padding(.horizontal, 7)
            .frame(height: 52)
            .contentShape(Rectangle())
        }
        .buttonStyle(PremiumPressButtonStyle())
    }
}

private struct SubtitleSizePreset: Identifiable {
    let id: String
    let title: String
    let value: Double
}

private struct PlayerAdvancedSettingsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var selectedAudioTrack: String
    @Binding var subtitleSize: Double
    @Binding var subtitleColor: PlayerSubtitleColor
    @Binding var subtitleDelay: Double
    @Binding var subtitleHeight: Double
    @Binding var subtitleShadow: Bool
    @Binding var subtitleBackground: Bool
    @Binding var subtitleFont: PlayerSubtitleFont
    @Binding var brightness: Double
    let mediaTitle: String
    let mediaContext: SubtitleMediaContext?
    let audioTracks: [PlayerAudioTrackOption]
    let selectedAudioTrackID: String?
    let isFillMode: Bool
    let onAspectRatioToggle: () -> Void
    let onBrightnessChange: (Double) -> Void
    let onAudioTrackChange: (String) -> Void
    let onRateChange: (Float) -> Void
    let onSubtitleSelected: (DownloadedSubtitle) -> Bool
    @State private var section = 2
    @State private var showSubtitleSearch = false

    private let subtitleSizes: [SubtitleSizePreset] = [
        SubtitleSizePreset(id: "very-small", title: "Very Small", value: 18),
        SubtitleSizePreset(id: "small", title: "Small", value: 21),
        SubtitleSizePreset(id: "medium", title: "Medium", value: 24),
        SubtitleSizePreset(id: "large", title: "Large", value: 28),
        SubtitleSizePreset(id: "very-large", title: "Very Large", value: 34)
    ]

    private var selectedSubtitleSizePresetID: String? {
        subtitleSizes.min {
            abs($0.value - subtitleSize) < abs($1.value - subtitleSize)
        }?.id
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                LinearGradient(
                    colors: [AppPalette.accent.opacity(0.18), .clear, Color.blue.opacity(0.08)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ).ignoresSafeArea()

                VStack(spacing: 0) {
                    sectionPicker.padding(.horizontal, 18).padding(.bottom, 10)
                    ScrollView(showsIndicators: false) {
                        VStack(spacing: 14) {
                            if section == 0 { videoSection }
                            else if section == 1 { audioSection }
                            else { subtitleSection }
                        }
                        .padding(.horizontal, 18)
                        .padding(.vertical, 12)
                        .padding(.bottom, 36)
                    }
                }
            }
            .navigationTitle("Advanced")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    AppAnimatedBackButton(size: 36) { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(AppPalette.accent)
                }
            }
            .toolbarColorScheme(.dark, for: .navigationBar)
        }
        .preferredColorScheme(.dark)
        .fullScreenCover(isPresented: $showSubtitleSearch) {
            SubtitleSearchView(
                mediaTitle: mediaTitle,
                mediaContext: mediaContext,
                onSubtitleSelected: onSubtitleSelected
            )
        }
    }

    private var sectionPicker: some View {
        HStack(spacing: 7) {
            sectionButton("Video", icon: "play.rectangle.fill", value: 0)
            sectionButton("Audio", icon: "waveform", value: 1)
            sectionButton("Subtitles", icon: "captions.bubble.fill", value: 2)
        }
        .padding(5)
        .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func sectionButton(_ title: String, icon: String, value: Int) -> some View {
        Button { withAnimation(.easeInOut(duration: 0.2)) { section = value } } label: {
            Label(title, systemImage: icon)
                .font(.system(size: 12, weight: .semibold))
                .frame(maxWidth: .infinity)
                .frame(height: 38)
                .foregroundStyle(section == value ? Color.white : Color.white.opacity(0.55))
                .background(section == value ? AppPalette.diagonalGradient : LinearGradient(colors: [.clear, .clear], startPoint: .leading, endPoint: .trailing),
                            in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private var videoSection: some View {
        VStack(spacing: 14) {
            card("Brightness", icon: "sun.max.fill") {
                Slider(value: Binding(get: { brightness }, set: { brightness = $0; onBrightnessChange($0) }), in: 0.05...1)
                    .tint(AppPalette.accent)
            }
            card("Aspect Ratio", icon: "aspectratio.fill") {
                optionRow(isFillMode ? "Fill Screen" : "Fit to Screen", detail: "Tap to change", selected: true, action: onAspectRatioToggle)
            }
            card("Playback Speed", icon: "speedometer") { speedButtons }
        }
    }

    private var audioSection: some View {
        card("Audio Track", icon: "music.note") {
            if audioTracks.count > 1 {
                ForEach(audioTracks) { track in
                    optionRow(track.title, detail: nil,
                              selected: (selectedAudioTrack.isEmpty ? selectedAudioTrackID : selectedAudioTrack) == track.id) {
                        selectedAudioTrack = track.id
                        onAudioTrackChange(track.id)
                    }
                }
            } else {
                emptyState("This video has one audio track", icon: "speaker.wave.2")
            }
        }
    }

    private var subtitleSection: some View {
        VStack(spacing: 14) {
            card("Online Subtitles", icon: "magnifyingglass") {
                Button { showSubtitleSearch = true } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "magnifyingglass.circle.fill")
                            .font(.system(size: 25))
                            .foregroundStyle(AppPalette.accent)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Find Subtitles").font(.system(size: 14, weight: .bold))
                            Text("Search and apply a subtitle without leaving the player")
                                .font(.caption).foregroundStyle(.white.opacity(0.48))
                        }
                        Spacer()
                        Image(systemName: "chevron.right").font(.caption.bold()).foregroundStyle(.white.opacity(0.35))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12).frame(minHeight: 58)
                    .background(Color.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 14))
                }
                .buttonStyle(.plain)
            }
            subtitlePreview
            card("Font", icon: "textformat") {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 9) {
                    ForEach(PlayerSubtitleFont.allCases) { font in
                        choiceTile(font.rawValue, selected: subtitleFont == font) { subtitleFont = font }
                    }
                }
            }
            card("Font Size", icon: "textformat.size") {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 2), spacing: 8) {
                    ForEach(subtitleSizes) { preset in
                        sizePresetButton(
                            preset.title,
                            selected: selectedSubtitleSizePresetID == preset.id
                        ) {
                            subtitleSize = preset.value
                        }
                    }
                }
            }
            card("Text Style", icon: "paintpalette.fill") {
                HStack(spacing: 12) {
                    ForEach(PlayerSubtitleColor.allCases) { color in
                        Button { subtitleColor = color } label: {
                            Circle().fill(color.color).frame(width: 34, height: 34)
                                .overlay(Circle().stroke(Color.white, lineWidth: subtitleColor == color ? 3 : 0))
                                .overlay(Circle().stroke(Color.black.opacity(0.5), lineWidth: 1).padding(3))
                        }.buttonStyle(.plain)
                    }
                    Spacer()
                }
                toggleRow("Text Shadow", icon: "circle.lefthalf.filled", isOn: $subtitleShadow)
                toggleRow("Background", icon: "rectangle.fill", isOn: $subtitleBackground)
            }
            card("Timing", icon: "clock.arrow.circlepath") {
                numericStepper("Subtitle Delay", value: subtitleDelay, display: String(format: "%+.2f s", subtitleDelay)) {
                    subtitleDelay = max(-10, subtitleDelay - 0.25)
                } increment: {
                    subtitleDelay = min(10, subtitleDelay + 0.25)
                }
                numericStepper("Vertical Position", value: subtitleHeight, display: "\(Int(subtitleHeight)) pt") {
                    subtitleHeight = max(0, subtitleHeight - 5)
                } increment: {
                    subtitleHeight = min(180, subtitleHeight + 5)
                }
            }
        }
    }

    private var subtitlePreview: some View {
        let previewSize = PlayerSubtitleSizing.pointSize(base: subtitleSize)
        return ZStack {
            LinearGradient(colors: [Color.indigo.opacity(0.55), Color.black], startPoint: .topLeading, endPoint: .bottomTrailing)
            VStack(spacing: 3) {
                Text("English subtitle preview")
                    .font(.custom(PlayerSubtitleTypeface.englishPostScriptName, fixedSize: CGFloat(previewSize)))
                Text("مرحباً، ستظهر الترجمة العربية بشكل صحيح")
                    .font(.system(size: previewSize, weight: .semibold, design: subtitleFont.design))
            }
                .foregroundStyle(subtitleColor.color)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 12).padding(.vertical, 7)
                .background(subtitleBackground ? Color.black.opacity(0.58) : .clear, in: RoundedRectangle(cornerRadius: 8))
                .shadow(color: subtitleShadow ? .black : .clear, radius: 4)
                .padding(16)
        }
        .frame(height: 126)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22).stroke(Color.white.opacity(0.1)))
    }

    private var speedButtons: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
            ForEach([0.5, 1.0, 1.25, 1.5, 2.0], id: \.self) { speed in
                Button("\(speed, specifier: "%g")×") { onRateChange(Float(speed)) }
                    .buttonStyle(PlayerSettingsChipStyle())
            }
        }
    }

    private func card<Content: View>(_ title: String, icon: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(title, systemImage: icon)
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(Color.white)
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.075), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20).stroke(Color.white.opacity(0.08)))
    }

    private func optionRow(_ title: String, detail: String?, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 11) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 14, weight: .medium)).foregroundStyle(.white).lineLimit(2)
                    if let detail { Text(detail).font(.caption).foregroundStyle(.white.opacity(0.45)) }
                }
                Spacer()
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selected ? AppPalette.accent : Color.white.opacity(0.22))
            }
            .padding(.horizontal, 12).frame(minHeight: 48)
            .background(Color.white.opacity(selected ? 0.09 : 0.035), in: RoundedRectangle(cornerRadius: 13))
        }.buttonStyle(.plain)
    }

    private func choiceTile(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack { Text(title); Spacer(); if selected { Image(systemName: "checkmark") } }
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(selected ? Color.white : Color.white.opacity(0.62))
                .padding(.horizontal, 12).frame(height: 44)
                .background(selected ? AppPalette.accent.opacity(0.3) : Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(selected ? AppPalette.accent : .clear))
        }.buttonStyle(.plain)
    }

    private func sizePresetButton(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(size: 13, weight: .bold, design: .rounded))
                .frame(maxWidth: .infinity).frame(height: 40)
                .foregroundStyle(selected ? Color.white : Color.white.opacity(0.55))
                .background(selected ? AppPalette.diagonalGradient : LinearGradient(colors: [.clear, .clear], startPoint: .leading, endPoint: .trailing), in: RoundedRectangle(cornerRadius: 11))
                .overlay(RoundedRectangle(cornerRadius: 11).stroke(Color.white.opacity(selected ? 0.18 : 0.06)))
        }.buttonStyle(.plain)
    }

    private func toggleRow(_ title: String, icon: String, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) { Label(title, systemImage: icon).font(.system(size: 14, weight: .medium)) }
            .tint(AppPalette.accent)
            .padding(.top, 4)
    }

    private func numericStepper(_ title: String, value: Double, display: String, decrement: @escaping () -> Void, increment: @escaping () -> Void) -> some View {
        HStack {
            Text(title).font(.system(size: 14, weight: .medium))
            Spacer()
            Button(action: decrement) { Image(systemName: "minus").frame(width: 34, height: 34) }
            Text(display).font(.system(size: 13, weight: .bold, design: .monospaced)).frame(width: 78)
            Button(action: increment) { Image(systemName: "plus").frame(width: 34, height: 34) }
        }
        .foregroundStyle(.white)
        .buttonStyle(.plain)
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 13))
    }

    private func emptyState(_ text: String, icon: String) -> some View {
        Label(text, systemImage: icon).font(.subheadline).foregroundStyle(.white.opacity(0.5)).padding(.vertical, 12)
    }
}

private struct PlayerSettingsChipStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .bold, design: .rounded))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity).frame(height: 40)
            .background(Color.white.opacity(configuration.isPressed ? 0.16 : 0.07), in: RoundedRectangle(cornerRadius: 11))
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
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
    var chapters: [PlayerChapterMarker] = []
    let onSeek: (Double) -> Void
    let onScrubbing: (Double, Bool) -> Void
    @State private var draggedValue: Double?

    private func nearestChapter(to progress: Double) -> PlayerChapterMarker? {
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
    var anchorEmbeddedSubtitlesToViewport = false
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
        lhs.videoSize == rhs.videoSize &&
        lhs.anchorEmbeddedSubtitlesToViewport == rhs.anchorEmbeddedSubtitlesToViewport
    }

    func makeUIView(context: Context) -> ZoomablePlayerSurface {
        let view = ZoomablePlayerSurface(player: player)
        view.onSingleTap = onSingleTap
        view.onInteractionChange = onInteractionChange
        view.onDoubleTap = onDoubleTap
        view.updateVideoSize(videoSize)
        view.setEmbeddedSubtitleViewportAnchoring(anchorEmbeddedSubtitlesToViewport)
        view.setFillMode(isFillMode)
        return view
    }

    func updateUIView(_ view: ZoomablePlayerSurface, context: Context) {
        view.updatePlayer(player)
        view.onSingleTap = onSingleTap
        view.onInteractionChange = onInteractionChange
        view.onDoubleTap = onDoubleTap
        view.updateVideoSize(videoSize)
        view.setEmbeddedSubtitleViewportAnchoring(anchorEmbeddedSubtitlesToViewport)
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

    // An orientation geometry update can temporarily dismantle this view.
    // The engine owns actual teardown; detaching here leaves audio playing
    // while the AVPlayerLayer has no video output after rotation.
    static func dismantleUIView(_ view: ZoomablePlayerSurface, coordinator: Coordinator) {
        view.prepareForTemporaryRemoval()
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
    private weak var attachedPlayer: AVPlayer?
    private var doubleTap: UITapGestureRecognizer!
    private var singleTap: UITapGestureRecognizer!
    private var videoSize: CGSize = .zero
    private var isFillMode = false
    private var anchorsEmbeddedSubtitlesToViewport = false
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

        attachedPlayer = player
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
            if anchorsEmbeddedSubtitlesToViewport {
                scrollView.contentOffset = bottomAlignedOffset()
                clampOffset()
            }
        }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil, playerLayer.player == nil, let attachedPlayer else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerLayer.player = attachedPlayer
        playerLayer.frame = contentView.bounds
        CATransaction.commit()
    }

    func updatePlayer(_ player: AVPlayer) {
        attachedPlayer = player
        if playerLayer.player !== player { playerLayer.player = player }
    }

    func prepareForTemporaryRemoval() {
        if reportedInteracting {
            reportedInteracting = false
            onInteractionChange?(false)
        }
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

    func setEmbeddedSubtitleViewportAnchoring(_ enabled: Bool) {
        guard anchorsEmbeddedSubtitlesToViewport != enabled else { return }
        anchorsEmbeddedSubtitlesToViewport = enabled
        guard isFillMode else { return }
        scrollView.contentOffset = enabled ? bottomAlignedOffset() : centeredOffset()
        clampOffset()
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
        scrollView.contentOffset = anchorsEmbeddedSubtitlesToViewport && isFillMode
            ? bottomAlignedOffset()
            : centeredOffset()
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

    private func bottomAlignedOffset() -> CGPoint {
        let centered = centeredOffset()
        let zoom = scrollView.zoomScale
        let displayed = displayedVideoSize()
        let boundsSize = scrollView.bounds.size
        let marginY = max(0, (contentView.bounds.height - displayed.height) / 2) * zoom
        let maxY = max(0, marginY + displayed.height * zoom - boundsSize.height)
        return CGPoint(x: centered.x, y: maxY)
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
    var subtitleMediaContext: SubtitleMediaContext? = nil
    var resumeAt: Double = 0
    var linkId: UUID? = nil
    var httpHeaders: [String: String]? = nil
    var episodeOptions: [PlayerEpisodeOption] = []
    var onSelectEpisode: ((String) -> Void)? = nil
    var onProgress: ((Double, Double, Int, Int) -> Void)? = nil

    init(url: URL, title: String, subtitleMediaContext: SubtitleMediaContext? = nil, resumeAt: Double = 0, linkId: UUID? = nil, httpHeaders: [String: String]? = nil, episodeOptions: [PlayerEpisodeOption] = [], onSelectEpisode: ((String) -> Void)? = nil, onProgress: ((Double, Double, Int, Int) -> Void)? = nil) {
        self.url = url; self.title = title; self.resumeAt = resumeAt; self.linkId = linkId
        self.subtitleMediaContext = subtitleMediaContext
        self.httpHeaders = httpHeaders; self.onProgress = onProgress
        self.episodeOptions = episodeOptions; self.onSelectEpisode = onSelectEpisode
    }

    var body: some View {
        VideoPlayerView(url: url, title: title, subtitleMediaContext: subtitleMediaContext, resumeAt: resumeAt, linkId: linkId, httpHeaders: httpHeaders, episodeOptions: episodeOptions, onSelectEpisode: onSelectEpisode, onProgress: onProgress)
    }

}
