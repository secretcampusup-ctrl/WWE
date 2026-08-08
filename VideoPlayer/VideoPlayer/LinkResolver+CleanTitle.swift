import Foundation

/// فلتر استخراج العنوان الوصفي النظيف من اسم ملف بالصيغة الشائعة:
/// Studio.YY.MM.DD.Actor.Name.Descriptive.Title.2160p.MP4.XXX-WRB
///
/// قواعد التمييز:
/// 1) الاستوديو (مهمل): أول كلمة قبل أول نقطة (.) في السطر.
/// 2) التاريخ (مهمل): الجزء المكوّن من أرقام ونقاط مباشرة بعد الاستوديو (مثال: 26.08.05).
/// 3) العنوان الوصفي (مطلوب): كل ما تبقى بعد ذلك، ويستمر حتى تظهر
///    الدقة (2160p) أو صيغة الملف (MP4) أو مجموعة الرفع (WRB, NBQ).
/// 4) المهمل الآخر: 2160p, MP4, WEBrip, XXX, WRB, NBQ, VSEX تُحذف نهائيًا،
///    وأي شيء بعد أول ظهور لها يُعتبر معلومات تقنية ويُتجاهل.
/// النتيجة: أسماء الممثلين + العنوان الوصفي فقط، مفصولة بمسافة واحدة.
extension LinkResolver {

    /// قائمة الكلمات المهملة (الدقة/الصيغة/مجموعة الرفع)
    private static let junkTitleTokens: Set<String> = [
        "2160P", "MP4", "WEBRIP", "XXX", "WRB", "NBQ", "VSEX"
    ]

    /// يتحقق ما إذا كان جزء معيّن (أو دمج أجزاء بشرطة مثل "XXX-WRB") مهملاً بالكامل
    private static func isJunkTitleToken(_ token: String) -> Bool {
        let upper = token.uppercased()
        if junkTitleTokens.contains(upper) { return true }
        // يغطي حالات الدمج بشرطة، مثل "XXX-WRB" أو "MP4-NBQ"
        let subParts = upper.split(separator: "-").map(String.init)
        return !subParts.isEmpty && subParts.allSatisfy { junkTitleTokens.contains($0) }
    }

    /// يستخرج عنوان العرض النظيف (أسماء الممثلين + العنوان الوصفي) من اسم ملف خام.
    ///
    /// مثال:
    /// ```
    /// let raw = "Studio.26.08.05.John.Doe.Jane.Roe.Some.Descriptive.Title.2160p.MP4.XXX-WRB"
    /// LinkResolver.cleanDisplayTitle(fromFilename: raw)
    /// // -> "John Doe Jane Roe Some Descriptive Title"
    /// ```
    static func cleanDisplayTitle(fromFilename filename: String) -> String {
        var parts = filename
            .split(separator: ".", omittingEmptySubsequences: true)
            .map(String.init)

        guard !parts.isEmpty else { return filename }

        // 1) الاستوديو (مهمل): أول جزء قبل أول نقطة
        parts.removeFirst()

        // 2) التاريخ (مهمل): أجزاء رقمية متتالية مباشرة بعد الاستوديو
        while let first = parts.first, !first.isEmpty, first.allSatisfy({ $0.isNumber }) {
            parts.removeFirst()
        }

        // 3) العنوان الوصفي (مطلوب): يستمر حتى ظهور أول علامة مهملة، ثم يتوقف
        var titleParts: [String] = []
        for token in parts {
            if isJunkTitleToken(token) { break }
            titleParts.append(token)
        }

        // إن لم يتبقَّ شيء (اسم ملف غير متوقع)، أعد الاسم كما هو بدل نص فارغ
        guard !titleParts.isEmpty else { return filename }

        return titleParts.joined(separator: " ")
    }
}
