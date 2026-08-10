import Foundation

/// إعدادات ThePornDB API
/// مسؤولة عن تخزين مفتاح API والإعدادات
struct ThePornDBSettings {

    // Temporarily paused, not removed. Flip this to true when adult metadata
    // should be enabled again. TMDB is the only active metadata provider now.
    static let isEnabled = false

    /// الحصول على مفتاح API من UserDefaults
    static var apiKey: String {
        get {
            if let userKey = UserDefaults.standard.string(forKey: "theporndb_api_key"), !userKey.isEmpty {
                return userKey
            }
            return "6r14sZOEGrWSD7L9E1MZkP4g1wNSGrSMyIWh5dOh5f271c34"
        }
        set {
            UserDefaults.standard.set(newValue, forKey: "theporndb_api_key")
        }
    }

    static var hasValidAPIKey: Bool {
        isEnabled && !apiKey.isEmpty
    }

    static let baseURL = "https://api.theporndb.net"

    struct PerformerSearch {
        static var defaultLimit: Int {
            get {
                UserDefaults.standard.integer(forKey: "theporndb_performer_limit") > 0
                    ? UserDefaults.standard.integer(forKey: "theporndb_performer_limit")
                    : 20
            }
            set {
                UserDefaults.standard.set(newValue, forKey: "theporndb_performer_limit")
            }
        }

        static var imageQuality: ImageQuality {
            get {
                let raw = UserDefaults.standard.string(forKey: "theporndb_image_quality") ?? "high"
                return ImageQuality(rawValue: raw) ?? .high
            }
            set {
                UserDefaults.standard.set(newValue.rawValue, forKey: "theporndb_image_quality")
            }
        }
    }

    struct SceneSearch {
        static var defaultLimit: Int {
            get {
                UserDefaults.standard.integer(forKey: "theporndb_scene_limit") > 0
                    ? UserDefaults.standard.integer(forKey: "theporndb_scene_limit")
                    : 20
            }
            set {
                UserDefaults.standard.set(newValue, forKey: "theporndb_scene_limit")
            }
        }

        static var filterByYear: Bool {
            get {
                UserDefaults.standard.bool(forKey: "theporndb_filter_year")
            }
            set {
                UserDefaults.standard.set(newValue, forKey: "theporndb_filter_year")
            }
        }

        static var year: Int {
            get {
                UserDefaults.standard.integer(forKey: "theporndb_year")
            }
            set {
                UserDefaults.standard.set(newValue, forKey: "theporndb_year")
            }
        }
    }

    enum ImageQuality: String {
        case low = "low"
        case medium = "medium"
        case high = "high"
    }
}