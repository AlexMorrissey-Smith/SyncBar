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

    var isProblem: Bool {
        switch self {
        case .error, .needsSignIn: return true
        default: return false
        }
    }
}

/// The state shown by the single SyncBar menu bar icon.
enum CombinedState: Equatable {
    case idle, syncing, problem

    init(_ states: [SyncState]) {
        if states.contains(where: \.isProblem) {
            self = .problem
        } else if states.contains(where: \.isSyncing) {
            self = .syncing
        } else {
            self = .idle
        }
    }

    var symbolName: String {
        switch self {
        case .idle: return "icloud"
        case .syncing: return "arrow.trianglehead.2.clockwise.rotate.90.icloud"
        case .problem: return "exclamationmark.icloud"
        }
    }
}
