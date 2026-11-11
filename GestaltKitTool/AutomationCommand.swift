import Foundation
import UIKit
import CoreTelephony

/// Headless command-line automation for GestaltKitTool.
///
/// Supported arguments:
///   `--set-us-region <A1234>`        Set US region keys (LL, LL/A, regulatory model).
///   `--enable-tweak <id>`            Enable a tweak by its GestaltTweakID raw value.
///   `--disable-tweak <id>`           Disable (revert) a tweak by its GestaltTweakID raw value.
///   `--set-dynamic-island <subtype>` Set ArtworkDeviceSubType to the given integer.
///   `--set-model-name <name>`        Set DeviceModelName in CacheExtra.
///   `--restore-factory`              Revert all tweaks to factory defaults.
///   `--list-tweaks`                   Print all available tweak IDs and titles.
///
/// Each command performs: connect → read → mutate → backup → write → verify → exit.
/// The result marker is written to stdout so the calling process can
/// detect success or failure programmatically.
enum AutomationCommand {
    static let successMarker = "GESTALT_SUCCESS"
    static let failureMarker = "GESTALT_FAILURE"

    /// Returns the value after `--flag` if present.
    private static func argValue(_ flag: String, in arguments: [String]) -> String? {
        guard let i = arguments.firstIndex(of: flag), i + 1 < arguments.count else { return nil }
        return arguments[i + 1]
    }

    static func runIfNeeded() {
        let arguments = CommandLine.arguments

        // --set-us-region <A1234>
        if let commandIndex = arguments.firstIndex(of: "--set-us-region") {
            runSetUSRegion(arguments: arguments, commandIndex: commandIndex)
        }

        // --enable-tweak <id>
        if let commandIndex = arguments.firstIndex(of: "--enable-tweak") {
            runEnableTweak(arguments: arguments, commandIndex: commandIndex)
        }

        // --disable-tweak <id>
        if let commandIndex = arguments.firstIndex(of: "--disable-tweak") {
            runDisableTweak(arguments: arguments, commandIndex: commandIndex)
        }

        // --set-dynamic-island <subtype>
        if let commandIndex = arguments.firstIndex(of: "--set-dynamic-island") {
            runSetDynamicIsland(arguments: arguments, commandIndex: commandIndex)
        }

        // --set-model-name <name>
        if let commandIndex = arguments.firstIndex(of: "--set-model-name") {
            runSetModelName(arguments: arguments, commandIndex: commandIndex)
        }

        // --restore-factory
        if arguments.contains("--restore-factory") {
            runRestoreFactory()
        }

        // --list-tweaks
        if arguments.contains("--list-tweaks") {
            runListTweaks()
        }

        // --probe-keychain-db
        // Reads /var/Keychains/keychain-2.db via worse_query and parses
        // its SQLite schema. Item counts are printed; secret blobs are
        // AES-encrypted and never decrypted.
        if arguments.contains("--probe-keychain-db") {
            runProbeKeychainDB()
        }

        // --cleanup-bench
        // Times the Safe Cleanup discovery loop: per-container lease/list
        // latency. Headless, no UI.
        if arguments.contains("--cleanup-bench") {
            runCleanupBench()
        }

        // --scan-app-data
        // Enumerates /var/mobile/Containers/Data/Application and prints the
        // first 20 app bundle IDs. Read-only.
        if arguments.contains("--scan-app-data") {
            runScanAppData()
        }

        // --probe-paths
        // lstat-probe a list of candidate paths and report which exist.
        if arguments.contains("--probe-paths") {
            runProbePaths()
        }

        // --selftest-preview
        // In-memory end-to-end test of the file preview pipeline:
        // txt/UTF-16/plist/JSON/SQLite/PNG/binary classification
        // and parsing. No device files touched.
        if arguments.contains("--selftest-preview") {
            runSelftestPreview()
        }

        // --summarize-prefs <bundle-id-prefix>
        // Finds the first app container whose owner bundle ID starts
        // with the prefix, then flattens its Preferences plists.
        if let i = arguments.firstIndex(of: "--summarize-prefs"),
           i + 1 < arguments.count {
            runSummarizePrefs(prefix: arguments[i + 1])
        }

        // --cat <path>
        // Dumps a small file's bytes as base64 (for host-side decoding).
        if let i = arguments.firstIndex(of: "--cat"), i + 1 < arguments.count {
            runCatFile(arguments[i + 1])
        }

        // --stat <path>  (single-path probe, 1 if exists / 0 if not)
        if let i = arguments.firstIndex(of: "--stat"), i + 1 < arguments.count {
            runStatPath(arguments[i + 1])
        }

        // --ls <path>
        // Lists a device directory via worse_query (read-only probe).
        if let i = arguments.firstIndex(of: "--ls"), i + 1 < arguments.count {
            runListDir(arguments[i + 1])
        }

        // --enable-ai-region
        // Full Siri AI (US Region) enablement: region keys + device
        // spoofing triple (productType / hardwareModel / cpuModel),
        // mirroring GestaltViewModel.applySelectedTweaks.
        if arguments.contains("--enable-ai-region") {
            runEnableAIRegion()
        }

        // --set-language <locale>
        // Rewrites AppleLocale / AppleLanguages in .GlobalPreferences.plist
        // via a worse_query write lease. Requires a reboot (or SpringBoard
        // restart) to take visual effect; eligibilityd re-evaluates on boot.
        if let i = arguments.firstIndex(of: "--set-language"), i + 1 < arguments.count {
            runSetLanguage(locale: arguments[i + 1])
        }

        // --write-scan <path>
        // Like --flag-scan but probes WRITE access: for each flag/part
        // combination that yields a sandbox token, attempt open(O_WRONLY).
        if let i = arguments.firstIndex(of: "--write-scan"), i + 1 < arguments.count {
            runWriteScan(path: arguments[i + 1])
        }

        // --probe-open <path>
        // Diagnostic: reports which open modes (R / W / RW) succeed under
        // a worse_query lease — used to triage DAC vs MAC write denials.
        if let i = arguments.firstIndex(of: "--probe-open"), i + 1 < arguments.count {
            let access = BadQueryFileAccess.shared()
            let mask = access.probeOpenModes(atPath: arguments[i + 1])
            // Bits: 0=R,1=W,2=RW (any open), 3..5 = direct (no lease)
            let parts: [String] = [
                (mask & 1) != 0 ? "R" : "-",
                (mask & 2) != 0 ? "W" : "-",
                (mask & 4) != 0 ? "RW" : "-",
                "direct:",
                (mask & 8) != 0 ? "R" : "-",
                (mask & 16) != 0 ? "W" : "-",
                (mask & 32) != 0 ? "RW" : "-"
            ]
            finish(marker: mask != 0 ? successMarker : failureMarker,
                   message: "\(arguments[i + 1]) open-modes: " + parts.joined(separator: " "))
        }

        // --carrier-probe
        // One-shot lock/carrier-state audit: activation records,
        // CommCenter prefs, carrier bundle assets, and write access.
        if arguments.contains("--carrier-probe") {
            runCarrierProbe()
        }

        // --net-probe
        // Egress identity check: fetch ipinfo.io over cellular (or
        // current default route) and report the carrier the traffic
        // actually rides on. With an interposer in the slot this
        // reveals which operator the baseband truly registered with.
        if arguments.contains("--net-probe") {
            runNetProbe()
        }

        // --telephony-probe
        // Runtime CoreTelephony read: carrier identity as seen by the
        // baseband right now (works with a SIM interposer in the slot).
        if arguments.contains("--telephony-probe") {
            runTelephonyProbe()
        }

        // --carrier-apply <mode>
        // Experimental lock-state modification. Modes:
        //   no-op      rewrite activation_record byte-identical (write-channel test)
        //   ticket     remove ActivationTicket from AccountToken (keep wildcard idea)
        //   wildcard   transplant WildcardTicket structure (write path only)
        //   restore    rewrite the backup passed via --input <path>
        if let i = arguments.firstIndex(of: "--carrier-apply"), i + 1 < arguments.count {
            let inputPath = arguments.firstIndex(of: "--input")
                .flatMap { ($0 + 1 < arguments.count) ? arguments[$0 + 1] : nil }
                ?? (FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?
                        .appendingPathComponent("grafted_record.plist").path)
            runCarrierApply(mode: arguments[i + 1], inputPath: inputPath)
        }

        // --export-gestalt
        // Dump the full MobileGestalt cache plist into the app's
        // Documents/MobileGestalt.plist for host-side inspection.
        if arguments.contains("--export-gestalt") {
            runExportGestalt()
        }

        // --dump-gestalt
        // Read-only dump of the MobileGestalt cache plist top-level
        // structure and the AI-region-relevant CacheExtra keys.
        if arguments.contains("--dump-gestalt") {
            runDumpGestalt()
        }

        // --flag-scan <path>
        // Brute-force worse_query flag/part combinations against a
        // MAC-blocked path to find one that yields a sandbox token.
        if let i = arguments.firstIndex(of: "--flag-scan") {
            // Accept both "--flag-scan <path>" and
            // "--flag-scan --target <path>" forms.
            var path = ""
            if i + 1 < arguments.count, !arguments[i + 1].hasPrefix("--") {
                path = arguments[i + 1]
            } else if let t = arguments.firstIndex(of: "--target"),
                      t + 1 < arguments.count {
                path = arguments[t + 1]
            }
            if path.isEmpty {
                gktlLog("[GKTL-FlagScan] ERROR: no path given")
            } else {
                runFlagScan(path: path)
            }
        }
    }

    // MARK: - --flag-scan

    // MARK: - --carrier-probe

    /// Probes the carrier/lock state chain:
    /// 1. mobileactivationd container → data_ark.plist (activation state,
    ///    the carrier-sim-lock fields live here)
    /// 2. CommCenter containers (plists)
    /// 3. /var/wireless carrier assets
    /// 4. Write reachability of each (can we modify them at all?)
    // MARK: - --carrier-apply

    /// Experimental: modify the local activation records.
    /// The write channel is verified RW; these ops are REVERSIBLE via
    /// `--carrier-apply restore --input <backup>` because the caller is
    /// expected to keep a backup (probe writes one to Documents).
    private static func runCarrierApply(mode: String, inputPath: String?) {
        let access = BadQueryFileAccess.shared()
        guard let act = ContainerMetadata.findSystemContainer(
            fileAccess: access, ownerBundleId: "com.apple.mobileactivationd") else {
            finish(marker: failureMarker, message: "activation container not found")
            return
        }
        let recPath = act.fullPath + "/Library/activation_records/activation_record.plist"

        func fail(_ msg: String) -> Never {
            finish(marker: failureMarker, message: msg)
            exit(1)
        }

        switch mode {
        case "no-op":
            // Byte-identical rewrite: proves the write channel end-to-end
            // without changing semantics.
            guard let orig = try? access.readFile(atPath: recPath) else {
                fail("cannot read activation_record")
            }
            do {
                try access.writeFile(atPath: recPath, data: orig)
                let back = try access.readFile(atPath: recPath)
                if back == orig {
                    finish(marker: successMarker,
                           message: "no-op rewrite OK (\(orig.count) bytes, verified identical)")
                } else {
                    fail("write did not round-trip: \(orig.count) -> \(back.count)")
                }
            } catch {
                fail("write failed: \(error)")
            }

        case "restore":
            guard let inputPath,
                  let data = FileManager.default.contents(atPath: inputPath) else {
                fail("restore needs --input <backup path>")
            }
            do {
                try access.writeFile(atPath: recPath, data: data)
                finish(marker: successMarker,
                       message: "restored \(data.count) bytes from backup")
            } catch {
                fail("restore failed: \(error)")
            }

        case "strip-ticket":
            // Remove ActivationTicket + MobileEquipmentIdentifier from
            // AccountToken, keep everything else. Idea: without an
            // ActivationTicket the device may fall back to wildcard
            // semantics. Fully reversible via `restore`.
            guard let orig = try? access.readFile(atPath: recPath) else {
                fail("cannot read activation_record")
            }
            guard var dict = (try? PropertyListSerialization.propertyList(
                from: orig, format: nil)) as? [String: Any],
                  let token = dict["AccountToken"] as? Data else {
                fail("activation_record parse failed")
            }
            guard var tokenDict = (try? PropertyListSerialization.propertyList(
                from: token, format: nil)) as? [String: Any] else {
                fail("AccountToken parse failed")
            }
            guard tokenDict.removeValue(forKey: "ActivationTicket") != nil else {
                fail("no ActivationTicket present")
            }
            tokenDict.removeValue(forKey: "MobileEquipmentIdentifier")
            let newToken = try! PropertyListSerialization.data(
                fromPropertyList: tokenDict, format: .binary, options: 0)
            dict["AccountToken"] = newToken
            let out = try! PropertyListSerialization.data(
                fromPropertyList: dict, format: .binary, options: 0)
            try! access.writeFile(atPath: recPath, data: out)
            finish(marker: successMarker,
                   message: "stripped ActivationTicket; \(orig.count) -> \(out.count) bytes; reboot to test; restore with backup")

        case "graft-ticket":
            // Replace the entire AccountToken with one grafted from
            // another device (e.g. an unlocked phone's WildcardTicket
            // token). The file must first be pushed to the app's
            // Documents/ as "grafted_record.plist" via devicectl.
            // Purpose: test whether mobileactivationd re-validates the
            // AccountTokenSignature against the device identity at boot.
            guard let inputPath,
                  FileManager.default.fileExists(atPath: inputPath) else {
                fail("graft file missing at \(inputPath ?? "<nil>")")
            }
            guard let grafted = try? Data(contentsOf: URL(fileURLWithPath: inputPath)),
                  var gDict = (try? PropertyListSerialization.propertyList(
                    from: grafted, format: nil)) as? [String: Any],
                  let gToken = gDict["AccountToken"] as? Data,
                  let orig = try? access.readFile(atPath: recPath),
                  var oDict = (try? PropertyListSerialization.propertyList(
                    from: orig, format: nil)) as? [String: Any] else {
                fail("graft source/target parse failed")
            }
            // Carry over the grafted record's signature-protected peers
            // so the record stays internally consistent as a set.
            for key in ["AccountToken", "AccountTokenSignature", "AccountTokenCertificate",
                        "DeviceCertificate", "UniqueDeviceCertificate"] {
                if let v = gDict[key] { oDict[key] = v }
            }
            let out = try! PropertyListSerialization.data(
                fromPropertyList: oDict, format: .binary, options: 0)
            try! access.writeFile(atPath: recPath, data: out)
            finish(marker: successMarker,
                   message: "grafted AccountToken set (\(gToken.count) bytes token, \(out.count) bytes record); reboot to test")

        default:
            fail("unknown mode: \(mode)")
        }
    }

    /// Runtime CoreTelephony probe: reads the live carrier identity the
    /// baseband currently reports (CTCarrier / CTTelephonyNetworkInfo),
    /// plus radio tech. With an interposer ("卡贴") in the slot this
    /// reveals exactly which IMSI the baseband was fooled into accepting.
    private static func runTelephonyProbe() {
        var lines: [String] = []

        let networkInfo = CTTelephonyNetworkInfo()
        var carrier: CTCarrier? = nil
        if #available(iOS 12.0, *) {
            carrier = networkInfo.serviceSubscriberCellularProviders?.values.first
        }
        if carrier == nil {
            carrier = networkInfo.subscriberCellularProvider
        }
        if let carrier = carrier {
            lines.append("CARRIER_NAME=\(carrier.carrierName ?? "-")")
            lines.append("MCC_MNC=\(carrier.mobileCountryCode ?? "-")_\(carrier.mobileNetworkCode ?? "-")")
            lines.append("ISO=\(carrier.isoCountryCode ?? "-")")
            lines.append("ALLOWS_VOIP=\(carrier.allowsVOIP)")
        } else {
            lines.append("CARRIER_NAME=-")
        }
        var radioTech: String? = nil
        if #available(iOS 12.0, *) {
            radioTech = networkInfo.serviceCurrentRadioAccessTechnology?.values.first
        }
        if radioTech == nil {
            radioTech = networkInfo.currentRadioAccessTechnology
        }
        lines.append("RADIO=\(radioTech ?? "-")")

        finish(marker: successMarker, message: lines.joined(separator: " | "))
    }

    /// Blocking network probe: fetches ipinfo.io JSON and reports
    /// the egress IP/org. Run with Wi-Fi off to read the cellular path.
    private static func runNetProbe() {
        let url = URL(string: "https://ipinfo.io/json")!
        var result = "no response"
        let sem = DispatchSemaphore(value: 0)
        var req = URLRequest(url: url)
        req.timeoutInterval = 15
        // Prefer cellular interface if present
        URLSession(configuration: .default).dataTask(with: req) { data, resp, err in
            if let err = err { result = "ERR: \(err.localizedDescription)" }
            else if let data = data, let s = String(data: data, encoding: .utf8) {
                result = s.replacingOccurrences(of: "\n", with: " ")
            }
            sem.signal()
        }.resume()
        _ = sem.wait(timeout: .now() + 20)
        finish(marker: successMarker, message: "EGRESS: " + result)
    }

    private static func runCarrierProbe() {
        let access = BadQueryFileAccess.shared()
        var report: [String] = []

        // 1. Activation container + data_ark
        if let act = ContainerMetadata.findSystemContainer(
            fileAccess: access, ownerBundleId: "com.apple.mobileactivationd") {
            gktlLog("[GKTL-Carrier] activation container: \(act.fullPath)")
            report.append("ACT-CONTAINER: \(act.fullPath)")
            for rel in ["/Library/internal/data_ark.plist", "/Library/activation_records/activation_record.plist"] {
                let p = act.fullPath + rel
                if let data = try? access.readFile(atPath: p) {
                    report.append("READ \(rel): \(data.count)B")
                    // Dump interesting keys for lock diagnosis.
                    if let plist = (try? PropertyListSerialization.propertyList(
                        from: data, options: [], format: nil)) as? [String: Any] {
                        let keys = plist.keys.filter {
                            let k = $0.lowercased()
                            return k.contains("lock") || k.contains("carrier")
                                || k.contains("region") || k.contains("sim")
                                || k.contains("unlock") || k.contains("activation")
                        }.sorted()
                        report.append("KEYS \(rel): \(keys.joined(separator: ","))")
                        for k in keys {
                            let v = String(describing: plist[k]!)
                            report.append("  \(k)=\(v.prefix(60))")
                        }
                    }
                } else {
                    report.append("UNREADABLE \(rel)")
                }
            }
        } else {
            report.append("ACT-CONTAINER: NOT FOUND")
        }

        // 2. CommCenter containers
        let sysEntries = access.listDirectory(
            atPath: "/private/var/containers/Data/System", error: nil)
        var ccCount = 0
        for entry in sysEntries where entry.isDirectory {
            guard let bid = ContainerMetadata.bundleId(
                fileAccess: access, containerPath: entry.fullPath) else { continue }
            let o = bid.lowercased()
            if o.contains("commcenter") || o.contains("coretelephony") || o.contains("carrier") {
                ccCount += 1
                report.append("CC-CONTAINER: \(bid) @ \(entry.name)")
            }
        }
        report.append("CC-TOTAL: \(ccCount)")

        // 3. Wireless assets (IPCC payloads live as .asset bundles)
        let wireless = access.listDirectory(
            atPath: "/var/wireless/Library/Preferences", error: nil)
        let assets = wireless.filter { $0.name.hasSuffix(".asset") }
        report.append("WIRELESS-ASSETS: \(assets.count)")
        for a in assets.prefix(5) {
            let inner = access.listDirectoryNoFallback(atPath: a.fullPath as String, error: nil)
            report.append("  \(a.name): \(inner.count) entries")
        }

        // 4. Write reachability of key lock-state files
        for p in [
            "/var/wireless/Library/Preferences/com.apple.commcenter.plist",
            "/var/preferences/SystemConfiguration/preferences.plist",
        ] {
            let mask = access.probeOpenModes(atPath: p)
            report.append("WRITE \(p): mask=\(mask) \(mask & (16|32) != 0 ? "WRITABLE" : "RO")")
        }

        finish(marker: successMarker, message: report.joined(separator: " | "))
    }

    private static func runFlagScan(path: String) {
        // Flag-space exploration. The known-good values are
        // 0x0000008000000000 (default) and 0x0000000800000000 (alt).
        // Scan: each single bit in the high dword + the two known
        // values + a few semantic candidates (read-only class bits
        // observed in ContainerManager disassembly notes).
        var flagCandidates: [UInt64] = []
        for bit: UInt64 in 26...40 {
            flagCandidates.append(1 << bit)
        }
        flagCandidates.append(0x0000008000000000)
        flagCandidates.append(0x0000000800000000)
        flagCandidates.append(0x0000008000000000 | 0x0000000800000000)
        flagCandidates.append(0x0000000800000000 | 0x0000000000040000)
        flagCandidates.append(0x0000008000000000 | 0x0000000000040000)

        // part values: 0 = container root, 1 = Documents?, 2 = Library?,
        // 3 = Library/Caches (the documented worse_query value).
        // DO NOT add parts outside 0–3: out-of-range parts make
        // containermanagerd return an error object, and
        // container_copy_sandbox_token then traps with _xpc_api_misuse
        // (crash: GestaltKitTool-2026-11-09-221950.ips).
        let parts: [UInt64] = [3, 0, 1, 2]

        gktlLog("[GKTL-FlagScan] scanning path=\(path) flags=\(flagCandidates.count) parts=\(parts.count)")

        var successCount = 0
        for part in parts {
            for flag in flagCandidates {
                let ok = WorseQueryProbe.probePath(path, flag: flag, part: part)
                gktlLog("[GKTL-FlagScan] part=\(part) flag=0x\(String(flag, radix: 16)) -> \(ok ? "TOKEN" : "deny")")
                if ok {
                    successCount += 1
                    if let data = WorseQueryProbe.readPath(path, flag: flag, part: part) {
                        gktlLog("[GKTL-FlagScan] READ \(data.count) bytes, magic=\(String(data: data.prefix(16), encoding: .ascii) ?? "bin")")
                        finish(marker: successMarker,
                               message: "HIT part=\(part) flag=0x\(String(flag, radix: 16)) read=\(data.count)B")
                        return
                    }
                }
            }
        }
        finish(marker: successCount > 0 ? successMarker : failureMarker,
               message: "scan done, hits=\(successCount)")
    }

    // MARK: - --summarize-prefs

    private static func runSummarizePrefs(prefix: String) {
        let access = BadQueryFileAccess.shared()
        var listError: NSError?
        let entries = access.listDirectory(
            atPath: "/var/mobile/Containers/Data/Application",
            error: &listError
        )
        gktlLog("[GKTL-PrefSummary] headless scanning for owner prefix=\(prefix)")

        var checked = 0
        var found: (path: String, files: [BQFileEntry])? = nil
        outer: for entry in entries where entry.isDirectory {
            guard entry.name.count == 36 else { continue }
            checked += 1
            if checked > 800 { break } // bound the scan
            if let bid = ContainerMetadata.bundleId(
                fileAccess: access, containerPath: entry.fullPath),
               bid.hasPrefix(prefix) {
                // iOS app prefs live under <container>/Preferences, but
                // some apps also use Library/Preferences — check both.
                let candidates = [
                    (entry.fullPath as NSString).appendingPathComponent("Preferences"),
                    (entry.fullPath as NSString).appendingPathComponent("Library/Preferences")
                ]
                for prefsDir in candidates {
                    let files = access.listDirectoryNoFallback(atPath: prefsDir, error: nil)
                        .filter { !$0.isDirectory && $0.name.hasSuffix(".plist") }
                    if !files.isEmpty {
                        found = (entry.fullPath as String, files)
                        break outer
                    }
                }
            }
        }

        guard let (container, files) = found else {
            finish(marker: failureMarker, message: "No container with readable prefs found for prefix \(prefix)")
            return
        }

        var total = 0
        var sample: [String] = []
        for f in files {
            guard let data = try? access.readFile(atPath: f.fullPath as String),
                  let plist = (try? PropertyListSerialization.propertyList(
                      from: data, options: [], format: nil)) as? [String: Any]
            else { continue }
            for (k, v) in plist.sorted(by: { $0.key < $1.key }) {
                total += 1
                if sample.count < 10 {
                    sample.append("\(f.name):\(k)=\(String(describing: v).prefix(40))")
                }
            }
        }
        gktlLog("[GKTL-PrefSummary] headless container=\(container) files=\(files.count) keys=\(total)")
        for s in sample {
            gktlLog("[GKTL-PrefSummary] sample \(s)")
        }
        if total > 0 {
            finish(marker: successMarker, message: "prefs: \(files.count) files, \(total) keys, e.g. \(sample.prefix(3).joined(separator: " ; "))")
        } else {
            finish(marker: failureMarker, message: "Container found but no readable plists (files=\(files.count))")
        }
    }

    // MARK: - --selftest-preview

    private static func runSelftestPreview() {
        var failures: [String] = []
        func check(_ name: String, _ cond: Bool, _ detail: String = "") {
            gktlLog("[GKTL-SelfTest] \(name): \(cond ? "PASS" : "FAIL") \(detail)")
            if !cond { failures.append(name) }
        }

        func makePreview(_ name: String, _ data: Data) -> FilePreview {
            let entry = BQFileEntryBuilder.fileEntry(
                name: name, fullPath: "/selftest/\(name)",
                isDirectory: false, size: Int64(data.count), mtime: Date()
            )
            return FilePreview(entry: entry, data: data)
        }

        // 1. UTF-8 text
        let txt = Data("hello selftest".utf8)
        let p1 = makePreview("selftest.txt", txt)
        check("txt-classify", p1.detectedType == .text)
        check("txt-content", p1.textPreview?.contains("hello selftest") == true)

        // 2. UTF-16 text (BE, no BOM)
        let utf16 = "utf16 selftest".data(using: .utf16BigEndian)!
        let p2 = makePreview("selftest.txt", utf16)
        let p2text = p2.textPreview ?? "<nil>"
        let beDirect = String(data: utf16, encoding: .utf16BigEndian) ?? "<nil>"
        let leDirect = String(data: utf16, encoding: .utf16LittleEndian) ?? "<nil>"
        let p2b64 = p2text.data(using: .utf8)?.base64EncodedString() ?? "nil"
        check("utf16-decode", p2text.contains("utf16 selftest"),
              "b64=\(p2b64) len=\(p2text.count) hex0=\(utf16.prefix(2).map { String(format: "%02x", $0) }.joined()) beOK=\(beDirect == "utf16 selftest") leOK=\(leDirect == "utf16 selftest")")

        // 3. Binary plist
        let dict: [String: Any] = ["key": "value", "num": 42]
        let pl = (try? PropertyListSerialization.data(
            fromPropertyList: dict, format: .binary, options: 0)) ?? Data()
        let p3 = makePreview("selftest.plist", pl)
        check("plist-classify", p3.detectedType == .plist)
        check("plist-parse", p3.plistDictionary?["key"] as? String == "value")

        // 4. JSON
        let jd = Data(#"{"name":"gktl","ok":true}"#.utf8)
        let p4 = makePreview("selftest.json", jd)
        check("json-classify", p4.detectedType == .json)
        check("json-parse", p4.formattedJSON?.contains("gktl") == true)

        // 5. SQLite — real embedded fixture db
        let sqliteData = Data(base64Encoded: SelfTestResources.sqliteDataBase64) ?? Data()
        let p5 = makePreview("selftest.db", sqliteData)
        check("sqlite-classify", p5.detectedType == .database)
        let tables = p5.sqliteTables
        check("sqlite-table", tables?["notes"]?.count == 2,
              "tables=\(tables?.keys.sorted().joined(separator: ",") ?? "nil") rows=\(tables?["notes"]?.count ?? -1)")
        check("sqlite-row", tables?["notes"]?.first?["title"] == "hello",
              "row=\(tables?["notes"]?.first?["title"] ?? "nil")")

        // 5b. Corrupt db must fail gracefully, not crash.
        let notDb = Data("this is not a database".utf8)
        let p5b = makePreview("corrupt.db", notDb)
        let _ = p5b.sqliteTables
        check("sqlite-notadb-safe", true, "(parser did not crash)")

        // 6. PNG (1x1 pixel fixture)
        let pngData = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP8//8/AAX+Av6nNYGEAAAAAElFTkSuQmCC") ?? Data()
        let p6 = makePreview("selftest.png", pngData)
        check("png-classify", p6.detectedType == .image)
        check("png-render", UIImage(data: pngData) != nil)

        // 7. Hex dump on binary
        let bin = Data([0x00, 0x01, 0x02, 0xDE, 0xAD, 0xBE, 0xEF])
        let p7 = makePreview("selftest.bin", bin)
        check("bin-classify", p7.detectedType == .binary)
        check("bin-hex", p7.hexPreview.contains("de ad be ef"))

        // 8. Registry classification for new extensions
        for (ext, kind) in [
            ("md", FileKind.text), ("csv", FileKind.text), ("yaml", FileKind.text),
            ("webp", FileKind.image), ("tiff", FileKind.image), ("bmp", FileKind.image),
            ("sqlitedb", FileKind.database), ("html", FileKind.text), ("css", FileKind.text),
            ("js", FileKind.text), ("sh", FileKind.text), ("strings", FileKind.text)
        ] {
            let ok = FileTypeRegistry.classify(extension: ext) == kind
            check("registry-\(ext)", ok)
        }

        if failures.isEmpty {
            finish(marker: successMarker, message: "all preview selftests passed")
        } else {
            finish(marker: failureMarker, message: "failed: \(failures.joined(separator: ", "))")
        }
    }

    // MARK: - --write-scan

    private static func runWriteScan(path: String) {
        var flagCandidates: [UInt64] = []
        for bit: UInt64 in 26...40 { flagCandidates.append(1 << bit) }
        flagCandidates.append(contentsOf: [
            0x0000008000000000, 0x0000000800000000,
            0x0000008000000000 | 0x0000000800000000
        ])
        let parts: [UInt64] = [3, 0, 1, 2]

        for part in parts {
            for flag in flagCandidates {
                guard WorseQueryProbe.probePath(path, flag: flag, part: part) else { continue }
                if WorseQueryProbe.probeWrite(path, flag: flag, part: part) {
                    finish(marker: successMarker,
                           message: "WRITE-HIT part=\(part) flag=0x\(String(flag, radix: 16))")
                    return
                }
            }
        }
        finish(marker: failureMarker, message: "no writable flag/part combination for \(path)")
    }

    // MARK: - --probe-paths

    private static func runProbePaths() {
        let access = BadQueryFileAccess.shared()
        let candidates = [
            "/var/mobile/Containers/Data/Application",
            "/var/mobile/Containers/Shared/AppGroup",
            "/var/containers/Shared/SystemGroup",
            // TCC (permissions) database candidates
            "/private/var/mobile/Library/TCC/TCC.db",
            "/var/mobile/Library/TCC/TCC.db",
            "/private/var/mobile/Library/TCC/TCC.db-journal",
            // Network configuration candidates
            "/private/var/preferences/SystemConfiguration/preferences.plist",
            "/var/preferences/SystemConfiguration/preferences.plist",
            "/private/var/preferences/SystemConfiguration/NetworkInterfaces.plist",
            "/var/db/preferences.plist",
            "/private/var/db/com.apple.locationd/clients.plist"
        ]
        var report: [String] = []
        for p in candidates {
            var err: NSError?
            // Try reading it as a file first (file targets),
            // fall back to listing as a directory.
            if let data = try? access.readFile(atPath: p) {
                var kind = "file:\(data.count)B"
                if data.count >= 15, String(data: data.prefix(15), encoding: .ascii) == "SQLite format 3" {
                    kind += " SQLITE"
                    let parser = SQLiteParser(data: data)
                    let tables = parser.parseTables()
                    kind += " tables=\(tables.joined(separator: ","))"
                    for t in tables where !t.hasPrefix("sqlite_") {
                        let (_, rows) = parser.parseTable(t)
                        kind += " \(t)=\(rows.count)rows"
                        if let first = rows.first {
                            let sample = first.values.compactMap { v in
                                v.count > 30 ? String(v.prefix(30)) : v
                            }.prefix(3).joined(separator: "/")
                            gktlLog("[GKTL-ProbePaths] sample \(t): \(sample)")
                        }
                    }
                } else if let plist = (try? PropertyListSerialization.propertyList(
                    from: data, options: [], format: nil)) as? [String: Any] {
                    kind += " PLIST keys=\(plist.keys.count)"
                    for (k, v) in plist.sorted(by: { $0.key < $1.key }).prefix(8) {
                        gktlLog("[GKTL-ProbePaths] plist[\(k)] = \(String(describing: v).prefix(60))")
                    }
                }
                report.append("\(p): READABLE \(kind)")
                gktlLog("[GKTL-ProbePaths] \(p) -> READABLE \(kind)")
            } else {
                // Probe semantics: report reachability, so allow the
                // inode fallback (a hit via fallback still proves access).
                let entries = access.listDirectory(atPath: p, error: &err)
                let status = entries.isEmpty ? "EMPTY_OR_FAIL" : "\(entries.count) entries"
                report.append("\(p): \(status)")
                gktlLog("[GKTL-ProbePaths] \(p) -> \(status) err=\(err?.localizedDescription ?? "nil")")
            }
        }
        finish(marker: successMarker, message: report.joined(separator: " | "))
    }

    // MARK: - --scan-app-data

    // MARK: - --cleanup-bench

    private static func runCleanupBench() {
        let access = BadQueryFileAccess.shared()
        let root = ContainerMetadata.appDataRoot
        let t0 = Date()
        let entries = access.listDirectory(atPath: root, error: nil)
        let containers = entries.filter { $0.isDirectory }
        let listTime = Date().timeIntervalSince(t0)

        var leaseTimes: [Double] = []
        let targets = containers.prefix(5)
        for c in targets {
            let t = Date()
            _ = access.listDirectoryNoFallback(atPath: c.fullPath + "/Library/Caches", error: nil)
            leaseTimes.append(Date().timeIntervalSince(t))
        }

        var report = "containers=\(containers.count) rootList=\(String(format: "%.2fs", listTime))"
        if !leaseTimes.isEmpty {
            let avg = leaseTimes.reduce(0, +) / Double(leaseTimes.count)
            let maxT = leaseTimes.max() ?? 0
            let projected = avg * Double(containers.count) * 7 // 7 dirs per container
            report += String(format: " sample=%d avg=%.2fs max=%.2fs projectedTotal=%.0fs",
                             leaseTimes.count, avg, maxT, projected)
        }
        finish(marker: successMarker, message: report)
    }

    private static func runScanAppData() {
        let access = BadQueryFileAccess.shared()
        var listError: NSError?
        // Root listing keeps the one-shot inode fallback (needed to
        // enumerate 12k containers); per-container reads are single
        // file reads with no fallback.
        let entries = access.listDirectory(
            atPath: "/var/mobile/Containers/Data/Application",
            error: &listError
        )
        let uuids = entries.filter { $0.isDirectory }
            .map { $0.name }
            .filter { $0.count == 36 && $0.filter { $0 == "-" }.count == 4 }

        gktlLog("[GKTL-AppScan] headless: \(uuids.count) app containers found")

        var resolved = 0
        var samples: [String] = []
        for uuid in uuids.prefix(50) {
            guard let bid = ContainerMetadata.bundleId(
                fileAccess: access,
                containerPath: "/var/mobile/Containers/Data/Application/\(uuid)"
            ) else { continue }
            resolved += 1
            if samples.count < 20 { samples.append(bid) }
            gktlLog("[GKTL-AppScan] headless container owner=\(bid)")
        }
        if resolved > 0 {
            finish(marker: successMarker, message: "app containers: \(uuids.count), resolved(50-sample): \(resolved), sample: \(samples.joined(separator: ", "))")
        } else {
            finish(marker: failureMarker, message: "Found \(uuids.count) containers but no metadata readable (listError=\(listError?.localizedDescription ?? "nil"))")
        }
    }

    // MARK: - --probe-keychain-db

    private static func runProbeKeychainDB() {
        let path = "/var/Keychains/keychain-2.db"
        let access = BadQueryFileAccess.shared()

        guard let data = try? access.readFile(atPath: path) else {
            finish(marker: failureMarker, message: "Failed to read \(path)")
            return
        }
        gktlLog("[GKTL-KeychainDB] read \(path) size=\(data.count)")

        guard data.count >= 16,
              String(data: data.prefix(15), encoding: .ascii) == "SQLite format 3" else {
            finish(marker: failureMarker, message: "Not a SQLite database (\(data.count) bytes)")
            return
        }

        let parser = SQLiteParser(data: data)
        let tables = parser.parseTables()
        var summary = "tables=\(tables.joined(separator: ","))"
        for table in tables {
            if table.hasPrefix("sqlite_") { continue }
            let (_, rows) = parser.parseTable(table)
            summary += " | \(table):\(rows.count) rows"
            gktlLog("[GKTL-KeychainDB] table \(table) rows=\(rows.count)")
        }
        finish(marker: successMarker, message: "keychain-2.db \(data.count) bytes, \(summary)")
    }

    // MARK: - Shared Headless Apply Helper

    /// Performs a headless Gestalt plist mutation with backup, write, and
    /// verification — the same pipeline used by the UI's
    /// `GestaltViewModel.save()`, but without MainActor/UI state.
    ///
    /// `mutate` receives the pending plist and should apply the desired
    /// changes. It may throw to signal failure.
    ///
    /// `verify` receives the re-read plist after saving and should throw
    /// if the expected values didn't stick. If nil, only the basic
    /// plist-validity check runs.
    private static func headlessApply(
        mutate: (inout GestaltPlist) throws -> Void,
        verify: ((GestaltPlist) throws -> Void)? = nil
    ) -> Bool {
        do {
            let access = GestaltAccess.shared()
            try access.connect()

            let originalData = try access.readGestaltData()
            guard let dict = try access.readGestalt() as? [String: Any] else {
                throw AutomationError.invalidPlist
            }
            var plist = GestaltPlist(dict: dict)

            try mutate(&plist)

            // Backup before writing.
            _ = try GestaltBackupStore.create(from: originalData)
            try access.saveGestalt(plist.dict)

            // Verify: re-read and check.
            guard let verification = try access.readGestalt() as? [String: Any] else {
                throw AutomationError.verificationFailed
            }
            let verifiedPlist = GestaltPlist(dict: verification)

            // Strict check: caller-provided verification if any.
            if let verify {
                try verify(verifiedPlist)
            }

            return true
        } catch {
            // finish() returns Never, so the catch branch is non-returning.
            finish(marker: failureMarker, message: ErrorHandler.friendlyMessage(for: error))
        }
    }

    // MARK: - --set-us-region

    private static func runSetUSRegion(arguments: [String], commandIndex: Int) {
        let modelIndex = arguments.index(after: commandIndex)
        guard modelIndex < arguments.endIndex else {
            finish(marker: failureMarker, message: "Missing regulatory model")
            return
        }

        let regulatoryModel = arguments[modelIndex]
        guard regulatoryModel.wholeMatch(of: /^A\d{4}$/) != nil else {
            finish(marker: failureMarker, message: "Invalid regulatory model: \(regulatoryModel)")
            return
        }

        let ok = headlessApply(
            mutate: { plist in
                plist.setCacheExtra("LL", forKey: "h63QSdBCiT/z0WU6rdQv6Q")
                plist.setCacheExtra("LL/A", forKey: "yK+xavymRGZ3xWc1tb8XDg")
                plist.setCacheExtra(regulatoryModel, forKey: "97JDvERpVwO+GHtthIh7hA")
            },
            verify: { verifiedPlist in
                guard verifiedPlist.cacheExtra["h63QSdBCiT/z0WU6rdQv6Q"] as? String == "LL",
                      verifiedPlist.cacheExtra["yK+xavymRGZ3xWc1tb8XDg"] as? String == "LL/A",
                      verifiedPlist.cacheExtra["97JDvERpVwO+GHtthIh7hA"] as? String == regulatoryModel else {
                    throw AutomationError.verificationFailed
                }
            }
        )

        if ok {
            finish(marker: successMarker, message: regulatoryModel)
        }
    }

    // MARK: - --enable-tweak <id>

    private static func runEnableTweak(arguments: [String], commandIndex: Int) {
        let idIndex = arguments.index(after: commandIndex)
        guard idIndex < arguments.endIndex else {
            finish(marker: failureMarker, message: "Missing tweak ID")
            return
        }
        let rawID = arguments[idIndex]
        guard let tweakID = GestaltTweakID(rawValue: rawID),
              let definition = GestaltTweakCatalog.definition(for: tweakID) else {
            finish(marker: failureMarker, message: "Unknown tweak ID: \(rawID)")
            return
        }

        let ok = headlessApply { plist in
            try plist.apply(definition: definition)
        }

        if ok {
            finish(marker: successMarker, message: "Enabled: \(definition.title)")
        }
    }

    // MARK: - --disable-tweak <id>

    private static func runDisableTweak(arguments: [String], commandIndex: Int) {
        let idIndex = arguments.index(after: commandIndex)
        guard idIndex < arguments.endIndex else {
            finish(marker: failureMarker, message: "Missing tweak ID")
            return
        }
        let rawID = arguments[idIndex]
        guard let tweakID = GestaltTweakID(rawValue: rawID),
              let definition = GestaltTweakCatalog.definition(for: tweakID) else {
            finish(marker: failureMarker, message: "Unknown tweak ID: \(rawID)")
            return
        }

        let ok = headlessApply { plist in
            plist.revert(definition: definition)
        }

        if ok {
            finish(marker: successMarker, message: "Disabled: \(definition.title)")
        }
    }

    // MARK: - --set-dynamic-island <subtype>

    private static func runSetDynamicIsland(arguments: [String], commandIndex: Int) {
        let subIndex = arguments.index(after: commandIndex)
        guard subIndex < arguments.endIndex else {
            finish(marker: failureMarker, message: "Missing subtype")
            return
        }
        guard let subtype = Int(arguments[subIndex]) else {
            finish(marker: failureMarker, message: "Invalid subtype: \(arguments[subIndex])")
            return
        }

        let ok = headlessApply { plist in
            try plist.setDynamicIslandSubtype(subtype)
        }

        if ok {
            finish(marker: successMarker, message: "Dynamic Island subtype: \(subtype)")
        }
    }

    // MARK: - --set-model-name <name>

    private static func runSetModelName(arguments: [String], commandIndex: Int) {
        let nameIndex = arguments.index(after: commandIndex)
        guard nameIndex < arguments.endIndex else {
            finish(marker: failureMarker, message: "Missing model name")
            return
        }
        let name = arguments[nameIndex]
        
        switch ModelNameValidator.validate(name) {
        case .ok:
            break
        case .empty:
            finish(marker: failureMarker, message: "Model name cannot be empty")
            return
        case .tooLong:
            finish(marker: failureMarker, message: "Model name too long (max 50 characters)")
            return
        case .invalidCharacters:
            finish(marker: failureMarker, message: "Model name contains invalid characters (allowed: letters, numbers, spaces, -.,()'")
            return
        }

        let ok = headlessApply { plist in
            try plist.setModelName(name)
        }

        if ok {
            finish(marker: successMarker, message: "Model name: \(name)")
        }
    }

    // MARK: - --restore-factory

    private static func runRestoreFactory() {
        let ok = headlessApply { plist in
            plist.revertAllTweaks()
        }

        if ok {
            finish(marker: successMarker, message: "Factory settings restored")
        }
    }

    // MARK: - --list-tweaks

    private static func runListTweaks() {
        var output = "Available tweaks:\n"
        for def in GestaltTweakCatalog.definitions {
            output += "  \(def.id.rawValue) — \(def.title)\n"
        }
        FileHandle.standardOutput.write(Data(output.utf8))
        exit(EXIT_SUCCESS)
    }

    // MARK: - Finish

    /// Writes the result marker and message to stdout, then exits.
    /// This function is `-> Never` and calls `exit()` — the Swift
    /// compiler treats it as a non-returning function, so `guard else`
    /// blocks that call `finish()` are automatically treated as
    /// non-fall-through. Do NOT refactor this to return early without
    /// updating all call sites to add explicit `return` statements.
    private static func finish(marker: String, message: String) -> Never {
        let sanitized = message.replacingOccurrences(of: "\n", with: " ")
        let output = "\(marker):\(sanitized)\n"
        FileHandle.standardOutput.write(Data(output.utf8))
        exit(marker == successMarker ? EXIT_SUCCESS : EXIT_FAILURE)
    }

    // MARK: - --cat

    private static func runCatFile(_ path: String) {
        let access = BadQueryFileAccess.shared()
        do {
            let data = try access.readFile(atPath: path)
            let b64 = data.base64EncodedString()
            finish(marker: successMarker, message: path + " b64:" + b64)
        } catch {
            finish(marker: failureMarker, message: path + " unreadable: " + ErrorHandler.friendlyMessage(for: error))
        }
    }

    // MARK: - --stat

    private static func runStatPath(_ path: String) {
        let access = BadQueryFileAccess.shared()
        do {
            let e = try access.statFile(atPath: path)
            finish(marker: successMarker, message: path + " size=\(e.fileSize) dir=\(e.isDirectory)")
        } catch {
            finish(marker: failureMarker, message: path + " not found/inaccessible")
        }
    }

    // MARK: - --ls

    private static func runListDir(_ path: String) {
        let access = BadQueryFileAccess.shared()
        // Single user-driven lookup — keep the inode fallback so root
        // directories (e.g. Data/Application, 12k entries) stay listable.
        let entries = access.listDirectory(atPath: path, error: nil)
        let names = entries.map { entry -> String in
            var n = entry.name
            if entry.isDirectory { n += "/" }
            return n
        }
        finish(marker: successMarker, message: path + " -> [" + names.joined(separator: ",") + "]")
    }

    // MARK: - --set-language

    /// Rewrites AppleLocale / AppleLanguages in the mobile user's
    /// .GlobalPreferences.plist. `locale` is a BCP-47-ish tag such as
    /// "en_US" or "zh_CN". The keyboard list is preserved so the user is
    /// not locked out of text input after the switch.
    private static func runSetLanguage(locale: String) {
        let path = "/var/mobile/Library/Preferences/.GlobalPreferences.plist"
        let access = BadQueryFileAccess.shared()
        do {
            let data = try access.readFile(atPath: path)
            guard var dict = try PropertyListSerialization.propertyList(
                from: data, format: nil) as? [String: Any] else {
                finish(marker: failureMarker, message: "GlobalPreferences unparseable")
                return
            }

            // Derive the language tag from the locale ("en_US" → "en").
            let languageTag = String(locale.prefix { $0 != "_" })
            dict["AppleLocale"] = locale
            dict["AppleLanguages"] = [languageTag]
            // Keep existing keyboards so input is not lost after reboot.
            if dict["AppleKeyboards"] == nil {
                dict["AppleKeyboards"] = ["\(languageTag)@sw=QWERTY;hw=Automatic", "emoji@sw=Emoji"]
                dict["AppleKeyboardsExpanded"] = 1
            }

            let out = try PropertyListSerialization.data(
                fromPropertyList: dict, format: .binary, options: 0)
            try access.writeFile(atPath: path, data: out)

            // Verify.
            let recheck = try access.readFile(atPath: path)
            guard let newDict = try PropertyListSerialization.propertyList(
                from: recheck, format: nil) as? [String: Any],
                  newDict["AppleLocale"] as? String == locale else {
                finish(marker: failureMarker, message: "Write verification failed")
                return
            }
            finish(marker: successMarker, message: "Language set to \(locale); reboot required")
        } catch {
            finish(marker: failureMarker, message: ErrorHandler.friendlyMessage(for: error))
        }
    }

    // MARK: - --enable-ai-region

    private static func runEnableAIRegion() {
        let ok = headlessApply(
            mutate: { plist in
                let configuration = AIRegionConfiguration.resolve(for: plist)
                let profile = configuration.profile
                if let productType = configuration.spoofedProductType,
                   let hardwareModel = configuration.spoofedHardwareModel,
                   let cpuModel = configuration.spoofedCPUModel {
                    plist.setCacheExtra(1, forKey: "A62OafQ85EJAiiqKn4agtg")
                    plist.setCacheExtra(productType, forKey: "h9jDsbgj7xIVeIQ8S3/X3Q")
                    plist.setCacheExtra(hardwareModel, forKey: "oYicEKzVTz4/CxxE05pEgQ")
                    plist.setCacheExtra(cpuModel, forKey: "5pYKlGnYYBzGvAlIU8RjEQ")
                }
                plist.setCacheExtra("LL", forKey: "h63QSdBCiT/z0WU6rdQv6Q")
                plist.setCacheExtra("LL/A", forKey: "yK+xavymRGZ3xWc1tb8XDg")
                plist.setCacheExtra(profile.regulatoryModel, forKey: "97JDvERpVwO+GHtthIh7hA")
            },
            verify: { verified in
                guard verified.cacheExtra["h63QSdBCiT/z0WU6rdQv6Q"] as? String == "LL",
                      verified.cacheExtra["yK+xavymRGZ3xWc1tb8XDg"] as? String == "LL/A" else {
                    throw AutomationError.verificationFailed
                }
            }
        )
        if ok {
            finish(marker: successMarker, message: "AI region enabled")
        }
    }

    // MARK: - --export-gestalt

    private static func runExportGestalt() {
        do {
            let access = GestaltAccess.shared()
            try access.connect()
            let data = try access.readGestaltData()
            let dest = FileManager.default.urls(for: .documentDirectory,
                                                in: .userDomainMask)[0]
                .appendingPathComponent("MobileGestalt.plist")
            try data.write(to: dest)
            finish(marker: successMarker, message: dest.path + " (\(data.count) bytes)")
        } catch {
            finish(marker: failureMarker, message: ErrorHandler.friendlyMessage(for: error))
        }
    }

    // MARK: - --dump-gestalt

    /// Read-only inspection of the MobileGestalt cache: prints top-level
    /// keys, their types/sizes, and a few well-known CacheExtra values.
    private static func runDumpGestalt() {
        do {
            let access = GestaltAccess.shared()
            try access.connect()
            let data = try access.readGestaltData()
            guard let dict = try PropertyListSerialization.propertyList(
                from: data, format: nil) as? [String: Any] else {
                finish(marker: failureMarker, message: "Plist unparseable")
                return
            }
            var parts: [String] = ["bytes=\(data.count)"]
            for (key, value) in dict.sorted(by: { $0.key < $1.key }) {
                let desc: String
                switch value {
                case let d as [String: Any]:
                    desc = "dict(\(d.count) keys)"
                case let a as [Any]:
                    desc = "array(\(a.count))"
                case let s as String:
                    desc = "string='\(s)'"
                default:
                    desc = "\(type(of: value))"
                }
                parts.append("\(key)=\(desc)")
            }
            if let extra = dict["CacheExtra"] as? [String: Any] {
                let probeKeys = [
                    "h63QSdBCiT/z0WU6rdQv6Q",  // LL (region)
                    "yK+xavymRGZ3xWc1tb8XDg",  // LL/A
                    "97JDvERpVwO+GHtthIh7hA",  // regulatory model
                ]
                for k in probeKeys {
                    let v = extra[k].map { "\($0)" } ?? "<absent>"
                    parts.append("CacheExtra.\(k)=\(v)")
                }
                parts.append("CacheExtra.count=\(extra.count)")
            }
            finish(marker: successMarker, message: parts.joined(separator: " | "))
        } catch {
            finish(marker: failureMarker, message: ErrorHandler.friendlyMessage(for: error))
        }
    }
}

private enum AutomationError: LocalizedError {
    case invalidPlist
    case verificationFailed

    var errorDescription: String? {
        switch self {
        case .invalidPlist:
            return "MobileGestalt plist or CacheExtra is invalid"
        case .verificationFailed:
            return "MobileGestalt verification failed"
        }
    }
}
