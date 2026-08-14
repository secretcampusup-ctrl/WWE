import SwiftUI
import AVFoundation
import UIKit

@MainActor
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
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
    static var allowedOrientations: UIInterfaceOrientationMask = .portrait

    static var isInterfacePortrait: Bool {
        guard let orientation = activeScene?.interfaceOrientation else { return false }
        return orientation == .portrait || orientation == .portraitUpsideDown
    }

    @discardableResult
    static func lockToCurrentOrientation() -> Bool {
        guard let scene = activeScene else { return false }
        allowedOrientations = .portrait
        apply(allowedOrientations, to: scene)
        return true
    }

    static func unlock() {
        // Outside the player the app always returns to portrait.
        allowedOrientations = .portrait
        guard let scene = activeScene else { return }
        apply(allowedOrientations, to: scene)
    }

    static func setPlayerLandscape(_ landscape: Bool) {
        allowedOrientations = landscape ? .landscapeRight : .portrait
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
        // Keep scrolling enabled everywhere but remove the thin iOS indicators
        // that flash along the screen edges while a ScrollView/List is moving.
        UIScrollView.appearance().showsVerticalScrollIndicator = false
        UIScrollView.appearance().showsHorizontalScrollIndicator = false
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
                .scrollIndicators(.hidden)
        }
    }
}
