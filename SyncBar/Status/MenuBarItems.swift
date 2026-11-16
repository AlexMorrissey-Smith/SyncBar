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

    /// Presses an item and waits briefly for the app to show a menu or panel.
    ///
    /// The AX return code alone is unreliable: an app that shows a classic
    /// NSMenu (Dropbox) runs the menu's tracking loop inside the press, so the
    /// call times out with `kAXErrorCannotComplete` even though the menu is
    /// open. Success is therefore judged by a new on-screen window owned by
    /// the app. Returns that window, or nil if nothing appeared.
    static func press(_ item: MenuBarItem) async -> OpenedWindow? {
        let before = windowNumbers(of: item.pid)
        let element = item.element
        // Short timeout so a blocking menu does not hold us up; run off the
        // main thread so SyncBar stays responsive meanwhile.
        Task.detached(priority: .userInitiated) {
            AXUIElementSetMessagingTimeout(element, 0.5)
            let result = AXUIElementPerformAction(element, kAXPressAction as CFString)
            if result != .success && result != .cannotComplete {
                // Some items only answer "show menu".
                _ = AXUIElementPerformAction(element, "AXShowMenu" as CFString)
            }
        }
        for _ in 0..<15 {
            try? await Task.sleep(for: .milliseconds(100))
            if let window = newWindow(of: item.pid, excluding: before) { return window }
        }
        return nil
    }

    // MARK: - Window check

    private static func windowList(of pid: pid_t) -> [[String: Any]] {
        let all = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        return all.filter { ($0[kCGWindowOwnerPID as String] as? pid_t) == pid }
    }

    private static func windowNumbers(of pid: pid_t) -> Set<Int> {
        Set(windowList(of: pid).compactMap { $0[kCGWindowNumber as String] as? Int })
    }

    struct OpenedWindow: Sendable {
        let number: Int
        let pid: pid_t
        let frame: CGRect
    }

    private static func newWindow(of pid: pid_t, excluding before: Set<Int>) -> OpenedWindow? {
        for window in windowList(of: pid) {
            guard let number = window[kCGWindowNumber as String] as? Int, !before.contains(number),
                  let bounds = window[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds),
                  rect.width > 20, rect.height > 20 else { continue }
            return OpenedWindow(number: number, pid: pid, frame: rect)
        }
        return nil
    }

    /// True while the window is still on screen.
    static func isOnScreen(_ window: OpenedWindow) -> Bool {
        windowNumbers(of: window.pid).contains(window.number)
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
