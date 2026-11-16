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
/// - The switches outlive SyncBar. After a crash or a forced restart, apps
///   can launch while still switched off and so have no item; SyncBar
///   switches them on and relaunches them (see `repairMissingItems`).
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
            .subtracting(cannotHide)
            .filter { itemsPresent.contains($0) }
        if !toHide.isEmpty { hide(toHide) }
    }

    // MARK: - Repair

    /// When each app was first seen running without a menu bar item.
    private var missingSince: [String: Date] = [:]
    private var lastRepair: [String: Date] = [:]
    private var repairCount: [String: Int] = [:]
    /// How long an app must run, and miss its item, before SyncBar relaunches
    /// it. Covers apps that are still starting and brief AX hiccups.
    private static let repairGrace: TimeInterval = 15
    private static let repairInterval: TimeInterval = 10 * 60
    /// Relaunches per app per SyncBar session, so an app that never shows an
    /// item is not relaunched over and over.
    private static let maxRepairs = 2

    /// Switches on apps found switched off at launch, e.g. left off by a
    /// SyncBar that did not quit cleanly. An app hidden live cannot be told
    /// apart from one that launched while switched off (neither shows up in
    /// the accessibility tree), so every app starts switched on: one with an
    /// item is hidden again by `update`, one without is relaunched by
    /// `repairMissingItems`.
    func switchOnLeftovers(among ids: Set<String>) {
        guard let states = try? NativeIconVisibility.allowedStates() else { return }
        let off = ids.filter { states[$0] == false }
        guard !off.isEmpty else { return }
        Log.write("hiding: \(off.sorted()) were switched off at launch; switching them on")
        do { try NativeIconVisibility.setAllowed(true, for: off) } catch { report(error) }
    }

    /// An app that starts while switched off never creates its menu bar
    /// item, so SyncBar can neither read its status nor open its panel, and
    /// switching it on later does not bring the item back. A featured app
    /// (which always has an item) that is switched on but runs without one
    /// is relaunched; `update` hides it again once its item exists. Apps
    /// SyncBar has hidden are left out: a hidden item is invisible to the
    /// accessibility API, so it always looks missing.
    /// - Parameters:
    ///   - apps: bundle IDs of the apps SyncBar shows accounts for.
    ///   - itemsPresent: apps that currently have a status item.
    func repairMissingItems(apps: Set<String>, itemsPresent: Set<String>) {
        let now = Date()
        for id in apps {
            let running = NSRunningApplication.runningApplications(withBundleIdentifier: id)
            guard !running.isEmpty, !itemsPresent.contains(id), !revealed.contains(id),
                  SyncApp.featured.contains(id), !hidden.contains(id),
                  repairCount[id, default: 0] < Self.maxRepairs
            else {
                missingSince[id] = nil
                continue
            }
            let since = missingSince[id] ?? now
            missingSince[id] = since
            let started = running.compactMap(\.launchDate).max() ?? .distantPast
            guard now.timeIntervalSince(since) >= Self.repairGrace,
                  now.timeIntervalSince(started) >= Self.repairGrace,
                  now.timeIntervalSince(lastRepair[id] ?? .distantPast) >= Self.repairInterval
            else { continue }

            lastRepair[id] = now
            missingSince[id] = nil
            repairCount[id, default: 0] += 1
            // Make sure it is switched on (it may have been switched off by
            // hand), so the relaunched app creates its item.
            do { try NativeIconVisibility.setAllowed(true, for: [id]) } catch { report(error); continue }
            Log.write("repair: \(id) has no menu bar item (launched while switched off?); relaunching it")
            Task { await AppRelauncher.relaunch(running) }
        }
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

    /// Apps that stay drawn after being switched off, for example when
    /// MenuBarAgent stops applying switches after a long uptime. SyncBar switches such apps back on and leaves their icons alone
    /// for the rest of the session. (Restarting MenuBarAgent to force the
    /// change was tried, but it could drop every app's menu bar item.)
    private(set) var cannotHide = Set<String>()

    private func verifyHidden(_ ids: Set<String>) {
        Task { @MainActor [weak self] in
            // Some apps take a few seconds to drop their item.
            try? await Task.sleep(for: .seconds(4))
            guard let self else { return }
            let stillHidden = ids.intersection(self.hidden).subtracting(self.revealed)
            let drawn = Set(MenuBarItems.agentItems().compactMap(\.bundleID)).intersection(stillHidden)
            guard !drawn.isEmpty else { return }
            Log.write("hiding: \(drawn.sorted()) still drawn after switching off; leaving them shown")
            self.cannotHide.formUnion(drawn)
            self.show(drawn)
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

/// Quits every process of an app and launches it again.
enum AppRelauncher {
    /// Quits `running` (force-quitting stragglers after 5 seconds) and
    /// relaunches the app in the background.
    @MainActor
    static func relaunch(_ running: [NSRunningApplication], fallbackURL: URL? = nil) async {
        let url = running.first?.bundleURL ?? fallbackURL
        running.forEach { $0.terminate() }
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(5)
        while running.contains(where: { !$0.isTerminated }), clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(200))
        }
        running.filter { !$0.isTerminated }.forEach { $0.forceTerminate() }
        try? await Task.sleep(for: .seconds(1))
        guard let url else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        _ = try? await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
    }
}
