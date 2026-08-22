import SwiftUI

/// Dedicated WebDAV integration / settings screen.
struct WebDAVSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var vm: AppViewModel
    @State private var showAddServer = false
    @State private var testingId: UUID?
    @State private var testMessage: String?
    @State private var testOK = false
    @State private var folderSelectionServer: WebDAVServer?

    var body: some View {
        NavigationView {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Connect NAS, Synology, Nextcloud, or any WebDAV server. Browse folders and stream videos with auth.")
                            .font(.footnote)
                            .foregroundColor(.secondary)
                    }
                } header: {
                    Text("WebDAV integration")
                }

                Section {
                    if vm.servers.isEmpty {
                        VStack(spacing: 12) {
                            Image(systemName: "externaldrive.connected.to.line.below")
                                .font(.system(size: 36))
                                .foregroundColor(.gray)
                            Text("No WebDAV accounts")
                                .font(.headline)
                                .foregroundColor(.gray)
                            Text("Tap Add Account to connect.")
                                .font(.footnote)
                                .foregroundColor(.gray)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 24)
                    } else {
                        ForEach(vm.servers) { server in
                            NavigationLink {
                                WebDAVFolderSelectionView(server: server, closesWhenSaved: true)
                            } label: {
                                WebDAVAccountRow(server: server)
                            }
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button(role: .destructive) {
                                    vm.deleteServer(server)
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                            .swipeActions(edge: .leading) {
                                Button {
                                    Task { await test(server) }
                                } label: {
                                    Label("Test", systemImage: "waveform.path.ecg")
                                }
                                .tint(.blue)
                            }
                            .contextMenu {
                                Button {
                                    Task { await test(server) }
                                } label: {
                                    Label("Test Connection", systemImage: "network")
                                }
                                Button {
                                    Task {
                                        await vm.connect(to: server)
                                    }
                                } label: {
                                    Label("Connect & Browse", systemImage: "folder")
                                }
                                Button(role: .destructive) {
                                    vm.deleteServer(server)
                                } label: {
                                    Label("Remove Account", systemImage: "trash")
                                }
                            }
                        }
                    }
                } header: {
                    HStack {
                        Text("Accounts")
                        Spacer()
                        Text("\(vm.servers.count)")
                            .foregroundColor(.secondary)
                    }
                } footer: {
                    Text("Swipe left to delete · Swipe right to test · Tap to choose Content folders.")
                }

                if let testMessage {
                    Section("Last test") {
                        HStack {
                            Image(systemName: testOK ? "checkmark.circle.fill" : "xmark.circle.fill")
                                .foregroundColor(testOK ? .green : .red)
                            Text(testMessage)
                                .font(.footnote)
                        }
                    }
                }

                Section("How to connect") {
                    Label("Host: IP, domain, or dav.mypikpak.com", systemImage: "1.circle")
                    Label("Port: 443 (HTTPS) or 80 (HTTP); NAS often 5005/5006", systemImage: "2.circle")
                    Label("Path: / for PikPak DAV; else /dav or /webdav", systemImage: "3.circle")
                    Label("Basic auth: custom username + password", systemImage: "4.circle")
                    Label("Paste user:pass@host or full URL in Add Account", systemImage: "5.circle")
                }
                .font(.footnote)

                Section("PikPak WebDAV example") {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Host  dav.mypikpak.com")
                        Text("Port  443 (HTTPS) or 80")
                        Text("Path  /")
                        Text("Auth  your PikPak email + password")
                    }
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(.secondary)
                }
            }
            .navigationTitle("WebDAV")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    AppAnimatedBackButton(size: 36) { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        showAddServer = true
                    } label: {
                        Label("Add Account", systemImage: "plus.circle.fill")
                    }
                }
            }
            .sheet(isPresented: $showAddServer) {
                AddServerView(vm: vm) { server in
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                        folderSelectionServer = server
                    }
                }
            }
            .sheet(item: $folderSelectionServer) { server in
                NavigationStack { WebDAVFolderSelectionView(server: server, closesWhenSaved: true) }
            }
            .overlay {
                if vm.isLoading {
                    ProgressView("Connecting…")
                        .padding(20)
                        .background(.ultraThinMaterial)
                        .cornerRadius(12)
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private func test(_ server: WebDAVServer) async {
        testingId = server.id
        testMessage = nil
        let client = WebDAVClient(server: server)
        do {
            try await client.testConnection()
            testOK = true
            testMessage = "Connected to \(server.name)"
            var s = server
            s.isConnected = true
            vm.updateServer(s)
        } catch {
            testOK = false
            testMessage = error.localizedDescription
            var s = server
            s.isConnected = false
            vm.updateServer(s)
        }
        testingId = nil
    }
}

struct WebDAVAccountRow: View {
    let server: WebDAVServer

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(server.isConnected
                          ? Color.green.opacity(0.15)
                          : Color.orange.opacity(0.15))
                    .frame(width: 42, height: 42)
                Image(systemName: "server.rack")
                    .foregroundColor(server.isConnected ? .green : .orange)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(server.name)
                    .font(.system(size: 15, weight: .semibold))
                Text(server.displayAddress)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                if !server.username.isEmpty {
                    Text("User: \(server.username)")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                Text(server.isConnected ? "Connected" : "Saved")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(server.isConnected ? .green : .secondary)
                Image(systemName: "chevron.right")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}
