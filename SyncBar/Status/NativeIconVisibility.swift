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
    static let appID = "group.com.apple.controlcenter"
    static let key = "trackedApplications"

    /// Control Center's group container. Preferences must be read and written
    /// with this container so cfprefsd tells MenuBarAgent about the change;
    /// the plain suite name only resolves inside the app group, and writing
    /// by file path changes the file without notifying anyone.
    static var containerPath: String {
        FileManager.default.homeDirectoryForCurrentUser.path + "/Library/Group Containers/" + appID
    }

    enum Failure: Error { case unreadable, noFullDiskAccess }

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

    /// Sets `isAllowed` for the given apps and returns the ones found.
    /// Apps macOS has not seen yet are skipped. Always writes, so observers
    /// are told even when the stored value already matched.
    @discardableResult
    static func setAllowed(_ allowed: Bool, for bundleIDs: Set<String>) throws -> Set<String> {
        var list = try trackedList()
        var found = Set<String>()
        for index in stride(from: 0, to: list.count - 1, by: 2) {
            guard let id = bundleID(of: list[index]), bundleIDs.contains(id),
                  var value = list[index + 1] as? [String: Any] else { continue }
            value["isAllowed"] = allowed
            list[index + 1] = value
            found.insert(id)
        }
        guard !found.isEmpty else { return [] }
        let data = try PropertyListSerialization.data(fromPropertyList: list, format: .binary, options: 0)
        _CFPreferencesSetAppValueWithContainer(key as CFString, data as CFData, appID as CFString, containerPath as CFString)
        _ = _CFPreferencesAppSynchronizeWithContainer(appID as CFString, containerPath as CFString)
        return found
    }

    // MARK: - Helpers

    static var plistPath: String {
        containerPath + "/Library/Preferences/" + appID + ".plist"
    }

    private static func trackedList() throws -> [Any] {
        _ = _CFPreferencesAppSynchronizeWithContainer(appID as CFString, containerPath as CFString)
        var data = _CFPreferencesCopyAppValueWithContainer(key as CFString, appID as CFString, containerPath as CFString)?
            .takeRetainedValue() as? Data
        if data == nil {
            // cfprefsd can refuse the container to some processes; the file
            // itself is still the source of truth.
            do {
                let file = try Data(contentsOf: URL(filePath: plistPath))
                let dict = try PropertyListSerialization.propertyList(from: file, format: nil) as? [String: Any]
                data = dict?[key] as? Data
                Log.write("menu bar settings: container read failed, file read \(data == nil ? "has no key" : "ok")")
            } catch CocoaError.fileReadNoPermission {
                // The container is protected; reading it needs Full Disk Access.
                throw Failure.noFullDiskAccess
            } catch {
                Log.write("menu bar settings: container and file read failed: \(error)")
            }
        }
        guard let data,
              let list = try PropertyListSerialization.propertyList(from: data, format: nil) as? [Any]
        else { throw Failure.unreadable }
        return list
    }

    private static func bundleID(of key: Any) -> String? {
        ((key as? [String: Any])?["bundle"] as? [String: Any])?["_0"] as? String
    }
}

// Private CoreFoundation functions (CFPreferences.c) for preferences that
// live in another app's group container.

@_silgen_name("_CFPreferencesCopyAppValueWithContainer")
private func _CFPreferencesCopyAppValueWithContainer(
    _ key: CFString, _ appName: CFString, _ containerPath: CFString
) -> Unmanaged<CFPropertyList>?

@_silgen_name("_CFPreferencesSetAppValueWithContainer")
private func _CFPreferencesSetAppValueWithContainer(
    _ key: CFString, _ value: CFPropertyList?, _ appName: CFString, _ containerPath: CFString
)

@_silgen_name("_CFPreferencesAppSynchronizeWithContainer")
private func _CFPreferencesAppSynchronizeWithContainer(_ appName: CFString, _ containerPath: CFString) -> Bool
