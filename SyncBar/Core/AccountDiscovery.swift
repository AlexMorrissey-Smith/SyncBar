import AppKit

/// Finds sync accounts on this Mac.
///
/// - File Provider accounts: every folder in ~/Library/CloudStorage carries the
///   extended attribute `com.apple.file-provider-domain-id` ("<providerID>/<domainID>").
/// - Nextcloud in classic folder-sync mode: folders listed in
///   ~/Library/Preferences/Nextcloud/nextcloud.cfg.
enum AccountDiscovery {
    static let domainAttribute = "com.apple.file-provider-domain-id"

    static func discover() -> [Account] {
        let fileProvider = fileProviderAccounts()
        let classic = classicNextcloudAccounts().filter { candidate in
            !fileProvider.contains { $0.folderURL.standardizedFileURL == candidate.folderURL.standardizedFileURL }
        }
        return fileProvider + classic
    }

    // MARK: - File Provider

    static func fileProviderAccounts() -> [Account] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let root = home.appending(path: "Library/CloudStorage", directoryHint: .isDirectory)
        guard let folders = try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else { return [] }

        return folders.sorted { $0.lastPathComponent < $1.lastPathComponent }.compactMap { folder in
            guard let value = xattr(domainAttribute, of: folder.path),
                  let slash = value.firstIndex(of: "/") else { return nil }
            let providerID = String(value[..<slash])
            let domainID = String(value[value.index(after: slash)...])
            let app = app(forProvider: providerID)

            var account = Account(
                id: value,
                app: app,
                folderURL: folder,
                detail: detail(forFolder: folder.lastPathComponent, app: app),
                fileProviderDomain: value
            )
            if app == .oneDrive {
                let instance = OneDriveInstances.instance(forDomainID: domainID, folder: folder)
                account.oneDriveInstance = instance
                if let instance, let user = OneDriveInstances.userLabel(forInstance: instance) {
                    account.detail += " (\(user))"
                }
            }
            return account
        }
    }

    /// Maps a File Provider extension ID to its containing app.
    static func app(forProvider providerID: String) -> SyncApp {
        switch providerID {
        case "com.microsoft.OneDrive.FileProvider": return .oneDrive
        case "com.getdropbox.dropbox.fileprovider": return .dropbox
        case "com.nextcloud.desktopclient.FileProviderExt": return .nextcloud
        case "com.google.drivefs.fpext": return .googleDrive
        default:
            // Extensions are normally "<app bundle ID>.<suffix>". Walk up until
            // an installed app matches.
            var parts = providerID.split(separator: ".").map(String.init)
            while parts.count > 1 {
                parts.removeLast()
                let candidate = parts.joined(separator: ".")
                if let url = NSWorkspaceLookup.appURL(for: candidate) {
                    let name = url.deletingPathExtension().lastPathComponent
                    return SyncApp(bundleID: candidate, name: name)
                }
            }
            return SyncApp(bundleID: providerID, name: providerID)
        }
    }

    /// "OneDrive-Contoso(2)" -> "Contoso", "Dropbox" -> "Dropbox",
    /// "GoogleDrive-jamie@example.com" -> "jamie@example.com".
    static func detail(forFolder name: String, app: SyncApp) -> String {
        var rest = name
        for prefix in [app.name + "-", app.name.replacingOccurrences(of: " ", with: "") + "-"]
        where rest.hasPrefix(prefix) {
            rest.removeFirst(prefix.count)
            break
        }
        rest = rest.replacing(/\(\d+\)$/, with: "")
        return rest.isEmpty ? name : rest
    }

    static func xattr(_ name: String, of path: String) -> String? {
        let size = getxattr(path, name, nil, 0, 0, 0)
        guard size > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard getxattr(path, name, &buffer, size, 0, 0) == size else { return nil }
        return String(decoding: buffer, as: UTF8.self).trimmingCharacters(in: .controlCharacters)
    }

    // MARK: - Classic Nextcloud

    static func classicNextcloudAccounts() -> [Account] {
        let cfg = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Preferences/Nextcloud/nextcloud.cfg")
        guard let text = try? String(contentsOf: cfg, encoding: .utf8) else { return [] }
        return parseNextcloudConfig(text).map { folder in
            Account(
                id: "folder:\(folder.localPath)",
                app: .nextcloud,
                folderURL: URL(filePath: folder.localPath, directoryHint: .isDirectory),
                detail: folder.label
            )
        }
    }

    struct NextcloudFolder: Equatable {
        var localPath: String
        var label: String
    }

    /// Reads `N\Folders\M\localPath=` entries (and their variants) from the
    /// [Accounts] section of nextcloud.cfg.
    static func parseNextcloudConfig(_ text: String) -> [NextcloudFolder] {
        var users: [String: String] = [:]
        var urls: [String: String] = [:]
        var folders: [(account: String, path: String)] = []
        var inAccounts = false

        for raw in text.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") { inAccounts = (line == "[Accounts]"); continue }
            guard inAccounts, let eq = line.firstIndex(of: "=") else { continue }
            let key = String(line[..<eq])
            let value = String(line[line.index(after: eq)...])
            let parts = key.split(separator: "\\").map(String.init)
            guard let account = parts.first else { continue }

            if parts.count == 2, parts[1] == "dav_user" || parts[1] == "user" { users[account] = value }
            if parts.count == 2, parts[1] == "url" { urls[account] = value }
            if parts.count == 4, parts[1].hasPrefix("Folders") || parts[1].hasPrefix("Multifolders"),
               parts[3] == "localPath"
            {
                folders.append((account, value))
            }
        }

        return folders.map { entry in
            let host = urls[entry.account].flatMap { URL(string: $0)?.host() }
            let label = [users[entry.account], host].compactMap { $0 }.joined(separator: " @ ")
            let path = entry.path.hasSuffix("/") && entry.path.count > 1 ? String(entry.path.dropLast()) : entry.path
            return NextcloudFolder(localPath: path, label: label.isEmpty ? (path as NSString).lastPathComponent : label)
        }
    }
}

/// Thin wrapper so discovery code stays testable without AppKit globals.
enum NSWorkspaceLookup {
    static func appURL(for bundleID: String) -> URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
    }
}
