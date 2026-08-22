import SwiftUI
import UIKit

/// Shared purple-to-blue visual identity used across navigation, playback and primary actions.
enum AppPalette {
    static let purple = Color(red: 0.56, green: 0.24, blue: 0.96)
    static let blue = Color(red: 0.12, green: 0.48, blue: 1.00)
    static let accent = Color(red: 0.40, green: 0.36, blue: 0.98)
    static let gradient = LinearGradient(colors: [purple, blue], startPoint: .leading, endPoint: .trailing)
    static let diagonalGradient = LinearGradient(colors: [purple, blue], startPoint: .topLeading, endPoint: .bottomTrailing)
}


struct PremiumPressButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.975 : 1)
            .brightness(configuration.isPressed ? 0.06 : 0)
            .animation(.spring(response: 0.26, dampingFraction: 0.72), value: configuration.isPressed)
    }
}

/// The app-wide back control. Its pressed state mirrors the expanding glass
/// button used by the system media surfaces: the circle grows under the
/// finger, gains a cool glass tint, then the owning navigation transition
/// takes over when the action is released.
struct AppAnimatedBackButton: View {
    var icon = "chevron.left"
    var size: CGFloat = 40
    var accessibilityLabel = "Back"
    let action: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isCommitting = false

    var body: some View {
        Button(action: performAction) {
            Image(systemName: icon)
                .font(.system(size: size * 0.42, weight: .semibold))
        }
        .buttonStyle(AppExpandingBackButtonStyle(size: size, isCommitting: isCommitting))
        .accessibilityLabel(accessibilityLabel)
    }

    private func performAction() {
        guard !isCommitting else { return }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        guard !reduceMotion else {
            action()
            return
        }

        isCommitting = true
        // Hold the expanded frame just long enough to remain visible on a
        // quick tap, then let the native pop/dismiss animation begin.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            action()
        }
    }
}

struct AppExpandingBackButtonStyle: ButtonStyle {
    var size: CGFloat = 40
    var isCommitting = false

    func makeBody(configuration: Configuration) -> some View {
        let isExpanded = configuration.isPressed || isCommitting
        return configuration.label
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background {
                ZStack {
                    Circle().fill(.ultraThinMaterial)
                    Circle().fill(
                        Color(red: 0.12, green: 0.16, blue: 0.19)
                            .opacity(isExpanded ? 0.88 : 0.46)
                    )
                }
            }
            .overlay {
                Circle().stroke(
                    Color.white.opacity(isExpanded ? 0.18 : 0.10),
                    lineWidth: 1
                )
            }
            .scaleEffect(isExpanded ? 1.38 : 1)
            .shadow(
                color: Color.black.opacity(isExpanded ? 0.30 : 0.16),
                radius: isExpanded ? 12 : 5,
                y: isExpanded ? 7 : 3
            )
            .contentShape(Circle())
            .animation(
                .interactiveSpring(response: 0.24, dampingFraction: 0.74, blendDuration: 0.08),
                value: isExpanded
            )
    }
}
