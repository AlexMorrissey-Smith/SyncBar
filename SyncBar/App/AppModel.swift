import AppKit
import Observation

/// Live state of one row.
struct AccountStatus {
    var state: SyncState = .unknown
    var menuBarText: String?
    var snapshot: FileProviderSnapshot?
    var snapshotDate: Date?
    /// A short message shown under the status, e.g. after a failed panel open.
    var note: String?
}

@MainActor
@Observable
final class AppModel {
    static let pollInterval: TimeInterval = 3
    static let discoveryInterval: TimeInterval = 30

    private(set) var accounts: [Account] = []
    private(set) var statuses: [Account.ID: AccountStatus] = [:]
    private(set) var isTrusted = MenuBarItems.isTrusted
    let preferences = Preferences()
    let iconHider = IconHider()

    /// Called after every refresh so the status item can update its icon.
    @ObservationIgnored var onUpdate: (() -> Void)?

    @ObservationIgnored private var items: [MenuBarItem] = []
    @ObservationIgnored private var pidInstances: [pid_t: String] = [:]
    @ObservationIgnored private let dumps = DumpRunner()
    @ObservationIgnored private var pollTimer: Timer?
    @ObservationIgnored private var lastDiscovery = Date.distantPast
    @ObservationIgnored private var launchDumpsDone = false

    /// Accounts in the user's order, without hidden ones.
    var visibleAccounts: [Account] {
        preferences.ordered(accounts).filter { !preferences.isHidden($0) }
    }

    var combinedState: CombinedState {
        CombinedState(visibleAccounts.map { statuses[$0.id]?.state ?? .unknown })
    }

    func start() {
        refresh()
        pollTimer = Timer.scheduledTimer(withTimeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        Task { await runLaunchDumps() }
    }

    // MARK: - Refresh

    func refresh() {
        isTrusted = MenuBarItems.isTrusted
        if Date().timeIntervalSince(lastDiscovery) > Self.discoveryInterval || accounts.isEmpty {
            accounts = AccountDiscovery.discover()
            preferences.register(accounts)
            lastDiscovery = Date()
        }

        let bundleIDs = Set(accounts.map(\.app.bundleID))
        items = isTrusted ? MenuBarItems.scan(bundleIDs: bundleIDs) : []
        updateOneDrivePIDs()

        for account in accounts {
            var status = statuses[account.id] ?? AccountStatus()
            status.menuBarText = menuBarItem(for: account)?.text
            status.state = StateCombiner.state(
                isRunning: process(for: account) != nil,
                menuBarText: status.menuBarText,
                snapshot: status.snapshot,
                snapshotDate: status.snapshotDate
            )
            statuses[account.id] = status

            // Dump while syncing, or when the menu bar item gives no usable
            // text (none while hidden, or only the app's name). Keying this on
            // the text rather than the combined state keeps the snapshot fresh
            // instead of letting it expire first. DumpRunner limits each
            // domain to once a minute.
            let fastState = status.menuBarText.map(StatusTextParser.state(from:)) ?? .unknown
            let fastSourceMissing = fastState == .unknown && status.state != .appNotRunning
            if launchDumpsDone, status.state.isSyncing || fastSourceMissing, let domain = account.fileProviderDomain {
                Task { await runDump(domain, for: account.id) }
            }
        }
        updateHiding()
        onUpdate?()
    }

    @ObservationIgnored private var lastHidingLog = ""

    private func updateHiding() {
        let targets = preferences.hideOriginalIcons ? Set(visibleAccounts.map(\.app.bundleID)) : []
        let present = Set(items.compactMap(\.bundleID))
        if isTrusted { iconHider.update(targets: targets, itemsPresent: present) }

        // Log only when something changes, so the file stays small.
        let line = "trusted=\(isTrusted) targets=\(targets.sorted()) present=\(present.sorted()) "
            + "hidden=\(iconHider.hidden.sorted()) error=\(iconHider.lastError ?? "none")"
        if line != lastHidingLog {
            lastHidingLog = line
            Log.write("hiding: " + line)
        }
    }

    private func runLaunchDumps() async {
        for account in accounts {
            guard let domain = account.fileProviderDomain else { continue }
            await runDump(domain, for: account.id)
        }
        launchDumpsDone = true
    }

    private func runDump(_ domain: String, for id: Account.ID) async {
        guard let snapshot = await dumps.dump(domain) else { return }
        statuses[id, default: AccountStatus()].snapshot = snapshot
        statuses[id, default: AccountStatus()].snapshotDate = Date()
        refresh()
    }

    private func updateOneDrivePIDs() {
        let live = Set(SyncApp.oneDrive.runningInstances.map(\.processIdentifier))
        pidInstances = pidInstances.filter { live.contains($0.key) }
        for pid in live where pidInstances[pid] == nil {
            if let instance = OneDriveInstances.instance(forPID: pid) { pidInstances[pid] = instance }
        }
    }

    // MARK: - Matching

    /// The running process that serves an account.
    func process(for account: Account) -> NSRunningApplication? {
        let running = account.app.runningInstances
        if let instance = account.oneDriveInstance {
            if let match = running.first(where: { pidInstances[$0.processIdentifier] == instance }) { return match }
            // Lock file not readable: only trust a single process.
            return pidInstances.isEmpty && running.count == 1 ? running.first : nil
        }
        return running.first
    }

    func menuBarItem(for account: Account) -> MenuBarItem? {
        let candidates = items.filter { $0.bundleID == account.app.bundleID }
        if account.oneDriveInstance != nil {
            guard let pid = process(for: account)?.processIdentifier else { return nil }
            return candidates.first { $0.pid == pid }
        }
        return candidates.first
    }

    // MARK: - Actions

    /// Opens the app's own menu bar panel, as if its icon had been clicked.
    func openPanel(for account: Account) async {
        refresh()
        // First try the app's own AXExtrasMenuBar item. It still answers while
        // the icon is switched off, and the app opens its panel under where
        // the icon would be, so nothing has to appear in the menu bar.
        if let process = process(for: account),
           let item = MenuBarItems.extrasItems(for: process).first {
            Log.write("open \(account.title) \(account.detail): pressing extras item of pid \(process.processIdentifier)")
            if let window = await MenuBarItems.press(item) {
                Log.write("open \(account.title): opened at \(NSStringFromRect(window.frame)) without revealing")
                placeUnderIcon(window, force: iconHider.hiddenAcrossAgentRestart.contains(account.app.bundleID))
                setNote(nil, for: account)
                return
            }
            Log.write("open \(account.title): extras press opened nothing; revealing the icon")
        }

        let window = await iconHider.withRevealed(account.app.bundleID) { [self] in
            // Re-scan: a revealed item is a fresh AX element.
            items = MenuBarItems.scan(bundleIDs: [account.app.bundleID])
            guard let item = menuBarItem(for: account) else { return nil }
            return await MenuBarItems.press(item)
        }
        if let window {
            Log.write("opened \(account.app.name) panel at \(NSStringFromRect(window.frame))")
            setNote(nil, for: account)
            refresh()
            return
        }
        if !isTrusted {
            setNote("SyncBar needs Accessibility access to open \(account.app.name)", for: account)
        } else if !isRunning(account) {
            setNote("\(account.app.name) isn't running. Right-click to launch it.", for: account)
        } else if menuBarItem(for: account) == nil {
            setNote("\(account.app.name) has no menu bar icon. Right-click to quit it, then launch it again.", for: account)
        } else {
            setNote("\(account.app.name) didn't open its menu. Try again.", for: account)
        }
    }

    /// SyncBar's own icon in screen coordinates (top-left origin), kept up to
    /// date by the status item controller.
    @ObservationIgnored var iconFrame: CGRect?

    /// An item whose icon is switched off can report a parked position, so
    /// its panel opens off screen or in a corner. Move such a panel under
    /// SyncBar's icon; `force` moves it anyway (apps whose item is parked).
    /// Classic menus (Dropbox) cannot be moved.
    private func placeUnderIcon(_ window: MenuBarItems.OpenedWindow, force: Bool) {
        guard let icon = iconFrame,
              let screen = NSScreen.screens.first(where: { $0.frame.minX <= icon.midX && icon.midX <= $0.frame.maxX })
                ?? NSScreen.main else { return }
        let width = screen.frame.width
        // Classic menus (Dropbox) report a frame above the screen; leave them.
        let misplaced = force || window.frame.minY > icon.maxY + 40 || window.frame.minX < screen.frame.minX
            || window.frame.maxX > screen.frame.minX + width
        guard misplaced else { return }
        let x = min(max(icon.midX - window.frame.width / 2, screen.frame.minX + 8),
                    screen.frame.minX + width - window.frame.width - 8)
        let moved = MenuBarItems.move(window, to: CGPoint(x: x, y: icon.maxY + 6))
        Log.write("open: panel was at \(NSStringFromRect(window.frame)); moved under SyncBar icon: \(moved)")
    }

    func openFolder(for account: Account) {
        NSWorkspace.shared.open(account.folderURL)
    }

    func launchApp(for account: Account) {
        guard let url = account.app.appURL else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.refresh() }
    }

    /// Quits every process of the account's app (both OneDrive accounts share
    /// one app), force-quitting stragglers after 5 seconds, then launches it again.
    func restartApp(for account: Account) {
        let running = account.app.runningInstances
        running.forEach { $0.terminate() }
        Task {
            let clock = ContinuousClock()
            let deadline = clock.now + .seconds(5)
            while running.contains(where: { !$0.isTerminated }), clock.now < deadline {
                try? await Task.sleep(for: .milliseconds(200))
            }
            running.filter { !$0.isTerminated }.forEach { $0.forceTerminate() }
            try? await Task.sleep(for: .seconds(1))
            launchApp(for: account)
        }
    }

    func quitApp(for account: Account) {
        process(for: account)?.terminate()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.refresh() }
    }

    func isRunning(_ account: Account) -> Bool { process(for: account) != nil }

    private func setNote(_ note: String?, for account: Account) {
        statuses[account.id, default: AccountStatus()].note = note
        guard note != nil else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
            if self?.statuses[account.id]?.note == note { self?.statuses[account.id]?.note = nil }
        }
    }
}
