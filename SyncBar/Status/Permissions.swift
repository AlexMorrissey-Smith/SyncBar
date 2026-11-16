import AppKit
import ApplicationServices

/// The two privacy permissions SyncBar needs, and how to get them.
///
/// macOS has no request prompt for Full Disk Access: an app can only send the
/// user to the right pane. A failed read of a protected file does add the app
/// to that list (switched off) on current macOS, so the user only has to flip
/// the switch; dragging the app in is the fallback.
enum Permissions {
    /// Reads menu bar items and opens the apps' panels.
    static var hasAccessibility: Bool { AXIsProcessTrusted() }

    /// Needed to change the per-app "Allow in the Menu Bar" switches, which
    /// live in Control Center's protected group container.
    static var hasFullDiskAccess: Bool {
        let fd = open(NativeIconVisibility.plistPath, O_RDONLY)
        guard fd >= 0 else { return false }
        close(fd)
        return true
    }

    /// Shows the system Accessibility prompt, which also lists SyncBar in Settings.
    static func requestAccessibility() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        openSettings("Privacy_Accessibility")
    }

    /// Lists SyncBar under Full Disk Access (by attempting a protected read)
    /// and opens that pane.
    static func requestFullDiskAccess() {
        _ = hasFullDiskAccess
        openSettings("Privacy_AllFiles")
    }

    private static func openSettings(_ anchor: String) {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")!
        NSWorkspace.shared.open(url)
    }
}
