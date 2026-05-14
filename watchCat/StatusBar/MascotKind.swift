import Foundation

/// Mascot characters the user can pick in Settings. Each value's `rawValue`
/// matches the asset-catalog prefix the regen script writes —
/// `cloud-cat-record-1-left`, `bean-shiba-pause-2`, etc. — so adding a new
/// mascot is a two-line change here plus a new `assets/mascot/<rawValue>/`
/// folder.
enum MascotKind: String, CaseIterable, Identifiable {
    case cloudCat = "cloud-cat"
    case cheeseCat = "cheese-cat"
    case calicoCat = "calico-cat"
    case beanShiba = "bean-shiba"
    case cozyBear = "cozy-bear"
    case roundOwl = "round-owl"
    case chillCapybara = "chill-capybara"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .cloudCat:      return "구름냥"
        case .cheeseCat:     return "치즈냥"
        case .calicoCat:     return "노랑귀냥"
        case .beanShiba:     return "방긋시바"
        case .cozyBear:      return "잿빛곰"
        case .roundOwl:      return "초롱부엉"
        case .chillCapybara: return "느긋바라"
        }
    }

    /// SPEC §F0/F1 — value persisted across launches. Defaults to `.cloudCat`
    /// so the app keeps shipping the original watchCat mascot until the user
    /// picks something else.
    static let userDefaultsKey = "watchCat.mascotKind"
    static let defaultKind: MascotKind = .cloudCat

    static var current: MascotKind {
        get {
            let raw = UserDefaults.standard.string(forKey: userDefaultsKey) ?? ""
            return MascotKind(rawValue: raw) ?? defaultKind
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: userDefaultsKey)
            NotificationCenter.default.post(name: .mascotKindDidChange, object: nil)
        }
    }
}

extension Notification.Name {
    /// Broadcast when the user picks a different mascot. `MascotAnimator`
    /// listens so the status-bar icon swaps live without restart.
    static let mascotKindDidChange = Notification.Name("watchCat.mascotKindDidChange")
}
