import Foundation

/// The sync state of one account, as shown in a row.
enum SyncState: Equatable, Sendable {
    case upToDate
    /// `fraction` is 0...1 when a byte count is known.
    case syncing(fraction: Double?)
    case paused
    case error(String?)
    case needsSignIn
    case appNotRunning
    /// The app is running but nothing it exposes could be mapped to a state.
    case unknown

    var label: String {
        switch self {
        case .upToDate: return "Up to date"
        case .syncing(let fraction):
            if let fraction { return "Syncing \(Int((fraction * 100).rounded()))%" }
            return "Syncing"
        case .paused: return "Paused"
        case .error(let detail): return detail.map { "Error: \($0)" } ?? "Error"
        case .needsSignIn: return "Needs sign-in"
        case .appNotRunning: return "App not running"
        case .unknown: return "Status unknown"
        }
    }

    var isSyncing: Bool {
        if case .syncing = self { return true }
        return false
    }
}

/// The state shown by the single SyncBar menu bar icon, most urgent first.
enum CombinedState: Equatable {
    case idle, paused, syncing, warning, error

    init(_ states: [SyncState]) {
        func any(_ test: (SyncState) -> Bool) -> Bool { states.contains(where: test) }
        if any({ if case .error = $0 { true } else { false } }) {
            self = .error
        } else if any({ $0 == .needsSignIn }) {
            self = .warning
        } else if any(\.isSyncing) {
            self = .syncing
        } else if !states.isEmpty, states.allSatisfy({ $0 == .paused }) {
            self = .paused
        } else {
            self = .idle
        }
    }

    var tooltip: String {
        switch self {
        case .idle: "SyncBar: everything up to date"
        case .paused: "SyncBar: syncing paused"
        case .syncing: "SyncBar: syncing"
        case .warning: "SyncBar: an account needs attention"
        case .error: "SyncBar: an account has a sync error"
        }
    }
}
