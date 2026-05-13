import Foundation
import AppKit

enum ChromeTabResult: Equatable {
    case tab(url: String, title: String, isIncognito: Bool)
    case chromeNotRunning
    case noActiveTab
    case permissionDenied
    case failure(String)
}

/// SPEC §F3.1 — read Chrome's active tab via AppleScript. The reader returns a
/// structured `ChromeTabResult` so callers can distinguish "no data" from
/// "permission missing" without parsing error strings.
@MainActor
protocol ChromeTabReading {
    func readActiveTab() -> ChromeTabResult
}

@MainActor
final class ChromeTabReader: ChromeTabReading {
    static let chromeBundleID = "com.google.Chrome"

    private let script: NSAppleScript? = {
        let source = """
        if application id "\(chromeBundleID)" is not running then return "NOT_RUNNING"
        tell application id "\(chromeBundleID)"
            if (count of windows) is 0 then return "NO_WINDOW"
            set theWindow to front window
            set theMode to mode of theWindow
            set theTab to active tab of theWindow
            set theURL to URL of theTab
            set theTitle to title of theTab
            return theMode & "\\t" & theURL & "\\t" & theTitle
        end tell
        """
        return NSAppleScript(source: source)
    }()

    func readActiveTab() -> ChromeTabResult {
        guard let script else { return .failure("script compile failed") }
        var errorInfo: NSDictionary?
        let result = script.executeAndReturnError(&errorInfo)
        if let errorInfo {
            // -1743 = errAEEventNotPermitted (TCC Apple Events denied)
            // -1744 = user cancelled the prompt
            let code = (errorInfo["NSAppleScriptErrorNumber"] as? Int) ?? 0
            if code == -1743 || code == -1744 {
                return .permissionDenied
            }
            let msg = (errorInfo["NSAppleScriptErrorMessage"] as? String) ?? "AppleScript error \(code)"
            return .failure(msg)
        }
        guard let raw = result.stringValue else { return .failure("empty result") }
        if raw == "NOT_RUNNING" { return .chromeNotRunning }
        if raw == "NO_WINDOW" { return .noActiveTab }
        let parts = raw.components(separatedBy: "\t")
        guard parts.count >= 2 else { return .failure("unexpected format: \(raw)") }
        let mode = parts[0]
        let url = parts[1]
        let title = parts.count >= 3 ? parts[2] : ""
        let isIncognito = mode.lowercased().contains("incognito")
        return .tab(url: url, title: title, isIncognito: isIncognito)
    }
}
