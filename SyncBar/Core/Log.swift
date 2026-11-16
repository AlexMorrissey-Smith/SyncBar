import Foundation

/// Appends diagnostic lines to ~/Library/Logs/SyncBar.log and the unified log.
enum Log {
    static let url = FileManager.default.homeDirectoryForCurrentUser
        .appending(path: "Library/Logs/SyncBar.log")

    static func write(_ message: String) {
        NSLog("SyncBar: %@", message)
        let line = "\(Date().formatted(.iso8601)) \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url)
        }
    }
}
