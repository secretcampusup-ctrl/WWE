import SwiftUI

struct FileBrowserView: View {
    let server: WebDAVServer
    @ObservedObject var vm: AppViewModel
    @State private var showingPlayer = false

    var body: some View {
        Group {
            if vm.isLoading {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Loading...").foregroundColor(.gray).font(.footnote)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = vm.errorMessage {
                VStack(spacing: 12) {
                    Image(systemName: "wifi.slash")
                        .font(.system(size: 40))
                        .foregroundColor(.gray)
                    Text(error)
                        .foregroundColor(.gray)
                        .font(.footnote)
                        .multilineTextAlignment(.center)
                    Button("Retry") {
                        Task { await vm.browse(server: server, path: "") }
                    }
                    .foregroundColor(.blue)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding()
            } else {
                List {
                    // Breadcrumb
                    if !vm.currentPath.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 4) {
                                Button("Home") {
                                    Task {
                                        vm.currentPath = []
                                        await vm.browse(server: server, path: "")
                                    }
                                }
                                .font(.system(size: 12))
                                .foregroundColor(.blue)
                                ForEach(vm.currentPath, id: \.self) { crumb in
                                    Image(systemName: "chevron.right")
                                        .font(.system(size: 10))
                                        .foregroundColor(.gray)
                                    Text(crumb)
                                        .font(.system(size: 12))
                                        .foregroundColor(.gray)
                                }
                            }
                        }
                        .listRowBackground(Color(white: 0.1))
                    }

                    ForEach(vm.currentFiles) { file in
                        if file.isDirectory {
                            Button(action: {
                                Task { await vm.openFolder(file, server: server) }
                            }) {
                                FileRow(file: file)
                            }
                        } else if file.isVideo {
                            Button(action: {
                                Task { @MainActor in
                                    guard await vm.preparePlayback(file: file, server: server) else { return }
                                    showingPlayer = true
                                }
                            }) {
                                FileRow(file: file, isNowPlaying: vm.nowPlaying?.id == file.id)
                            }
                        } else {
                            FileRow(file: file)
                        }
                    }
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle(server.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                HStack(spacing: 4) {
                    Circle()
                        .fill(server.isConnected ? Color.green : Color.orange)
                        .frame(width: 8, height: 8)
                    Text(server.isConnected ? "Connected" : "Offline")
                        .font(.system(size: 11))
                        .foregroundColor(server.isConnected ? .green : .orange)
                }
            }
        }
        .fullScreenCover(isPresented: $showingPlayer) {
            if let url = vm.nowPlayingURL, let file = vm.nowPlaying {
                RoutedVideoPlayerView(
                    url: url,
                    title: file.name,
                    resumeAt: vm.nowPlayingResumeAt,
                    linkId: vm.nowPlayingLinkId,
                    httpHeaders: vm.nowPlayingHeaders
                ) { seconds, duration, w, h in
                    vm.updatePlaybackProgress(
                        seconds: seconds,
                        duration: duration,
                        width: w,
                        height: h,
                        linkId: vm.nowPlayingLinkId,
                        streamURL: url
                    )
                }
            }
        }
        .task { await vm.browse(server: server, path: "") }
    }
}

struct FileRow: View {
    let file: WebDAVFile
    var isNowPlaying: Bool = false

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(iconBackground)
                    .frame(width: 36, height: 36)
                Image(systemName: iconName)
                    .foregroundColor(iconColor)
                    .font(.system(size: 16))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(file.displayName)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.white)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    if !file.fileExtension.isEmpty && !file.isDirectory {
                        Text(file.fileExtension)
                            .font(.system(size: 10))
                            .foregroundColor(.gray)
                    }
                    if !file.sizeFormatted.isEmpty {
                        Text(file.sizeFormatted)
                            .font(.system(size: 10))
                            .foregroundColor(.gray)
                    }
                    if isNowPlaying {
                        Text("Now playing")
                            .font(.system(size: 10))
                            .foregroundColor(.green)
                    }
                }
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.system(size: 12))
                .foregroundColor(.gray.opacity(0.5))
        }
        .padding(.vertical, 4)
    }

    private var iconName: String {
        if file.isDirectory { return "folder.fill" }
        if isNowPlaying     { return "play.fill" }
        if file.isVideo     { return "film" }
        return "doc"
    }

    private var iconBackground: Color {
        if file.isDirectory { return Color(red: 0.1, green: 0.16, blue: 0.24) }
        if isNowPlaying     { return Color(red: 0.04, green: 0.18, blue: 0.08) }
        if file.isVideo     { return Color(red: 0.12, green: 0.06, blue: 0.2) }
        return Color(white: 0.15)
    }

    private var iconColor: Color {
        if file.isDirectory { return .blue }
        if isNowPlaying     { return AppPalette.accent }
        if file.isVideo     { return Color(red: 0.75, green: 0.35, blue: 0.95) }
        return .gray
    }
}
