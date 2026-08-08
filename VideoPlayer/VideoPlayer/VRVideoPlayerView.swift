import SwiftUI
import UIKit
import CoreMotion
import MobileVLCKit

struct RoutedVideoPlayerView: View {
    let url: URL
    let title: String
    var resumeAt: Double = 0
    var linkId: UUID? = nil
    var httpHeaders: [String: String]? = nil
    var onProgress: ((Double, Double, Int, Int) -> Void)? = nil

    var body: some View {
        if Self.isVRVideo(url: url, title: title) {
            DedicatedVRPlayerView(url: url, title: title, resumeAt: resumeAt, httpHeaders: httpHeaders, onProgress: onProgress)
        } else {
            VideoPlayerView(url: url, title: title, resumeAt: resumeAt, linkId: linkId, httpHeaders: httpHeaders, onProgress: onProgress)
        }
    }

    private static func isVRVideo(url: URL, title: String) -> Bool {
        let raw = (title + " " + url.lastPathComponent).lowercased()
        let normalized = raw.replacingOccurrences(of: ".", with: " ").replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: "-", with: " ")
        let tokens = Set(normalized.split { !$0.isLetter && !$0.isNumber }.map(String.init))
        if !tokens.isDisjoint(with: ["vr", "360", "360vr", "equirectangular", "spherical", "sbs", "ou", "180vr"]) { return true }
        return raw.contains("side-by-side") || raw.contains("top-bottom") || raw.contains("projection=360")
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
                            Text("VR 360 · \(controller.resolutionLabel)").font(.caption).foregroundStyle(.green)
                        }
                        Spacer()
                        Image(systemName: "view.3d").font(.system(size: 17, weight: .semibold)).foregroundStyle(.green)
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
                        Slider(value: Binding(get: { controller.progress }, set: { controller.seek($0) }), in: 0...1).tint(.green)
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

    var resolutionLabel: String { videoWidth > 0 ? "\(videoWidth)×\(videoHeight)" : "Loading" }
    var currentLabel: String { Self.time(currentSeconds) }
    var durationLabel: String { Self.time(durationSeconds) }
    func toggle() { surface?.toggle() }
    func skip(_ seconds: Double) { surface?.skip(seconds) }
    func seek(_ value: Double) { surface?.seek(value) }
    func stop() { surface?.stop() }

    func update(playing: Bool, buffering: Bool, position: Double, current: Double, duration: Double, size: CGSize) {
        isPlaying = playing; isBuffering = buffering; progress = min(1, max(0, position))
        currentSeconds = current; durationSeconds = duration
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
        addSubview(videoView)
        let tap = UITapGestureRecognizer(target: self, action: #selector(tapped))
        let pan = UIPanGestureRecognizer(target: self, action: #selector(panned(_:)))
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(pinched(_:)))
        tap.require(toFail: pan); addGestureRecognizer(tap); addGestureRecognizer(pan); addGestureRecognizer(pinch)
        player.drawable = videoView
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layoutSubviews() { super.layoutSubviews(); videoView.frame = bounds; player.drawable = videoView }

    func play(url: URL, resumeAt: Double, headers: [String: String]?) {
        guard currentURL != url else { return }
        currentURL = url
        let media = VLCMedia(url: url)
        media.addOption(":projection-mode=1")
        media.addOption(":avcodec-hw=none")
        media.addOption(":network-caching=2500")
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
    func stop() { motion.stopDeviceMotionUpdates(); timer?.invalidate(); player.stop(); player.drawable = nil }
}