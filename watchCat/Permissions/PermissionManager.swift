import AppKit
import ApplicationServices
import ServiceManagement
import SwiftUI

@MainActor
final class PermissionManager: ObservableObject {
    static let shared = PermissionManager()

    @Published private(set) var states: [PermissionKind: Bool] = [:]
    @Published private(set) var launchAtLoginEnabled: Bool = false

    private let chromeBundleID = "com.google.Chrome"
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
            .appleEvents: checkChromeAutomation(prompt: false)
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
            _ = checkChromeAutomation(prompt: true)
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

    private func checkChromeAutomation(prompt: Bool) -> Bool {
        let target = NSAppleEventDescriptor(bundleIdentifier: chromeBundleID)
        guard let descPtr = target.aeDesc else { return false }
        var desc = descPtr.pointee
        let typeWildCard: DescType = 0x2A2A2A2A  // '****'
        let status = AEDeterminePermissionToAutomateTarget(&desc, typeWildCard, typeWildCard, prompt)
        return status == noErr
    }
}
