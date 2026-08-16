# GestaltKitTool

English | [简体中文](./README_zh-CN.md)

> Project renamed from **WeskTool** to **GestaltKitTool** as of this revision. The
> bundle identifier `com.wesk.vtool` is intentionally preserved so that existing
> installations upgrade in place (retaining the local Backup/Patch library and any
> already-written MobileGestalt state).

GestaltKitTool is a native SwiftUI MobileGestalt utility that runs directly on iPhone. It reads the device's `com.apple.MobileGestalt.plist` and provides common capability presets, a complete field editor, backup/import/restore workflows, cross-app sandbox file browsing, and system file inspection — all powered by the `bad_query` sandbox escape.

> [!WARNING]
> This project uses private APIs and modifies system cache data. Incorrect MobileGestalt values can break system features or UI behavior and may require restoring the device. Use it only on devices you own or are authorized to manage.

> [!NOTE]
> GestaltKitTool does not install a jailbreak, Bootstrap, or persistent daemons, and does not inject code into third-party apps, so it is not detected as a jailbreak.

## Features

### MobileGestalt tab

- Dynamic Island device subtypes and the alternate support flag
- Device model name shown in About
- Boot/shutdown chime, charge limit, tap to wake, and Camera Control settings
- Apple Pencil, Action Button, and Collision SOS settings
- Always-On Display, AOD vibrancy, wallpaper parallax, and Liquid Glass low-performance mode
- Stage Manager, iPad app compatibility, and Nugget's iPadOS `CacheData` patch
- Siri AI US region, Apple internal install, internal storage, and Security Research Device mode
- Advanced field editor: search and edit String, Integer, Float, Boolean, Data, Array, and Dictionary values in `CacheExtra` and at the plist top level
- Backup library: manually back up, import, export, restore, and delete local backups with pre-write verification

Presets follow Nugget's staged-apply model: toggles represent changes for the next write, and all selected changes are committed with the bottom Apply button. Selections are cleared after a successful write. Options that write conflicting values are mutually exclusive. After a successful write or restore, GestaltKitTool automatically refreshes SpringBoard so changes take effect.

### Explorer tab

- Discover and browse all app data containers, app group containers, and system group containers on the device
- `bad_query` bypasses the sandbox to list and read files from any app's private data container
- Navigate directories with breadcrumb trail, bookmark favorite paths, and enter custom absolute paths
- File preview with automatic type detection: property list (tree view), JSON (pretty-printed), text, image (PNG/JPEG/HEIC), hex dump, and binary
- Recursive search across directories with incremental results and cancellation support

### Inspector tab

- Inspect sensitive system files that demonstrate the full impact of the `bad_query` sandbox escape
- 10 target files across 6 categories: Identity & Gestalt, System Containers, App Sandboxes, Bundle Containers, Network Configuration, and System Information
- Property list tree browser with key-value inspection
- Export read results for further analysis

### Settings tab

- Language switching between English and Simplified Chinese (follows system by default)
- Diagnostics panel with 5 tests: bad_query availability, sandbox lease, container discovery, file read, and directory listing

## Requirements and signing

- Supported system versions: iOS 27 beta 1 through beta 4 only
- Xcode and a signing method that can install apps on the target device
- Developer Mode enabled on the device
- Bundle identifier: `com.wesk.vtool`

GestaltKitTool checks the running system build before accessing MobileGestalt. The current release accepts only iOS 27 beta 1–4 (24A5355q, 24A5370h, 24A5380h, and 24A5390f). Apple may change these private behaviors at any time.

## Building

Open `GestaltKitTool.xcodeproj` in Xcode, select your own development team for the target, and build. You can also build from the command line:

```sh
xcodebuild \
  -project GestaltKitTool.xcodeproj \
  -scheme WeskTool \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  DEVELOPMENT_TEAM=YOUR_TEAM_ID \
  build
```

To validate the source without signing:

```sh
xcodebuild \
  -project GestaltKitTool.xcodeproj \
  -scheme WeskTool \
  -sdk iphoneos \
  -destination 'generic/platform=iOS' \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  build
```

> **Note on the scheme name:** The Xcode scheme is still called `WeskTool` because the scheme
> name mirrors the Xcode target name, which we keep stable (so `SWIFT_OBJC_BRIDGING_HEADER`
> paths, Xcode target uuids, and `TEST_HOST` references remain internally consistent). Only
> the **displayed product name** (`PRODUCT_NAME` / `CFBundleDisplayName`) and the **project
> file name** (`GestaltKitTool.xcodeproj`) were renamed.

IPA files, certificates, provisioning profiles, development team identifiers, and local Xcode user data are intentionally excluded from the repository.

## Usage

1. Install and open GestaltKitTool, then wait for it to read MobileGestalt.
2. Use the **MobileGestalt** tab for capability presets, advanced field editing, and backup management.
3. Use the **Explorer** tab to browse any app's sandbox or arbitrary device paths.
4. Use the **Inspector** tab to inspect sensitive system files.
5. Use the **Settings** tab to switch language or run diagnostics.
6. After a successful write or restore, GestaltKitTool automatically refreshes SpringBoard so the changes take effect.

## Credits

- [Nugget](https://github.com/leminlimez/Nugget) — MobileGestalt presets and the iPadOS `CacheData` approach
- [FilzaSlop](https://github.com/0xjohnnydev/FilzaSlop) — ContainerManager file-access research
- [bad_query](https://github.com/forcequitOS/bad_query) — path-based ContainerManager sandbox escape
- [0xJohnny](https://x.com/0xjohnny) — MobileHouseArrest / ContainerManager proof of concept
- [neospring](https://github.com/rooootdev/neospring) — WebKit respring implementation
- [GestaltEdit](https://github.com/frs0n/GestaltEdit) — The MobileGestalt tab is built on this project
- [FilzaJailedDS](https://github.com/34306/FilzaJailedDS) — Sandbox-escape verification and write-hardening patterns

GestaltKitTool is an independent implementation and is not affiliated with Apple or any of the projects listed above.

## License

[MIT License](./LICENSE)
