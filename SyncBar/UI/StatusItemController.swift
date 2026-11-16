import AppKit
import SwiftUI

/// Owns SyncBar's single menu bar icon and its popover.
@MainActor
final class StatusItemController: NSObject, NSPopoverDelegate {
    private let model: AppModel
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let popover = NSPopover()
    private var settingsWindow: NSWindow?
    private var setupWindow: NSWindow?
    private var shownState: CombinedState?
    private var spinTimer: Timer?
    private var rotation: CGFloat = 0

    init(model: AppModel) {
        self.model = model
        super.init()

        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePopover)
        statusItem.button?.setAccessibilityTitle("SyncBar")

        popover.behavior = .transient
        popover.animates = false
        popover.delegate = self
        popover.contentViewController = NSHostingController(
            rootView: MenuView(
                model: model,
                open: { [weak self] account in self?.openPanel(for: account) },
                showSettings: { [weak self] in self?.showSettings() },
                showSetup: { [weak self] in self?.showSetup() }
            )
        )

        // Test hook: `com.morrisseymedia.syncbar.open` with an account detail
        // (e.g. "contoso") as the object opens that row, as a click would.
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.morrisseymedia.syncbar.open"), object: nil, queue: .main
        ) { [weak self] note in
            let query = note.object as? String ?? ""
            MainActor.assumeIsolated {
                guard let self, let account = self.model.visibleAccounts.first(where: {
                    $0.detail.localizedCaseInsensitiveContains(query) || $0.title.localizedCaseInsensitiveContains(query)
                }) else { return }
                self.openPanel(for: account)
            }
        }

        model.onUpdate = { [weak self] in self?.updateIcon() }
        updateIcon()
    }

    private func updateIcon() {
        let state = model.combinedState
        guard state != shownState, let button = statusItem.button else { return }
        shownState = state
        button.toolTip = state.tooltip
        rotation = 0
        button.image = MenuBarIcon.image(for: state)

        // Spin the sync badge while anything is syncing.
        spinTimer?.invalidate()
        spinTimer = nil
        if state == .syncing {
            spinTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 15, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.spin() }
            }
        }
    }

    private func spin() {
        // One full turn every 1.6 s.
        rotation = (rotation + 2 * .pi / 24).truncatingRemainder(dividingBy: 2 * .pi)
        statusItem.button?.image = MenuBarIcon.image(for: .syncing, rotation: rotation)
    }

    @objc private func togglePopover() {
        if popover.isShown {
            popover.performClose(nil)
        } else if let button = statusItem.button {
            model.refresh()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    /// Closes the popover first, so the other app's panel can take focus.
    private func openPanel(for account: Account) {
        if let button = statusItem.button, let window = button.window, let screen = window.screen ?? NSScreen.screens.first {
            // Convert to top-left-origin screen coordinates, as AX and CGWindow use.
            let rect = window.convertToScreen(button.convert(button.bounds, to: nil))
            let top = NSScreen.screens.first?.frame.maxY ?? screen.frame.maxY
            model.iconFrame = CGRect(x: rect.minX, y: top - rect.maxY, width: rect.width, height: rect.height)
        }
        popover.performClose(nil)
        Task { [model] in
            try? await Task.sleep(for: .milliseconds(200))
            await model.openPanel(for: account)
        }
    }

    /// True when a permission SyncBar needs is missing.
    var needsSetup: Bool {
        !Permissions.hasAccessibility || (model.preferences.hideOriginalIcons && !Permissions.hasFullDiskAccess)
    }

    func showSetup() {
        popover.performClose(nil)
        if setupWindow == nil {
            let view = SetupView(needsFullDiskAccess: model.preferences.hideOriginalIcons) { [weak self] in
                self?.setupWindow?.close()
                self?.setupWindow = nil
                self?.model.refresh()
            }
            let window = NSWindow(contentViewController: NSHostingController(rootView: view))
            window.title = "SyncBar"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            setupWindow = window
        }
        NSApp.activate()
        setupWindow?.makeKeyAndOrderFront(nil)
    }

    private func showSettings() {
        popover.performClose(nil)
        if settingsWindow == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: SettingsView(model: model)))
            window.title = "SyncBar Settings"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        NSApp.activate()
        settingsWindow?.makeKeyAndOrderFront(nil)
    }
}
