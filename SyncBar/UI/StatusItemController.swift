import AppKit
import SwiftUI

/// Owns SyncBar's single menu bar icon and its popover.
@MainActor
final class StatusItemController: NSObject, NSPopoverDelegate {
    private let model: AppModel
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let popover = NSPopover()
    private var settingsWindow: NSWindow?
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
                showSettings: { [weak self] in self?.showSettings() }
            )
        )

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
        popover.performClose(nil)
        Task { [model] in
            try? await Task.sleep(for: .milliseconds(200))
            await model.openPanel(for: account)
        }
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
