import Foundation
import Testing
@testable import SyncBar

private func fixture(_ name: String) throws -> String {
    let bundle = Bundle(for: BundleToken.self)
    let url = try #require(bundle.url(forResource: name, withExtension: "txt"))
    return try String(contentsOf: url, encoding: .utf8)
}

private final class BundleToken {}

@Suite struct FileProviderDumpParserTests {
    @Test func idleRealDumpIsUpToDate() throws {
        let snapshot = FileProviderDumpParser.parse(try fixture("idle-nextcloud"))
        #expect(snapshot.isAlive)
        #expect(snapshot.needsAuth == false)
        #expect(snapshot.errorCount == 0)
        #expect(snapshot.upload == nil)
        #expect(snapshot.download == nil)
        #expect(snapshot.impliedState == .upToDate)
    }

    @Test func syncingDumpReportsByteProgress() {
        let dump = """
        domain: 9 (Example)
         \u{1B}[33m alive (945) via ExtensionKit\u{1B}[39m for:
              needs-auth:     no
              errors:         0
        sync engine state:
            + upload progress: <gprogress:NSProgressFileOperationKindUploading pp:<NSProgress: 0x1> / Fraction completed: 0.2500 / Completed: 250 of 1000 url:<FPFS>/x>
            + download progress: <gprogress:NSProgressFileOperationKindDownloading pp:<NSProgress: 0x2> / Fraction completed: 0.5000 / Completed: 500 of 1000 url:<FPFS>/x>
        """
        let snapshot = FileProviderDumpParser.parse(dump)
        #expect(snapshot.isAlive)
        #expect(snapshot.upload == TransferProgress(completedBytes: 250, totalBytes: 1000))
        #expect(snapshot.download == TransferProgress(completedBytes: 500, totalBytes: 1000))
        #expect(snapshot.activeTransfer == TransferProgress(completedBytes: 750, totalBytes: 2000))
        #expect(snapshot.impliedState == .syncing(fraction: 0.375))
    }

    @Test func needsAuthWins() {
        let dump = """
         alive (1) via ExtensionKit for:
              needs-auth:     yes
              errors:         2
            + upload progress: <gprogress: Completed: 1 of 10 url:x>
            + download progress: <gprogress: url:x>
        """
        let snapshot = FileProviderDumpParser.parse(dump)
        #expect(snapshot.needsAuth == true)
        #expect(snapshot.errorCount == 2)
        #expect(snapshot.impliedState == .needsSignIn)
    }

    @Test func errorsWithoutAuthProblemAreErrors() {
        let dump = """
              needs-auth:     no
              errors:         3
        """
        #expect(FileProviderDumpParser.parse(dump).impliedState == .error("3 File Provider errors"))
    }

    @Test func deadExtensionIsUnknown() {
        let dump = """
              needs-auth:     no
              errors:         0
            + upload progress: <gprogress:NSProgressFileOperationKindUploading url:x>
            + download progress: <gprogress:NSProgressFileOperationKindDownloading url:x>
        """
        let snapshot = FileProviderDumpParser.parse(dump)
        #expect(!snapshot.isAlive)
        #expect(snapshot.impliedState == .unknown)
    }

    @Test func completedTransfersAreNotActive() {
        let dump = """
         alive (1) via ExtensionKit for:
            + upload progress: <gprogress: Completed: 10 of 10 url:x>
            + download progress: <gprogress: Completed: 0 of 0 url:x>
        """
        #expect(FileProviderDumpParser.parse(dump).impliedState == .upToDate)
    }

    @Test func parserStopsAfterSyncEngineHeader() {
        var parser = FileProviderDumpParser()
        parser.consume("    + upload progress: <gprogress: url:x>")
        #expect(!parser.isComplete)
        parser.consume("    + download progress: <gprogress: url:x>")
        #expect(parser.isComplete)
        // Later item lines must not change the result.
        parser.consume("      needs-auth:     yes")
        #expect(parser.snapshot.needsAuth == nil)
    }
}

@Suite struct StatusTextParserTests {
    @Test(arguments: [
        ("OneDrive — Contoso\nBacked up and synced", SyncState.upToDate),
        ("macOS VFS for user@cloud.example.net: Last sync was successful.", .upToDate),
        ("Dropbox 230.4\nUp to date", .upToDate),
        ("OneDrive — Contoso\nSyncing 3 files", .syncing(fraction: nil)),
        ("Dropbox\nSyncing 42%", .syncing(fraction: 0.42)),
        ("Nextcloud: Syncing 3 of 12 (1 min left)", .syncing(fraction: 0.25)),
        ("OneDrive — Contoso\nPaused", .paused),
        ("Nextcloud: Sync is paused", .paused),
        ("OneDrive\nYou're not signed in", .needsSignIn),
        ("Nextcloud: Disconnected from server", .error(nil)),
        ("BetterDisplay", .unknown),
    ])
    func mapsMenuBarText(text: String, expected: SyncState) {
        #expect(StatusTextParser.state(from: text) == expected)
    }
}
