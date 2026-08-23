# GestaltKitTool

English | [简体中文](./README_zh-CN.md)

> Project renamed from **WeskTool** to **GestaltKitTool** as of this revision. Bundle identifier `com.wesk.vtool` is preserved so existing installations upgrade in place, retaining the local Backup/Patch library and written MobileGestalt state.

GestaltKitTool is a SwiftUI MobileGestalt utility for iPhone. It reads `com.apple.MobileGestalt.plist` and provides capability presets, field editing, backup/import/restore, cross-app sandbox file browsing, and system file inspection. All file access outside the app sandbox uses the `bad_query` sandbox escape.

> **WARNING**: This project uses private APIs and modifies system cache data. Incorrect MobileGestalt values can break system features or UI and may require a device restore. Use only on devices you own or are authorized to manage.

> **NOTE**: GestaltKitTool does not install a jailbreak, Bootstrap, or persistent daemons, and does not inject code into third-party apps. It is not detected as a jailbreak.

## Features

### MobileGestalt tab

- Dynamic Island device subtypes and the alternate support flag
- Device model name shown in About
- Boot/shutdown chime, charge limit, tap to wake, Camera Control
- Apple Pencil, Action Button, Collision SOS settings
- Always-On Display, AOD vibrancy, wallpaper parallax, Liquid Glass low-performance mode
- Stage Manager, iPad app compatibility, Nugget's iPadOS `CacheData` patch
- Siri AI US region, Apple internal install, internal storage, Security Research Device mode
- Field editor: search and edit String, Integer, Float, Boolean, Data, Array, and Dictionary values in `CacheExtra` and at the plist top level
- Backup library: back up, import, export, restore, and delete local backups with pre-write verification
- One-tap app backup: back up any app's entire data container to GestaltKitTool's private container

Presets follow Nugget's staged-apply model. Toggles represent changes for the next write, and all selected changes are committed via the Apply button at the bottom. Selections are cleared after a successful write. Options writing conflicting values are mutually exclusive. After a successful write or restore, SpringBoard is automatically refreshed.

### Explorer tab

- Browse all app data containers, app group containers, and system group containers
- `bad_query` bypasses the sandbox to list and read files from any app's private data container
- Navigate via breadcrumb trail, bookmark favorite paths, enter custom absolute paths
- File preview with type detection: property list (tree view), JSON (pretty-printed), text, image (PNG/JPEG/HEIC), hex dump, binary
- Recursive directory search with incremental results and cancellation
- Batch file operations: multi-select delete, move, export

### Inspector tab

- Reads sensitive system files to demonstrate the scope of the `bad_query` sandbox escape
- 10 target files across 6 categories: Identity & Gestalt, System Containers, App Sandboxes, Bundle Containers, Network Configuration, System Information
- Property list tree browser with key-value inspection
- Export read results for further analysis

### Settings tab

- Language switching: English / Simplified Chinese (follows system by default)
- Diagnostics panel with 6 tests: bad_query availability, sandbox lease, container discovery, file read, directory listing, MobileGestalt write probe
- Safe Cleanup: scan and clear app cache/tmp directories to free disk space
- First-launch onboarding with 3 steps

## Requirements and signing

- Supported systems: iOS 26.0–26.6.1, iOS 27 beta 1 through beta 4
- Xcode and a signing method that can install apps on the target device
- Developer Mode enabled on the device
- Bundle identifier: `com.wesk.vtool`

GestaltKitTool checks the running system version before accessing MobileGestalt. iOS 26 support is based on the bad_query author's declaration and has not been tested on every 26.x release. iOS 27 beta retains an exact build whitelist (24A5355q, 24A5370h, 24A5380h, 24A5390f) to prevent untested builds from running. If Apple patches bad_query in the future, the supported range will be adjusted accordingly.

Apple may change these private behaviors at any time.

## Building

Open `GestaltKitTool.xcodeproj` in Xcode, select your development team for the target, and build. Command line:

```sh
xcodebuild \
  -project GestaltKitTool.xcodeproj \
  -scheme GestaltKitTool \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  DEVELOPMENT_TEAM=YOUR_TEAM_ID \
  build
```

Validate source without signing:

```sh
xcodebuild \
  -project GestaltKitTool.xcodeproj \
  -scheme GestaltKitTool \
  -sdk iphoneos \
  -destination 'generic/platform=iOS' \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  build
```

> **Renaming note**: Xcode scheme, target name, bridging header, and `TEST_HOST` have all been renamed to `GestaltKitTool`. Only the bundle identifier (`com.wesk.vtool`) and one source file (`WeskToolEnhancements.swift`) keep the former project name — the former preserves in-place upgrades for existing installations, the latter is a historical filename with no build impact.

IPA files, certificates, provisioning profiles, development team identifiers, and local Xcode user data are excluded from the repository.

## Usage

1. Install and open GestaltKitTool; wait for it to read MobileGestalt.
2. Use the **MobileGestalt** tab for presets, field editing, and backup management.
3. Use the **Explorer** tab to browse app sandboxes or arbitrary device paths.
4. Use the **Inspector** tab to inspect sensitive system files.
5. Use the **Settings** tab to switch language or run diagnostics.
6. After a successful write or restore, SpringBoard is automatically refreshed.

## Credits

- [Nugget](https://github.com/leminlimez/Nugget) — MobileGestalt presets and iPadOS `CacheData` approach (借鉴)
- [FilzaSlop](https://github.com/0xjohnnydev/FilzaSlop) — ContainerManager file-access research (借鉴)
- [bad_query](https://github.com/forcequitOS/bad_query) — Path-based ContainerManager sandbox escape (依赖)
- [0xJohnny](https://x.com/0xjohnny) — MobileHouseArrest / ContainerManager proof of concept (借鉴)
- [neospring](https://github.com/rooootdev/neospring) — WebKit respring implementation (基于开发)
- [GestaltEdit](https://github.com/frs0n/GestaltEdit) — MobileGestalt tab built on this project (基于开发)
- [FilzaJailedDS](https://github.com/34306/FilzaJailedDS) — Sandbox-escape verification and write-hardening patterns (借鉴)

GestaltKitTool is an independent implementation and is not affiliated with Apple or any listed project.

## License

[MIT License](./LICENSE)
