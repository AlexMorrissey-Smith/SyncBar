import Foundation
import Observation
import ServiceManagement

/// Row order, hidden rows and the login item.
@MainActor
@Observable
final class Preferences {
    private enum Key {
        static let order = "accountOrder"
        static let hidden = "hiddenAccounts"
        static let known = "knownAccounts"
        static let hideIcons = "hideOriginalIcons"
        static let googleDriveShown = "googleDriveShown"
    }

    private let defaults = UserDefaults.standard
    private(set) var order: [String]
    private(set) var hidden: Set<String>

    /// Hide the sync apps' own menu bar icons.
    var hideOriginalIcons: Bool {
        didSet { defaults.set(hideOriginalIcons, forKey: Key.hideIcons) }
    }

    init() {
        order = defaults.stringArray(forKey: Key.order) ?? []
        hidden = Set(defaults.stringArray(forKey: Key.hidden) ?? [])
        hideOriginalIcons = defaults.object(forKey: Key.hideIcons) as? Bool ?? true
    }

    /// Records newly found accounts. Accounts of apps SyncBar was not built
    /// for (e.g. Google Drive) start hidden.
    func register(_ accounts: [Account]) {
        // Google Drive accounts were hidden by default before SyncBar
        // supported Google Drive; show them once.
        if !defaults.bool(forKey: Key.googleDriveShown) {
            hidden.subtract(accounts.filter { $0.app == .googleDrive }.map(\.id))
            defaults.set(true, forKey: Key.googleDriveShown)
        }
        var known = Set(defaults.stringArray(forKey: Key.known) ?? [])
        for account in accounts where !known.contains(account.id) {
            known.insert(account.id)
            if !SyncApp.featured.contains(account.app.bundleID) { hidden.insert(account.id) }
            if !order.contains(account.id) { order.append(account.id) }
        }
        defaults.set(Array(known), forKey: Key.known)
        save()
    }

    func ordered(_ accounts: [Account]) -> [Account] {
        accounts.sorted { a, b in
            (order.firstIndex(of: a.id) ?? .max) < (order.firstIndex(of: b.id) ?? .max)
        }
    }

    func isHidden(_ account: Account) -> Bool { hidden.contains(account.id) }

    func setHidden(_ isHidden: Bool, for account: Account) {
        if isHidden { hidden.insert(account.id) } else { hidden.remove(account.id) }
        save()
    }

    func move(_ accounts: [Account], fromOffsets source: IndexSet, toOffset destination: Int) {
        var ids = ordered(accounts).map(\.id)
        ids.move(fromOffsets: source, toOffset: destination)
        order = ids + order.filter { !ids.contains($0) }
        save()
    }

    private func save() {
        defaults.set(order, forKey: Key.order)
        defaults.set(Array(hidden), forKey: Key.hidden)
    }

    // MARK: - Launch at login

    var launchAtLogin: Bool {
        get {
            access(keyPath: \.launchAtLogin)
            return SMAppService.mainApp.status == .enabled
        }
        set {
            withMutation(keyPath: \.launchAtLogin) {
                do {
                    if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                } catch {
                    Log.write("launch at login change failed: \(error)")
                }
            }
        }
    }

    /// True when macOS wants the user to approve the login item in System Settings.
    var loginItemNeedsApproval: Bool { SMAppService.mainApp.status == .requiresApproval }
}
