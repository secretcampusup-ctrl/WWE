import SwiftUI
import AVFoundation
import UIKit

@MainActor
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        VideoThumbnailLoader.logDiagnostic("========== APP LAUNCH ==========", level: .info)
        // Must happen before this method returns, per BGTaskScheduler requirements.
        PikPakAutoSyncManager.shared.registerBackgroundTask()
        return true
    }

    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        if identifier == VideoDownloadManager.sessionIdentifier {
            VideoDownloadManager.shared
                .setBackgroundEventsCompletionHandler(completionHandler)
        } else {
            BackgroundVideoCacheManager.shared
                .setBackgroundEventsCompletionHandler(completionHandler)
        }
    }

    func application(
        _ application: UIApplication,
        supportedInterfaceOrientationsFor window: UIWindow?
    ) -> UIInterfaceOrientationMask {
        ScreenOrientationLock.allowedOrientations
    }
}

@MainActor
enum ScreenOrientationLock {
    static var allowedOrientations: UIInterfaceOrientationMask = .allButUpsideDown

    @discardableResult
    static func lockToCurrentOrientation() -> Bool {
        guard let scene = activeScene else { return false }

        switch scene.interfaceOrientation {
        case .portrait:
            allowedOrientations = .portrait
        case .portraitUpsideDown:
            allowedOrientations = .portraitUpsideDown
        case .landscapeLeft:
            allowedOrientations = .landscapeLeft
        case .landscapeRight:
            allowedOrientations = .landscapeRight
        default:
            allowedOrientations = scene.screen.bounds.width > scene.screen.bounds.height
                ? .landscape
                : .portrait
        }

        apply(allowedOrientations, to: scene)
        return true
    }

    static func unlock() {
        allowedOrientations = .allButUpsideDown
        guard let scene = activeScene else { return }
        apply(allowedOrientations, to: scene)
    }

    private static var activeScene: UIWindowScene? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
    }

    private static func apply(_ orientations: UIInterfaceOrientationMask, to scene: UIWindowScene) {
        scene.windows.first(where: \.isKeyWindow)?
            .rootViewController?
            .setNeedsUpdateOfSupportedInterfaceOrientations()
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: orientations)) { _ in }
    }
}

@main
struct VideoPlayerApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    init() {
        ThumbnailPipeline.configure()
        BackgroundVideoCacheManager.shared.cancelAllPrefetches()
        VideoDownloadManager.shared.activate()
        PikPakAutoSyncManager.shared.activate()
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(
            .playback,
            mode: .moviePlayback,
            options: [.allowAirPlay, .allowBluetoothA2DP]
        )
        try? session.setActive(true)
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .preferredColorScheme(.dark)
        }
    }
}
