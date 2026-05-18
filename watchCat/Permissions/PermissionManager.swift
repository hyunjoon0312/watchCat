import AppKit
import ApplicationServices
import ServiceManagement
import SwiftUI

@MainActor
final class PermissionManager: ObservableObject {
    static let shared = PermissionManager()

    @Published private(set) var states: [PermissionKind: Bool] = [:]
    @Published private(set) var launchAtLoginEnabled: Bool = false

    /// SPEC §F3 multi-browser — Apple Events permission is granted *per target
    /// bundle*. We probe each supported browser; the consolidated state for the
    /// dashboard is "true if at least one browser is reachable" so users who
    /// only use Safari aren't nagged about Chrome.
    private let browserBundleIDs: [String] = BrowserKind.allCases.map(\.bundleID)
    private var activeObserver: NSObjectProtocol?

    private init() {
        refresh()
        // The system permission UI lives outside watchCat, so we never see a
        // "permission granted" callback. Re-check whenever the user comes back
        // to the app from System Settings.
        activeObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    deinit {
        if let activeObserver {
            NotificationCenter.default.removeObserver(activeObserver)
        }
    }

    func refresh() {
        states = [
            .accessibility: AXIsProcessTrusted(),
            .screenRecording: CGPreflightScreenCaptureAccess(),
            .appleEvents: checkAnyBrowserAutomation(prompt: false)
        ]
        launchAtLoginEnabled = SMAppService.mainApp.status == .enabled
    }

    /// watchCat이 기본 동작에 필요한 핵심 권한(접근성·화면 기록)이 부여돼
    /// 있는지. brew 업그레이드 직후 ad-hoc 서명 cdhash가 바뀌면 TCC가 같은
    /// 앱으로 못 알아봐 false로 떨어진다 — 이때 배너로 사용자에게 재인증을
    /// 안내한다.
    var needsCoreReauth: Bool {
        let a = states[.accessibility] ?? false
        let s = states[.screenRecording] ?? false
        return !(a && s)
    }

    /// 재인증이 필요한 핵심 권한만 추려 반환. 가이드 시트에서 "어떤 항목을
    /// 다시 켜야 하는지" 사용자에게 정확히 알려주기 위함.
    var missingCorePermissions: [PermissionKind] {
        [.accessibility, .screenRecording].filter { states[$0] != true }
    }

    func request(_ kind: PermissionKind) {
        switch kind {
        case .accessibility:
            let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
            _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
        case .screenRecording:
            // macOS force-terminates apps when Screen Recording TCC state
            // changes — there's no graceful re-evaluation. Detach a watcher
            // process that reopens watchCat after we die so the user doesn't
            // have to manually relaunch from Finder.
            Self.spawnRelauncherIfTerminated(timeoutSeconds: 30)
            _ = CGRequestScreenCaptureAccess()
        case .appleEvents:
            // Same defensive relauncher: prompts can occasionally cascade and
            // surface edge cases that leave the app in a bad state. Spawning
            // is safe — if we never die, the relauncher loop just gives up.
            Self.spawnRelauncherIfTerminated(timeoutSeconds: 30)
            _ = checkAnyBrowserAutomation(prompt: true)
        }
        // System dialogs may take a moment; re-check shortly after.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            self?.refresh()
        }
    }

    /// Fire-and-forget shell helper that polls our PID for `timeoutSeconds`
    /// seconds. The moment our process disappears (TCC kill), it `open`s the
    /// app bundle so watchCat comes back automatically. If we never die
    /// (user denied / closed the prompt), the loop just exits.
    private static func spawnRelauncherIfTerminated(timeoutSeconds: Int) {
        let bundlePath = Bundle.main.bundlePath
        let myPID = ProcessInfo.processInfo.processIdentifier
        let script = """
        PID=\(myPID)
        for i in $(seq 1 \(timeoutSeconds)); do
          if ! kill -0 $PID 2>/dev/null; then
            sleep 1
            /usr/bin/open -n "\(bundlePath)"
            exit 0
          fi
          sleep 1
        done
        """
        let task = Process()
        task.launchPath = "/bin/sh"
        task.arguments = ["-c", script]
        try? task.run()
    }

    func openSystemSettings(for kind: PermissionKind) {
        guard let url = kind.systemSettingsURL else { return }
        NSWorkspace.shared.open(url)
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                }
            } else {
                if SMAppService.mainApp.status == .enabled {
                    try SMAppService.mainApp.unregister()
                }
            }
        } catch {
            NSLog("[watchCat] Launch at Login toggle failed: \(error.localizedDescription)")
        }
        refresh()
    }

    /// Probe Apple Events permission across every supported browser. Returns
    /// `true` if any one of them is reachable — that's enough for watchCat to
    /// be useful. When `prompt: true`, macOS surfaces the TCC dialog for any
    /// browser that's installed but unanswered.
    private func checkAnyBrowserAutomation(prompt: Bool) -> Bool {
        var anyGranted = false
        for bundleID in browserBundleIDs {
            if checkAutomation(target: bundleID, prompt: prompt) {
                anyGranted = true
                // Keep iterating only when we're prompting — otherwise we'd
                // skip remaining browsers' prompts after the first hit.
                if !prompt { break }
            }
        }
        return anyGranted
    }

    private func checkAutomation(target bundleID: String, prompt: Bool) -> Bool {
        // Skip uninstalled browsers — calling AEDeterminePermissionToAutomateTarget
        // against a missing bundle can stall the prompt loop / produce confusing
        // TCC dialogs for apps the user doesn't even have. If they install the
        // browser later, the next refresh will pick it up.
        guard NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil else {
            return false
        }
        let target = NSAppleEventDescriptor(bundleIdentifier: bundleID)
        guard let descPtr = target.aeDesc else { return false }
        var desc = descPtr.pointee
        let typeWildCard: DescType = 0x2A2A2A2A  // '****'
        let status = AEDeterminePermissionToAutomateTarget(&desc, typeWildCard, typeWildCard, prompt)
        return status == noErr
    }
}
