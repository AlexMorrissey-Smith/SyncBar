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
        guard hidden.contains(bundleID) else {
            Log.write("\(bundleID) not hidden, pressing directly")
            return await open()
        }
        Log.write("revealing \(bundleID)")

        revealed.insert(bundleID)
        show([bundleID])
        // Give MenuBarAgent time to draw the item before pressing it; a press
        // on an undrawn item reports success and does nothing.
        try? await Task.sleep(for: .milliseconds(400))
        let drawn = await waitForAgentItem(bundleID, timeout: .milliseconds(1500))
        Log.write("\(bundleID) item drawn: \(drawn)")

        let window = await open()
        Log.write("\(bundleID) opened window: \(window.map { NSStringFromRect($0.frame) } ?? "none")")
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

    @discardableResult
    private func waitForAgentItem(_ bundleID: String, timeout: Duration) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while clock.now < deadline {
            if MenuBarItems.agentItems().contains(where: { $0.bundleID == bundleID }) { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return false
    }

    /// MenuBarAgent can stop reacting to switch changes after running for a
    /// long time (seen after a week of uptime on macOS 27.3): the setting is
    /// stored but the icons stay. A fresh MenuBarAgent applies it at launch
    /// and reacts live again. SyncBar checks each hide and, if the icons are
    /// still drawn, restarts MenuBarAgent (launchd relaunches it at once).
    private var lastAgentRestart = Date.distantPast
    private static let agentRestartInterval: TimeInterval = 10 * 60

    private func verifyHidden(_ ids: Set<String>) {
        Task { @MainActor [weak self] in
            // Some apps (Nextcloud) take a few seconds to drop their item.
            try? await Task.sleep(for: .seconds(4))
            guard let self else { return }
            let stillHidden = ids.intersection(self.hidden).subtracting(self.revealed)
            let drawn = Set(MenuBarItems.agentItems().compactMap(\.bundleID)).intersection(stillHidden)
            guard !drawn.isEmpty else { return }
            guard Date().timeIntervalSince(self.lastAgentRestart) > Self.agentRestartInterval else {
                Log.write("hiding: \(drawn.sorted()) still drawn; MenuBarAgent restarted recently, not again")
                return
            }
            self.lastAgentRestart = Date()
            Log.write("hiding: \(drawn.sorted()) still drawn after switching off; restarting MenuBarAgent")
            await self.restartMenuBarAgent(stuck: drawn)
        }
    }

    /// Apps that were switched off while MenuBarAgent restarted. Some of them
    /// (Nextcloud) lose their item until they relaunch; SyncBar does not need
    /// it, because it opens their panels through AXExtrasMenuBar, but the app
    /// must relaunch when SyncBar quits so its icon comes back.
    private(set) var hiddenAcrossAgentRestart = Set<String>()

    /// Restarts MenuBarAgent; launchd relaunches it at once and the new one
    /// applies the switches on launch.
    ///
    /// Only the `stuck` apps stay switched off across the restart. An app
    /// that is off while MenuBarAgent starts gets its item parked off screen,
    /// so its panel would open in the screen's corner; the other hidden apps
    /// are switched on for the restart and hidden live again afterwards,
    /// which keeps their items at their real menu bar positions.
    private func restartMenuBarAgent(stuck: Set<String>) async {
        let others = hidden.subtracting(stuck)
        if !others.isEmpty { show(others) }
        try? await Task.sleep(for: .seconds(1))
        hiddenAcrossAgentRestart.formUnion(stuck)
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/killall")
        process.arguments = ["MenuBarAgent"]
        try? process.run()
        // Wait for launchd to relaunch it and for the apps to re-register.
        try? await Task.sleep(for: .seconds(4))
        let again = others.subtracting(revealed)
        if !again.isEmpty { hide(again) }
    }

    /// Called as SyncBar quits, after `showAll()`: relaunches apps whose item
    /// did not come back.
    func relaunchAppsMissingTheirItem() {
        guard !hiddenAcrossAgentRestart.isEmpty else { return }
        Thread.sleep(forTimeInterval: 1.5)
        let drawn = Set(MenuBarItems.agentItems().compactMap(\.bundleID))
        for id in hiddenAcrossAgentRestart.subtracting(drawn) {
            let running = NSRunningApplication.runningApplications(withBundleIdentifier: id)
            guard let url = running.first?.bundleURL else { continue }
            Log.write("quit: \(id) has no menu bar item; relaunching it")
            running.forEach { $0.terminate() }
            // Relaunch from a detached shell, since SyncBar is exiting.
            let shell = Process()
            shell.executableURL = URL(filePath: "/bin/sh")
            shell.arguments = ["-c", "sleep 4; /usr/bin/open \"$0\"", url.path]
            try? shell.run()
        }
    }

    private func hide(_ ids: Set<String>) {
        do {
            // Apps macOS does not track yet are skipped; leave them out of
            // `hidden` so a later update tries again, and so verifyHidden
            // does not restart MenuBarAgent over an app it never switched off.
            let switchedOff = try NativeIconVisibility.setAllowed(false, for: ids)
            guard !switchedOff.isEmpty else { return }
            verifyHidden(switchedOff)
            hidden.formUnion(switchedOff)
            lastError = nil
            needsFullDiskAccess = false
        } catch {
            report(error)
        }
    }

    /// True when hiding failed because SyncBar lacks Full Disk Access.
    private(set) var needsFullDiskAccess = false

    private func report(_ error: Error) {
        needsFullDiskAccess = (error as? NativeIconVisibility.Failure) == .noFullDiskAccess
        lastError = needsFullDiskAccess
            ? "SyncBar needs Full Disk Access to change menu bar settings."
            : "Can't change menu bar settings (\(error))."
    }

    private func show(_ ids: Set<String>) {
        do {
            try NativeIconVisibility.setAllowed(true, for: ids)
            hidden.subtract(ids)
            lastError = nil
            needsFullDiskAccess = false
        } catch {
            report(error)
        }
    }
}
