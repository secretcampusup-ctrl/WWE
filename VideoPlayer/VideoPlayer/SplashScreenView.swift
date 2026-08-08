import SwiftUI

/// Root wrapper: shows the animated splash first, then cross-fades into the
/// real app. Keeping this as a tiny separate view (instead of stuffing the
/// flag into VideoPlayerApp) means the splash timing/transition can be tuned
/// here without touching the app entry point.
struct RootView: View {
    @State private var showSplash = true

    var body: some View {
        ZStack {
            if showSplash {
                SplashScreenView {
                    withAnimation(.easeInOut(duration: 0.55)) {
                        showSplash = false
                    }
                }
                .transition(
                    .asymmetric(
                        insertion: .identity,
                        removal: .opacity.combined(with: .scale(scale: 1.06))
                    )
                )
                .zIndex(1)
            } else {
                MainTabView()
                    .transition(.opacity)
            }
        }
    }
}

/// Professional animated splash: pulsing glow, a spring-in app mark, a
/// gradient wordmark, a slim loading bar, then the developer credit.
/// Everything is timed off a single `onAppear` so the sequence always plays
/// the same way regardless of device speed.
private struct SplashScreenView: View {
    let onFinished: () -> Void

    // Entrance state
    @State private var glowScale: CGFloat = 0.6
    @State private var glowOpacity: Double = 0
    @State private var ringScale: CGFloat = 0.7
    @State private var ringOpacity: Double = 0
    @State private var markScale: CGFloat = 0.4
    @State private var markOpacity: Double = 0
    @State private var markRotation: Double = -14
    @State private var titleOffset: CGFloat = 14
    @State private var titleOpacity: Double = 0
    @State private var subtitleOpacity: Double = 0
    @State private var progress: CGFloat = 0
    @State private var creditOpacity: Double = 0

    // Idle pulse (loops until dismissal)
    @State private var pulse = false

    private var appName: String {
        let raw = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? "Video Player"
        // Strip a trailing " V0.0.137"-style version so the wordmark stays clean.
        return raw.replacingOccurrences(
            of: #"\s*V?\d+(\.\d+)+\s*$"#,
            with: "",
            options: .regularExpression
        )
    }

    var body: some View {
        ZStack {
            background

            VStack(spacing: 0) {
                Spacer()

                mark
                    .padding(.bottom, 26)

                Text(appName)
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                    .foregroundStyle(AppTheme.titleGradient)
                    .tracking(1.2)
                    .offset(y: titleOffset)
                    .opacity(titleOpacity)

                Text("VIDEO PLAYER")
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(4)
                    .foregroundColor(AppTheme.muted)
                    .padding(.top, 4)
                    .opacity(subtitleOpacity)

                Spacer()

                loadingBar
                    .padding(.horizontal, 70)
                    .padding(.bottom, 18)

                Text("Developed by Nurtadha N. Salman")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.white.opacity(0.5))
                    .opacity(creditOpacity)
                    .padding(.bottom, 34)
            }
        }
        .onAppear { runSequence() }
    }

    // MARK: - Layers

    private var background: some View {
        ZStack {
            AppTheme.bg.ignoresSafeArea()

            RadialGradient(
                colors: [Color.green.opacity(0.22), Color.clear],
                center: .center,
                startRadius: 10,
                endRadius: 340
            )
            .scaleEffect(glowScale)
            .opacity(glowOpacity)
            .ignoresSafeArea()

            RadialGradient(
                colors: [Color(red: 0.1, green: 0.5, blue: 0.9).opacity(0.10), Color.clear],
                center: .bottomTrailing,
                startRadius: 10,
                endRadius: 420
            )
            .ignoresSafeArea()
        }
    }

    private var mark: some View {
        ZStack {
            // Expanding ring flourish behind the icon.
            Circle()
                .stroke(AppTheme.accentGradient, lineWidth: 2)
                .frame(width: 118, height: 118)
                .scaleEffect(ringScale)
                .opacity(ringOpacity)

            // App-icon-style rounded square.
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .fill(AppTheme.accentGradient)
                .frame(width: 92, height: 92)
                .shadow(color: Color.green.opacity(0.45), radius: pulse ? 22 : 12, y: 6)
                .overlay(
                    RoundedRectangle(cornerRadius: 26, style: .continuous)
                        .stroke(Color.white.opacity(0.25), lineWidth: 1)
                )

            Image(systemName: "play.fill")
                .font(.system(size: 34, weight: .bold))
                .foregroundColor(.black.opacity(0.85))
                .offset(x: 2)
        }
        .scaleEffect(markScale * (pulse ? 1.04 : 1.0))
        .rotationEffect(.degrees(markRotation))
        .opacity(markOpacity)
    }

    private var loadingBar: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.white.opacity(0.08))
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(AppTheme.accentGradient)
                    .frame(width: proxy.size.width * progress)
            }
        }
        .frame(height: 4)
        .opacity(subtitleOpacity)
    }

    // MARK: - Sequence

    private func runSequence() {
        // 1) Icon springs in with a small overshoot + the glow blooms behind it.
        withAnimation(.spring(response: 0.62, dampingFraction: 0.62)) {
            markScale = 1
            markOpacity = 1
            markRotation = 0
        }
        withAnimation(.easeOut(duration: 0.9)) {
            glowScale = 1
            glowOpacity = 1
        }

        // 2) The ring "pings" outward once, right after the icon lands.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.32) {
            ringOpacity = 0.9
            withAnimation(.easeOut(duration: 0.7)) {
                ringScale = 1.55
                ringOpacity = 0
            }
        }

        // 3) Wordmark rises into place.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.38) {
            withAnimation(.easeOut(duration: 0.5)) {
                titleOffset = 0
                titleOpacity = 1
            }
        }

        // 4) Subtitle + loading bar fade in, bar fills over ~1s.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.62) {
            withAnimation(.easeOut(duration: 0.4)) {
                subtitleOpacity = 1
            }
            withAnimation(.easeInOut(duration: 1.0)) {
                progress = 1
            }
        }

        // 5) Gentle continuous breathing pulse on the icon while it waits.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
            withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) {
                pulse = true
            }
        }

        // 6) Developer credit is the last thing to arrive.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            withAnimation(.easeOut(duration: 0.5)) {
                creditOpacity = 1
            }
        }

        // 7) Hand off to the app.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.15) {
            onFinished()
        }
    }
}
