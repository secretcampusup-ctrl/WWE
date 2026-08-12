import SwiftUI

/// Diagnostic screen for thumbnail loading issues
struct ThumbnailDiagnosticScreen: View {
    @State private var logs: [ThumbnailLogEntry] = []
    @State private var filter: LogLevel? = nil
    @State private var searchTerm: String = ""
    @State private var showingExportAlert = false
    @State private var exportSuccess = false
    @State private var shareText: String?
    
    private let maxDisplayLogs = 200
    
    var filteredLogs: [ThumbnailLogEntry] {
        logs.filter { entry in
            if let filter, entry.level != filter {
                return false
            }
            if !searchTerm.isEmpty, !entry.message.contains(searchTerm) {
                return false
            }
            return true
        }.suffix(maxDisplayLogs)
    }
    
    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                // Filter bar
                VStack(spacing: 8) {
                    HStack {
                        TextField("Search logs...", text: $searchTerm, onEditingChanged: { _ in })
                            .textFieldStyle(RoundedBorderTextFieldStyle())
                            .padding(.horizontal, 12)
                            .foregroundColor(.primary)
                            .background(Color(white: 0.15))
                            .cornerRadius(8)
                        
                        Button(action: clearLogs) {
                            Image(systemName: "trash")
                                .font(.system(size: 16))
                                .foregroundColor(.red)
                        }
                        .padding(.trailing, 8)
                    }
                    
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            filterButton(nil, label: "All")
                            filterButton(.debug, label: "Debug")
                            filterButton(.info, label: "Info")
                            filterButton(.warning, label: "Warning")
                            filterButton(.error, label: "Error")
                        }
                        .padding(.horizontal, 12)
                    }
                }
                .padding(.vertical, 8)
                .background(Color(white: 0.08))
                
                // Log list
                List {
                    ForEach(filteredLogs) { log in
                        HStack(alignment: .top, spacing: 8) {
                            levelBadge(log.level)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(log.message)
                                    .font(.system(size: 12))
                                    .lineLimit(nil)
                                    .foregroundColor(.secondary)
                                if let fileID = log.fileID {
                                    Text("File: \(fileID)")
                                        .font(.system(size: 10))
                                        .foregroundColor(.gray)
                                }
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
                .listStyle(.plain)
                .refreshable {
                    await loadLogs()
                }
                
                // Export button
                Button(action: exportLogs) {
                    HStack {
                        Image(systemName: "square.and.arrow.up")
                        Text("Export Logs")
                    }
                    .padding(.vertical, 12)
                    .frame(maxWidth: .infinity)
                    .background(Color.blue.opacity(0.8))
                    .foregroundColor(.white)
                    .cornerRadius(8)
                    .padding(16)
                }

                // Share the disk-persisted log directly — this is the version
                // that survives a crash or force-quit, unlike the in-memory
                // list above (which is what "Export Logs" writes).
                Button {
                    shareText = VideoThumbnailLoader.exportPersistedDiagnosticLog()
                } label: {
                    HStack {
                        Image(systemName: "ladybug.fill")
                        Text("Share Persisted Log (survives crash)")
                    }
                    .padding(.vertical, 12)
                    .frame(maxWidth: .infinity)
                    .background(Color.red.opacity(0.8))
                    .foregroundColor(.white)
                    .cornerRadius(8)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 16)
                }
                .sheet(isPresented: Binding(get: { shareText != nil }, set: { if !$0 { shareText = nil } })) {
                    if let shareText {
                        ActivityShareSheet(items: [shareText])
                    }
                }
            }
            .navigationTitle("Thumbnails Debug")
            .navigationBarTitleDisplayMode(.inline)
        }
        .preferredColorScheme(.dark)
        .onAppear {
            Task { await loadLogs() }
        }
        .alert("Export Results", isPresented: $showingExportAlert) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(exportSuccess ? "Logs exported successfully!" : "Export failed")
        }
    }
    
    private func filterButton(_ level: LogLevel?, label: String) -> some View {
        Button(action: { filter = level }) {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(filter == level ? Color.blue : Color(white: 0.2))
                .foregroundColor(filter == level ? .white : .gray)
                .cornerRadius(12)
        }
    }
    
    private func levelBadge(_ level: LogLevel) -> some View {
        Circle()
            .fill(level.color)
            .frame(width: 10, height: 10)
            .overlay(
                Text(String(level.rawValue.first!).uppercased())
                    .font(.system(size: 8, weight: .bold))
                    .foregroundColor(.white)
            )
    }
    
    private func clearLogs() {
        VideoThumbnailLoader.clearDiagnosticLogs()
        logs = []
    }
    
    private func exportLogs() {
        let export = VideoThumbnailLoader.exportDiagnosticLogs()
        do {
            try export.write(to: exportedLogURL(), atomically: true, encoding: .utf8)
            exportSuccess = true
        } catch {
            exportSuccess = false
        }
        showingExportAlert = true
    }
    
    private func exportedLogURL() -> URL {
        let docDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return docDir.appendingPathComponent("thumbnail_logs_\(Date().toISOString()).txt")
    }
    
    private func loadLogs() async {
        logs = VideoThumbnailLoader.getDiagnosticLogs(filter: filter, searchTerm: searchTerm.isEmpty ? nil : searchTerm)
    }
}

// MARK: - Helper Extensions

extension LogLevel {
    var color: Color {
        switch self {
        case .debug: return Color.gray
        case .info: return Color.blue
        case .warning: return Color.orange
        case .error: return Color.red
        }
    }
}

extension Date {
    func toISOString() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate, .withTime, .withDashSeparatorInDate]
        return formatter.string(from: self).replacingOccurrences(of: ":", with: "-")
    }
}

// MARK: - Share Sheet

struct ActivityShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

// MARK: - Preview

#Preview {
    ThumbnailDiagnosticScreen()
}