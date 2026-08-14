import SwiftUI
import Kingfisher

/// لون ذهبي هادئ يُستخدم فقط لوسم الموقع/الشبكة على بطاقة المشهد،
/// حتى لا يتنافس مع الأخضر الأساسي في AppTheme
private enum TPDBAccent {
    static let gold = Color(red: 0.85, green: 0.71, blue: 0.29)
}

/// واجهة البحث في ThePornDB — تُستخدم لاختيار صورة غلاف من نتائج
/// البحث عن Performers أو Scenes وإرجاعها عبر onPick
struct ThePornDBSearchView: View {
    enum SearchMode {
        case performers
        case scenes
        case jav
    }

    let initialQuery: String
    let onPick: (UIImage) -> Void
    let onPickScene: ((ThePornDBScene, UIImage) -> Void)?

    @Environment(\.dismiss) private var dismiss
    @State private var query: String
    @State private var mode: SearchMode = .performers
    @State private var performers: [ThePornDBPerformer] = []
    @State private var scenes: [ThePornDBScene] = []
    @State private var isSearching = false
    @State private var errorMessage: String?
    @State private var apiError: ThePornDBError?
    @State private var searchTask: Task<Void, Never>?
    @State private var pickingID: String?

    init(
        initialQuery: String,
        initialMode: SearchMode = .performers,
        onPickScene: ((ThePornDBScene, UIImage) -> Void)? = nil,
        onPick: @escaping (UIImage) -> Void
    ) {
        self.initialQuery = initialQuery
        self.onPick = onPick
        self.onPickScene = onPickScene
        _query = State(initialValue: initialQuery)
        _mode = State(
            initialValue: VideoTitleFormatter.catalogIdentifier(from: initialQuery) == nil
                ? initialMode
                : .jav
        )
    }

    private let performerColumns = [
        GridItem(.flexible(), spacing: 10),
        GridItem(.flexible(), spacing: 10),
        GridItem(.flexible(), spacing: 10)
    ]

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                modePicker
                    .padding(.horizontal, 16)
                    .padding(.top, 6)

                searchField
                    .padding(.horizontal, 16)

                ScrollView {
                    content
                }
            }
            .background(AppTheme.bg.ignoresSafeArea())
            .navigationTitle("Search ThePornDB")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                        .tint(AppTheme.accent)
                }
            }
            .onAppear {
                if !query.isEmpty { startSearch() }
            }
            .onChange(of: mode) { _ in startSearch() }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: - منتقي الوضع

    private var modePicker: some View {
        HStack(spacing: 4) {
            modeButton("Performers", tag: .performers)
            modeButton("Scenes", tag: .scenes)
            modeButton("JAV", tag: .jav)
        }
        .padding(4)
        .background(AppTheme.card, in: Capsule())
    }

    private func modeButton(_ title: String, tag: SearchMode) -> some View {
        Button {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { mode = tag }
        } label: {
            Text(title)
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .foregroundColor(mode == tag ? .black : .white.opacity(0.6))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background {
                    if mode == tag {
                        Capsule().fill(AppTheme.accentGradient)
                    }
                }
        }
        .buttonStyle(.plain)
    }

    // MARK: - حقل البحث

    private var searchField: some View {
        HStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.white.opacity(0.35))
                TextField("", text: $query, prompt: Text("Search here...").foregroundColor(.white.opacity(0.3)))
                    .foregroundColor(.white)
                    .submitLabel(.search)
                    .onSubmit { startSearch() }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .background(AppTheme.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))

            Button(action: startSearch) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundColor(.black)
                    .frame(width: 44, height: 44)
                    .background(AppTheme.accentGradient, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .opacity(query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.4 : 1)
        }
    }

    // MARK: - المحتوى

    @ViewBuilder
    private var content: some View {
        if isSearching {
            loadingState
        } else if let error = apiError {
            errorState(error: error)
        } else if mode == .performers {
            performersContent
        } else {
            scenesContent
        }
    }

    private var loadingState: some View {
        VStack(spacing: 12) {
            ProgressView()
                .tint(AppTheme.accent)
            Text("Searching...")
                .font(.system(size: 13))
                .foregroundColor(.white.opacity(0.5))
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 90)
    }

    @ViewBuilder
    private var performersContent: some View {
        if performers.isEmpty {
            emptyState(
                icon: "person.crop.circle.badge.questionmark",
                title: "Search for a performer",
                message: "Enter a performer name to find images"
            )
        } else {
            LazyVGrid(columns: performerColumns, spacing: 10) {
                ForEach(performers) { performer in
                    PerformerCard(
                        performer: performer,
                        isPicking: pickingID == performer.id
                    ) {
                        selectPerformer(performer)
                    }
                }
            }
            .padding(16)
        }
    }

    @ViewBuilder
    private var scenesContent: some View {
        if scenes.isEmpty {
            emptyState(
                icon: "film",
                title: mode == .jav ? "Search the JAV catalogue" : "Search for a scene",
                message: mode == .jav ? "Enter a code such as JUR-174" : "Enter a scene or performer name"
            )
        } else {
            LazyVStack(spacing: 10) {
                ForEach(scenes) { scene in
                    SceneCard(
                        scene: scene,
                        isPicking: pickingID == scene.id
                    ) {
                        selectScene(scene)
                    }
                }
            }
            .padding(16)
        }
    }

    // MARK: - حالة Emptyة

    private func emptyState(icon: String, title: String, message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 40, weight: .light))
                .foregroundColor(.white.opacity(0.25))
            Text(title)
                .font(.system(size: 16, weight: .bold, design: .rounded))
                .foregroundColor(.white)
            Text(message)
                .font(.system(size: 13))
                .foregroundColor(.white.opacity(0.45))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 80)
    }

    // MARK: - حالة الخطأ

    private func errorState(error: ThePornDBError) -> some View {
        VStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(Color.orange.opacity(0.15))
                    .frame(width: 60, height: 60)
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 24))
                    .foregroundColor(.orange)
            }
            Text("Something went wrong")
                .font(.system(size: 17, weight: .bold, design: .rounded))
                .foregroundColor(.white)

            if let errorDescription = error.errorDescription {
                Text(errorDescription)
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.5))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 28)
            }

            Button(action: startSearch) {
                Text("Try Again")
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundColor(.black)
                    .padding(.horizontal, 26)
                    .padding(.vertical, 11)
                    .background(AppTheme.accentGradient, in: Capsule())
            }
            .buttonStyle(.plain)
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
    }

    // MARK: - بدء البحث

    private func startSearch() {
        searchTask?.cancel()

        let searchQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !searchQuery.isEmpty else {
            performers = []
            scenes = []
            return
        }

        isSearching = true
        errorMessage = nil
        apiError = nil

        searchTask = Task {
            do {
                if mode == .performers {
                    let limit = ThePornDBSettings.PerformerSearch.defaultLimit
                    let response = try await ThePornDBAPIService.shared.searchPerformers(
                        query: searchQuery,
                        limit: limit
                    )

                    await MainActor.run {
                        performers = response.list
                        isSearching = false
                    }
                } else if mode == .scenes {
                    var year: Int?
                    if ThePornDBSettings.SceneSearch.filterByYear {
                        year = ThePornDBSettings.SceneSearch.year
                    }

                    let limit = ThePornDBSettings.SceneSearch.defaultLimit
                    let response = try await ThePornDBAPIService.shared.searchScenes(
                        query: searchQuery,
                        limit: limit,
                        year: year
                    )

                    await MainActor.run {
                        scenes = response.list
                        isSearching = false
                    }
                } else {
                    let limit = ThePornDBSettings.SceneSearch.defaultLimit
                    let response = try await ThePornDBAPIService.shared.searchJav(
                        query: searchQuery,
                        limit: limit
                    )

                    await MainActor.run {
                        scenes = response.list
                        isSearching = false
                    }
                }
            } catch let error as ThePornDBError {
                await MainActor.run {
                    apiError = error
                    errorMessage = error.localizedDescription
                    isSearching = false
                }
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    isSearching = false
                }
            }
        }
    }

    // MARK: - اختيار ممثلة

    private func selectPerformer(_ performer: ThePornDBPerformer) {
        guard pickingID == nil else { return }
        pickingID = performer.id
        Task {
            do {
                guard let imageURL = performer.bestImage else {
                    await MainActor.run {
                        errorMessage = "No image is available for this performer"
                        pickingID = nil
                    }
                    return
                }

                let image = try await ThePornDBAPIService.shared.downloadImage(from: imageURL)
                await MainActor.run {
                    onPick(image)
                    dismiss()
                }
            } catch let error as ThePornDBError {
                await MainActor.run {
                    apiError = error
                    errorMessage = error.localizedDescription
                    pickingID = nil
                }
            } catch {
                await MainActor.run {
                    errorMessage = "Image download failed: \(error.localizedDescription)"
                    pickingID = nil
                }
            }
        }
    }

    // MARK: - اختيار مشهد

    private func selectScene(_ scene: ThePornDBScene) {
        guard pickingID == nil else { return }
        pickingID = scene.id
        Task {
            do {
                guard let imageURL = scene.bestImage else {
                    await MainActor.run {
                        errorMessage = "No image is available for this scene"
                        pickingID = nil
                    }
                    return
                }

                let image = try await ThePornDBAPIService.shared.downloadImage(from: imageURL)
                await MainActor.run {
                    if let onPickScene { onPickScene(scene, image) }
                    else { onPick(image) }
                    dismiss()
                }
            } catch let error as ThePornDBError {
                await MainActor.run {
                    apiError = error
                    errorMessage = error.localizedDescription
                    pickingID = nil
                }
            } catch {
                await MainActor.run {
                    errorMessage = "Image download failed: \(error.localizedDescription)"
                    pickingID = nil
                }
            }
        }
    }
}

// MARK: - تنظيف العرض (اسم الممثلة / عنوان المشهد)

private extension ThePornDBPerformer {
    /// اسم نظيف للعرض في بطاقة الممثلة — يُبقي الاسم فقط
    /// ويزيل أي أقواس أو معلومات إضافية قد تأتي ملتصقة بالاسم من الـ API
    var displayName: String? {
        guard let raw = name?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        var cleaned = raw
        cleaned = cleaned.replacingOccurrences(of: #"[\(\[].*?[\)\]]"#, with: "", options: .regularExpression)
        cleaned = cleaned.replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? raw : cleaned
    }
}

private extension ThePornDBScene {
    /// عنوان نظيف للعرض — يزيل التاريخ وأسماء Performers إن كانت مضمّنة
    /// داخل نص العنوان نفسه (شائع في نتائج ThePornDB)، ويُبقي فقط اسم المشهد
    var displayTitle: String? {
        guard var cleaned = title?.trimmingCharacters(in: .whitespacesAndNewlines), !cleaned.isEmpty else { return nil }

        // إزالة صيغ التاريخ الشائعة (2024-01-01 / 01.01.2024 / (2024) / سنة مفردة)
        let datePatterns = [
            #"\b\d{4}-\d{2}-\d{2}\b"#,
            #"\b\d{2}[./-]\d{2}[./-]\d{4}\b"#,
            #"\((19|20)\d{2}\)"#,
            #"\b(19|20)\d{2}\b"#
        ]
        for pattern in datePatterns {
            cleaned = cleaned.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        }

        // إزالة أسماء Performers المعروفة إن كانت مذكورة داخل العنوان
        if let names = performers?.compactMap({ $0.name?.trimmingCharacters(in: .whitespacesAndNewlines) }) {
            for name in names where !name.isEmpty {
                cleaned = cleaned.replacingOccurrences(of: name, with: "", options: [.caseInsensitive])
            }
        }

        // تنظيف الفواصل والأقواس والمسافات المتبقية بعد الحذف
        cleaned = cleaned.replacingOccurrences(of: #"[-|:]{1,}"#, with: " ", options: .regularExpression)
        cleaned = cleaned.replacingOccurrences(of: #"[()\[\]]"#, with: "", options: .regularExpression)
        cleaned = cleaned.replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)

        return cleaned.isEmpty ? title : cleaned
    }
}

// MARK: - بطاقة الممثلة (بورتريه)

private struct PerformerCard: View {
    let performer: ThePornDBPerformer
    let isPicking: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            ZStack(alignment: .bottomLeading) {
                if let imageURL = performer.bestImage {
                    KFImage(URL(string: imageURL))
                        .cacheOriginalImage()
                        .backgroundDecode()
                        .placeholder {
                            ZStack { AppTheme.card; ProgressView().tint(AppTheme.accent) }
                        }
                        .onFailureView {
                            ZStack {
                                AppTheme.card
                                Image(systemName: "person")
                                    .font(.system(size: 28))
                                    .foregroundColor(.white.opacity(0.25))
                            }
                        }
                        .resizable()
                        .scaledToFill()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .clipped()
                } else {
                    ZStack {
                        AppTheme.card
                        Image(systemName: "person")
                            .font(.system(size: 28))
                            .foregroundColor(.white.opacity(0.25))
                    }
                }

                LinearGradient(
                    colors: [.clear, .black.opacity(0.85)],
                    startPoint: .center,
                    endPoint: .bottom
                )

                if let name = performer.displayName {
                    Text(name)
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .foregroundColor(.white)
                        .lineLimit(2)
                        .padding(8)
                }

                if isPicking {
                    Color.black.opacity(0.55)
                    ProgressView().tint(AppTheme.accent)
                }
            }
        }
        .buttonStyle(.plain)
        .aspectRatio(3.0 / 4.0, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.white.opacity(0.06), lineWidth: 1)
        )
        .disabled(isPicking)
    }
}

// MARK: - بطاقة المشهد (أفقية بلمسة شريط الفيلم)

private struct SceneCard: View {
    let scene: ThePornDBScene
    let isPicking: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 0) {
                SprocketStrip()
                    .frame(width: 12)
                    .background(AppTheme.bg)

                ZStack(alignment: .bottomLeading) {
                    if let imageURL = scene.bestImage {
                        KFImage(URL(string: imageURL))
                            .cacheOriginalImage()
                            .backgroundDecode()
                            .placeholder {
                                ZStack { AppTheme.card; ProgressView().tint(AppTheme.accent) }
                            }
                            .onFailureView {
                                ZStack {
                                    AppTheme.card
                                    Image(systemName: "film")
                                        .font(.system(size: 28))
                                        .foregroundColor(.white.opacity(0.25))
                                }
                            }
                            .resizable()
                            .scaledToFill()
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .clipped()
                    } else {
                        ZStack {
                            AppTheme.card
                            Image(systemName: "film")
                                .font(.system(size: 28))
                                .foregroundColor(.white.opacity(0.25))
                        }
                    }

                    LinearGradient(
                        colors: [.clear, .black.opacity(0.9)],
                        startPoint: .top,
                        endPoint: .bottom
                    )

                    VStack(alignment: .leading, spacing: 5) {
                        Spacer()
                        if let title = scene.displayTitle {
                            Text(title)
                                .font(.system(size: 14, weight: .bold, design: .rounded))
                                .foregroundColor(.white)
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)
                        }
                        HStack(spacing: 6) {
                            if let site = scene.site, !site.isEmpty {
                                Text(site)
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundColor(.black)
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 3)
                                    .background(TPDBAccent.gold, in: Capsule())
                            }
                            if let date = scene.date, !date.isEmpty {
                                Text(date)
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundColor(.white.opacity(0.5))
                            }
                        }
                    }
                    .padding(11)

                    if isPicking {
                        Color.black.opacity(0.55)
                        ProgressView().tint(AppTheme.accent)
                    }
                }
            }
        }
        .buttonStyle(.plain)
        .aspectRatio(16.0 / 9.0 + 0.1, contentMode: .fit)
        .background(AppTheme.card)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.white.opacity(0.06), lineWidth: 1)
        )
        .disabled(isPicking)
    }
}

/// شريط ثقوب سينمائي صغير على حافة بطاقة المشهد — تفصيلة بصرية
/// تُذكّر بشريط الفيلم بدل أن تكون مجرد بطاقة عادية
private struct SprocketStrip: View {
    var body: some View {
        GeometryReader { geo in
            let holeSize: CGFloat = 3.5
            let spacing: CGFloat = 9
            let count = max(Int(geo.size.height / spacing), 1)
            VStack(spacing: spacing - holeSize) {
                ForEach(0..<count, id: \.self) { _ in
                    Circle()
                        .fill(AppTheme.cardElevated)
                        .frame(width: holeSize, height: holeSize)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, spacing / 2)
        }
    }
}
