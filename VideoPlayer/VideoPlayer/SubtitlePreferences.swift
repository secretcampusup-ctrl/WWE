import SwiftUI

struct SubtitleMediaContext: Equatable, Sendable {
    let title: String
    let tmdbID: Int?
    let mediaType: String?
    let season: Int?
    let episode: Int?

    var isEpisode: Bool { season != nil && episode != nil }
}

enum SubtitlePreferenceKeys {
    static let size = "player.subtitle.size"
    static let color = "player.subtitle.color"
    static let delay = "player.subtitle.delay"
    static let height = "player.subtitle.height"
    static let shadow = "player.subtitle.shadow"
    static let background = "player.subtitle.background"
    static let font = "player.subtitle.font"
    static let preferredLanguage = "player.subtitle.preferredLanguage"
    static let searchLanguages = "player.subtitle.searchLanguages"
    static let automaticDownload = "player.subtitle.automaticDownload"
}

struct SubtitleLanguageOption: Identifiable, Hashable {
    let code: String
    let title: String
    let apiName: String
    let aliases: [String]
    var id: String { code }

    init(code: String, title: String, apiName: String, aliases: [String] = []) {
        self.code = code
        self.title = title
        self.apiName = apiName
        self.aliases = aliases
    }

    static let supported: [SubtitleLanguageOption] = [
        .init(code: "AR", title: "Arabic", apiName: "arabic", aliases: ["ara"]),
        .init(code: "EN", title: "English", apiName: "english", aliases: ["eng"]),
        .init(code: "FA", title: "Persian", apiName: "persian", aliases: ["fas", "per", "farsi"]),
        .init(code: "TR", title: "Turkish", apiName: "turkish", aliases: ["tur"]),
        .init(code: "FR", title: "French", apiName: "french", aliases: ["fra", "fre"]),
        .init(code: "ES", title: "Spanish", apiName: "spanish", aliases: ["spa"]),
        .init(code: "DE", title: "German", apiName: "german", aliases: ["deu", "ger"]),
        .init(code: "IT", title: "Italian", apiName: "italian", aliases: ["ita"]),
        .init(code: "PT", title: "Portuguese", apiName: "portuguese", aliases: ["por"]),
        .init(code: "RU", title: "Russian", apiName: "russian", aliases: ["rus"]),
        .init(code: "KO", title: "Korean", apiName: "korean", aliases: ["kor"]),
        .init(code: "JA", title: "Japanese", apiName: "japanese", aliases: ["jpn"]),
        .init(code: "ZH", title: "Chinese", apiName: "chinese", aliases: ["zho", "chi"]),
        .init(code: "ID", title: "Indonesian", apiName: "indonesian", aliases: ["ind"]),
        .init(code: "HI", title: "Hindi", apiName: "hindi", aliases: ["hin"]),
        .init(code: "UR", title: "Urdu", apiName: "urdu", aliases: ["urd"])
    ]
}

enum SubtitlePreferences {
    static var preferredLanguageCode: String {
        let value = UserDefaults.standard.string(forKey: SubtitlePreferenceKeys.preferredLanguage)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased() ?? ""
        if SubtitleLanguageOption.supported.contains(where: { $0.code == value }) {
            return value
        }
        // No forced default language — fall back to English only when unset.
        return "EN"
    }

    static var searchLanguageCodes: [String] {
        let stored = UserDefaults.standard.string(forKey: SubtitlePreferenceKeys.searchLanguages) ?? ""
        let allowed = Set(SubtitleLanguageOption.supported.map(\.code))
        var values = stored.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() }
            .filter { allowed.contains($0) }
        let preferred = preferredLanguageCode
        if !values.contains(preferred) {
            values.insert(preferred, at: 0)
        } else {
            values.removeAll(where: { $0 == preferred })
            values.insert(preferred, at: 0)
        }
        if values.isEmpty { values = [preferred] }
        return values
    }

    static var automaticDownloadEnabled: Bool {
        UserDefaults.standard.bool(forKey: SubtitlePreferenceKeys.automaticDownload)
    }

    static func languageMatches(code rawCode: String?, title: String? = nil, preferredCode: String? = nil) -> Bool {
        let preferred = (preferredCode ?? preferredLanguageCode).uppercased()
        let option = SubtitleLanguageOption.supported.first(where: { $0.code == preferred })
        let candidates = [preferred.lowercased(), option?.apiName.lowercased()].compactMap { $0 }
            + (option?.aliases.map { $0.lowercased() } ?? [])
        if let code = rawCode?.lowercased().replacingOccurrences(of: "_", with: "-"),
           candidates.contains(where: { code == $0 || code.hasPrefix($0 + "-") }) {
            return true
        }
        guard let title = title?.lowercased() else { return false }
        return candidates.filter { $0.count > 2 }.contains(where: { title.contains($0) })
    }
}

struct SubtitleSettingsView: View {
    private struct SizePreset: Identifiable {
        let title: String
        let value: Double
        var id: Double { value }
    }

    @Environment(\.dismiss) private var dismiss
    @AppStorage(SubtitlePreferenceKeys.size) private var subtitleSize = 24.0
    @AppStorage(SubtitlePreferenceKeys.color) private var subtitleColorRaw = PlayerSubtitleColor.white.rawValue
    @AppStorage(SubtitlePreferenceKeys.delay) private var subtitleDelay = 0.0
    @AppStorage(SubtitlePreferenceKeys.height) private var subtitleHeight = 0.0
    @AppStorage(SubtitlePreferenceKeys.shadow) private var subtitleShadow = true
    @AppStorage(SubtitlePreferenceKeys.background) private var subtitleBackground = true
    @AppStorage(SubtitlePreferenceKeys.font) private var subtitleFontRaw = PlayerSubtitleFont.rounded.rawValue
    @AppStorage(SubtitlePreferenceKeys.preferredLanguage) private var preferredLanguage = "EN"
    @AppStorage(SubtitlePreferenceKeys.searchLanguages) private var searchLanguages = "EN"
    @AppStorage(SubtitlePreferenceKeys.automaticDownload) private var automaticDownload = false

    private let sizes: [SizePreset] = [
        .init(title: "Very Small", value: 18),
        .init(title: "Small", value: 21),
        .init(title: "Medium", value: 24),
        .init(title: "Large", value: 28),
        .init(title: "Very Large", value: 34)
    ]

    private var subtitleColor: PlayerSubtitleColor {
        PlayerSubtitleColor(rawValue: subtitleColorRaw) ?? .white
    }

    private var subtitleFont: PlayerSubtitleFont {
        PlayerSubtitleFont(rawValue: subtitleFontRaw) ?? .rounded
    }

    private var selectedSearchLanguages: Set<String> {
        Set(searchLanguages.split(separator: ",").map(String.init))
    }

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(spacing: 14) {
                    preview
                    languageCard
                    fontCard
                    sizeCard
                    styleCard
                    timingCard
                }
                .padding(18)
                .padding(.bottom, 32)
            }
            .background(
                LinearGradient(
                    colors: [AppTheme.bg, AppPalette.accent.opacity(0.1), AppTheme.bg],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ).ignoresSafeArea()
            )
            .navigationTitle("Subtitles")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    AppAnimatedBackButton(size: 36) { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(AppPalette.accent)
                }
            }
            .toolbarColorScheme(.dark, for: .navigationBar)
        }
        .preferredColorScheme(.dark)
    }

    private var languageCard: some View {
        card("Language & Search", icon: "captions.bubble.fill") {
            VStack(alignment: .leading, spacing: 8) {
                Text("Preferred Language").font(.system(size: 14, weight: .semibold))
                Text("Used first for automatic download and embedded tracks. Tap any language.")
                    .font(.caption).foregroundStyle(.white.opacity(0.45))
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 9) {
                    ForEach(SubtitleLanguageOption.supported) { language in
                        preferredLanguageButton(language)
                    }
                }
            }

            Divider().overlay(Color.white.opacity(0.08))
            Text("Search Languages")
                .font(.system(size: 14, weight: .semibold))
            Text("Choose which languages appear in subtitle search. Preferred is included automatically.")
                .font(.caption).foregroundStyle(.white.opacity(0.45))
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 9) {
                ForEach(SubtitleLanguageOption.supported) { language in
                    languageButton(language)
                }
            }

            Divider().overlay(Color.white.opacity(0.08))
            Toggle(isOn: $automaticDownload) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Automatic Subtitle Download").font(.system(size: 14, weight: .semibold))
                    Text("Search and apply the best result whenever a video opens")
                        .font(.caption).foregroundStyle(.white.opacity(0.45))
                }
            }
            .tint(AppPalette.accent)
        }
    }

    private var fontCard: some View {
        card("Font", icon: "textformat") {
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 9) {
                ForEach(PlayerSubtitleFont.allCases) { font in
                    choice(font.rawValue, selected: subtitleFont == font) { subtitleFontRaw = font.rawValue }
                }
            }
        }
    }

    private var sizeCard: some View {
        card("Font Size", icon: "textformat.size") {
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 9) {
                ForEach(sizes) { preset in
                    choice(preset.title, selected: subtitleSize == preset.value) { subtitleSize = preset.value }
                }
            }
        }
    }

    private var styleCard: some View {
        card("Text Style", icon: "paintpalette.fill") {
            HStack(spacing: 14) {
                ForEach(PlayerSubtitleColor.allCases) { color in
                    Button { subtitleColorRaw = color.rawValue } label: {
                        Circle().fill(color.color).frame(width: 36, height: 36)
                            .overlay(Circle().stroke(Color.white, lineWidth: subtitleColor == color ? 3 : 0))
                            .overlay(Circle().stroke(Color.black.opacity(0.5), lineWidth: 1).padding(3))
                    }.buttonStyle(.plain)
                }
                Spacer()
            }
            Toggle("Text Shadow", isOn: $subtitleShadow).tint(AppPalette.accent)
            Toggle("Background", isOn: $subtitleBackground).tint(AppPalette.accent)
        }
    }

    private var timingCard: some View {
        card("Timing & Position", icon: "clock.arrow.circlepath") {
            stepper("Subtitle Delay", display: String(format: "%+.2f s", subtitleDelay)) {
                subtitleDelay = max(-10, subtitleDelay - 0.25)
            } increment: {
                subtitleDelay = min(10, subtitleDelay + 0.25)
            }
            stepper("Vertical Position", display: "\(Int(subtitleHeight)) pt") {
                subtitleHeight = max(0, subtitleHeight - 5)
            } increment: {
                subtitleHeight = min(180, subtitleHeight + 5)
            }
        }
    }

    private var preview: some View {
        let pointSize = PlayerSubtitleSizing.pointSize(base: subtitleSize)
        return ZStack {
            LinearGradient(colors: [Color.indigo.opacity(0.55), Color.black], startPoint: .topLeading, endPoint: .bottomTrailing)
            VStack(spacing: 3) {
                Text("English subtitle preview")
                    .font(.custom(PlayerSubtitleTypeface.englishPostScriptName, fixedSize: CGFloat(pointSize)))
                Text("Subtitle preview text")
                    .font(.system(size: pointSize, weight: .semibold, design: subtitleFont.design))
            }
            .foregroundStyle(subtitleColor.color)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(subtitleBackground ? Color.black.opacity(0.58) : .clear, in: RoundedRectangle(cornerRadius: 8))
            .shadow(color: subtitleShadow ? .black : .clear, radius: 4)
            .padding(16)
        }
        .frame(height: 126)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22).stroke(Color.white.opacity(0.1)))
    }

    private func preferredLanguageButton(_ language: SubtitleLanguageOption) -> some View {
        let selected = preferredLanguage == language.code
        return Button {
            preferredLanguage = language.code
            var values = selectedSearchLanguages
            values.insert(language.code)
            searchLanguages = SubtitleLanguageOption.supported.map(\.code).filter(values.contains).joined(separator: ",")
        } label: {
            HStack {
                Text(language.title)
                Spacer()
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selected ? AppPalette.accent : Color.white.opacity(0.25))
            }
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 11).frame(height: 42)
            .background(Color.white.opacity(selected ? 0.14 : 0.04), in: RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(selected ? AppPalette.accent.opacity(0.55) : Color.clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private func languageButton(_ language: SubtitleLanguageOption) -> some View {
        let selected = selectedSearchLanguages.contains(language.code) || language.code == preferredLanguage
        return Button {
            // Preferred language stays in the search set; other languages toggle freely.
            if language.code == preferredLanguage { return }
            var values = selectedSearchLanguages
            if selected { values.remove(language.code) } else { values.insert(language.code) }
            values.insert(preferredLanguage)
            searchLanguages = SubtitleLanguageOption.supported.map(\.code).filter(values.contains).joined(separator: ",")
        } label: {
            HStack {
                Text(language.title)
                Spacer()
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selected ? AppPalette.accent : Color.white.opacity(0.25))
            }
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 11).frame(height: 42)
            .background(Color.white.opacity(selected ? 0.1 : 0.04), in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
    }

    private func card<Content: View>(_ title: String, icon: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(title, systemImage: icon).font(.system(size: 15, weight: .bold))
            content()
        }
        .foregroundStyle(.white)
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20).stroke(Color.white.opacity(0.08)))
    }

    private func choice(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack { Text(title); Spacer(); if selected { Image(systemName: "checkmark") } }
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 11).frame(height: 42)
                .background(Color.white.opacity(selected ? 0.12 : 0.045), in: RoundedRectangle(cornerRadius: 12))
        }.buttonStyle(.plain)
    }

    private func stepper(
        _ title: String,
        display: String,
        decrement: @escaping () -> Void,
        increment: @escaping () -> Void
    ) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 14, weight: .medium))
                Text(display).font(.caption.monospacedDigit()).foregroundStyle(.white.opacity(0.5))
            }
            Spacer()
            Button(action: decrement) { Image(systemName: "minus") }
            Button(action: increment) { Image(systemName: "plus") }
        }
        .buttonStyle(SubtitleStepperButtonStyle())
    }
}

private struct SubtitleStepperButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 34, height: 34)
            .background(Color.white.opacity(configuration.isPressed ? 0.18 : 0.09), in: Circle())
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
