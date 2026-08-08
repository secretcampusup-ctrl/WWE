import SwiftUI

// MARK: - Design Tokens

private enum DBTheme {
    static let background = Color(red: 0.043, green: 0.043, blue: 0.051)   // #0B0B0D
    static let surface    = Color(red: 0.094, green: 0.094, blue: 0.110)   // #18181C
    static let surfaceHi  = Color(red: 0.133, green: 0.133, blue: 0.153)   // #222227
    static let accent     = Color(red: 0.188, green: 0.820, blue: 0.345)   // #30D158
    static let gold       = Color(red: 0.851, green: 0.706, blue: 0.290)   // #D9B44A
    static let textPrimary   = Color(white: 0.96)
    static let textSecondary = Color(white: 0.62)
    static let divider    = Color(white: 1.0).opacity(0.06)
}

// MARK: - Tab Selector

enum ThePornDBSearchTab: String, CaseIterable {
    case performers = "Performers"
    case scenes = "Scenes"
}

struct ThePornDBTabPicker: View {
    @Binding var selection: ThePornDBSearchTab
    @Namespace private var pillNamespace

    var body: some View {
        HStack(spacing: 4) {
            ForEach(ThePornDBSearchTab.allCases, id: \.self) { tab in
                Button {
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.85)) {
                        selection = tab
                    }
                } label: {
                    Text(tab.rawValue)
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .foregroundStyle(selection == tab ? DBTheme.background : DBTheme.textSecondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background {
                            if selection == tab {
                                Capsule()
                                    .fill(DBTheme.accent)
                                    .matchedGeometryEffect(id: "pill", in: pillNamespace)
                            }
                        }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .background(DBTheme.surface, in: Capsule())
    }
}

// MARK: - Performer Card (portrait headshot tile)

struct ThePornDBPerformerCard: View {
    let performer: ThePornDBPerformer

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .bottomLeading) {
                RemoteImage(urlString: performer.bestImage, aspect: 3.0 / 4.0)

                LinearGradient(
                    colors: [.clear, .black.opacity(0.85)],
                    startPoint: .center,
                    endPoint: .bottom
                )

                VStack(alignment: .leading, spacing: 2) {
                    Text(performer.name ?? "—")
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    if let nat = performer.extras?.nationality, !nat.isEmpty {
                        Text(nat)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(DBTheme.gold)
                            .lineLimit(1)
                    }
                }
                .padding(10)
            }
        }
        .aspectRatio(3.0 / 4.0, contentMode: .fit)
        .background(DBTheme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(DBTheme.divider, lineWidth: 1)
        )
    }
}

// MARK: - Scene Card (landscape, with sprocket-hole edge)

struct ThePornDBSceneCard: View {
    let scene: ThePornDBScene

    var body: some View {
        HStack(spacing: 0) {
            SprocketStrip()
                .frame(width: 14)
                .background(DBTheme.background)

            ZStack(alignment: .bottomLeading) {
                RemoteImage(urlString: scene.bestImage, aspect: 16.0 / 9.0)

                LinearGradient(
                    colors: [.clear, .black.opacity(0.9)],
                    startPoint: .top,
                    endPoint: .bottom
                )

                VStack(alignment: .leading, spacing: 6) {
                    Spacer()
                    Text(scene.title ?? "—")
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)

                    HStack(spacing: 6) {
                        if let site = scene.site, !site.isEmpty {
                            Text(site)
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(DBTheme.background)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(DBTheme.gold, in: Capsule())
                        }
                        if let date = scene.date, !date.isEmpty {
                            Text(date)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(DBTheme.textSecondary)
                        }
                    }
                }
                .padding(12)
            }
        }
        .aspectRatio(16.0 / 9.0 + 0.12, contentMode: .fit)
        .background(DBTheme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(DBTheme.divider, lineWidth: 1)
        )
    }
}

/// شريط ثقوب الفيلم السينمائي — تفصيلة بصرية مميزة لبطاقات Scenes
private struct SprocketStrip: View {
    var body: some View {
        GeometryReader { geo in
            let holeSize: CGFloat = 4
            let spacing: CGFloat = 10
            let count = max(Int(geo.size.height / spacing), 1)
            VStack(spacing: spacing - holeSize) {
                ForEach(0..<count, id: \.self) { _ in
                    Circle()
                        .fill(DBTheme.surfaceHi)
                        .frame(width: holeSize, height: holeSize)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, spacing / 2)
        }
    }
}

// MARK: - Remote Image with shimmer placeholder

private struct RemoteImage: View {
    let urlString: String?
    let aspect: CGFloat

    var body: some View {
        GeometryReader { geo in
            if let urlString, let url = URL(string: urlString) {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    case .failure:
                        placeholder
                    case .empty:
                        ShimmerView()
                    @unknown default:
                        placeholder
                    }
                }
            } else {
                placeholder
            }
        }
        .aspectRatio(aspect, contentMode: .fit)
        .clipped()
    }

    private var placeholder: some View {
        ZStack {
            DBTheme.surfaceHi
            Image(systemName: "photo")
                .font(.system(size: 22))
                .foregroundStyle(DBTheme.textSecondary.opacity(0.5))
        }
    }
}

private struct ShimmerView: View {
    @State private var animate = false

    var body: some View {
        LinearGradient(
            colors: [DBTheme.surface, DBTheme.surfaceHi, DBTheme.surface],
            startPoint: animate ? .topLeading : .bottomTrailing,
            endPoint: animate ? .bottomTrailing : .topLeading
        )
        .onAppear {
            withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) {
                animate = true
            }
        }
    }
}

// MARK: - Empty / Error states

struct ThePornDBEmptyState: View {
    let icon: String
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(DBTheme.textSecondary)
            Text(title)
                .font(.system(size: 17, weight: .bold, design: .rounded))
                .foregroundStyle(DBTheme.textPrimary)
            Text(message)
                .font(.system(size: 14))
                .foregroundStyle(DBTheme.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 80)
    }
}

struct ThePornDBErrorState: View {
    let message: String
    let onRetry: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill(Color.orange.opacity(0.15))
                    .frame(width: 64, height: 64)
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 26))
                    .foregroundStyle(.orange)
            }
            Text("Something went wrong")
                .font(.system(size: 18, weight: .bold, design: .rounded))
                .foregroundStyle(DBTheme.textPrimary)
            Text(message)
                .font(.system(size: 13))
                .foregroundStyle(DBTheme.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 28)

            Button(action: onRetry) {
                Text("Try Again")
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(DBTheme.background)
                    .padding(.horizontal, 28)
                    .padding(.vertical, 12)
                    .background(DBTheme.accent, in: Capsule())
            }
            .buttonStyle(.plain)
            .padding(.top, 6)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
    }
}

// MARK: - Results Grid

struct ThePornDBPerformersGrid: View {
    let performers: [ThePornDBPerformer]

    private let columns = [
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12)
    ]

    var body: some View {
        LazyVGrid(columns: columns, spacing: 12) {
            ForEach(performers) { performer in
                ThePornDBPerformerCard(performer: performer)
            }
        }
        .padding(16)
    }
}

struct ThePornDBScenesGrid: View {
    let scenes: [ThePornDBScene]

    var body: some View {
        LazyVStack(spacing: 12) {
            ForEach(scenes) { scene in
                ThePornDBSceneCard(scene: scene)
            }
        }
        .padding(16)
    }
}

// MARK: - Skeleton loading grid

struct ThePornDBLoadingGrid: View {
    let tab: ThePornDBSearchTab

    var body: some View {
        Group {
            if tab == .performers {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                    ForEach(0..<9, id: \.self) { _ in
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(DBTheme.surface)
                            .aspectRatio(3.0 / 4.0, contentMode: .fit)
                            .overlay(ShimmerView().clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous)))
                    }
                }
            } else {
                LazyVStack(spacing: 12) {
                    ForEach(0..<5, id: \.self) { _ in
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(DBTheme.surface)
                            .aspectRatio(16.0 / 9.0 + 0.12, contentMode: .fit)
                            .overlay(ShimmerView().clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous)))
                    }
                }
            }
        }
        .padding(16)
        .redacted(reason: .placeholder)
    }
}
