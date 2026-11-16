# SyncBar

One menu bar icon for all your cloud sync accounts on macOS 27.

SyncBar lists every OneDrive, Dropbox and Nextcloud account on the Mac with its
current status (Up to date, Syncing with progress, Paused, Error, Needs sign-in,
App not running). Its own icon combines them: a solid cloud, with a spinning
badge while anything syncs and a warning or error badge when an account needs
attention. Clicking a row opens that app's own menu bar panel. SyncBar can also
hide the apps' own icons, so only its icon remains.

## Requirements

- macOS 27.2 or later (built and tested on 27.3)
- Xcode 27.2 or later
- Accessibility permission (SyncBar asks on first run)

## Build and run

```sh
xcodebuild -project SyncBar.xcodeproj -scheme SyncBar -configuration Debug -derivedDataPath build build
open build/Build/Products/Debug/SyncBar.app
```

Run the parser tests:

```sh
xcodebuild -project SyncBar.xcodeproj -scheme SyncBar -derivedDataPath build test
```

The project is generated from `project.yml` with [XcodeGen](https://github.com/yonaskolb/XcodeGen)
(`xcodegen generate`). The generated `SyncBar.xcodeproj` is committed, so XcodeGen is only
needed when adding files. Signing uses an "Apple Development" identity; set
`DEVELOPMENT_TEAM` in `project.yml` to your own team ID. Keep a stable signing
identity: an ad-hoc signed build loses its Accessibility permission on every rebuild.

## How it works

**Finding accounts.** Each folder in `~/Library/CloudStorage` carries the extended
attribute `com.apple.file-provider-domain-id` (`<providerID>/<domainID>`), which maps it
to its app. Nextcloud in classic folder-sync mode is read from
`~/Library/Preferences/Nextcloud/nextcloud.cfg`. OneDrive runs one process per account;
SyncBar tells them apart by the `settings/LockInstance_<Business1|Business2|Personal>` lock
file each process holds open.

**Reading status.** Two sources are combined:

1. Every few seconds, the text of each app's menu bar item (title, description, help,
   value), read through the Accessibility API. On macOS 27 all third-party status items
   are hosted in `com.apple.MenuBarAgent`'s accessibility tree; SyncBar walks it and
   matches items to apps with `AXUIElementGetPid`. The owning app's `AXExtrasMenuBar` is
   kept as a fallback.
2. `fileproviderctl dump <provider>/<domain>` for byte progress, sign-in and error state.
   Dumps run one at a time, at most once a minute per account, only while an account is
   syncing (or its menu bar text is unavailable) plus once at launch. SyncBar stops
   reading as soon as the header is parsed, with a 45-second timeout.

**Opening an app's panel.** SyncBar performs `AXPress` on the app's hosted item, which
makes the app open its own menu or popover at its real icon. Success is judged by a new
window from that app, because apps that show a classic menu block the press reply.

**Hiding the apps' icons.** macOS 27 no longer pushes icons off screen (icons that don't
fit go into the system overflow), so SyncBar uses the system's own per-app switch, the
same one as System Settings › Menu Bar › Menu Bar Controls. It is stored in Control
Center's group container preferences (`trackedApplications`). SyncBar:

- hides an app only once it is running and has created its icon (an app that starts
  while switched off never creates one);
- switches an app back on for a moment to open its panel, and off again when the panel
  closes;
- switches an app back on when it quits, and every app back on when SyncBar quits.

## Credits

- [FileProviderProgress](https://github.com/finia2NA/FileProviderProgress) by finia2NA (MIT):
  the approach for parsing `fileproviderctl dump` output and xattr-based domain discovery.
- [ncstatus](https://github.com/weiaoli2/ncstatus) by weiaoli2: reference for reading
  File Provider status.
- [OmniWM](https://github.com/OmniNull/OmniWM) (pull request 1041) and
  [Thaw](https://github.com/thaw-app/Thaw): reference for walking MenuBarAgent's
  accessibility tree and for revealing an item before pressing it on macOS 27. No code
  was copied from either (both are GPL).

## License

MIT. See [LICENSE](LICENSE).
