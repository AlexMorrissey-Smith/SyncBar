import AppKit
import SwiftUI

/// The popover: one row per visible account, then the footer.
struct MenuView: View {
    let model: AppModel
    let open: (Account) -> Void
    let showSettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !model.isTrusted {
                AccessibilityBanner()
                Divider()
            }

            if model.visibleAccounts.isEmpty {
                Text(model.accounts.isEmpty ? "No sync accounts found" : "All accounts are hidden")
                    .foregroundStyle(.secondary)
                    .padding(12)
            } else {
                VStack(spacing: 2) {
                    ForEach(model.visibleAccounts) { account in
                        AccountRow(
                            account: account,
                            status: model.statuses[account.id] ?? AccountStatus(),
                            isRunning: model.isRunning(account),
                            open: { open(account) },
                            openFolder: { model.openFolder(for: account) },
                            launch: { model.launchApp(for: account) },
                            quit: { model.quitApp(for: account) }
                        )
                    }
                }
                .padding(6)
            }

            Divider()
            HStack {
                Button("Settings…", action: showSettings)
                Spacer()
                Button("Quit SyncBar") { NSApp.terminate(nil) }
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .frame(width: 320)
    }
}

private struct AccessibilityBanner: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Accessibility access needed", systemImage: "exclamationmark.triangle.fill")
                .font(.headline)
                .foregroundStyle(.orange)
            Text("SyncBar reads each app's menu bar status and opens its panel through Accessibility. Turn SyncBar on in System Settings › Privacy & Security › Accessibility.")
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Button("Open Accessibility Settings") {
                let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
                NSWorkspace.shared.open(url)
            }
        }
        .padding(12)
    }
}

private struct AccountRow: View {
    let account: Account
    let status: AccountStatus
    let isRunning: Bool
    let open: () -> Void
    let openFolder: () -> Void
    let launch: () -> Void
    let quit: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: open) {
            HStack(spacing: 10) {
                Image(nsImage: account.app.icon)
                    .resizable()
                    .frame(width: 28, height: 28)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 4) {
                        Text(account.title).fontWeight(.medium)
                        Text(account.detail).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                    HStack(spacing: 4) {
                        Image(systemName: symbol).foregroundStyle(tint).imageScale(.small)
                        Text(status.state.label).foregroundStyle(.secondary)
                    }
                    .font(.callout)
                    if case .syncing(let fraction?) = status.state {
                        ProgressView(value: fraction).controlSize(.small)
                    }
                    if let note = status.note {
                        Text(note).font(.caption).foregroundStyle(.orange)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
            .background(isHovered ? Color.primary.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(status.menuBarText ?? account.folderURL.path)
        .contextMenu {
            Button("Open Folder in Finder", action: openFolder)
            if isRunning {
                Button("Quit \(account.app.name)", action: quit)
            } else {
                Button("Launch \(account.app.name)", action: launch)
            }
        }
    }

    private var symbol: String {
        switch status.state {
        case .upToDate: "checkmark.circle.fill"
        case .syncing: "arrow.triangle.2.circlepath"
        case .paused: "pause.circle.fill"
        case .error: "exclamationmark.triangle.fill"
        case .needsSignIn: "person.crop.circle.badge.exclamationmark"
        case .appNotRunning: "moon.zzz.fill"
        case .unknown: "questionmark.circle"
        }
    }

    private var tint: Color {
        switch status.state {
        case .upToDate: .green
        case .syncing: .blue
        case .paused: .secondary
        case .error, .needsSignIn: .orange
        case .appNotRunning, .unknown: .secondary
        }
    }
}
