import SwiftUI

struct TMDBSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var token = TMDBSettings.readAccessToken
    @State private var connectionStatus: String?
    @State private var isTesting = false

    var body: some View {
        NavigationStack {
            Form {
                Section("TMDB") {
                    SecureField("Read Access Token or API Key", text: $token)
                        .textContentType(.password)
                    Text("Use the Read Access Token from your TMDB account settings. It is stored only on this device.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button(isTesting ? "Testing…" : "Test Connection") {
                        TMDBSettings.readAccessToken = token
                        isTesting = true
                        Task {
                            let error = await TMDBService.shared.testConnection()
                            connectionStatus = error ?? "Connected to TMDB successfully."
                            isTesting = false
                        }
                    }.disabled(token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isTesting)
                    if let connectionStatus {
                        Text(connectionStatus).font(.caption).foregroundStyle(connectionStatus.hasPrefix("Connected") ? .green : .red)
                    }
                }
            }
            .navigationTitle("TMDB Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { TMDBSettings.readAccessToken = token; dismiss() }
                }
            }
        }
    }
}
