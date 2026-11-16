import AppKit
import SwiftUI

/// Walks the user through the permissions SyncBar needs. Checks every second
/// and calls `done` once everything is granted.
struct SetupView: View {
    let needsFullDiskAccess: Bool
    let done: () -> Void

    @State private var accessibility = Permissions.hasAccessibility
    @State private var fullDiskAccess = Permissions.hasFullDiskAccess

    private var allGranted: Bool { accessibility && (fullDiskAccess || !needsFullDiskAccess) }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 64, height: 64)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Set up SyncBar").font(.title2.weight(.semibold))
                    Text("SyncBar needs two permissions to show your sync apps' status and replace their menu bar icons.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            VStack(spacing: 10) {
                Step(
                    number: 1,
                    title: "Accessibility",
                    detail: "Reads each app's status and opens its menu when you click a row.",
                    granted: accessibility,
                    action: Permissions.requestAccessibility
                )
                if needsFullDiskAccess {
                    Step(
                        number: 2,
                        title: "Full Disk Access",
                        detail: "Lets SyncBar switch the apps' own icons off in the menu bar settings.",
                        granted: fullDiskAccess,
                        action: Permissions.requestFullDiskAccess
                    )
                }
            }

            if !allGranted {
                HStack(spacing: 10) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 32, height: 32)
                        .onDrag { NSItemProvider(object: Bundle.main.bundleURL as NSURL) }
                        .help("Drag into the list in System Settings")
                    Text("Click Open Settings and switch SyncBar on. If it isn't in the list, drag this icon into it. If macOS asks, choose Quit & Reopen.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            HStack {
                Spacer()
                Button(allGranted ? "Done" : "Later", action: done)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 460)
        .task {
            while !Task.isCancelled {
                accessibility = Permissions.hasAccessibility
                fullDiskAccess = Permissions.hasFullDiskAccess
                if allGranted {
                    try? await Task.sleep(for: .seconds(1))
                    done()
                    return
                }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }
}

private struct Step: View {
    let number: Int
    let title: String
    let detail: String
    let granted: Bool
    let action: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(granted ? Color.green : Color.accentColor)
                if granted {
                    Image(systemName: "checkmark").font(.system(size: 12, weight: .bold))
                } else {
                    Text("\(number)").font(.system(size: 13, weight: .bold))
                }
            }
            .foregroundStyle(.white)
            .frame(width: 26, height: 26)

            VStack(alignment: .leading, spacing: 2) {
                Text(title).fontWeight(.semibold)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if granted {
                Text("Granted").font(.caption.weight(.medium)).foregroundStyle(.green)
            } else {
                Button("Open Settings", action: action)
            }
        }
        .padding(12)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
    }
}
