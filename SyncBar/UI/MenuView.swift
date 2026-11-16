import AppKit
import SwiftUI

/// The popover: a summary header, one row per visible account, then the footer.
struct MenuView: View {
    let model: AppModel
    let open: (Account) -> Void
    let showSettings: () -> Void
    let showSetup: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Header(
                state: model.combinedState,
                accounts: model.visibleAccounts.count,
                upToDate: model.visibleAccounts.filter { model.statuses[$0.id]?.state == .upToDate }.count
            )

            if !model.isTrusted || model.iconHider.needsFullDiskAccess {
                SetupBanner(
                    title: model.isTrusted ? "Permission needed to hide icons" : "Permission needed",
                    action: showSetup
                )
                .padding(.horizontal, 10)
                .padding(.bottom, 8)
            }

            if model.visibleAccounts.isEmpty {
                Text(model.accounts.isEmpty ? "No sync accounts found" : "All accounts are hidden")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 20)
            } else {
                VStack(spacing: 2) {
                    ForEach(model.visibleAccounts) { account in
                        let running = model.isRunning(account)
                        AccountRow(
                            account: account,
                            status: model.statuses[account.id] ?? AccountStatus(),
                            isRunning: running,
                            open: { running ? open(account) : model.launchApp(for: account) },
                            openFolder: { model.openFolder(for: account) },
                            launch: { model.launchApp(for: account) },
                            quit: { model.quitApp(for: account) },
                            restart: { model.restartApp(for: account) }
                        )
                    }
                }
                .padding(.horizontal, 6)
                .padding(.bottom, 6)
            }

            Divider().padding(.horizontal, 12)

            HStack(spacing: 2) {
                Text("SyncBar")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Spacer()
                FooterButton(symbol: "gearshape", help: "Settings…", action: showSettings)
                FooterButton(symbol: "power", help: "Quit SyncBar") { NSApp.terminate(nil) }
            }
            .padding(.leading, 14)
            .padding(.trailing, 8)
            .padding(.vertical, 6)
        }
        .frame(width: 330)
        .focusEffectDisabled()
    }
}

// MARK: - Header

private struct Header: View {
    let state: CombinedState
    let accounts: Int
    let upToDate: Int

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(tint.gradient, in: Circle())
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.headline)
                Text(accounts == 1 ? "1 account" : "\(accounts) accounts")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }

    private var title: String {
        switch state {
        case .idle: upToDate == accounts ? "Everything is up to date" : "\(upToDate) of \(accounts) up to date"
        case .paused: "Syncing is paused"
        case .syncing: "Syncing…"
        case .warning: "An account needs attention"
        case .error: "A sync error needs attention"
        }
    }

    private var symbol: String {
        switch state {
        case .idle: "checkmark"
        case .paused: "pause.fill"
        case .syncing: "arrow.triangle.2.circlepath"
        case .warning: "exclamationmark"
        case .error: "xmark"
        }
    }

    private var tint: Color {
        switch state {
        case .idle: .green
        case .paused: .gray
        case .syncing: .blue
        case .warning: .orange
        case .error: .red
        }
    }
}

// MARK: - Setup banner

private struct SetupBanner: View {
    let title: String
    let action: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "hand.raised.fill").foregroundStyle(.orange)
            Text(title).font(.subheadline.weight(.semibold))
            Spacer()
            Button("Set Up…", action: action).controlSize(.small)
        }
        .padding(10)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: - Row

private struct AccountRow: View {
    let account: Account
    let status: AccountStatus
    let isRunning: Bool
    let open: () -> Void
    let openFolder: () -> Void
    let launch: () -> Void
    let quit: () -> Void
    let restart: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: open) {
            HStack(spacing: 10) {
                Image(nsImage: account.app.icon)
                    .resizable()
                    .frame(width: 32, height: 32)
                    .opacity(isRunning ? 1 : 0.5)
                    .saturation(isRunning ? 1 : 0)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(account.title)
                            .fontWeight(.medium)
                        Spacer(minLength: 6)
                        StatusLabel(state: status.state)
                    }
                    if let subtitle = account.subtitle {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    if case .syncing(let fraction?) = status.state {
                        ProgressView(value: fraction)
                            .progressViewStyle(.linear)
                            .controlSize(.small)
                    }
                    if let note = status.note {
                        Text(note)
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
            .background(
                isHovered ? Color.primary.opacity(0.07) : .clear,
                in: RoundedRectangle(cornerRadius: 8)
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(isRunning ? (status.menuBarText ?? account.folderURL.path) : "Click to launch \(account.app.name)")
        .contextMenu {
            Button("Open Folder in Finder", systemImage: "folder", action: openFolder)
            Divider()
            if isRunning {
                Button("Restart \(account.app.name)", systemImage: "arrow.clockwise", action: restart)
                Button("Quit \(account.app.name)", systemImage: "xmark.circle", action: quit)
            } else {
                Button("Launch \(account.app.name)", systemImage: "play.circle", action: launch)
            }
        }
    }
}

/// A coloured symbol and short text for one account's state.
private struct StatusLabel: View {
    let state: SyncState

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: symbol)
            Text(state.label)
                .lineLimit(1)
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(tint)
    }

    private var symbol: String {
        switch state {
        case .upToDate: "checkmark.circle.fill"
        case .syncing: "arrow.triangle.2.circlepath"
        case .paused: "pause.circle.fill"
        case .error: "exclamationmark.triangle.fill"
        case .needsSignIn: "person.crop.circle.badge.exclamationmark"
        case .appNotRunning: "moon.zzz"
        case .unknown: "questionmark.circle"
        }
    }

    private var tint: Color {
        switch state {
        case .upToDate: .green
        case .syncing: .blue
        case .error: .red
        case .needsSignIn: .orange
        case .paused, .appNotRunning, .unknown: .secondary
        }
    }
}

// MARK: - Footer

private struct FooterButton: View {
    let symbol: String
    let help: String
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .frame(width: 26, height: 22)
                .contentShape(Rectangle())
                .background(isHovered ? Color.primary.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .onHover { isHovered = $0 }
        .help(help)
    }
}
