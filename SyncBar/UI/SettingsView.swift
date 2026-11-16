import AppKit
import SwiftUI

/// Reorder or hide rows, and launch at login.
struct SettingsView: View {
    let model: AppModel

    var body: some View {
        @Bindable var preferences = model.preferences

        Form {
            Section {
                List {
                    ForEach(preferences.ordered(model.accounts)) { account in
                        HStack(spacing: 8) {
                            Image(systemName: "line.3.horizontal").foregroundStyle(.tertiary)
                            Image(nsImage: account.app.icon).resizable().frame(width: 20, height: 20)
                            VStack(alignment: .leading) {
                                Text(account.title)
                                Text(account.detail).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Toggle("Show", isOn: Binding(
                                get: { !preferences.isHidden(account) },
                                set: { preferences.setHidden(!$0, for: account) }
                            ))
                            .labelsHidden()
                        }
                    }
                    .onMove { source, destination in
                        preferences.move(model.accounts, fromOffsets: source, toOffset: destination)
                    }
                }
                .frame(minHeight: 220)
            } header: {
                Text("Accounts")
            } footer: {
                Text("Drag to reorder. Switch off to hide a row.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Toggle("Hide the apps' own menu bar icons", isOn: $preferences.hideOriginalIcons)
                    .onChange(of: preferences.hideOriginalIcons) { model.refresh() }
                if let error = model.iconHider.lastError {
                    Text(error).font(.caption).foregroundStyle(.orange)
                    if model.iconHider.needsFullDiskAccess {
                        Button("Open Full Disk Access Settings") {
                            Permissions.requestFullDiskAccess()
                        }
                    }
                }
            } footer: {
                Text("SyncBar switches the shown apps off in System Settings › Menu Bar and turns each one back on for a moment when you open it. Quitting SyncBar shows them again.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Toggle("Launch at login", isOn: $preferences.launchAtLogin)
                if preferences.loginItemNeedsApproval {
                    Text("Approve SyncBar in System Settings › General › Login Items.")
                        .font(.caption).foregroundStyle(.orange)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 440, height: 560)
    }
}
