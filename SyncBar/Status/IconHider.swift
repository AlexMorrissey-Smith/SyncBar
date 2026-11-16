import AppKit

/// Hides the sync apps' own menu bar icons by switching them off in macOS's
/// "Allow in the Menu Bar" settings, and briefly switches one back on when
/// SyncBar needs to open that app's panel.
///
/// Rules, from what macOS 27.3 does:
/// - Only hide an app once it is running and has created its status item.
///   An app that launches while switched off never creates one.
/// - When a hidden app quits, switch it back on right away, so its next
///   launch creates an item again.
/// - When SyncBar quits, switch everything it hid back on.
@MainActor
final class IconHider {
    /// Bundle IDs SyncBar has switched off.
    private(set) var hidden = Set<String>()
    /// Bundle IDs currently shown so their panel can open.
    private var revealed = Set<String>()
    private(set) var lastError: String?
    private var terminationObserver: NSObjectProtocol?

    init() {
        terminationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            guard let id = app?.bundleIdentifier else { return }
            MainActor.assumeIsolated {
                guard let self, self.hidden.contains(id) else { return }
                // OneDrive runs one process per account; wait until all are gone.
                guard NSRunningApplication.runningApplications(withBundleIdentifier: id).isEmpty else { return }
                self.show([id])
            }
        }
    }

    /// Brings the hidden set in line with what should be hidden.
    /// - Parameters:
    ///   - targets: apps whose icons should be hidden (empty to show all).
    ///   - itemsPresent: apps that currently have a status item.
    func update(targets: Set<String>, itemsPresent: Set<String>) {
        let toShow = hidden.subtracting(targets)
        if !toShow.isEmpty { show(toShow) }

        let toHide = targets
            .subtracting(hidden)
            .subtracting(revealed)
            .filter { itemsPresent.contains($0) }
        if !toHide.isEmpty { hide(toHide) }
    }

    func showAll() {
        if !hidden.isEmpty { show(hidden) }
    }

    func isHidden(_ bundleID: String) -> Bool { hidden.contains(bundleID) }

    /// Shows an app's icon, waits for its item to be drawn, runs `open`, and
    /// hides the icon again once the opened panel or menu closes.
    func withRevealed(_ bundleID: String, open: () async -> MenuBarItems.OpenedWindow?) async -> MenuBarItems.OpenedWindow? {
        guard hidden.contains(bundleID) else { return await open() }

        revealed.insert(bundleID)
        show([bundleID])
        // Give MenuBarAgent time to draw the item before pressing it; a press
        // on an undrawn item reports success and does nothing.
        try? await Task.sleep(for: .milliseconds(400))
        await waitForAgentItem(bundleID, timeout: .milliseconds(1500))

        let window = await open()
        if let window {
            while MenuBarItems.isOnScreen(window) {
                try? await Task.sleep(for: .milliseconds(300))
            }
        }
        revealed.remove(bundleID)
        hide([bundleID])
        return window
    }

    // MARK: - Private

    private func waitForAgentItem(_ bundleID: String, timeout: Duration) async {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while clock.now < deadline {
            if MenuBarItems.agentItems().contains(where: { $0.bundleID == bundleID }) { return }
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    private func hide(_ ids: Set<String>) {
        do {
            try NativeIconVisibility.setAllowed(false, for: ids)
            hidden.formUnion(ids)
            lastError = nil
        } catch {
            lastError = "Can't change menu bar settings (\(error))."
        }
    }

    private func show(_ ids: Set<String>) {
        do {
            try NativeIconVisibility.setAllowed(true, for: ids)
            hidden.subtract(ids)
            lastError = nil
        } catch {
            lastError = "Can't change menu bar settings (\(error))."
        }
    }
}
