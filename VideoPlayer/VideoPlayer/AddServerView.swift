import SwiftUI

struct AddServerView: View {
    @Environment(\.dismiss) var dismiss
    @ObservedObject var vm: AppViewModel

    @State private var name      = "PikPak WebDAV"
    @State private var host      = "dav.mypikpak.com"
    @State private var port      = "80"
    @State private var path      = "/"
    @State private var username  = ""
    @State private var password  = ""
    @State private var useHTTPS  = false
    @State private var isTesting = false
    @State private var statusMsg = ""
    @State private var statusOK  = false
    @State private var pasteField = ""

    var body: some View {
        NavigationView {
            Form {
                Section {
                    TextField("https://user:pass@dav.mypikpak.com", text: $pasteField)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                        .keyboardType(.URL)
                    Button("Parse pasted URL") {
                        applyPaste()
                    }
                    .disabled(pasteField.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                } header: {
                    Text("Quick paste")
                } footer: {
                    Text("Supports full URLs, user:pass@host, and paths.")
                }

                Section {
                    Button {
                        applyPikPakPreset()
                    } label: {
                        Label("PikPak WebDAV preset", systemImage: "bolt.horizontal.circle.fill")
                    }
                } header: {
                    Text("Presets")
                } footer: {
                    Text("Host: dav.mypikpak.com · Port 443 (HTTPS) or 80 · Path /")
                }

                Section(header: Text("Protocol")) {
                    Toggle("Use HTTPS", isOn: $useHTTPS)
                        .onChange(of: useHTTPS) { https in
                            if https && (port == "80" || port.isEmpty) { port = "443" }
                            if !https && (port == "443" || port.isEmpty) { port = "80" }
                        }
                }

                Section(header: Text("Connection")) {
                    HStack {
                        Text("Host")
                        Spacer()
                        TextField("dav.mypikpak.com", text: $host)
                            .multilineTextAlignment(.trailing)
                            .autocapitalization(.none)
                            .keyboardType(.URL)
                            .disableAutocorrection(true)
                    }
                    HStack {
                        Text("Port")
                        Spacer()
                        TextField(useHTTPS ? "443" : "80", text: $port)
                            .multilineTextAlignment(.trailing)
                            .keyboardType(.numberPad)
                    }
                    HStack {
                        Text("Path")
                        Spacer()
                        TextField("/", text: $path)
                            .multilineTextAlignment(.trailing)
                            .autocapitalization(.none)
                            .disableAutocorrection(true)
                    }
                }

                Section {
                    HStack {
                        Text("Username")
                        Spacer()
                        TextField("email or id", text: $username)
                            .multilineTextAlignment(.trailing)
                            .autocapitalization(.none)
                            .disableAutocorrection(true)
                            .textContentType(.username)
                    }
                    HStack {
                        Text("Password")
                        Spacer()
                        SecureField("••••••••", text: $password)
                            .multilineTextAlignment(.trailing)
                            .textContentType(.password)
                    }
                } footer: {
                    Text("Custom basic auth is sent on every PROPFIND and stream request.")
                }

                Section(header: Text("Name")) {
                    TextField("PikPak WebDAV", text: $name)
                }

                Section {
                    Button(action: testConnection) {
                        HStack {
                            if isTesting {
                                ProgressView().scaleEffect(0.8)
                            }
                            Text(isTesting ? "Connecting…" : "Test Connection")
                        }
                    }
                    .disabled(host.isEmpty || isTesting)

                    if !statusMsg.isEmpty {
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: statusOK ? "checkmark.circle.fill" : "xmark.circle.fill")
                                .foregroundColor(statusOK ? .green : .red)
                            Text(statusMsg)
                                .font(.footnote)
                                .foregroundColor(statusOK ? .green : .red)
                        }
                    }
                }
            }
            .navigationTitle("New Server")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(host.isEmpty)
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private func applyPaste() {
        let parsed = WebDAVServer.parseConnectionString(pasteField)
        if !parsed.host.isEmpty { host = parsed.host }
        if let p = parsed.port { port = String(p) }
        if let pathVal = parsed.path { path = pathVal }
        if let u = parsed.username { username = u }
        if let pw = parsed.password { password = pw }
        if let https = parsed.useHTTPS {
            useHTTPS = https
            if port.isEmpty || port == "0" {
                port = https ? "443" : "80"
            }
        }
        if name.isEmpty {
            name = host.isEmpty ? "WebDAV" : host
        }
    }

    private func applyPikPakPreset() {
        host = "dav.mypikpak.com"
        useHTTPS = false
        port = "80"
        path = "/"
        if name.isEmpty || name == host {
            name = "PikPak WebDAV"
        }
        statusMsg = "Preset applied — enter your PikPak username & password, then Test."
        statusOK = true
    }

    private func testConnection() {
        isTesting = true
        statusMsg = ""
        let server = buildServer()
        let client = WebDAVClient(server: server)
        Task {
            do {
                try await client.testConnection()
                await MainActor.run {
                    statusMsg = "Connected successfully"
                    statusOK  = true
                    isTesting = false
                }
            } catch {
                await MainActor.run {
                    statusMsg = error.localizedDescription
                    statusOK  = false
                    isTesting = false
                }
            }
        }
    }

    private func save() {
        var server = buildServer()
        server.isConnected = statusOK
        vm.addServer(server)
        dismiss()
    }

    private func buildServer() -> WebDAVServer {
        // Allow credentials embedded in host field (user:pass@host)
        var h = host
        var u = username
        var p = password
        var pt = path
        var portNum = Int(port) ?? (useHTTPS ? 443 : 80)
        var https = useHTTPS

        let parsed = WebDAVServer.parseConnectionString(host)
        if parsed.host != host || parsed.username != nil {
            if !parsed.host.isEmpty { h = parsed.host }
            if let pu = parsed.username, u.isEmpty { u = pu }
            if let pp = parsed.password, p.isEmpty { p = pp }
            if let pathVal = parsed.path, pt == "/" || pt.isEmpty { pt = pathVal }
            if let pr = parsed.port { portNum = pr }
            if let httpsVal = parsed.useHTTPS { https = httpsVal }
        }

        return WebDAVServer(
            name:      name.isEmpty ? h : name,
            host:      h,
            port:      portNum,
            path:      pt.isEmpty ? "/" : pt,
            username:  u,
            password:  p,
            useHTTPS:  https
        )
    }
}
