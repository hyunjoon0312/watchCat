import Foundation

/// SPEC §1 비기능 요건 — 보존 기간 기본 90일(설정 가능). Persisted in UserDefaults so
/// changes survive relaunch, with a small allow-list of supported values to keep
/// the UI uncomplicated. "Forever" (0) disables automatic pruning entirely.
enum RetentionSettings {
    static let userDefaultsKey = "watchCat.retentionDays"

    /// Allowed values shown in the picker. 0 = 보관 무제한.
    static let allowedDays: [Int] = [7, 30, 90, 180, 365, 0]
    static let defaultDays: Int = 90

    static var days: Int {
        get {
            let d = UserDefaults.standard
            // `object(forKey:)` distinguishes "not set" from a stored 0.
            guard let raw = d.object(forKey: userDefaultsKey) as? Int else { return defaultDays }
            return allowedDays.contains(raw) ? raw : defaultDays
        }
        set {
            let valid = allowedDays.contains(newValue) ? newValue : defaultDays
            UserDefaults.standard.set(valid, forKey: userDefaultsKey)
        }
    }

    static func displayLabel(for days: Int) -> String {
        if days == 0 { return "무제한" }
        if days == 365 { return "1년" }
        if days == 7 { return "1주" }
        if days == 30 { return "1개월" }
        if days == 90 { return "3개월" }
        if days == 180 { return "6개월" }
        return "\(days)일"
    }
}
