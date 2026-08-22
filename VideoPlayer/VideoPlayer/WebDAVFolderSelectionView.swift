import SwiftUI

enum WebDAVContentSelectionStore {
    private static let pathsKey = "webdav.content.selectedPaths.v1"
    private static let configuredKey = "webdav.content.configuredServers.v1"

    static func selectedPaths(for serverID: UUID) -> [String]? {
        let configured = Set(UserDefaults.standard.stringArray(forKey: configuredKey) ?? [])
        guard configured.contains(serverID.uuidString) else { return nil }
        return dictionary()[serverID.uuidString] ?? []
    }

    static func save(_ paths: Set<String>, for serverID: UUID) {
        var values = dictionary()
        values[serverID.uuidString] = Array(minimalRoots(Array(paths))).sorted()
        UserDefaults.standard.set(values, forKey: pathsKey)
        var configured = Set(UserDefaults.standard.stringArray(forKey: configuredKey) ?? [])
        configured.insert(serverID.uuidString)
        UserDefaults.standard.set(Array(configured), forKey: configuredKey)
        UserDefaults.standard.set(UUID().uuidString, forKey: revisionKey(serverID))
    }

    static func save(_ paths: [String], for serverID: UUID) { save(Set(paths), for: serverID) }

    static func revision(for serverID: UUID) -> String {
        UserDefaults.standard.string(forKey: revisionKey(serverID)) ?? "legacy"
    }

    static func minimalRoots(_ paths: [String]) -> [String] {
        let normalized = Set(paths.map(normalize))
        if normalized.contains("") { return [""] }
        return normalized.filter { candidate in
            !normalized.contains { other in
                other != candidate && candidate.hasPrefix(other.hasSuffix("/") ? other : other + "/")
            }
        }.sorted()
    }

    private static func normalize(_ path: String) -> String {
        var value = path.trimmingCharacters(in: .whitespacesAndNewlines)
        while value.count > 1 && value.hasSuffix("/") { value.removeLast() }
        return value == "/" ? "" : value
    }

    private static func dictionary() -> [String: [String]] {
        UserDefaults.standard.dictionary(forKey: pathsKey) as? [String: [String]] ?? [:]
    }

    private static func revisionKey(_ id: UUID) -> String { "webdav.content.revision.\(id.uuidString)" }
}

enum WebDAVContentIndexStore {
    private static let cacheKey = "webdav.content.fileIndex.v1"
    private struct Payload: Codable { let revision: String; let files: [WebDAVFile] }

    static func load(serverID: UUID, revision: String) -> [WebDAVFile]? {
        guard let data = UserDefaults.standard.data(forKey: key(serverID)),
              let payload = try? JSONDecoder().decode(Payload.self, from: data),
              payload.revision == revision else { return nil }
        return payload.files
    }

    static func save(_ files: [WebDAVFile], serverID: UUID, revision: String) {
        guard let data = try? JSONEncoder().encode(Payload(revision: revision, files: files)) else { return }
        UserDefaults.standard.set(data, forKey: key(serverID))
    }

    private static func key(_ id: UUID) -> String { cacheKey + "." + id.uuidString }
}

struct WebDAVFolderSelectionView: View {
    @Environment(\.dismiss) private var dismiss
    let server: WebDAVServer
    var closesWhenSaved = false

    @State private var selected = Set<String>()
    @State private var pathStack: [(name: String, path: String)] = []
    @State private var folders: [WebDAVFile] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var didLoad = false

    private var currentPath: String { pathStack.last?.path ?? "" }
    private var allFoldersSelected: Bool { selected.contains("") }

    var body: some View {
        List {
            Section {
                Toggle(isOn: Binding(
                    get: { allFoldersSelected },
                    set: { enabled in selected = enabled ? [""] : [] }
                )) {
                    Label("All folders", systemImage: "externaldrive.fill")
                }
                .tint(AppPalette.accent)
            } footer: {
                Text("Only selected folders and their subfolders will appear in Content. You can change this at any time.")
            }

            if !pathStack.isEmpty {
                Section {
                    Button { pathStack.removeLast(); Task { await loadFolders() } } label: {
                        Label("Back", systemImage: "chevron.left")
                    }
                }
            }

            Section(pathStack.last?.name ?? "Folders") {
                if isLoading {
                    HStack { Spacer(); ProgressView("Loading folders…"); Spacer() }.padding(.vertical, 16)
                } else if let errorMessage {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Could not load folders", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        Text(errorMessage).font(.caption).foregroundStyle(.secondary)
                        Button("Try Again") { Task { await loadFolders() } }
                    }.padding(.vertical, 8)
                } else if folders.isEmpty {
                    Text("No subfolders here").foregroundStyle(.secondary)
                } else {
                    ForEach(folders) { folder in folderRow(folder) }
                }
            }

            if !selected.isEmpty {
                Section("Included in Content") {
                    ForEach(Array(selected).sorted(), id: \.self) { path in
                        Label(path.isEmpty ? "All folders" : path, systemImage: "checkmark.circle.fill")
                            .font(.footnote).foregroundStyle(path.isEmpty ? AppPalette.accent : .primary)
                    }
                }
            }
        }
        .navigationTitle("Content Folders")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                AppAnimatedBackButton(size: 36) { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    WebDAVContentSelectionStore.save(selected, for: server.id)
                    if closesWhenSaved { dismiss() }
                }
            }
        }
        .task {
            guard !didLoad else { return }
            didLoad = true
            if let saved = WebDAVContentSelectionStore.selectedPaths(for: server.id) { selected = Set(saved) }
            await loadFolders()
        }
    }

    private func folderRow(_ folder: WebDAVFile) -> some View {
        HStack(spacing: 12) {
            Button { toggle(folder.path) } label: {
                Image(systemName: isIncluded(folder.path) ? "checkmark.circle.fill" : "circle")
                    .font(.title3).foregroundStyle(isIncluded(folder.path) ? AppPalette.accent : .secondary)
            }.buttonStyle(.plain).disabled(allFoldersSelected)
            Image(systemName: "folder.fill").foregroundStyle(.yellow)
            Text(folder.name).lineLimit(1)
            Spacer()
            Button {
                pathStack.append((folder.name, folder.path))
                Task { await loadFolders() }
            } label: {
                Image(systemName: "chevron.right").foregroundStyle(.secondary).padding(.vertical, 6)
            }.buttonStyle(.plain)
        }
    }

    private func isIncluded(_ path: String) -> Bool {
        allFoldersSelected || selected.contains(path)
    }

    private func toggle(_ path: String) {
        if selected.contains(path) { selected.remove(path) } else { selected.insert(path) }
    }

    private func loadFolders() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            folders = try await WebDAVClient(server: server).listFiles(at: currentPath, forceRefresh: false)
                .filter(\.isDirectory)
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        } catch {
            folders = []
            errorMessage = error.localizedDescription
        }
    }
}
