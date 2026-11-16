import Foundation

/// Reads and writes macOS 27's per-app "Allow in the Menu Bar" switches
/// (System Settings › Menu Bar › Menu Bar Controls).
///
/// They live in the `trackedApplications` key of Control Center's group
/// container preferences: a binary property list
/// holding an array of alternating keys and values, where each key is
/// `{bundle: {_0: <bundle ID>}}` and each value carries `isAllowed`.
///
/// Observed behaviour on macOS 27.3:
/// - An app that *starts* while switched off never creates its status item,
///   so it cannot be opened until it is relaunched with the switch on.
/// - An app switched off while running keeps its item alive but hidden.
/// SyncBar therefore only hides apps that are already running with an item,
/// and switches everything back on when it quits.
enum NativeIconVisibility {
    /// The group container's preferences, addressed by absolute path. Asking
    /// for the plain suite name only works inside the app group, which
    /// SyncBar isn't part of.
    static var domain: CFString {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/Library/Group Containers/group.com.apple.controlcenter/Library/Preferences/group.com.apple.controlcenter" as CFString
    }
    static var key: CFString { "trackedApplications" as CFString }

    enum Failure: Error { case unreadable, notTracked }

    /// `isAllowed` per tracked bundle ID.
    static func allowedStates() throws -> [String: Bool] {
        let list = try trackedList()
        var result: [String: Bool] = [:]
        for index in stride(from: 0, to: list.count - 1, by: 2) {
            guard let id = bundleID(of: list[index]) else { continue }
            result[id] = (list[index + 1] as? [String: Any])?["isAllowed"] as? Bool ?? true
        }
        return result
    }

    /// Sets `isAllowed` for the given apps. Apps macOS has not seen yet are skipped.
    @discardableResult
    static func setAllowed(_ allowed: Bool, for bundleIDs: Set<String>) throws -> Set<String> {
        var list = try trackedList()
        var changed = Set<String>()
        for index in stride(from: 0, to: list.count - 1, by: 2) {
            guard let id = bundleID(of: list[index]), bundleIDs.contains(id),
                  var value = list[index + 1] as? [String: Any] else { continue }
            if value["isAllowed"] as? Bool != allowed {
                value["isAllowed"] = allowed
                list[index + 1] = value
                changed.insert(id)
            }
        }
        guard !changed.isEmpty else { return [] }
        let data = try PropertyListSerialization.data(fromPropertyList: list, format: .binary, options: 0)
        CFPreferencesSetAppValue(key, data as CFData, domain)
        // Writing through cfprefsd (not the file) lets MenuBarAgent see the change.
        CFPreferencesAppSynchronize(domain)
        return changed
    }

    // MARK: - Helpers

    private static func trackedList() throws -> [Any] {
        CFPreferencesAppSynchronize(domain)
        guard let data = CFPreferencesCopyAppValue(key, domain) as? Data,
              let list = try PropertyListSerialization.propertyList(from: data, format: nil) as? [Any]
        else { throw Failure.unreadable }
        return list
    }

    private static func bundleID(of key: Any) -> String? {
        ((key as? [String: Any])?["bundle"] as? [String: Any])?["_0"] as? String
    }
}
