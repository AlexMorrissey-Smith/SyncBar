import AppKit

/// A sync app SyncBar knows how to talk to.
struct SyncApp: Hashable, Sendable {
    let bundleID: String
    let name: String

    static let oneDrive = SyncApp(bundleID: "com.microsoft.OneDrive", name: "OneDrive")
    static let dropbox = SyncApp(bundleID: "com.getdropbox.dropbox", name: "Dropbox")
    static let nextcloud = SyncApp(bundleID: "com.nextcloud.desktopclient", name: "Nextcloud")

    /// Apps whose accounts are shown by default. Other File Provider apps are
    /// listed too, but start hidden.
    static let featured: Set<String> = [oneDrive.bundleID, dropbox.bundleID, nextcloud.bundleID]

    var appURL: URL? { NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) }

    var icon: NSImage {
        guard let url = appURL else { return NSImage(systemSymbolName: "icloud", accessibilityDescription: nil)! }
        return NSWorkspace.shared.icon(forFile: url.path)
    }

    var runningInstances: [NSRunningApplication] {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
    }
}

/// One sync account: a File Provider domain, or a classic Nextcloud sync folder.
struct Account: Identifiable, Hashable, Sendable {
    /// "<providerID>/<domainID>" for File Provider accounts, "folder:<path>" otherwise.
    let id: String
    let app: SyncApp
    let folderURL: URL
    /// The second line of the row, e.g. "Contoso (creative)".
    var detail: String
    /// For File Provider accounts: the argument for `fileproviderctl dump`.
    var fileProviderDomain: String?
    /// For OneDrive: the settings instance ("Business1", "Personal", …) that
    /// tells its two processes and menu bar items apart.
    var oneDriveInstance: String?

    var title: String { app.name }

    /// The detail as shown under the title, or nil when it would only repeat
    /// the app name. Nextcloud's "user@server" (classic folders) and
    /// "server-user" (File Provider folders) become "user on server".
    var subtitle: String? {
        guard detail != app.name, !detail.isEmpty else { return nil }
        if app == .nextcloud, let at = detail.lastIndex(of: "@") {
            let user = detail[..<at], server = detail[detail.index(after: at)...]
            if !user.isEmpty, server.contains(".") { return "\(user) on \(server)" }
        }
        // The server ends at the first "-" after a dotted top-level domain,
        // since user names can contain "-" too.
        if app == .nextcloud, let m = detail.wholeMatch(of: /(.+?\.[A-Za-z]{2,})-(.+)/) {
            return "\(m.2) on \(m.1)"
        }
        return detail
    }
}
