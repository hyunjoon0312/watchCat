import AppKit
import Combine
import SwiftUI

/// Owns the status-bar item and the popover that drops down from it. The
/// pre-redesign version built an `NSMenu`; this version hosts a custom SwiftUI
/// popover (`StatusBarPopoverView`) for a cleaner, RunCat-style panel with
/// today's summary, pause toggle, and three primary actions.
@MainActor
final class StatusBarController: NSObject {
    private let statusItem: NSStatusItem
    private var animator: MascotAnimator?
    private let sessionStore: SessionStore?

    /// Lazy-built so the SwiftUI view tree isn't constructed until the user
    /// first opens the popover. Tested manually — the menubar app launches
    /// noticeably faster on cold-start with this delayed.
    private lazy var popoverModel = StatusBarPopoverModel(sessionStore: sessionStore)
    private lazy var popover: NSPopover = makePopover()

    /// Click monitor that closes the popover on any out-of-popover click. The
    /// built-in `.transient` behavior covers most cases, but on multi-display
    /// setups we've seen it occasionally miss — this is a belt-and-suspenders
    /// catch.
    private var clickMonitor: Any?

    init(sessionStore: SessionStore?) {
        self.sessionStore = sessionStore
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        attachButton()
    }

    private func attachButton() {
        guard let button = statusItem.button else { return }
        button.imagePosition = .imageOnly
        // Left-click toggles the popover; right-click currently does the same
        // (no separate context menu — everything's in the popover now).
        button.action = #selector(togglePopover(_:))
        button.target = self
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        animator = MascotAnimator(button: button)
    }

    /// Wires the live web-recorder signals into the popover model. Called by
    /// `AppDelegate` after both objects exist.
    func attach(webRecorder: WebSessionRecorder) {
        popoverModel.attach(webRecorder: webRecorder)
    }

    // MARK: - Popover lifecycle

    private func makePopover() -> NSPopover {
        let pop = NSPopover()
        pop.behavior = .transient
        pop.animates = true
        let view = StatusBarPopoverView(
            model: popoverModel,
            onOpenDashboard: { [weak self] in self?.openDashboard() },
            onOpenSettings: { [weak self] in self?.openSettings() },
            onQuit: { NSApp.terminate(nil) },
            onClose: { [weak self] in self?.closePopover() }
        )
        pop.contentViewController = NSHostingController(rootView: view)
        // The hosting controller normally resizes to fit; setting an explicit
        // size avoids first-open flicker as SwiftUI computes its intrinsic size.
        pop.contentSize = NSSize(width: 360, height: 480)
        return pop
    }

    @objc private func togglePopover(_ sender: Any?) {
        if popover.isShown {
            closePopover()
        } else {
            showPopover()
        }
    }

    private func showPopover() {
        guard let button = statusItem.button else { return }
        // Refresh today's totals every time the user opens the popover so the
        // numbers don't read stale after long stretches of menubar inactivity.
        popoverModel.reload()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        NSApp.activate(ignoringOtherApps: true)
        installClickMonitor()
    }

    private func closePopover() {
        if popover.isShown { popover.performClose(nil) }
        removeClickMonitor()
    }

    private func installClickMonitor() {
        guard clickMonitor == nil else { return }
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor in self?.closePopover() }
        }
    }

    private func removeClickMonitor() {
        if let m = clickMonitor {
            NSEvent.removeMonitor(m)
            clickMonitor = nil
        }
    }

    // MARK: - Actions delegated from the popover

    private func openDashboard() {
        DashboardWindowController.shared.show(store: sessionStore)
    }

    private func openSettings() {
        SettingsWindowController.shared.show()
    }
}
