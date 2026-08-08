import SwiftUI

/// واجهة ThePornDB Settings
struct ThePornDBSettingsView: View {
    @State private var apiKey: String
    @State private var performerLimit: String
    @State private var sceneLimit: String
    @State private var filterByYear: Bool
    @State private var year: String
    @State private var imageQuality: ThePornDBSettings.ImageQuality
    
    @Environment(\.dismiss) private var dismiss
    
    init() {
        _apiKey = State(initialValue: ThePornDBSettings.apiKey)
        _performerLimit = State(initialValue: String(ThePornDBSettings.PerformerSearch.defaultLimit))
        _sceneLimit = State(initialValue: String(ThePornDBSettings.SceneSearch.defaultLimit))
        _filterByYear = State(initialValue: ThePornDBSettings.SceneSearch.filterByYear)
        _year = State(initialValue: String(ThePornDBSettings.SceneSearch.year))
        _imageQuality = State(initialValue: ThePornDBSettings.PerformerSearch.imageQuality)
    }
    
    var body: some View {
        NavigationStack {
            Form {
                Section("API Key") {
                    SecureField("ThePornDB API Key", text: $apiKey)
                        .textContentType(.password)
                    
                    Text("Get an API key from: https://theporndb.net/api")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                Section("Performer Search Settings") {
                    HStack {
                        Text("Result Count")
                        Spacer()
                        TextField("20", text: $performerLimit)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 60)
                            .multilineTextAlignment(.center)
                    }
                    
                    Picker("Image Quality", selection: $imageQuality) {
                        Text("Low").tag(ThePornDBSettings.ImageQuality.low)
                        Text("Medium").tag(ThePornDBSettings.ImageQuality.medium)
                        Text("High").tag(ThePornDBSettings.ImageQuality.high)
                    }
                }
                
                Section("Scene Search Settings") {
                    HStack {
                        Text("Result Count")
                        Spacer()
                        TextField("20", text: $sceneLimit)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 60)
                            .multilineTextAlignment(.center)
                    }
                    
                    Toggle("Filter by Year", isOn: $filterByYear)
                    
                    if filterByYear {
                        HStack {
                            Text("Year")
                            Spacer()
                            TextField("2024", text: $year)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 80)
                                .multilineTextAlignment(.center)
                        }
                    }
                }
            }
            .navigationTitle("ThePornDB Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") {
                        saveSettings()
                        dismiss()
                    }
                }
            }
        }
    }
    
    private func saveSettings() {
        ThePornDBSettings.apiKey = apiKey
        ThePornDBSettings.PerformerSearch.defaultLimit = Int(performerLimit) ?? 20
        ThePornDBSettings.SceneSearch.defaultLimit = Int(sceneLimit) ?? 20
        ThePornDBSettings.SceneSearch.filterByYear = filterByYear
        ThePornDBSettings.SceneSearch.year = Int(year) ?? 0
        ThePornDBSettings.PerformerSearch.imageQuality = imageQuality
    }
}
