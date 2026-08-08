import SwiftUI

/// Lets the user turn on automatic PikPak downloading and tune how it behaves.
/// Reachable from the PikPak tab's toolbar.
struct PikPakAutoSyncSettingsView: View {
    @ObservedObject var vm: AppViewModel
    @ObservedObject private var sync = PikPakAutoSyncManager.shared
    @Environment(\.dismiss) private var dismiss

    private var hasServer: Bool {
        vm.servers.contains { $0.host.lowercased().contains("dav.mypikpak.com") }
    }

    var body: some View {
        NavigationView {
            Form {
                if !hasServer {
                    Section {
                        Text("Connect your PikPak account first (gear icon on the PikPak tab), then turn this on.")
                            .font(.footnote)
                            .foregroundColor(.secondary)
                    }
                }

                Section {
                    Toggle("Auto-download new videos", isOn: $sync.isEnabled)
                        .disabled(!hasServer)
                } footer: {
                    Text("Periodically checks your PikPak drive and automatically downloads any video that isn't downloaded yet — no need to open it first.")
                }

                Section("Check frequency") {
                    Stepper(value: $sync.pollIntervalMinutes, in: 15...240, step: 15) {
                        Text("Every \(sync.pollIntervalMinutes) min")
                    }
                    Text("This is a minimum interval — iOS ultimately decides when background checks run. Opening the app also triggers an immediate check, and this always runs while the app is open.")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }

                Section("Minimum file size") {
                    Stepper(value: $sync.minimumSizeMB, in: 0...2000, step: 50) {
                        Text(sync.minimumSizeMB == 0 ? "No minimum" : "At least \(sync.minimumSizeMB) MB")
                    }
                }

                Section("Status") {
                    if sync.isSyncing {
                        HStack {
                            ProgressView()
                            Text("Checking for new videos…")
                        }
                    } else if let last = sync.lastSyncDate {
                        Text("Last checked \(last.formatted(.relative(presentation: .named)))")
                            .foregroundColor(.secondary)
                        if sync.lastQueuedCount > 0 {
                            Text("Queued \(sync.lastQueuedCount) new video\(sync.lastQueuedCount == 1 ? "" : "s")")
                                .foregroundColor(.green)
                        }
                    } else {
                        Text("Not checked yet")
                            .foregroundColor(.secondary)
                    }

                    if let error = sync.lastError {
                        Text(error)
                            .foregroundColor(.red)
                            .font(.footnote)
                    }

                    Button {
                        Task { await sync.syncNow() }
                    } label: {
                        HStack {
                            Spacer()
                            Text("Check Now")
                            Spacer()
                        }
                    }
                    .disabled(sync.isSyncing || !hasServer)
                }
            }
            .navigationTitle("Auto Download")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}
