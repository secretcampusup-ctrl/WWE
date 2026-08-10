import SwiftUI

/// PikPak account: sign in, browse your Drive, tap a video to play it.
/// This screen was missing from the UI — the login/browse logic already existed
/// in AppViewModel + PikPakClient but nothing ever called it.
struct PikPakLibraryView: View {
    @ObservedObject var vm: AppViewModel

    @State private var email = ""
    @State private var password = ""
    @State private var loginError: String?
    @State private var isSigningIn = false
    @State private var showingPlayer = false
    @State private var playError: String?
    @State private var showingDiagnosticScreen = false

    var body: some View {
        NavigationView {
            Group {
                if vm.pikpakAccount == nil {
                    loginForm
                } else {
                    browser
                }
            }
            .navigationTitle("PikPak")
            .toolbar {
                if vm.pikpakAccount != nil {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button(action: { showingDiagnosticScreen = true }) {
                            Image(systemName: "list.bullet.clipboard")
                                .foregroundColor(.blue)
                        }
                    }
                    
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button(role: .destructive) {
                            vm.pikpakLogout()
                        } label: {
                            Label("Sign Out", systemImage: "rectangle.portrait.and.arrow.right")
                        }
                    }
                }
            }
        }
        .fullScreenCover(isPresented: $showingDiagnosticScreen) {
            ThumbnailDiagnosticScreen()
        }
        .preferredColorScheme(.dark)
    }

    // MARK: - Login

    private var loginForm: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Sign in to browse and play files from your PikPak Drive, and to fully resolve PikPak share links.")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
            } header: {
                Text("PikPak account")
            }

            Section {
                TextField("Email", text: $email)
                    .keyboardType(.emailAddress)
                    .textContentType(.username)
                    .autocapitalization(.none)
                    .disableAutocorrection(true)
                SecureField("Password", text: $password)
                    .textContentType(.password)
            }

            if let loginError {
                Section {
                    Text(loginError)
                        .foregroundColor(.red)
                        .font(.footnote)
                }
            }

            Section {
                Button {
                    Task { await signIn() }
                } label: {
                    HStack {
                        Spacer()
                        if isSigningIn {
                            ProgressView()
                        } else {
                            Text("Sign In").fontWeight(.semibold)
                        }
                        Spacer()
                    }
                }
                .disabled(email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                          || password.isEmpty || isSigningIn)
            } footer: {
                Text("If PikPak asks for extra verification (captcha), sign in from the official PikPak app or web first, then try again here.")
            }
        }
    }

    private func signIn() async {
        isSigningIn = true
        loginError = nil
        let err = await vm.pikpakLogin(email: email, password: password)
        isSigningIn = false
        if let err {
            loginError = err
        } else {
            password = ""
        }
    }

    // MARK: - Browser

    private var browser: some View {
        Group {
            if vm.isLoading && vm.pikpakFiles.isEmpty {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Loading…").foregroundColor(.gray).font(.footnote)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = vm.errorMessage, vm.pikpakFiles.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 40))
                        .foregroundColor(.gray)
                    Text(error)
                        .foregroundColor(.gray)
                        .font(.footnote)
                        .multilineTextAlignment(.center)
                    Button("Retry") {
                        Task { await refresh(force: true) }
                    }
                    .foregroundColor(.blue)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding()
            } else {
                List {
                    if !vm.pikpakPath.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 4) {
                                Button("Root") {
                                    Task {
                                        vm.pikpakPath = []
                                        await refresh()
                                    }
                                }
                                .font(.system(size: 12))
                                .foregroundColor(.blue)
                                ForEach(Array(vm.pikpakPath.enumerated()), id: \.offset) { _, crumb in
                                    Image(systemName: "chevron.right")
                                        .font(.system(size: 10))
                                        .foregroundColor(.gray)
                                    Text(crumb.name)
                                        .font(.system(size: 12))
                                        .foregroundColor(.gray)
                                }
                            }
                        }
                        .listRowBackground(Color(white: 0.1))

                        Button {
                            Task { await vm.pikpakGoBack() }
                        } label: {
                            Label("Back", systemImage: "chevron.left")
                        }
                    }

                    if vm.pikpakFiles.isEmpty {
                        Text("This folder is empty.")
                            .foregroundColor(.gray)
                            .font(.footnote)
                    }

                    ForEach(vm.pikpakFiles) { file in
                        if file.isFolder {
                            Button {
                                Task { await vm.openPikPakFolder(file) }
                            } label: {
                                PikPakFileRow(file: file)
                            }
                        } else if file.isVideo {
                            Button {
                                Task { await play(file) }
                            } label: {
                                PikPakFileRow(file: file, isNowPlaying: vm.nowPlaying?.name == file.name && vm.nowPlayingURL != nil)
                            }
                        } else {
                            PikPakFileRow(file: file)
                        }
                    }
                }
                .listStyle(.plain)
                .refreshable { await refresh(force: true) }
            }
        }
        .overlay(alignment: .bottom) {
            if let playError {
                Text(playError)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(Color.red.opacity(0.9), in: Capsule())
                    .padding(.bottom, 16)
            }
        }
        .fullScreenCover(isPresented: $showingPlayer) {
            if let url = vm.nowPlayingURL, let file = vm.nowPlaying {
                RoutedVideoPlayerView(
                    url: url,
                    title: file.name,
                    resumeAt: vm.nowPlayingResumeAt,
                    linkId: vm.nowPlayingLinkId
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
        .task { await refresh(force: false) }
    }

    private func refresh(force: Bool = false) async {
        do {
            try await vm.refreshPikPakFiles(force: force)
        } catch {
            vm.errorMessage = error.localizedDescription
        }
    }

    private func play(_ file: PikPakFileItem) async {
        playError = nil
        if let err = await vm.playPikPakFile(file) {
            playError = err
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                if playError == err { playError = nil }
            }
        } else {
            showingPlayer = true
        }
    }
}

/// PikPak file thumbnail: ThePornDB is the only source. No `thumbnailLink`
/// (PikPak's own preview image) and no video-frame extraction — matches the
/// same policy already used by the WebDAV grid (`PikPakFilePoster`). Goes
/// through the shared `ThumbnailLoadGate` so a folder full of videos doesn't
/// fire a burst of simultaneous ThePornDB requests.
private struct PikPakThePornDBThumbnail: View {
    let file: PikPakFileItem

    @State private var image: UIImage?
    @State private var isLoading = false

    private var stableCacheKey: String { "pikpak-file|\(file.id)" }

    var body: some View {
        ZStack {
            Color(white: 0.1)
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else if isLoading {
                ProgressView()
                    .tint(.white.opacity(0.7))
                    .controlSize(.small)
            } else {
                Image(systemName: "film")
                    .font(.system(size: 14))
                    .foregroundColor(.gray)
            }
        }
        .task(id: file.id) {
            if let cached = VideoThumbnailLoader.cachedImage(forStableKey: stableCacheKey) {
                image = cached
                return
            }
            let query = VideoTitleFormatter.title(from: file.name)
            guard !query.isEmpty else { return }

            isLoading = true
            await ThumbnailLoadGate.shared.acquire()
            defer {
                isLoading = false
                Task { await ThumbnailLoadGate.shared.release() }
            }
            guard !Task.isCancelled else { return }

            if let metadata = await VideoThumbnailLoader.fetchThePornDBMetadata(for: query),
               let cover = metadata.coverImage {
                image = cover
                VideoThumbnailLoader.cacheImage(cover, forStableKey: stableCacheKey)
            }
        }
    }
}

private struct PikPakFileRow: View {
    let file: PikPakFileItem
    var isNowPlaying: Bool = false

    var body: some View {
        HStack(spacing: 12) {
            if file.isVideo {
                PikPakThePornDBThumbnail(file: file)
                    .frame(width: 56, height: 36)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5)
                    )
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(iconBackground)
                        .frame(width: 36, height: 36)
                    Image(systemName: iconName)
                        .foregroundColor(iconColor)
                        .font(.system(size: 16))
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(file.name)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.white)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    if !file.sizeFormatted.isEmpty {
                        Text(file.sizeFormatted)
                            .font(.system(size: 10))
                            .foregroundColor(.gray)
                    }
                    if isNowPlaying {
                        Text("Now playing")
                            .font(.system(size: 10))
                            .foregroundColor(AppPalette.accent)
                    }
                }
            }
            Spacer()
            if !file.isFolder {
                Image(systemName: "chevron.right")
                    .font(.system(size: 12))
                    .foregroundColor(.gray.opacity(0.5))
            }
        }
        .padding(.vertical, 4)
    }

    private var iconName: String {
        if file.isFolder    { return "folder.fill" }
        if isNowPlaying     { return "play.fill" }
        if file.isVideo     { return "film" }
        return "doc"
    }

    private var iconBackground: Color {
        if file.isFolder    { return Color(red: 0.1, green: 0.16, blue: 0.24) }
        if isNowPlaying     { return Color(red: 0.04, green: 0.18, blue: 0.08) }
        if file.isVideo     { return Color(red: 0.12, green: 0.06, blue: 0.2) }
        return Color(white: 0.15)
    }

    private var iconColor: Color {
        if file.isFolder    { return .blue }
        if isNowPlaying     { return AppPalette.accent }
        if file.isVideo     { return Color(red: 0.75, green: 0.35, blue: 0.95) }
        return .gray
    }
}



