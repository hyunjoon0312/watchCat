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

    func request(_ kind: PermissionKind) {
        switch kind {
        case .accessibility:
            let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
            _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
        case .screenRecording:
            _ = CGRequestScreenCaptureAccess()
        case .appleEvents:
            // Prompt for every supported browser. macOS only shows a prompt for
            // browsers that are installed *and* haven't been answered before,
            // so this is a no-op for missing browsers / already-granted ones.
            _ = checkAnyBrowserAutomation(prompt: true)
        }
        // System dialogs may take a moment; re-check shortly after.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            self?.refresh()
        }
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
        let target = NSAppleEventDescriptor(bundleIdentifier: bundleID)
        guard let descPtr = target.aeDesc else { return false }
        var desc = descPtr.pointee
        let typeWildCard: DescType = 0x2A2A2A2A  // '****'
        let status = AEDeterminePermissionToAutomateTarget(&desc, typeWildCard, typeWildCard, prompt)
        return status == noErr
    }
}
