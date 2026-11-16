import Foundation

/// Maps the text a sync app exposes on its menu bar item (title, description,
/// help/tooltip, value) to a `SyncState`.
///
/// Known strings, as seen on macOS 27.3:
/// - OneDrive: "OneDrive — <org>\nBacked up and synced", "…\nSyncing…", "…\nPaused", "…\nSign in".
/// - Dropbox: "Dropbox <version>\nUp to date", "Syncing…".
/// - Nextcloud: "macOS VFS for <account>: Last sync was successful.", "Syncing …", "Sync is paused", "Disconnected …".
enum StatusTextParser {
    static func state(from text: String) -> SyncState {
        let t = text.lowercased()

        if t.containsAny("not signed in", "sign in", "signed out", "sign-in", "log in", "login required",
                         "reauthent", "re-authent", "credentials", "authentication")
        {
            return .needsSignIn
        }
        if t.containsAny("error", "can't sync", "cannot sync", "couldn't sync", "unable to sync", "sync failed",
                         "problem", "disconnected", "not connected", "conflict", "account is full",
                         "storage is full", "out of space", "blocked")
        {
            return .error(nil)
        }
        if t.contains("paused") {
            return .paused
        }
        if t.containsAny("syncing", "uploading", "downloading", "processing", "preparing", "indexing",
                         "updating", "sync in progress", "checking for changes", "looking for changes",
                         "starting", "connecting")
        {
            return .syncing(fraction: fraction(in: t))
        }
        if t.containsAny("up to date", "up-to-date", "backed up", "synced", "last sync was successful",
                         "sync was successful", "sync complete", "all files are")
        {
            return .upToDate
        }
        return .unknown
    }

    /// Finds "42%" or "3 of 10" in a status string.
    static func fraction(in text: String) -> Double? {
        if let m = text.firstMatch(of: /(\d{1,3})\s?%/), let pct = Double(m.1), pct <= 100 {
            return pct / 100
        }
        if let m = text.firstMatch(of: /(\d+)\s+of\s+(\d+)/), let a = Double(m.1), let b = Double(m.2), b > 0, a <= b {
            return a / b
        }
        return nil
    }
}

private extension String {
    func containsAny(_ needles: String...) -> Bool {
        needles.contains { contains($0) }
    }
}
