import AppKit
import SwiftUI

/// Owns the dashboard window lifecycle. One shared controller — re-clicking the
/// menu item just refocuses the existing window instead of stacking new ones.
@MainActor
final class DashboardWindowController: NSObject, NSWindowDelegate {
    static let shared = DashboardWindowController()

    private var window: NSWindow?

    /// Caller injects the live SessionStore; we don't keep a strong reference so
    /// closing/reopening the dashboard always re-binds to the current store.
    func show(store: SessionStore?) {
        if let w = window {
            w.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let root = DashboardView(store: store)
        let hosting = NSHostingController(rootView: root)
        let w = NSWindow(contentViewController: hosting)
        w.title = "watchCat 대시보드"
        w.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        w.titlebarAppearsTransparent = true
        // Initial size comfortable for every period; minSize prevents content
        // from clipping when the user shrinks the window after a period swap.
        w.setContentSize(NSSize(width: 1200, height: 820))
        w.contentMinSize = NSSize(width: 1140, height: 700)
        w.center()
        w.isReleasedWhenClosed = false
        w.delegate = self
        window = w
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    nonisolated func windowWillClose(_ notification: Notification) {
        Task { @MainActor in self.window = nil }
    }
}
