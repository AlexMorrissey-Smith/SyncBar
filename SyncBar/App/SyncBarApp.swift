import AppKit
import SwiftUI

@main
struct SyncBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        // All UI lives in the status item; this scene is never shown.
        Settings { EmptyView() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let model = AppModel()
    private var statusController: StatusItemController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Unit tests load the app as their host; don't put an icon in the menu bar then.
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
        statusController = StatusItemController(model: model)
        model.start()
        if statusController?.needsSetup == true { statusController?.showSetup() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Never leave the apps' icons switched off without SyncBar running.
        model.iconHider.showAll()
        model.iconHider.relaunchAppsMissingTheirItem()
    }
}
