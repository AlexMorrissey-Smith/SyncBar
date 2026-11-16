import Foundation

/// Byte progress of an upload or download, from a `fileproviderctl dump`.
struct TransferProgress: Equatable, Sendable {
    var completedBytes: Int64
    var totalBytes: Int64

    var fraction: Double? {
        totalBytes > 0 ? Double(completedBytes) / Double(totalBytes) : nil
    }

    var isComplete: Bool { completedBytes >= totalBytes }
}

/// The parts of a `fileproviderctl dump <provider>/<domain>` that SyncBar uses.
struct FileProviderSnapshot: Equatable, Sendable {
    var isAlive = false
    var needsAuth: Bool?
    var errorCount: Int?
    var upload: TransferProgress?
    var download: TransferProgress?

    /// Combined upload and download progress, when either has a byte count.
    var activeTransfer: TransferProgress? {
        let active = [upload, download].compactMap { $0 }.filter { !$0.isComplete && $0.totalBytes > 0 }
        guard !active.isEmpty else { return nil }
        return TransferProgress(
            completedBytes: active.reduce(0) { $0 + $1.completedBytes },
            totalBytes: active.reduce(0) { $0 + $1.totalBytes }
        )
    }

    /// The state this snapshot implies on its own.
    var impliedState: SyncState {
        if needsAuth == true { return .needsSignIn }
        if let errorCount, errorCount > 0 { return .error("\(errorCount) File Provider error\(errorCount == 1 ? "" : "s")") }
        if let transfer = activeTransfer { return .syncing(fraction: transfer.fraction) }
        // File Provider launches extensions on demand, so an idle one (Dropbox)
        // is often not alive. A clean sign-in and error report still means
        // nothing is pending.
        if isAlive || (needsAuth == false && errorCount == 0) { return .upToDate }
        return .unknown
    }
}

/// Line-by-line parser for `fileproviderctl dump` output.
///
/// The dump of a large domain runs to hundreds of thousands of lines, but
/// everything SyncBar needs sits in the header, which ends with the
/// "sync engine state" block. Feed lines with `consume(_:)` and stop reading
/// as soon as `isComplete` is true.
///
/// Parsing approach adapted from FileProviderProgress by finia2NA (MIT).
struct FileProviderDumpParser {
    private(set) var snapshot = FileProviderSnapshot()
    private(set) var isComplete = false
    private var sawUpload = false
    private var sawDownload = false

    init() {}

    /// Parses a whole dump at once.
    static func parse(_ text: String) -> FileProviderSnapshot {
        var parser = FileProviderDumpParser()
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            parser.consume(String(line))
            if parser.isComplete { break }
        }
        return parser.snapshot
    }

    mutating func consume(_ rawLine: String) {
        guard !isComplete else { return }
        let line = Self.stripANSI(rawLine)

        if line.contains("upload progress:") {
            sawUpload = true
            snapshot.upload = Self.transfer(in: line)
        } else if line.contains("download progress:") {
            sawDownload = true
            snapshot.download = Self.transfer(in: line)
        } else if line.contains("needs-auth:") {
            snapshot.needsAuth = Self.yesNo(in: line)
        } else if line.trimmingCharacters(in: .whitespaces).hasPrefix("errors:") {
            snapshot.errorCount = Self.trailingInt(in: line)
        } else if line.contains(" alive ") || line.hasPrefix("alive ") {
            snapshot.isAlive = true
        }

        if sawUpload && sawDownload { isComplete = true }
    }

    // MARK: - Helpers

    private static func stripANSI(_ s: String) -> String {
        guard s.contains("\u{1B}") else { return s }
        return s.replacing(/\x1B\[[0-9;]*m/, with: "")
    }

    private static func transfer(in line: String) -> TransferProgress? {
        guard let m = line.firstMatch(of: /Completed:\s*(\d+)\s+of\s+(\d+)/),
              let done = Int64(m.1), let total = Int64(m.2) else { return nil }
        return TransferProgress(completedBytes: done, totalBytes: total)
    }

    private static func yesNo(in line: String) -> Bool? {
        if line.contains(/:\s*yes\b/) { return true }
        if line.contains(/:\s*no\b/) { return false }
        return nil
    }

    private static func trailingInt(in line: String) -> Int? {
        guard let m = line.firstMatch(of: /:\s*(\d+)\s*$/) else { return nil }
        return Int(m.1)
    }
}
