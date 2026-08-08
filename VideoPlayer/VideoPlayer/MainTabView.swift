import SwiftUI
import UIKit
import Kingfisher

struct MainTabView: View {
    @StateObject private var vm = AppViewModel()
    @State private var selectedTab = 0
    @State private var pikPakHomeToken = 0
    @Namespace private var dockSelection

    var body: some View {
        ZStack(alignment: .bottom) {
            ContentView(vm: vm, isActive: selectedTab == 0)
                .opacity(selectedTab == 0 ? 1 : 0).allowsHitTesting(selectedTab == 0)
            OffcloudView(vm: vm)
                .opacity(selectedTab == 1 ? 1 : 0).allowsHitTesting(selectedTab == 1)
            PikPakWebDAVView(vm: vm, homeToken: pikPakHomeToken, isActive: selectedTab == 2)
                .opacity(selectedTab == 2 ? 1 : 0).allowsHitTesting(selectedTab == 2)
            MediaView(vm: vm)
                .opacity(selectedTab == 3 ? 1 : 0).allowsHitTesting(selectedTab == 3)

            HStack(spacing: 5) {
                dockButton("Library", "play.rectangle.fill", 0)
                dockButton("Offcloud", "cloud.fill", 1)
                dockButton("PikPak", "externaldrive.fill", 2)
                dockButton("Media", "dot.radiowaves.left.and.right", 3)
            }
            .padding(6)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(Capsule().stroke(Color.white.opacity(0.13), lineWidth: 0.7))
            .shadow(color: .black.opacity(0.38), radius: 18, y: 8)
            .padding(.horizontal, 28)
            .padding(.bottom, 1)
        }
        .animation(.easeOut(duration: 0.18), value: selectedTab)
        .ignoresSafeArea(.keyboard, edges: .bottom)
        .tint(.green)
        .preferredColorScheme(.dark)
    }

    private func dockButton(_ title: String, _ icon: String, _ tab: Int) -> some View {
        Button {
            if tab == 2, selectedTab == 2 { pikPakHomeToken &+= 1 }
            withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) { selectedTab = tab }
        } label: {
            VStack(spacing: 3) {
                Image(systemName: icon).font(.system(size: 17, weight: .semibold))
                Text(title).font(.system(size: 9, weight: .semibold))
            }
            .foregroundStyle(selectedTab == tab ? Color.white : Color.white.opacity(0.48))
            .frame(maxWidth: .infinity).padding(.vertical, 7)
            .background {
                if selectedTab == tab {
                    Capsule().fill(Color.white.opacity(0.14))
                        .matchedGeometryEffect(id: "dock", in: dockSelection)
                }
            }
        }.buttonStyle(.plain)
    }
}
// MARK: - Shared visual tokens

enum AppTheme {
    static let bg = Color(red: 0.04, green: 0.04, blue: 0.05)
    static let card = Color(red: 0.10, green: 0.10, blue: 0.12)
    static let cardElevated = Color(red: 0.13, green: 0.13, blue: 0.15)
    static let accent = Color.green
    static let accentDeep = Color(red: 0.0, green: 0.55, blue: 0.25)
    static let muted = Color.white.opacity(0.45)
    static let mutedDeep = Color.white.opacity(0.38)

    static let titleGradient = LinearGradient(
        colors: [
            Color(red: 0.85, green: 0.98, blue: 0.92),
            Color(red: 0.55, green: 0.95, blue: 0.75)
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    static let accentGradient = LinearGradient(
        colors: [
            Color.green,
            Color(red: 0.15, green: 0.75, blue: 0.40)
        ],
        startPoint: .leading,
        endPoint: .trailing
    )
}
