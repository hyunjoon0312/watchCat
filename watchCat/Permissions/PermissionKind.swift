import Foundation

enum PermissionKind: String, CaseIterable, Identifiable {
    case accessibility
    case screenRecording
    case appleEvents

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .accessibility: return "접근성"
        case .screenRecording: return "화면 기록"
        case .appleEvents: return "브라우저 자동화"
        }
    }

    var reason: String {
        switch self {
        case .accessibility:
            return "활성 앱 전환을 안정적으로 감지하기 위해 필요합니다."
        case .screenRecording:
            return "활성 창 정보를 정확히 얻기 위해 필요합니다."
        case .appleEvents:
            return "Chrome / Safari / NAVER Whale의 활성 탭(도메인)을 읽기 위해 필요합니다."
        }
    }

    var systemSettingsURL: URL? {
        let path: String
        switch self {
        case .accessibility:    path = "Privacy_Accessibility"
        case .screenRecording:  path = "Privacy_ScreenCapture"
        case .appleEvents:      path = "Privacy_Automation"
        }
        return URL(string: "x-apple.systempreferences:com.apple.preference.security?\(path)")
    }
}
