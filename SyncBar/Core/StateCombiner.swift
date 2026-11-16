import Foundation

/// Combines the fast source (menu bar item text) with the detailed source
/// (`fileproviderctl dump`) into one state per account.
enum StateCombiner {
    /// A dump older than this is ignored.
    static let snapshotLifetime: TimeInterval = 5 * 60

    static func state(
        isRunning: Bool,
        menuBarText: String?,
        snapshot: FileProviderSnapshot?,
        snapshotDate: Date?,
        now: Date = Date()
    ) -> SyncState {
        guard isRunning else { return .appNotRunning }

        let fast = menuBarText.map(StatusTextParser.state(from:)) ?? .unknown
        guard let snapshot, let snapshotDate, now.timeIntervalSince(snapshotDate) < snapshotLifetime else {
            return fast
        }

        // The File Provider framework knows about a lost sign-in even when the
        // app's tooltip has not caught up.
        if !snapshot.isRegistered || snapshot.needsAuth == true { return .needsSignIn }

        switch fast {
        case .syncing(let textFraction):
            // Prefer real byte counts over whatever the tooltip says.
            return .syncing(fraction: snapshot.activeTransfer?.fraction ?? textFraction)
        case .unknown:
            // Only fall back to the dump's own verdict (including its error
            // count, which also counts Spotlight indexing errors) when the app
            // itself tells us nothing.
            return snapshot.impliedState
        default:
            return fast
        }
    }
}
