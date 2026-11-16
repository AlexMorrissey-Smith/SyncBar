import Darwin
import Foundation

/// OneDrive runs one process (and one menu bar item) per account. Each process
/// holds a lock file named after its settings folder, e.g.
/// ~/Library/Application Support/OneDrive/settings/LockInstance_Business1.
/// The same folder name ties a File Provider domain to its process.
enum OneDriveInstances {
    static var settingsRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/OneDrive/settings", directoryHint: .isDirectory)
    }

    /// The settings instance for a File Provider domain.
    ///
    /// Domain IDs such as "Dbfs_Business2" name it directly. Older domains are
    /// named after the folder ("OneDrive - Contoso"); for those, look for the
    /// instance whose .ini file mentions the CloudStorage folder.
    static func instance(forDomainID domainID: String, folder: URL) -> String? {
        if let m = domainID.firstMatch(of: /(Business\d+|Personal)/) {
            return String(m.1)
        }
        let needle = "CloudStorage/\(folder.lastPathComponent)"
        for instance in instanceFolders() {
            for ini in iniFiles(in: instance) {
                if let text = latin1(ini), text.contains(needle + "\n") || text.contains(needle + "\r") || text.contains(needle + "\"") {
                    return instance.lastPathComponent
                }
            }
        }
        return nil
    }

    /// A short user label from the account's library URL, e.g.
    /// ".../personal/creative_contoso_com" -> "creative".
    static func userLabel(forInstance instance: String) -> String? {
        let folder = settingsRoot.appending(path: instance, directoryHint: .isDirectory)
        for ini in iniFiles(in: folder) {
            guard let text = latin1(ini),
                  let m = text.firstMatch(of: /libraryScope = 0 .*?"https:\/\/[^"]*\/personal\/([A-Za-z0-9.\-]+)_/)
            else { continue }
            return String(m.1)
        }
        return nil
    }

    /// The settings instance a running OneDrive process serves, from its open lock file.
    static func instance(forPID pid: pid_t) -> String? {
        for path in openFilePaths(pid: pid) {
            if let range = path.range(of: "/OneDrive/settings/LockInstance_") {
                return String(path[range.upperBound...])
            }
        }
        return nil
    }

    // MARK: - Helpers

    private static func instanceFolders() -> [URL] {
        (try? FileManager.default.contentsOfDirectory(at: settingsRoot, includingPropertiesForKeys: [.isDirectoryKey]))?
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .filter { $0.lastPathComponent.hasPrefix("Business") || $0.lastPathComponent == "Personal" } ?? []
    }

    private static func iniFiles(in folder: URL) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil))?
            .filter { $0.pathExtension == "ini" } ?? []
    }

    private static func latin1(_ url: URL) -> String? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        return String(data: data, encoding: .isoLatin1)
    }

    /// Paths of the vnodes a process has open, via libproc.
    static func openFilePaths(pid: pid_t) -> [String] {
        let bufferSize = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard bufferSize > 0 else { return [] }
        let count = Int(bufferSize) / MemoryLayout<proc_fdinfo>.stride
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: count)
        let used = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds, bufferSize)
        guard used > 0 else { return [] }

        var paths: [String] = []
        for fd in fds.prefix(Int(used) / MemoryLayout<proc_fdinfo>.stride)
        where fd.proc_fdtype == UInt32(PROX_FDTYPE_VNODE) {
            var info = vnode_fdinfowithpath()
            let size = Int32(MemoryLayout<vnode_fdinfowithpath>.stride)
            guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDVNODEPATHINFO, &info, size) == size else { continue }
            let path = withUnsafeBytes(of: &info.pvip.vip_path) { raw in
                String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
            }
            paths.append(path)
        }
        return paths
    }
}
