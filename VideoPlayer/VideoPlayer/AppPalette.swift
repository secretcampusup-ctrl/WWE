import SwiftUI

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
