import Foundation

enum ThePornDBError: Error, LocalizedError {
    case missingAPIKey
    case invalidURL
    case invalidResponse
    case decodingError(Error)
    /// نفس خطأ فك الترميز، لكن مع نص الاستجابة الخام كما وصل من الخادم،
    /// حتى يظهر في واجهة التطبيق مباشرة بدون الحاجة لـ Xcode console
    case decodingErrorWithRaw(Error, raw: String)
    case serverError(Int)
    case unauthorized
    case networkError(Error)
    case timeout
    case apiError(String)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey: return "API key is missing"
        case .invalidURL: return "Invalid URL"
        case .invalidResponse: return "Invalid server response"
        case .decodingError(let e): return "Data decoding error: \(e.localizedDescription)"
        case .decodingErrorWithRaw(let e, let raw):
            let snippet = raw.isEmpty ? "(Empty)" : String(raw.prefix(500))
            return "Data decoding error: \(e.localizedDescription)\n\nRaw server response:\n\(snippet)"
        case .serverError(let code): return "Server error (\(code))"
        case .unauthorized: return "Invalid API key"
        case .networkError(let e): return "Network error: \(e.localizedDescription)"
        case .timeout: return "Request timed out"
        case .apiError(let msg): return msg
        }
    }
}

struct ThePornDBPerformer: Identifiable, Codable {
    let id: String?
    let name: String?
    let slug: String?
    let image: String?
    let thumbnail: String?
    let poster: String?
    let avatar: String?
    let extras: PerformerExtras?

    var bestImage: String? { image ?? thumbnail ?? poster ?? avatar ?? extras?.avatar }
}

/// يفك أي قيمة قادمة كنص أو رقم أو Bool وتحوّلها كلها إلى String
/// حتى لو الـ API غيّر نوع الحقل (مثلاً height كرقم بدل نص) ما ينهار الـ decode كامل
struct LossyString: Codable {
    let value: String

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let s = try? container.decode(String.self) {
            value = s
        } else if let i = try? container.decode(Int.self) {
            value = String(i)
        } else if let d = try? container.decode(Double.self) {
            value = String(d)
        } else if let b = try? container.decode(Bool.self) {
            value = String(b)
        } else {
            value = ""
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(value)
    }
}

/// يفك مصفوفة نصوص حتى لو الـ API رجّعها كنص واحد بدل مصفوفة
struct LossyStringArray: Codable {
    let values: [String]

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let arr = try? container.decode([String].self) {
            values = arr
        } else if let arr = try? container.decode([LossyString].self) {
            values = arr.map { $0.value }
        } else if let s = try? container.decode(String.self) {
            values = s.isEmpty ? [] : [s]
        } else {
            values = []
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(values)
    }
}

extension ThePornDBPerformer {
    struct PerformerExtras: Codable {
        private let _avatar: LossyString?
        private let _birthday: LossyString?
        private let _nationality: LossyString?
        private let _ethnicity: LossyString?
        private let _gender: LossyString?
        private let _eye_color: LossyString?
        private let _hair_color: LossyString?
        private let _height: LossyString?
        private let _weight: LossyString?
        private let _measurements: LossyString?
        private let _aliases: LossyStringArray?
        private let _tattoos: LossyStringArray?
        private let _piercings: LossyStringArray?

        var avatar: String? { _avatar?.value }
        var birthday: String? { _birthday?.value }
        var nationality: String? { _nationality?.value }
        var ethnicity: String? { _ethnicity?.value }
        var gender: String? { _gender?.value }
        var eye_color: String? { _eye_color?.value }
        var hair_color: String? { _hair_color?.value }
        var height: String? { _height?.value }
        var weight: String? { _weight?.value }
        var measurements: String? { _measurements?.value }
        var aliases: [String]? { _aliases?.values }
        var tattoos: [String]? { _tattoos?.values }
        var piercings: [String]? { _piercings?.values }

        enum CodingKeys: String, CodingKey {
            case _avatar = "avatar"
            case _birthday = "birthday"
            case _nationality = "nationality"
            case _ethnicity = "ethnicity"
            case _gender = "gender"
            case _eye_color = "eye_color"
            case _hair_color = "hair_color"
            case _height = "height"
            case _weight = "weight"
            case _measurements = "measurements"
            case _aliases = "aliases"
            case _tattoos = "tattoos"
            case _piercings = "piercings"
        }
    }
}

struct ThePornDBPerformersResponse: Codable {
    let data: [ThePornDBPerformer]?
    let performers: [ThePornDBPerformer]?
    let results: [ThePornDBPerformer]?

    var list: [ThePornDBPerformer] { data ?? performers ?? results ?? [] }
}

/// يفك حقل "site" حتى لو الـ API رجّعه ككائن {"id":.., "name":"..."} بدل نص بسيط
struct LossySite: Codable {
    let name: String?

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let s = try? container.decode(String.self) {
            name = s
        } else if let dict = try? container.decode([String: LossyJSONValue].self) {
            name = dict["name"]?.stringValue ?? dict["title"]?.stringValue
        } else {
            name = nil
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(name ?? "")
    }
}

/// قيمة JSON عامة (نص/رقم/Bool) تُستخدم لقراءة حقول داخل كائن غير معروف الشكل مسبقاً
struct LossyJSONValue: Codable {
    let stringValue: String?

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let s = try? container.decode(String.self) {
            stringValue = s
        } else if let i = try? container.decode(Int.self) {
            stringValue = String(i)
        } else if let d = try? container.decode(Double.self) {
            stringValue = String(d)
        } else {
            stringValue = nil
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(stringValue ?? "")
    }
}

struct ThePornDBScene: Identifiable, Codable {
    private let _id: LossyString?
    let title: String?
    let slug: String?
    private let _site: LossySite?
    let date: String?
    let poster: String?
    let thumbnail: String?
    private let _images: LossyStringArray?
    let performers: [PerformerRef]?
    let tags: [TagRef]?

    var id: String? { _id?.value }
    var site: String? { _site?.name }
    var images: [String]? { _images?.values }

    var bestImage: String? { poster ?? thumbnail ?? images?.first }
    var tagNames: [String] { (tags ?? []).compactMap { $0.name } }

    enum CodingKeys: String, CodingKey {
        case _id = "id"
        case title, slug
        case _site = "site"
        case date, poster, thumbnail
        case _images = "images"
        case performers, tags
    }
}

extension ThePornDBScene {
    struct PerformerRef: Codable {
        private let _id: LossyString?
        let name: String?
        let image: String?

        var id: String? { _id?.value }

        enum CodingKeys: String, CodingKey {
            case _id = "id"
            case name, image
        }
    }

    /// A scene tag. The API is inconsistent about whether tags come back as
    /// plain strings or `{"id": ..., "name": ...}` objects, so this accepts either.
    struct TagRef: Codable {
        let name: String?

        init(from decoder: Decoder) throws {
            if let container = try? decoder.singleValueContainer(),
               let plain = try? container.decode(String.self) {
                name = plain
                return
            }
            let keyed = try decoder.container(keyedBy: CodingKeys.self)
            name = try keyed.decodeIfPresent(String.self, forKey: .name)
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encode(name ?? "")
        }

        enum CodingKeys: String, CodingKey {
            case name
        }
    }
}

struct ThePornDBScenesResponse: Codable {
    let data: [ThePornDBScene]?
    let scenes: [ThePornDBScene]?
    let results: [ThePornDBScene]?

    var list: [ThePornDBScene] { data ?? scenes ?? results ?? [] }
}