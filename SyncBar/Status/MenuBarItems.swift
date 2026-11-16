import AppKit
import ApplicationServices

/// A third-party status item found in the menu bar through the Accessibility API.
struct MenuBarItem: @unchecked Sendable {
    let element: AXUIElement
    let pid: pid_t
    let bundleID: String?
    /// Title, description, help and value joined with newlines.
    let text: String
    /// Where the item came from, for diagnostics.
    let source: Source

    enum Source: String, Sendable { case menuBarAgent, extrasMenuBar }
}

/// Reads and presses other apps' menu bar items.
///
/// On macOS 27, apps no longer answer `AXExtrasMenuBar`: every third-party
/// status item is hosted in com.apple.MenuBarAgent's window, as
/// window > group > item, and `AXUIElementGetPid` on the item returns the
/// owning app's pid. Pressing that item makes the app open its own menu or
/// popover at the real icon. On macOS 26 and earlier, the owning app's
/// `AXExtrasMenuBar` still works, so it is kept as a fallback.
///
/// Approach informed by OmniWM (PR 1041) and the Thaw menu bar manager.
enum MenuBarItems {
    static let agentBundleID = "com.apple.MenuBarAgent"

    static var isTrusted: Bool { AXIsProcessTrusted() }

    @discardableResult
    static func promptForTrust() -> Bool {
        let key = "AXTrustedCheckOptionPrompt" // kAXTrustedCheckOptionPrompt, which is not concurrency-safe in Swift 6
        return AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    /// All third-party status items owned by the given bundle IDs.
    static func scan(bundleIDs: Set<String>) -> [MenuBarItem] {
        var items = agentItems().filter { $0.bundleID.map(bundleIDs.contains) ?? false }
        // Fallback for apps the agent tree did not cover (macOS 26 and earlier).
        let covered = Set(items.map(\.pid))
        for bundleID in bundleIDs {
            for app in NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            where !covered.contains(app.processIdentifier) {
                items += extrasItems(for: app)
            }
        }
        return items
    }

    /// Presses an item. Returns true when the app accepted the press.
    static func press(_ item: MenuBarItem) -> Bool {
        let result = AXUIElementPerformAction(item.element, kAXPressAction as CFString)
        if result == .success { return true }
        // Some items only answer "show menu".
        return AXUIElementPerformAction(item.element, "AXShowMenu" as CFString) == .success
    }

    // MARK: - MenuBarAgent

    static func agentItems() -> [MenuBarItem] {
        guard let agent = NSRunningApplication.runningApplications(withBundleIdentifier: agentBundleID).first
        else { return [] }
        let agentPID = agent.processIdentifier
        let root = AXUIElementCreateApplication(agentPID)
        AXUIElementSetMessagingTimeout(root, 1.0)

        var found: [MenuBarItem] = []
        var seen = Set<String>()
        for window in children(of: root, attribute: kAXWindowsAttribute) {
            collect(in: window, agentPID: agentPID, depth: 0, into: &found, seen: &seen)
        }
        return found
    }

    private static func collect(
        in element: AXUIElement, agentPID: pid_t, depth: Int,
        into found: inout [MenuBarItem], seen: inout Set<String>
    ) {
        guard depth < 4 else { return }
        for child in children(of: element, attribute: kAXChildrenAttribute) {
            var pid: pid_t = 0
            AXUIElementGetPid(child, &pid)
            if pid != agentPID, pid > 0 {
                // A foreign element hosted by the agent. Skip the duplicate
                // AXApplication subtrees the agent also exposes.
                guard string(child, kAXRoleAttribute) != (kAXApplicationRole as String) else { continue }
                let text = describe(child)
                let key = "\(pid)|\(text)"
                if seen.insert(key).inserted {
                    let bundleID = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
                    found.append(MenuBarItem(element: child, pid: pid, bundleID: bundleID, text: text, source: .menuBarAgent))
                }
            } else {
                collect(in: child, agentPID: agentPID, depth: depth + 1, into: &found, seen: &seen)
            }
        }
    }

    // MARK: - AXExtrasMenuBar fallback

    static func extrasItems(for app: NSRunningApplication) -> [MenuBarItem] {
        let root = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(root, 1.0)
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(root, "AXExtrasMenuBar" as CFString, &value) == .success,
              let bar = value, CFGetTypeID(bar) == AXUIElementGetTypeID() else { return [] }
        return children(of: bar as! AXUIElement, attribute: kAXChildrenAttribute).map {
            MenuBarItem(element: $0, pid: app.processIdentifier, bundleID: app.bundleIdentifier,
                        text: describe($0), source: .extrasMenuBar)
        }
    }

    // MARK: - AX helpers

    static func describe(_ element: AXUIElement) -> String {
        let keys = [kAXTitleAttribute, kAXDescriptionAttribute, kAXHelpAttribute, kAXValueAttribute]
        var parts: [String] = []
        for key in keys {
            guard let value = string(element, key), !value.isEmpty, !parts.contains(value) else { continue }
            parts.append(value)
        }
        return parts.joined(separator: "\n")
    }

    private static func children(of element: AXUIElement, attribute: String) -> [AXUIElement] {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return [] }
        return (value as? [AXUIElement]) ?? []
    }

    private static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        if let s = value as? String { return s }
        if let n = value as? NSNumber { return n.stringValue }
        return nil
    }
}
