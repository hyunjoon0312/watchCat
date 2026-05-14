import Foundation

/// Mascot characters the user can pick in Settings. Each value's `rawValue`
/// matches the asset-catalog prefix the regen script writes — `cat-record-1-left`,
/// `shiba-pause-2`, etc. — so adding a new mascot is a two-line change here
/// plus a new `assets/mascot/<rawValue>/` folder.
enum MascotKind: String, CaseIterable, Identifiable {
    case cat
    case orangeCat = "orange-cat"
    case shiba
    case owl
    case capybara

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .cat:        return "고양이"
        case .orangeCat:  return "주황 고양이"
        case .shiba:      return "시바견"
        case .owl:        return "부엉이"
        case .capybara:   return "카피바라"
        }
    }

    /// One-line "what's this mascot like" copy shown under the picker. Helps
    /// the user pick the personality that fits their vibe.
    var blurb: String {
        switch self {
        case .cat:        return "기본 고양이 — 흰 본체 + 핑크 코"
        case .orangeCat:  return "둥글둥글 통통한 주황 태비"
        case .shiba:      return "황갈 + 흰 머즐의 시바 강아지"
        case .owl:        return "큰 디스크 눈으로 지켜보는 부엉이"
        case .capybara:   return "느긋한 표정의 카피바라"
        }
    }

    /// SPEC §F0/F1 — value persisted across launches. Defaults to `.cat` so the
    /// app keeps shipping the original watchCat mascot until the user picks
    /// something else.
    static let userDefaultsKey = "watchCat.mascotKind"
    static let defaultKind: MascotKind = .cat

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
