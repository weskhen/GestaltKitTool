//
//  DiagnosticsView.swift
//  GestaltKitTool
//
//  Diagnostics panel — tests bad_query availability, sandbox lease
//  acquisition, container discovery, and file read operations.
//

import Combine
import SwiftUI

struct DiagnosticsView: View {
    @StateObject private var model = DiagnosticsModel()

    var body: some View {
        List {
            Section {
                Button {
                    model.runAll()
                } label: {
                    HStack {
                        Image(systemName: "stethoscope")
                        Text("Run All Diagnostics")
                    }
                }
                .disabled(model.isRunning)

                Button {
                    model.runFlagProbe()
                } label: {
                    HStack {
                        Image(systemName: "flask")
                        Text(String(localized: "Probe Flags (Find RW)"))
                    }
                }
                .disabled(model.isRunning)

                Button {
                    model.runCarrierProbe()
                } label: {
                    HStack {
                        Image(systemName: "antenna.radiowaves.left.and.right")
                        Text(String(localized: "Probe Carrier Bundles (IPCC)"))
                    }
                }
                .disabled(model.isRunning)
            } footer: {
                Text(String(localized: "Run All tests bad_query / worse_query availability, sandbox lease, container discovery, and file read operations. Probe Flags enumerates flag combinations to find one that grants read-write access (diagnostic only, results in Console.app filter [GKTL-ObjC])."))
            }

            Section("Results") {
                ForEach(model.results) { result in
                    DiagnosticResultRow(result: result)
                }
                if !model.results.isEmpty {
                    Button {
                        let text = model.results.map { result in
                            "[\(result.status.label)] \(result.name)\n\(result.detail ?? "")"
                        }.joined(separator: "\n\n")
                        UIPasteboard.general.string = text
                    } label: {
                        Label(String(localized: "Copy Results"), systemImage: "doc.on.doc")
                    }
                    Button {
                        model.saveReport()
                    } label: {
                        Label(String(localized: "Save Report"), systemImage: "square.and.arrow.down")
                    }
                }
            }

            if !model.log.isEmpty {
                Section("Log") {
                    Text(model.log)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }

        }
        .navigationTitle("Diagnostics")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            // Auto-run the carrier probe 5s after the view appears so the
            // whole pipeline can be validated without manual interaction.
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            if !model.isRunning && !model.hasAutoRun {
                model.hasAutoRun = true
                model.runCarrierProbe()
            }
        }
    }
}

// MARK: - Diagnostic Result Row

/// Shared deep-probe used by the carrier/IPCC diagnostics: recursive
/// no-fallback listing with syslog dump of entries and plists.
/// Replaces the former probeGroup / probeFull / probeTree near-duplicates.
private func probeDeep(
    _ fileAccess: BadQueryFileAccess,
    _ dirPath: String,
    _ depth: Int,
    maxDepth: Int = 4,
    maxEntries: Int = 40,
    label: String,
    plistFilter: ((String) -> Bool)? = nil,
    plistDump: ((String, [String: Any], Int) -> Void)? = nil
) {
    if depth > maxDepth { return }
    var err: NSError?
    let entries = fileAccess.listDirectoryNoFallback(atPath: dirPath, error: &err)
    for entry in entries.prefix(maxEntries) {
        gktlLog("[GKTL-ObjC] \(label) d\(depth) \((dirPath as NSString).lastPathComponent)/\(entry.name): \(entry.isDirectory ? "dir" : "file") size=\(entry.fileSize)")
        if entry.isDirectory {
            probeDeep(fileAccess, entry.fullPath as String, depth + 1,
                      maxDepth: maxDepth, maxEntries: maxEntries,
                      label: label, plistFilter: plistFilter, plistDump: plistDump)
        } else if entry.name.hasSuffix(".plist"),
                  plistFilter?(entry.name) ?? true {
            if let data = try? fileAccess.readFile(atPath: entry.fullPath as String),
               let plist = (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)) as? [String: Any] {
                plistDump?(entry.name, plist, data.count)
            } else {
                gktlLog("[GKTL-ObjC] \(label)-PLIST \(entry.name): unreadable or not-a-dict")
            }
        }
    }
}

private struct DiagnosticResultRow: View {
    let result: DiagnosticResult

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: result.status.icon)
                .foregroundStyle(result.status.color)
                .font(.body)

            VStack(alignment: .leading, spacing: 3) {
                Text(result.name)
                    .font(.body)
                    .foregroundStyle(.primary)

                if let detail = result.detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer()

            Text(result.status.label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(result.status.color)
        }
    }
}

// MARK: - Diagnostics Model

@MainActor
final class DiagnosticsModel: ObservableObject {
    @Published var results: [DiagnosticResult] = []
    @Published var isRunning = false
    /// Guard so the auto-run (5s after appear) only fires once per session.
    @Published var hasAutoRun = false
    @Published var log = ""

    private let fileAccess = BadQueryFileAccess.shared()

    func runFlagProbe() {
        guard !isRunning else { return }
        isRunning = true
        results = []
        log = ""

        let gestaltPath = "/var/containers/Shared/SystemGroup/systemgroup.com.apple.mobilegestaltcache/Library/Caches/com.apple.MobileGestalt.plist"

        Task.detached(priority: .userInitiated) {
            BadQueryProbeFlags(gestaltPath)

            await MainActor.run {
                self.log = String(localized: "Flag probe complete. Check Console.app (filter [GKTL-ObjC]) for results.\nLook for lines with canWrite=1 — that flag value grants read-write access.")
                self.isRunning = false
            }
        }
    }

    /// Read-only probe of the carrier-bundle overlay storage.
    ///
    /// Discovers the actual overlay directory layout on this iOS build,
    /// reads the current carrier version plist, and tests whether the
    /// sandbox lease grants write access there. Nothing is modified.
    func runCarrierProbe() {
        guard !isRunning else { return }
        isRunning = true
        results = []
        log = ""

        let fileAccess = self.fileAccess

        Task.detached(priority: .userInitiated) { [weak self] in
            var collected: [DiagnosticResult] = []

            // Candidate overlay roots across iOS 26/27 layouts.
            var candidates = [
                // Modern iOS (26/27): carrier bundles are delivered as
                // MobileAssets. The downloaded asset lives here and IS
                // reachable via the sandbox escape. Version-anchoring the
                // asset's metadata.plist "locks" the IPCC against OTA updates.
                "/var/MobileAsset/AssetsV2/com_apple_MobileAsset_CarrierBundles",
                "/var/mobile/Library/Carrier Bundles/Overlay",
                "/var/mobile/Library/Carrier Bundles/overlay",
                "/var/mobile/Library/Carrier Bundles",
                "/var/wireless/Library/Carrier Bundles/Overlay",
                "/var/wireless/Library/Carrier Bundles"
            ]

            // Discover carrier-related system groups — CommCenter state on
            // modern iOS lives under /var/containers/Shared/SystemGroup/.
            do {
                // The fsgetpath fallback returns /var-wide false positives,
                // so instead probe KNOWN candidate group names via lstat
                // (pre-check works: uid=501 responses confirmed on device).
                let candidateGroupNames = [
                    "systemgroup.com.apple.mobilegestaltcache", // known-good reference
                    "systemgroup.com.apple.CommCenter",
                    "systemgroup.com.apple.commcenter",
                    "systemgroup.com.apple.carrierd",
                    "systemgroup.com.apple.CarrierBundle",
                    "systemgroup.com.apple.carrierbundles",
                    "systemgroup.com.apple.coretelephony",
                    "systemgroup.com.apple.CoreTelephony",
                    "systemgroup.com.apple.cellular",
                    "systemgroup.com.apple.modem",
                    "systemgroup.com.apple.wireless",
                    "systemgroup.com.apple.mobileasset",
                    "systemgroup.com.apple.MobileAsset",
                    "systemgroup.com.apple.apticket", // APTickets live near activation
                    "systemgroup.com.apple.diskmanagement"
                ]
                for g in candidateGroupNames {
                    let groupRoot = "/var/containers/Shared/SystemGroup/\(g)"
                    let fm = FileManager.default
                    var isDir: ObjCBool = false
                    if fm.fileExists(atPath: groupRoot, isDirectory: &isDir) {
                        gktlLog("[GKTL-ObjC] SYSGROUP-EXISTS: \(g) isDir=\(isDir.boolValue)")
                    } else {
                        gktlLog("[GKTL-ObjC] SYSGROUP-ABSENT: \(g)")
                    }
                }
                // Existence check via fileExists == lstat; do NOT trust the
                // fsgetpath fallback for this directory (false positives).
                let groups: [String] = []
                let carrierGroups = groups.filter { name in
                    let n = name.lowercased()
                    return n.contains("carrier") || n.contains("commcenter") || n.contains("wireless") || n.contains("cellular") || n.contains("telephony") || n.contains("modem")
                }
                if !carrierGroups.isEmpty {
                    for group in carrierGroups {
                        let groupRoot = "/var/containers/Shared/SystemGroup/\(group)"
                        // Deep-probe: recursive listing + plist dumps, so the
                        // actual carrier state files surface in syslog.
                        probeDeep(fileAccess, groupRoot, 0, label: "CG") { name, plist, byteCount in
                            let dump = plist.map { "\($0.key)=\(String(describing: $0.value).prefix(60))" }.sorted().joined(separator: "; ")
                            gktlLog("[GKTL-ObjC] CG-PLIST \(name) [\(byteCount)B]: \(dump)")
                        }
                        // List the group's contents to discover its layout.
                        var groupErr: NSError?
                        let groupEntries = fileAccess.listDirectoryNoFallback(atPath: groupRoot, error: &groupErr)
                        if !groupEntries.isEmpty {
                            collected.append(DiagnosticResult(
                                name: "Group Layout: \(group)",
                                status: .pass,
                                detail: groupEntries.map { $0.isDirectory ? $0.name + "/" : $0.name }.joined(separator: "\n")
                            ))
                        }
                        let libRoot = groupRoot + "/Library"
                        candidates.insert(libRoot + "/Carrier Bundles", at: 0)
                        candidates.insert(libRoot + "/Carrier Bundles/Overlay", at: 0)
                        // Also probe any CacheDirectory-style subpaths found.
                        for entry in groupEntries where entry.isDirectory {
                            candidates.insert("\(groupRoot)/\(entry.name)/Carrier Bundles", at: 0)
                        }
                    }
                }
            } catch {
                // SystemGroup listing failed — static candidates still apply.
            }

            // Discover CommCenter system containers (iOS 26/27 data layout).
            // Only direct UUID-named children are accepted — the .data
            // symlinks inside resolve to unrelated /private/var paths and
            // would pollute the candidate list.
            do {
                let systemContainers = fileAccess.listDirectoryNoFallback(atPath: "/var/containers/Data/System", error: nil)
                gktlLog("[GKTL-ObjC] Data/System listing count=\(systemContainers.count)")
                for c in systemContainers.prefix(40) {
                    gktlLog("[GKTL-ObjC] DataSystem entry: \(c.isDirectory ? "dir" : "file") \(c.name)")
                }
                for container in systemContainers where container.isDirectory {
                    // Read the container's metadata plist to identify its
                    // owner bundle ID — CommCenter / carrier containers are
                    // the IPCC targets.
                    var ownerID = "unknown"
                    if let data = try? fileAccess.readFile(
                        atPath: (container.fullPath as NSString).appendingPathComponent(
                            ContainerMetadata.metadataFilename)) {
                        if let bid = ContainerMetadata.bundleId(from: data) {
                            ownerID = bid
                        } else {
                            // Dump raw for diagnosis — maybe key differs or plist malformed.
                            let preview = String(data: data.prefix(200), encoding: .utf8) ?? data.prefix(40).map { String(format: "%02x", $0) }.joined()
                            ownerID = "raw[\(data.count)B]: \(preview)"
                        }
                    }
                    gktlLog("[GKTL-ObjC] SysContainer \(container.name) owner=\(ownerID)")
                    // Deep-probe the ENTIRE container for cellular owners —
                    // coretelephony / CommCenter hold the carrier (IPCC) data.
                    let o = ownerID.lowercased()
                    if o.contains("coretelephony") || o.contains("commcenter") || o.contains("carrier") {
                        probeDeep(fileAccess, container.fullPath as String, 0, label: "CT") { name, plist, byteCount in
                            let dump = plist.map { "\($0.key)=\(String(describing: $0.value).prefix(60))" }.sorted().joined(separator: "; ")
                            gktlLog("[GKTL-ObjC] CT-PLIST \(name) [\(byteCount)B]: \(dump)")
                        }
                    }
                    // Descend into Library for CommCenter / carrier markers.
                    let libPath = (container.fullPath as NSString).appendingPathComponent("Library")
                    var libErr: NSError?
                    let libEntries = fileAccess.listDirectoryNoFallback(atPath: libPath as String, error: &libErr)
                    for le in libEntries.prefix(15) {
                        gktlLog("[GKTL-ObjC] SysContainer \(container.name) Library: \(le.isDirectory ? "dir" : "file") \(le.name)")
                        // Any CommCenter-ish child is the carrier data home.
                        let n = le.name.lowercased()
                        let isCarrierHome = ownerID.lowercased().contains("unknown") && (n.contains("activation") || n.contains("dcrt") || n.contains("internal") || n.contains("splunk") || n == "preferences" || n.contains("caches"))
                        if n.contains("commcenter") || n.contains("carrier") || n.contains("wireless") || n.contains("cellular") || n.contains("activation") || n.contains("dcrt") || n.contains("internal") || (isCarrierHome) {
                            gktlLog("[GKTL-ObjC] *** CARRIER MARKER in \(container.name): \(le.name) — deep-listing")
                            // Recurse up to 3 levels, read any plist found.
                            probeDeep(fileAccess, le.fullPath as String, 1,
                                      maxDepth: 3, maxEntries: 25, label: "TREE") { name, plist, byteCount in
                                // For data_ark / activation records, dump ALL keys
                                // with values (truncated) — these hold carrier state.
                                let isKeyFile = name.contains("data_ark") || name.contains("activation_record")
                                if isKeyFile {
                                    let dump = plist.map { "\($0.key)=\(String(describing: $0.value).prefix(80))" }.sorted().joined(separator: "; ")
                                    gktlLog("[GKTL-ObjC] PLIST-DUMP \(name) [\(byteCount)B]: \(dump)")
                                } else {
                                    let carrierKeys = plist.keys.filter {
                                        let k = $0.lowercased()
                                        return k.contains("carrier") || k.contains("activation") || k.contains("sim") || k.contains("baseband") || k.contains("region") || k.contains("boot") || k.contains("regulatory")
                                    }
                                    gktlLog("[GKTL-ObjC] PLIST-READ \(name) [\(byteCount)B]: \(carrierKeys.sorted().joined(separator: ", "))")
                                }
                            }
                        }
                    }
                    if ownerID.lowercased().contains("commcenter") || ownerID.lowercased().contains("carrier") {
                        let libRoot = (container.fullPath as NSString).appendingPathComponent("Library")
                        candidates.insert(
                            (libRoot as NSString).appendingPathComponent("Carrier Bundles"),
                            at: 0
                        )
                        // Also probe CommCenter data layout.
                        for sub in ["CommCenter", "Carrier Bundles", "Preferences", "Caches"] {
                            candidates.insert(
                                (libRoot as NSString).appendingPathComponent(sub),
                                at: 0
                            )
                        }
                    }
                }
            } catch {
                // Not listable — static candidates below still apply.
            }

            var overlayRoot: NSString?
            for root in candidates {
                var listError: NSError?
                let entries = fileAccess.listDirectoryNoFallback(atPath: root, error: &listError)
                if listError == nil {
                    overlayRoot = root as NSString
                    collected.append(DiagnosticResult(
                        name: "Overlay Root Found",
                        status: .pass,
                        detail: root + (entries.isEmpty ? " (empty)" : "")
                    ))
                    break
                }
            }
            if overlayRoot == nil {
                collected.append(DiagnosticResult(
                    name: "Overlay Root",
                    status: .fail,
                    detail: "No candidate carrier-bundle overlay directory exists on this build. Candidates probed:\n" + candidates.joined(separator: "\n")
                ))
            }

            // Enumerate MobileAsset asset-type directories first — the
            // CarrierBundles asset only appears after a carrier settings
            // update is downloaded; other asset types reveal real layout.
            var maError: NSError?
            let maEntries = fileAccess.listDirectoryNoFallback(atPath: "/var/MobileAsset/AssetsV2", error: &maError)
            for e in maEntries {
                // Mirror every discovered asset type to syslog so the
                // operator can read results without the device screen.
                	gktlLog("[GKTL-ObjC] MobileAsset asset entry: \(e.isDirectory ? "dir" : "file") \(e.name)")
            }
            if !maEntries.isEmpty {
                let names = maEntries.map { $0.isDirectory ? $0.name + "/" : $0.name }.sorted().joined(separator: "\n")
                collected.append(DiagnosticResult(
                    name: "MobileAsset AssetsV2",
                    status: .pass,
                    detail: names
                ))
                // Clean per-path lstat probes. listDirectory results are
                // cache-polluted (dedupe by name across different parents),
                // but statFileAtPath gives per-path truth.
                // What IS /var/wireless? Readlink to check symlink status.
                var rlErr: NSError?
                if let linkData = try? fileAccess.readFile(atPath: "/var/wireless"),
                   linkData.count < 4096,
                   let link = String(data: linkData, encoding: .utf8) {
                    gktlLog("[GKTL-ObjC] READLINK /var/wireless -> \(link)")
                } else {
                    gktlLog("[GKTL-ObjC] READLINK /var/wireless failed err=\(rlErr?.localizedDescription ?? "readFile nil")")
                }
                // ——— worse_query reachability evaluation for real (existing) targets ———
                // Run WorseQueryAcquire directly (bypassing bad_query) to
                // measure whether the vulnerability can obtain a sandbox
                // extension for each candidate. Only meaningful for paths
                // that actually exist (lstat hit).
                var wqEvalTargets: [String] = [
                    // Known-good reference: the MobileGestalt cache plist that
                    // worse_query successfully leased on iPhone 16 earlier
                    // today (uid=501 file). If this also fails here, the
                    // difference is device/OS, not path.
                    "/private/var/containers/Shared/SystemGroup/systemgroup.com.apple.mobilegestaltcache/Library/Caches/com.apple.MobileGestalt.plist",
                    "/private/var/MobileAsset/PreinstalledAssetsV2/InstallWithOs/com_apple_MobileAsset_CoreAS/1d2111630fc9db4987eac0118a22245c6b478a00.asset/AssetSource.plist",
                    "/private/var/MobileAsset/AssetsV2",
                    "/private/var/wireless",
                    "/private/var/wireless/Library/Preferences",
                    "/private/var/containers/Data/System",
                    // CommCenter carrier state files — traditional location.
                    "/private/var/wireless/Library/Preferences/com.apple.commcenter.plist",
                    "/private/var/wireless/Library/Preferences/com.apple.commcenter.data.plist",
                    "/private/var/wireless/Library/Preferences/com.apple.commcenter.plists",
                    // Live-list /var/wireless/Library/Preferences via the Caches
                    // trick on the Data/System coretelephony container (symlink).
                    "/private/var/containers/Data/System/F388D181-9B75-4559-B4B1-18251A40DCC9/Library/Caches"
                ]
                // Probe known CommCenter/carrier plist FILENAMES inside
                // /var/wireless/Library/Preferences — opendir is MAC-blocked
                // but single-file lstat may pass (like MobileGestalt cache).
                let prefDir = "/private/var/wireless/Library/Preferences"
                let knownPrefFiles = [
                    "com.apple.commcenter.plist",
                    "com.apple.commcenter.data.plist",
                    "com.apple.commcenter.plists",
                    "com.apple.commcenter.regions.plist",
                    "com.apple.commcenter.summary.plist",
                    "com.apple.commcenter.status.plist",
                    "com.apple.carrierbundle.defaults.plist",
                    "com.apple.cellular_plist.plist",
                    "com.apple.operator.plist",
                    "com.apple.AppleCellularCore.plist"
                ]
                gktlLog("[GKTL-ObjC] === WIRELESS-PREFS FILE PROBE (lstat) ===")
                var hitPrefFiles: [String] = []
                for f in knownPrefFiles {
                    let p = prefDir + "/" + f
                    var st = stat()
                    if lstat(p, &st) == 0 {
                        gktlLog("[GKTL-ObjC] WPREF-HIT \(p) size=\(st.st_size) mode=\(st.st_mode)")
                        hitPrefFiles.append(p)
                    } else {
                        gktlLog("[GKTL-ObjC] WPREF-MISS \(p) errno=\(errno)")
                    }
                }
                // Read any that HIT.
                for p in hitPrefFiles {
                    if let data = try? fileAccess.readFile(atPath: p),
                       let plist = (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)) as? [String: Any] {
                        let dump = plist.map { "\($0.key)=\(String(describing: $0.value).prefix(60))" }.sorted().joined(separator: "; ")
                        gktlLog("[GKTL-ObjC] WPREF-PLIST \(p) [\(data.count)B]: \(dump)")
                    } else {
                        gktlLog("[GKTL-ObjC] WPREF-READFAIL \(p)")
                    }
                }
                gktlLog("[GKTL-ObjC] === WIRELESS-PREFS FILE PROBE END ===")
                // CFPreferences XPC probe — reads via cfprefsd (no file MAC).
                gktlLog("[GKTL-ObjC] === CFPREFS PROBE START ===")
                for domain in ["com.apple.commcenter", "com.apple.commcenter.data"] {
                    if let keys = CFPreferencesCopyKeyList(domain as CFString, kCFPreferencesAnyUser, kCFPreferencesCurrentHost) as? [String] {
                        gktlLog("[GKTL-ObjC] CFPREFS-KEYS \(domain): \(keys.sorted().joined(separator: ", "))")
                        for k in keys.prefix(30) {
                            if let v = CFPreferencesCopyValue(k as CFString, domain as CFString, kCFPreferencesAnyUser, kCFPreferencesCurrentHost) {
                                gktlLog("[GKTL-ObjC] CFPREFS-VAL \(domain)/\(k) = \(String(describing: v).prefix(80))")
                            }
                        }
                    } else {
                        gktlLog("[GKTL-ObjC] CFPREFS-NIL keylist \(domain)")
                    }
                }
                gktlLog("[GKTL-ObjC] === CFPREFS PROBE END ===")
                // Append the discovered AssetsV2 subdirectory full path.
                wqEvalTargets.append("/private/var/MobileAsset/AssetsV2/wireless")
                gktlLog("[GKTL-ObjC] === worse_query EVAL START (altFlags=NO standard) ===")
                for target in wqEvalTargets {
                    let handle = WorseQueryAcquire(target, false)
                    if handle > 0 {
                        gktlLog("[GKTL-ObjC] WQ-EVAL HIT handle=\(handle) target=\(target)")
                        WorseQueryRelease(handle)
                    } else {
                        gktlLog("[GKTL-ObjC] WQ-EVAL MISS code=\(handle) target=\(target)")
                        // Retry with altFlags (iOS 26-style).
                        let altHandle = WorseQueryAcquire(target, true)
                        if altHandle > 0 {
                            gktlLog("[GKTL-ObjC] WQ-EVAL ALT-HIT handle=\(altHandle) target=\(target)")
                            WorseQueryRelease(altHandle)
                        } else {
                            gktlLog("[GKTL-ObjC] WQ-EVAL ALT-MISS code=\(altHandle) target=\(target)")
                        }
                    }
                }
                gktlLog("[GKTL-ObjC] === worse_query EVAL END ===")
                // List /var/wireless/Library/Preferences via listDirectory and
                // log names — carrier plists (com.apple.CarrierSettings.*)
                // would appear here if present.
                var lpErr: NSError?
                let lpEntries = fileAccess.listDirectoryNoFallback(atPath: "/var/wireless/Library/Preferences", error: &lpErr)
                gktlLog("[GKTL-ObjC] PREFERENCES listing count=\(lpEntries.count) err=\(lpErr?.localizedDescription ?? "none")")
                for p in lpEntries.prefix(50) {
                    gktlLog("[GKTL-ObjC] PREF entry: \(p.isDirectory ? "dir" : "file") \(p.name) size=\(p.fileSize) fullPath=\(p.fullPath)")
                }
                // Probe .asset payload directories found by the scan.
                for p in lpEntries where p.isDirectory && p.name.hasSuffix(".asset") {
                    for plistName in ["metadata.plist", "version.plist", "AssetSource.plist"] {
                        let plistPath = ((p.fullPath as NSString) as NSString).appendingPathComponent(plistName)
                        if let data = try? fileAccess.readFile(atPath: plistPath),
                           let plist = (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)) as? [String: Any] {
                            let summary = plist.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: "\n")
                            gktlLog("[GKTL-ObjC] ASSET \(p.name)/\(plistName):\n\(summary)")
                        } else {
                            // try direct child path too
                            let altPath = (p.fullPath as NSString).appendingPathComponent("AssetData/\(plistName)")
                            if let data = try? fileAccess.readFile(atPath: altPath),
                               let plist = (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)) as? [String: Any] {
                                let summary = plist.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: "\n")
                                gktlLog("[GKTL-ObjC] ASSET \(p.name)/AssetData/\(plistName):\n\(summary)")
                            }
                        }
                    }
                    // List AssetData contents
                    let assetDataPath = (p.fullPath as NSString).appendingPathComponent("AssetData")
                    var adErr: NSError?
                    let adEntries = fileAccess.listDirectoryNoFallback(atPath: assetDataPath as String, error: &adErr)
                    for a in adEntries.prefix(15) {
                        gktlLog("[GKTL-ObjC] ASSETDATA \(p.name): \(a.isDirectory ? "dir" : "file") \(a.name) size=\(a.fileSize)")
                    }
                }
                for probePath in [
                    "/var/wireless/Library/Carrier Bundles",
                    "/var/wireless/Library/Carrier Bundles/Overlay",
                    "/var/wireless/Library/Carrier Bundles/Overlay/Primary",
                    "/var/wireless/Library/Preferences",
                    "/var/wireless/Library/CarrierSettings",
                    "/var/wireless/Library/CarrierSettings/Attachments",
                    "/var/wireless/Library/CommCenter",
                    "/var/wireless/Library/CommCenter/carrier.plist",
                    "/var/wireless/Library/CommCenter/Primary",
                    "/var/wireless/Library/CommCenter/Primary/carrier.plist"
                ] {
                    var pErr: NSError?
                    if let st = try? fileAccess.statFile(atPath: probePath) {
                        gktlLog("[GKTL-ObjC] LSTAT HIT \(probePath) size=\(st.fileSize) isDir=\(st.isDirectory ? 1 : 0)")
                    } else {
                        gktlLog("[GKTL-ObjC] LSTAT MISS \(probePath) err=\(pErr?.localizedDescription ?? "nil")")
                    }
                }
                // Deep-probe wireless dir — carrier bundles home on iOS 26/27.
                if let wirelessDir = maEntries.first(where: { $0.name == "wireless" && $0.isDirectory }) {
                    var wErr: NSError?
                    let wEntries = fileAccess.listDirectoryNoFallback(atPath: wirelessDir.fullPath as String, error: &wErr)
                    for w in wEntries {
                        gktlLog("[GKTL-ObjC] wireless entry: \(w.isDirectory ? "dir" : "file") \(w.name)")
                    }
                    for w in wEntries where w.isDirectory {
                        var cErr: NSError?
                        let cEntries = fileAccess.listDirectoryNoFallback(atPath: w.fullPath as String, error: &cErr)
                        for c in cEntries.prefix(20) {
                            gktlLog("[GKTL-ObjC] wireless/\(w.name) entry: \(c.isDirectory ? "dir" : "file") \(c.name)")
                        }
                        // Go one level deeper for Carrier Bundles payloads.
                        if w.name.lowercased().contains("carrier") {
                            for c in cEntries where c.isDirectory {
                                var pErr: NSError?
                                let pEntries = fileAccess.listDirectoryNoFallback(atPath: c.fullPath as String, error: &pErr)
                                for p in pEntries.prefix(20) {
                                    gktlLog("[GKTL-ObjC] \(w.name)/\(c.name) entry: \(p.isDirectory ? "dir" : "file") \(p.name)")
                                }
                                for plistName in ["metadata.plist", "version.plist"] {
                                    let plistPath = ((c.fullPath as NSString) as NSString).appendingPathComponent(plistName)
                                    if let data = try? fileAccess.readFile(atPath: plistPath),
                                       let plist = (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)) as? [String: Any] {
                                        let summary = plist.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: " ")
                                        gktlLog("[GKTL-ObjC] CarrierAsset \(c.name)/\(plistName): \(summary)")
                                    }
                                }
                            }
                        }
                    }
                }
                // Deep-probe any carrier-related asset type.
                for entry in maEntries where entry.isDirectory && entry.name.lowercased().contains("carrier") {
                    var subError: NSError?
                    let assetEntries = fileAccess.listDirectoryNoFallback(atPath: entry.fullPath as String, error: &subError)
                    for asset in assetEntries where asset.isDirectory {
                        let dirPath = (asset.fullPath as NSString)
                        for plistName in ["metadata.plist", "version.plist"] {
                            let plistPath = dirPath.appendingPathComponent(plistName)
                            if let data = try? fileAccess.readFile(atPath: plistPath),
                               let plist = (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)) as? [String: Any] {
                                let interesting = plist.filter { key, _ in
                                        let k = key.lowercased()
                                        return k.contains("version") || k.contains("carrier")
                                    }
                                    	gktlLog("[GKTL-ObjC] CarrierAsset \(asset.name)/\(plistName): \(interesting.map { "\($0.key)=\($0.value)" }.joined(separator: " "))")
                                    collected.append(DiagnosticResult(
                                    name: "\(asset.name)/\(plistName)",
                                    status: .pass,
                                    detail: interesting.isEmpty
                                        ? plist.keys.sorted().prefix(15).joined(separator: ", ")
                                        : interesting.map { "\($0.key) = \($0.value)" }.joined(separator: "\n")
                                ))
                            }
                        }
                    }
                }
            }

            // Enumerate bundles under the discovered root.
            if let root = overlayRoot as String? {
                var listError: NSError?
                let entries = fileAccess.listDirectoryNoFallback(atPath: root, error: &listError)
                if entries.isEmpty && listError != nil {
                    collected.append(DiagnosticResult(
                        name: "Overlay Listing",
                        status: .fail,
                        detail: listError?.localizedDescription ?? "Overlay root is empty or listing was denied."
                    ))
                } else {
                    let names = entries.map { $0.isDirectory ? $0.name + "/" : $0.name }.joined(separator: "\n")
                    collected.append(DiagnosticResult(
                        name: "Overlay Contents",
                        status: .pass,
                        detail: names
                    ))

                    // MobileAsset payloads are directories named by content
                    // hash; each contains metadata.plist with the version.
                    // Descend to find payload dirs + plists.
                    var plistCandidates: [String] = []
                    for entry in entries where entry.isDirectory {
                        let dirPath = (entry.fullPath as NSString)
                        var subError: NSError?
                        let subEntries = fileAccess.listDirectoryNoFallback(atPath: dirPath as String, error: &subError)
                        for sub in subEntries {
                            if sub.isDirectory {
                                // Payload dir: look for metadata.plist / version.plist inside.
                                let payloadDir = (sub.fullPath as NSString)
                                for plistName in ["metadata.plist", "version.plist", "carrier.plist", "overrides.plist"] {
                                    plistCandidates.append(payloadDir.appendingPathComponent(plistName))
                                }
                            } else if sub.name.hasSuffix(".plist") {
                                plistCandidates.append(sub.fullPath as String)
                            }
                        }
                    }
                    // Legacy layout: .bundle directories with plists inside.
                    for entry in entries where entry.isDirectory && entry.name.hasSuffix(".bundle") {
                        let bundlePath = (entry.fullPath as NSString)
                        for plistName in ["version.plist", "carrier.plist", "overrides.plist"] {
                            plistCandidates.append(bundlePath.appendingPathComponent(plistName))
                        }
                    }

                    var readAnyVersion = false
                    for filePath in plistCandidates.prefix(8) {
                        if let data = try? fileAccess.readFile(atPath: filePath),
                           let plist = (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)) as? [String: Any] {
                            readAnyVersion = true
                            let interesting = plist.filter { key, _ in
                                let k = key.lowercased()
                                return k.contains("version") || k.contains("carrier") || k == "cfbundleversion"
                            }
                            let summary = interesting.isEmpty
                                ? plist.keys.sorted().prefix(12).joined(separator: ", ")
                                : interesting.map { "\($0.key) = \($0.value)" }.joined(separator: "\n")
                            collected.append(DiagnosticResult(
                                name: (filePath as NSString).lastPathComponent,
                                status: .pass,
                                detail: "\(filePath)\n\(summary)"
                            ))
                        }
                    }
                    if plistCandidates.isEmpty && readAnyVersion == false {
                        collected.append(DiagnosticResult(
                            name: "Payload Plists",
                            status: .warn,
                            detail: "No version/carrier plists found inside the overlay contents."
                        ))
                    }
                }
            }

            // Write-permission probe on a scratch file inside the overlay
            // root (created, then deleted — never touches carrier data).
            if let root = overlayRoot as String? {
                let probePath = (root as NSString).appendingPathComponent("gktl_write_probe.tmp")
                let probeData = Data("probe".utf8)
                var writeDetail: String?
                let wrote: Bool
                do {
                    try fileAccess.writeFile(atPath: probePath, data: probeData)
                    wrote = true
                    try? fileAccess.deleteFile(atPath: probePath)
                } catch let err as NSError {
                    wrote = false
                    writeDetail = err.localizedDescription
                }
                if wrote {
                    collected.append(DiagnosticResult(
                        name: "Overlay Write Access",
                        status: .pass,
                        detail: "Sandbox lease grants RW in the overlay — carrier plist modification is technically possible."
                    ))
                } else {
                    collected.append(DiagnosticResult(
                        name: "Overlay Write Access",
                        status: .fail,
                        detail: writeDetail ?? "Write denied — overlay is read-only under this lease."
                    ))
                }
            }

            // ---- Final verdict -------------------------------------------------
            // Auto-derive the overall conclusion from the collected results
            // so the user sees feasibility at a glance.
            let overlayFound = collected.contains { $0.name == "Overlay Root Found" }
            let writePass = collected.contains { $0.name == "Overlay Write Access" && $0.status == .pass }
            let readVersions = collected.filter { $0.name.hasPrefix("Read ") && $0.status == .pass }
            var verdict: DiagnosticResult
            if overlayFound && writePass {
                verdict = DiagnosticResult(
                    name: String(localized: "Conclusion: IPCC modification FEASIBLE"),
                    status: .pass,
                    detail: String(localized: "The carrier-bundle overlay exists and the sandbox lease grants read-write access. Version-anchored IPCC locking (e.g. writing a high version number into version.plist so OTA carrier payloads are refused) is technically possible on this device."))
            } else if overlayFound && !readVersions.isEmpty {
                verdict = DiagnosticResult(
                    name: String(localized: "Conclusion: IPCC READ-ONLY"),
                    status: .warn,
                    detail: String(localized: "The carrier-bundle overlay exists and plist files are readable, but writes are denied. You can inspect carrier configuration but cannot lock/modify it on this build."))
            } else if overlayFound {
                verdict = DiagnosticResult(
                    name: String(localized: "Conclusion: overlay exists, contents inaccessible"),
                    status: .warn,
                    detail: String(localized: "The overlay directory exists but its carrier plists could not be read. Modification is not possible without read access."))
            } else {
                verdict = DiagnosticResult(
                    name: String(localized: "Conclusion: IPCC modification NOT possible on this iOS build"),
                    status: .fail,
                    detail: String(localized: "No carrier-bundle overlay directory exists in any writable location. On this iOS version, carrier configuration has been moved out of user-writable storage (likely onto the sealed system volume), so the sandbox escape cannot reach it. IPCC locking via worse_query is only viable on iOS versions where /var/mobile/Library/Carrier Bundles/Overlay still exists (iOS 26.x and earlier)."))
            }
            collected.insert(verdict, at: 0)
            // ---------------------------------------------------------------------

            let summary = collected
            await MainActor.run { [weak self] in
                self?.results = summary
                self?.log = String(localized: "Carrier-bundle probe complete. Read-only — nothing on the device was modified (except a deleted scratch file).")
                self?.isRunning = false
            }
        }
    }

    /// Saves the current results as a timestamped text report in the
    /// app's Documents directory (visible in the Files app, shareable
    /// via the Explorer tab).
    func saveReport() {
        guard !results.isEmpty else { return }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let stamp = formatter.string(from: Date())
        let text = """
        GestaltKitTool Diagnostic Report
        ================================
        Date: \(ISO8601DateFormatter().string(from: Date()))
        Device: \(UIDevice.current.model) — iOS \(UIDevice.current.systemVersion)

        \(results.map { result in
            "[\(result.status.label)] \(result.name)\n\(result.detail ?? "")"
        }.joined(separator: "\n\n"))
        """
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("GKTL-Diagnostics-\(stamp).txt")
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            log = String(format: String(localized: "Report saved: %@"), url.lastPathComponent)
        } catch {
            log = String(format: String(localized: "Failed to save report: %@"), error.localizedDescription)
        }
    }

    func runAll() {
        guard !isRunning else { return }
        isRunning = true
        results = []
        log = ""

        NotificationCenter.default.post(
            name: .init("GKTCancelBackgroundExplorerTasks"),
            object: nil
        )

        let fileAccess = self.fileAccess

        // for cooperative cancellation and better backpressure.
        Task.detached(priority: .userInitiated) {
            // MARK: Test 1 — bad_query Availability
            let r1: DiagnosticResult = {
                let available = BadQueryBridgeAvailable()
                return DiagnosticResult(
                    name: "bad_query Availability",
                    status: available ? .pass : .fail,
                    detail: available
                        ? "bad_query bridge is loaded and available."
                        : "bad_query bridge is NOT available."
                )
            }()

            // MARK: Test 1b — worse_query Availability (fallback engine)
            //
            // worse_query (class 7 appGroup + Caches symlink escape) takes
            // over automatically when bad_query is patched/rejected. It has
            // two prerequisites: ContainerManager symbols (same as bad_query)
            // AND an accessible App Group container (entitlement-gated).
            let r1b: DiagnosticResult = {
                if !WorseQueryBridgeAvailable() {
                    return DiagnosticResult(
                        name: "worse_query Availability",
                        status: .fail,
                        detail: "worse_query bridge is NOT available (ContainerManager symbols missing — unsupported OS)."
                    )
                }
                if !WorseQueryGroupContainerAvailable() {
                    return DiagnosticResult(
                        name: "worse_query Availability",
                        status: .fail,
                        detail: String(localized: "worse_query App Group container NOT accessible — check the com.apple.security.application-groups entitlement.")
                    )
                }
                return DiagnosticResult(
                    name: "worse_query Availability",
                    status: .pass,
                    detail: String(localized: "worse_query App Group container accessible.")
                )
            }()

            // MARK: Shared lease acquisition
            //
            // All sandbox-granted tests (2, 4, 6) operate on the same
            // MobileGestalt plist file. Instead of acquiring 3 separate
            // ContainerManager leases (3 × 1-3 s XPC round-trips),
            // we acquire ONE lease and share it across all tests.
            // This cuts total diagnostic time by ~60% on devices where
            // ContainerManager XPC is slow (iOS 27 beta).
            let gestaltPath = "/var/containers/Shared/SystemGroup/systemgroup.com.apple.mobilegestaltcache/Library/Caches/com.apple.MobileGestalt.plist"
            let cacheDir = "/var/containers/Shared/SystemGroup/systemgroup.com.apple.mobilegestaltcache/Library/Caches"

            var leaseError: NSString?
            let sharedLease = BadQueryLease(forPath: gestaltPath, error: &leaseError)
            let leaseActive = sharedLease?.isActive ?? false
            defer { sharedLease?.invalidate() }

            // MARK: Test 2 — Sandbox Lease Acquisition (shared)
            let r2: DiagnosticResult = {
                if leaseActive {
                    return DiagnosticResult(
                        name: "Sandbox Lease Acquisition",
                        status: .pass,
                        detail: String(localized: "Lease acquired for file:\n\(gestaltPath)")
                    )
                } else {
                    let errMsg = leaseError as? String ?? String(localized: "unknown error")
                    // Enrich the error with iOS version-specific guidance.
                    let osVersion = ProcessInfo.processInfo.operatingSystemVersion
                    let build = GestaltAccess.currentOSBuild()
                    var enriched = String(localized: "Failed to acquire lease: \(errMsg)")
                    if osVersion.majorVersion == 26 && osVersion.minorVersion == 0 {
                        enriched += "\n\n" + String(localized: "[ iOS 26.0.x detected (build \(build)) ] bad_query's ContainerManager query was accepted but the kernel refused to issue a sandbox extension. This is a known symptom on early iOS 26.0 builds where the sandbox policy differs from iOS 27. Possible causes:\n  1. The MobileGestalt cache plist has not been generated yet — try respringing once, then rerun diagnostics.\n  2. The bad_query exploit parameters (class=13, part=3, flags=0x8000000000) may need adjustment for this specific build.\n  3. Apple may have partially patched bad_query in this build.\n\nCheck the device console (Console.app, filter [GKTL-ObjC]) for detailed per-stage logs showing exactly where the lease acquisition failed (lstat / create / getSingleResult / copySandboxToken / consume).")
                    } else if osVersion.majorVersion == 27 && osVersion.minorVersion >= 2 {
                        // On 27.2+ bad_query is expected to be dead; the worse_query
                        // fallback handles the lease. If we still got here, worse_query
                        // also failed — its prerequisites are the most likely cause.
                        enriched += "\n\n" + String(localized: "[ iOS \(osVersion.majorVersion).\(osVersion.minorVersion) ] bad_query is patched on this build (expected) and the worse_query fallback also failed. Check that the app was signed with the com.apple.security.application-groups entitlement and that the App Group (\(WorseQueryGroupIdentifier())) exists. See [GKTL-ObjC] console logs for the worse_query stage that failed.")
                    }
                    return DiagnosticResult(
                        name: "Sandbox Lease Acquisition",
                        status: .fail,
                        detail: enriched
                    )
                }
            }()

            // MARK: Test 3 — Container Discovery (fsgetpath, no lease needed)
            let r3: DiagnosticResult = {
                let appDataRoot = "/var/mobile/Containers/Data/Application"
                var listError: NSError?
                let entries = fileAccess.listDirectory(atPath: appDataRoot, error: &listError)
                let count = entries.filter { $0.isDirectory }.count
                let msg: String
                let status: DiagnosticStatus
                if let listError {
                    msg = "Container discovery failed: \(listError.localizedDescription)"
                    status = .fail
                } else if count == 0 {
                    msg = "No app containers found."
                    status = .warn
                } else {
                    msg = "Discovered \(count) app data containers."
                    status = .pass
                }
                return DiagnosticResult(name: "Container Discovery", status: status, detail: msg)
            }()

            // MARK: Test 4 — File Read Test (uses shared lease, no extra XPC)
            //
            // The shared lease is already active for gestaltPath, so we
            // can read the file directly without acquiring another
            // lease via fileAccess.readFile. This eliminates the 2nd
            // ContainerManager XPC round-trip entirely.
            let r4: DiagnosticResult = {
                do {
                    let data = try Data(contentsOf: URL(fileURLWithPath: gestaltPath))
                    return DiagnosticResult(
                        name: "File Read Test",
                        status: data.count > 0 ? .pass : .warn,
                        detail: "Read \(data.count) bytes from MobileGestalt plist."
                    )
                } catch {
                    return DiagnosticResult(
                        name: "File Read Test",
                        status: .fail,
                        detail: "Cannot read MobileGestalt plist: \(error.localizedDescription)"
                    )
                }
            }()

            // MARK: Test 5 — Directory Listing Test (fsgetpath, no lease needed)
            let r5: DiagnosticResult = {
                let testPath = "/var/containers/Shared/SystemGroup/systemgroup.com.apple.mobilegestaltcache/Library/Caches"
                var listError: NSError?
                let entries = fileAccess.listDirectoryNoFallback(atPath: testPath, error: &listError)
                let msg: String
                let status: DiagnosticStatus
                if let listError {
                    msg = "Directory listing failed: \(listError.localizedDescription)"
                    status = .fail
                } else if entries.isEmpty {
                    msg = "Directory is empty or inaccessible."
                    status = .warn
                } else {
                    msg = "Listed \(entries.count) entries in MobileGestalt cache dir."
                    status = .pass
                }
                return DiagnosticResult(name: "Directory Listing Test", status: status, detail: msg)
            }()

            // MARK: Test 6 — MobileGestalt Write Test (uses shared lease)
            //
            // Mirrors saveGestalt:'s exact open() flags (O_WRONLY|O_CLOEXEC|O_NOFOLLOW):
            //   1. Open gestaltPath — if it fails, saveGestalt: will fail too.
            //   2. If open succeeds, close immediately (non-destructive).
            //   3. Optional O_CREAT probe is informational-only and never flips Pass/Fail.
            let r6: DiagnosticResult = {
                guard leaseActive else {
                    let detail = leaseError as? String ?? "unknown bad_query error"
                    return DiagnosticResult(
                        name: "MobileGestalt Write Test",
                        status: .fail,
                        detail: "No active sandbox lease — skipping write probe (\(detail))."
                    )
                }

                return gestaltPath.withCString { gestaltFsRep in
                    // MARK: - Phase A (truth): open REAL plist like saveGestalt: does
                    let gestaltFd = open(gestaltFsRep,
                                         O_WRONLY | O_CLOEXEC | O_NOFOLLOW)
                    guard gestaltFd >= 0 else {
                        let err = errno
                        let hint: String
                        switch err {
                        case EACCES:
                            hint = "\nHint (DAC ownership mismatch): The MobileGestalt cache plist is not writable by our uid (\(geteuid())). This is a real failure — saveGestalt: will return EACCES too, even with an active bad_query lease."
                        case EPERM:
                            hint = "\nHint (EPERM despite lease): MAC-level policy or the immutable flag blocks O_WRONLY on the plist. saveGestalt: will also fail with EPERM."
                        case ENOENT:
                            hint = "\nHint (ENOENT): The MobileGestalt plist does not exist at the expected path. This can happen on a freshly-booted device before MobileGestalt has written its cache; try respringing once then rerun diagnostics."
                        case EBADF:
                            hint = "\nHint (EBADF from open): The sandbox extension for this path was rejected or has been revoked. Try rerunning diagnostics to reacquire the lease."
                        default:
                            hint = ""
                        }
                        return DiagnosticResult(
                            name: "MobileGestalt Write Test",
                            status: .fail,
                            detail: "saveGestalt: mirror probe — cannot open MobileGestalt plist for writing (errno=\(err): \(String(cString: strerror(err)))). \(hint)"
                        )
                    }
                    // Close immediately — no mutation. A successful
                    // open() with saveGestalt:'s exact flags is the
                    // strongest possible signal that saveGestalt: will
                    // also be able to open the fd and proceed.
                    let closeResult = close(gestaltFd)
                    let closeErrno = errno

                    // MARK: - Phase B (informational only): O_CREAT probe
                    // Never downgrades Phase A's Pass; only adds an optional warning note.
                    let tmpFile = cacheDir + "/.gestaltkit_tool_writeprobe.tmp"
                    var probeMsg: String? = nil
                    var probeStatus: DiagnosticStatus = .pass
                    tmpFile.withCString { probeFsRep in
                        defer { unlink(probeFsRep) }
                        let pfd = open(probeFsRep,
                                       O_WRONLY | O_CREAT | O_TRUNC | O_EXCL,
                                       0o644)
                        if pfd >= 0 {
                            // Phase B: informational O_CREAT probe with strict return checks.
                            let sig: [UInt8] = [0x57, 0x45, 0x53, 0x4B]
                            let written: Int = sig.withUnsafeBytes { p in
                                guard let b = p.baseAddress else { return -1 }
                                return write(pfd, b, 4)
                            }
                            let fsyncRet = fsync(pfd)
                            let fsyncErr = fsyncRet != 0 ? errno : 0
                            let probeClose = close(pfd)
                            let probeCloseErr = probeClose != 0 ? errno : 0
                            _ = unlink(probeFsRep)
                            var notes: [String] = []
                            if written < 4 { notes.append("write=\(written)") }
                            if fsyncRet != 0 { notes.append("fsync errno=\(fsyncErr)") }
                            if probeClose != 0 { notes.append("close errno=\(probeCloseErr)") }
                            if notes.isEmpty {
                                probeMsg = "Directory O_CREAT probe: pass."
                            } else {
                                probeMsg = "Directory O_CREAT probe: pass (\(notes.joined(separator: "; ")))."
                                probeStatus = .warn
                            }
                        } else {
                            let err = errno
                            // Phase B EPERM/EACCES are expected — MAC policy denies O_CREAT.
                            // Phase A already proved saveGestalt: works, so Phase B stays .pass.
                            probeStatus = .pass
                            switch err {
                            case EPERM:
                                probeMsg = "Directory O_CREAT probe: EPERM (expected on most iOS versions — MAC/immutable flag denies creation inside cache dir. Not a problem for saveGestalt:, which overwrites the existing plist)."
                            case EACCES:
                                probeMsg = "Directory O_CREAT probe: EACCES (DAC ownership mismatch on cache dir). saveGestalt: may still work (it does not O_CREAT)."
                            case EEXIST:
                                probeMsg = "Directory O_CREAT probe: EEXIST (stale probe file). Probe was cleaned up by defer/unlink."
                            default:
                                probeMsg = "Directory O_CREAT probe: errno=\(err) (\(String(cString: strerror(err))))."
                                probeStatus = .warn
                            }
                        }
                    }

                    // MARK: - Compose final result
                    var finalStatus: DiagnosticStatus = .pass
                    var detail = "saveGestalt: mirror probe — opened MobileGestalt.plist O_WRONLY (matches saveGestalt: open flags). saveGestalt: should succeed. \(probeMsg ?? "")"
                    if closeResult != 0 {
                        finalStatus = .warn
                        detail = "saveGestalt: mirror probe — opened MobileGestalt.plist O_WRONLY OK, but close() returned errno=\(closeErrno). Non-fatal, but indicates flushing issues. \(probeMsg ?? "")"
                    }
                    // Phase B (O_CREAT probe) is informational-only.
                    // Phase A success = saveGestalt: will work → .pass.
                    return DiagnosticResult(
                        name: "MobileGestalt Write Test",
                        status: finalStatus,
                        detail: detail
                    )
                }
            }()

            let allResults = [r1, r1b, r2, r3, r4, r5, r6]
            let logText = allResults.map { $0.detail ?? "" }.joined(separator: "\n")

            Task { @MainActor [weak self] in
                self?.results = allResults
                self?.log = logText + "\n" + String(localized: "Diagnostics complete.")
                self?.isRunning = false
            }
        }
    }
}

// MARK: - Diagnostic Status

enum DiagnosticStatus {
    case pass, warn, fail

    var icon: String {
        switch self {
        case .pass: "checkmark.circle.fill"
        case .warn: "exclamationmark.triangle.fill"
        case .fail: "xmark.octagon.fill"
        }
    }

    var color: Color {
        switch self {
        case .pass: .green
        case .warn: .orange
        case .fail: .red
        }
    }

    var label: String {
        switch self {
        case .pass: String(localized: "Pass")
        case .warn: String(localized: "Warning")
        case .fail: String(localized: "Fail")
        }
    }
}

// MARK: - Diagnostic Result Model

struct DiagnosticResult: Identifiable {
    let id = UUID()
    let name: String
    let status: DiagnosticStatus
    let detail: String?
}
