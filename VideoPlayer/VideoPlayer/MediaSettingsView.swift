import SwiftUI

struct MediaSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var settings: MediaFeedSettings
    @FocusState private var focusedField: MediaCategory?
    let onSave: (MediaFeedSettings) -> Void

    init(settings: MediaFeedSettings, onSave: @escaping (MediaFeedSettings) -> Void) {
        _settings = State(initialValue: settings)
        self.onSave = onSave
    }

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("Add the RSS link for each category below. Tap a filter on the Media screen to search it directly.")
                        .font(.system(size: 13))
                        .foregroundColor(.white.opacity(0.55))
                        .fixedSize(horizontal: false, vertical: true)

                    ForEach(MediaCategory.allCases) { category in
                        feedField(for: category)
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Label("Tip", systemImage: "lightbulb")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(MediaPalette.accent)
                        Text("If your tracker's RSS uses a search parameter, include a {query} placeholder, e.g. https://example.com/rss?search={query}&cat=1080p. Without a placeholder, the search text is appended automatically.")
                            .font(.system(size: 12))
                            .foregroundColor(.white.opacity(0.5))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(14)
                    .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 14))
                }
                .padding(16)
            }
            .background(MediaPalette.bg.ignoresSafeArea())
            .navigationTitle("RSS Feeds")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    AppAnimatedBackButton(size: 36) { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Save") {
                        onSave(settings)
                        dismiss()
                    }
                    .fontWeight(.semibold)
                    .foregroundColor(MediaPalette.accent)
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    @ViewBuilder
    private func feedField(for category: MediaCategory) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(category.rawValue, systemImage: category.icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.white)

            TextField(
                "https://example.com/rss?search={query}",
                text: Binding(
                    get: { settings.url(for: category) },
                    set: { settings.setURL($0, for: category) }
                )
            )
            .focused($focusedField, equals: category)
            .textFieldStyle(.plain)
            .foregroundColor(.white)
            .keyboardType(.URL)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .padding(12)
            .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(
                        focusedField == category ? MediaPalette.accent.opacity(0.7) : Color.white.opacity(0.08),
                        lineWidth: 1
                    )
            )
        }
    }
}
