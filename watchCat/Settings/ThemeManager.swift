import AppKit
import Combine

/// User-facing theme choice. `.system` defers to macOS's appearance setting,
/// `.light` / `.dark` pin the app regardless of the system.
enum ThemePreference: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .system: return "자동 (시스템)"
        case .light:  return "라이트"
        case .dark:   return "다크"
        }
    }

    /// SF Symbol shown on the icon picker. `circle.lefthalf.filled` reads as
    /// "half-and-half / depends on environment" for the auto option.
    var iconName: String {
        switch self {
        case .system: return "circle.lefthalf.filled"
        case .light:  return "sun.max.fill"
        case .dark:   return "moon.fill"
        }
    }

    /// `nil` means "follow system" — assigning nil to `NSApp.appearance`
    /// clears any explicit override and lets the OS-level setting through.
    var appearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light:  return NSAppearance(named: .aqua)
        case .dark:   return NSAppearance(named: .darkAqua)
        }
    }
}

/// Owns the persisted theme preference and applies it to `NSApp.appearance`.
/// Created once at launch (via `ThemeManager.shared`) so the choice takes
/// effect before any window opens, then re-applies whenever the user picks
/// a different option in Settings.
@MainActor
final class ThemeManager: ObservableObject {
    static let shared = ThemeManager()
    private static let key = "watchCat.themePreference"

    @Published var preference: ThemePreference {
        didSet {
            UserDefaults.standard.set(preference.rawValue, forKey: Self.key)
            apply()
        }
    }

    private init() {
        let raw = UserDefaults.standard.string(forKey: Self.key) ?? ""
        self.preference = ThemePreference(rawValue: raw) ?? .system
        apply()
    }

    func apply() {
        NSApp.appearance = preference.appearance
    }
}
