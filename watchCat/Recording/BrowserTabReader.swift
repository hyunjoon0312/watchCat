import AppKit
import Foundation

/// Browsers that watchCat can read the active tab from. Adding a new browser
/// means: 1) extend this enum, 2) provide an AppleScript in `BrowserTabReader`,
/// 3) bump the Info.plist usage description to mention it.
///
/// Whale is Chromium-based and accepts Chrome's AppleScript dictionary
/// verbatim, so it reuses the Chrome script with its own bundle ID. Safari
/// uses Apple's distinct dictionary (`name of current tab` etc.) and gets a
/// dedicated script.
enum BrowserKind: String, CaseIterable, Equatable {
    case chrome = "com.google.Chrome"
    case whale  = "com.naver.Whale"
    case safari = "com.apple.Safari"

    var bundleID: String { rawValue }

    var displayName: String {
        switch self {
        case .chrome: return "Chrome"
        case .whale:  return "Whale"
        case .safari: return "Safari"
        }
    }

    static func from(bundleID: String?) -> BrowserKind? {
        guard let bundleID else { return nil }
        return BrowserKind(rawValue: bundleID)
    }
}

/// Outcome of a tab read. Same shape across all browsers — callers don't need
/// to special-case Safari vs. Chrome.
enum BrowserTabResult: Equatable {
    case tab(url: String, title: String, isIncognito: Bool)
    case browserNotRunning
    case noActiveTab
    case permissionDenied
    case failure(String)
}

@MainActor
protocol BrowserTabReading {
    func readActiveTab(for browser: BrowserKind) -> BrowserTabResult
}

@MainActor
final class BrowserTabReader: BrowserTabReading {
    /// SPEC §F3 — Chrome was the only supported browser in v0.1; kept here as a
    /// shorthand used in a handful of legacy code paths until everything reads
    /// `BrowserKind.chrome.bundleID` directly.
    static let chromeBundleID = BrowserKind.chrome.bundleID

    private var scripts: [BrowserKind: NSAppleScript] = [:]

    init() {
        // Chrome and Whale share the Chromium AppleScript dictionary. The mode
        // string is "incognito" on Chrome and "시크릿 모드" / "secret" on Whale —
        // we detect both downstream so private-window URLs collapse into the
        // shared incognito bucket regardless of source.
        for kind in [BrowserKind.chrome, .whale] {
            let src = """
            if application id "\(kind.bundleID)" is not running then return "NOT_RUNNING"
            tell application id "\(kind.bundleID)"
                if (count of windows) is 0 then return "NO_WINDOW"
                set theWindow to front window
                set theMode to mode of theWindow
                set theTab to active tab of theWindow
                set theURL to URL of theTab
                set theTitle to title of theTab
                return theMode & "\\t" & theURL & "\\t" & theTitle
            end tell
            """
            scripts[kind] = NSAppleScript(source: src)
        }
        // Safari's dictionary has no `mode` property and uses "current tab" +
        // "name of tab" (not "title"). It also can't report private-browsing
        // state via AppleScript — that's a known macOS limitation, not ours.
        // We emit an empty mode string so the parser keeps working.
        let safariSrc = """
        if application id "\(BrowserKind.safari.bundleID)" is not running then return "NOT_RUNNING"
        tell application id "\(BrowserKind.safari.bundleID)"
            if (count of windows) is 0 then return "NO_WINDOW"
            set theTab to current tab of front window
            set theURL to URL of theTab
            set theTitle to name of theTab
            return "" & "\\t" & theURL & "\\t" & theTitle
        end tell
        """
        scripts[.safari] = NSAppleScript(source: safariSrc)
    }

    func readActiveTab(for browser: BrowserKind) -> BrowserTabResult {
        guard let script = scripts[browser] else {
            return .failure("no script for \(browser.displayName)")
        }
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
        if raw == "NOT_RUNNING" { return .browserNotRunning }
        if raw == "NO_WINDOW" { return .noActiveTab }
        let parts = raw.components(separatedBy: "\t")
        guard parts.count >= 2 else { return .failure("unexpected format: \(raw)") }
        let mode = parts[0]
        let url = parts[1]
        let title = parts.count >= 3 ? parts[2] : ""
        // Cover the three terms browsers use for private windows. Safari emits
        // an empty mode (no API), so Safari private windows are recorded as
        // normal traffic — documented as a known limitation.
        let lowered = mode.lowercased()
        let isIncognito = lowered.contains("incognito")
            || lowered.contains("private")
            || mode.contains("시크릿")
        return .tab(url: url, title: title, isIncognito: isIncognito)
    }
}
