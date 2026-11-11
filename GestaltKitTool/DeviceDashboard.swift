//
//  DeviceDashboard.swift
//  GestaltKitTool
//
//  Three read-side features:
//  1. Activation credential backup export (data_ark + activation_record)
//  2. Device identity dashboard (MobileGestalt cache → key fields)
//  3. Keychain reachability probe (exploratory, expect sandbox blocks)
//

import Combine
import Foundation
import Security

// MARK: - 1. Activation Credential Backup

/// Reads both activation plists and packages them for export:
/// raw plists + a JSON summary with the binary fields base64'd.
@MainActor
final class ActivationBackupExporter: ObservableObject {

    @Published private(set) var isExporting = false
    @Published private(set) var exportURL: URL?
    @Published private(set) var errorMessage: String?

    private let fileAccess = BadQueryFileAccess.shared()

    func export(from container: SystemContainer?) async {
        guard !isExporting else { return }
        isExporting = true
        errorMessage = nil
        exportURL = nil
        defer { isExporting = false }

        var target = container
        if target == nil {
            target = await Self.findActivationContainer(fileAccess)
        }
        guard let target else {
            errorMessage = String(localized: "mobileactivationd container not found — scan System Containers first.")
            return
        }

        let arkPath = (target.fullPath as NSString)
            .appendingPathComponent("Library/internal/data_ark.plist")
        let recPath = (target.fullPath as NSString)
            .appendingPathComponent("Library/activation_records/activation_record.plist")

        let fa = fileAccess
        let (arkData, recData): (Data?, Data?) = await Task.detached(priority: .userInitiated) {
            let a = try? fa.readFile(atPath: arkPath)
            let r = try? fa.readFile(atPath: recPath)
            return (a, r)
        }.value

        guard arkData != nil || recData != nil else {
            errorMessage = String(localized: "Both activation plists unreadable on this device.")
            return
        }

        // JSON summary: plist keys with binary fields base64-encoded.
        var summary: [String: Any] = [
            "exportedAt": ISO8601DateFormatter().string(from: Date()),
            "containerUUID": target.uuid,
        ]
        if let ark = arkData,
           let dict = (try? PropertyListSerialization.propertyList(
               from: ark, options: [], format: nil)) as? [String: Any] {
            summary["data_ark.plist"] = Self.jsonify(dict)
        }
        if let rec = recData,
           let dict = (try? PropertyListSerialization.propertyList(
               from: rec, options: [], format: nil)) as? [String: Any] {
            summary["activation_record.plist"] = Self.jsonify(dict)
        }

        do {
            let json = try JSONSerialization.data(
                withJSONObject: summary,
                options: [.prettyPrinted, .sortedKeys])
            let stamp = Self.timestamp()
            let url = try ExportFileManager.makeExportURL(
                fileName: "activation-backup-\(stamp).json",
                data: json)
            exportURL = url
        } catch {
            errorMessage = String(
                format: String(localized: "Failed to save report: %@"),
                error.localizedDescription)
        }
    }

    private nonisolated static func jsonify(_ dict: [String: Any]) -> [String: Any] {
        var out: [String: Any] = [:]
        for (k, v) in dict {
            if let data = v as? Data {
                out[k] = [
                    "encoding": "base64",
                    "bytes": data.count,
                    "value": data.base64EncodedString(),
                ]
            } else if let d = v as? Date {
                out[k] = d.timeIntervalSince1970
            } else {
                out[k] = v
            }
        }
        return out
    }

    private nonisolated static func timestamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        f.timeZone = .current
        return f.string(from: Date())
    }

    private nonisolated static func findActivationContainer(
        _ fa: BadQueryFileAccess
    ) async -> SystemContainer? {
        // Shared lookup (ContainerMetadata.findSystemContainer).
        guard let hit = ContainerMetadata.findSystemContainer(
            fileAccess: fa, ownerBundleId: "com.apple.mobileactivationd"
        ) else { return nil }
        return SystemContainer(
            uuid: hit.uuid,
            fullPath: hit.fullPath,
            ownerBundleID: "com.apple.mobileactivationd")
    }
}

// MARK: - 2. Device Identity Dashboard

/// One key field per row of the dashboard.
struct DeviceInfoRow: Identifiable {
    let key: String
    let displayValue: String
    var id: String { key }
}

@MainActor
final class DeviceDashboardModel: ObservableObject {

    @Published private(set) var rows: [DeviceInfoRow] = []
    @Published private(set) var isRunning = false
    @Published private(set) var errorMessage: String?

    /// Optional hook for headless mode: called once with the rows
    /// so they can be mirrored to syslog.
    var runOnRead: (([DeviceInfoRow]) -> Void)?

    private let fileAccess = BadQueryFileAccess.shared()

    /// Gestalt CacheExtra keys shown on the dashboard, in display
    /// order. Base64 key names are the actual plist keys (verified
    /// in GestaltTweaks.swift / GestaltViewModel.swift).
    private static let dashboardKeys: [(key: String, title: String)] = [
        ("h9jDsbgj7xIVeIQ8S3/X3Q", "Device Model (ProductType)"),
        ("oYicEKzVTz4/CxxE05pEgQ", "Hardware Model"),
        ("A62OafQ85EJAiiqKn4agtg", "Model Number Flag"),
        ("h63QSdBCiT/z0WU6rdQv6Q", "Region Code"),
        ("yK+xavymRGZ3xWc1tb8XDg", "Region Info"),
        ("97JDvERpVwO+GHtthIh7hA", "Regulatory Model"),
        ("5pYKlGnYYBzGvAlIU8RjEQ", "CPU Model"),
        ("YlEtTtHlNesRBMal1CqRaA", "Dynamic Island Capability"),
        ("2OOJf1VhaM7NxfRok3HbWQ", "Always-On Display (1/2)"),
        ("j8/Omm6s1lsmTDFsXjsBfA", "Always-On Display (2/2)"),
        ("QHxt+hGLaBPbQJbXiUJX3w", "Boot Chime Capability"),
        ("37NVydb//GP/GrhuTN+exg", "Charge Limit Menu"),
        ("yZf3GTRMGTuwSV/lD7Cagw", "Tap to Wake"),
        ("CwvKxM2cEogD3p+HYgaW0Q", "Camera Control Settings (1/2)"),
        ("oOV1jhJbdV3AddkcCg0AEA", "Camera Control Settings (2/2)"),
        ("yhHcB0iH0d1XzPO/CFd3ow", "Apple Pencil Settings"),
        ("cT44WE1EohiwRzhsZ8xEsw", "Action Button Settings"),
        ("HCzWusHQwZDea6nNhaKndw", "Collision SOS"),
        ("qeaj75wk3HF4DwQ8qbIi7g", "Stage Manager Support"),
        ("9MZ5AdH43csAUaj/dU+IQ", "iPad Apps Compatibility"),
    ]

    func run() {
        guard !isRunning else { return }
        isRunning = true
        errorMessage = nil
        gktlLog("[GKTL-Dashboard] run() started")

        let fa = fileAccess
        Task.detached(priority: .userInitiated) { [weak self] in
            let cachePath = "/private/var/containers/Shared/SystemGroup/systemgroup.com.apple.mobilegestaltcache/Library/Caches/com.apple.MobileGestalt.plist"
            guard let data = try? fa.readFile(atPath: cachePath),
                  let plist = (try? PropertyListSerialization.propertyList(
                      from: data, options: [], format: nil)) as? [String: Any]
            else {
                gktlLog("[GKTL-Dashboard] READ FAILED for MobileGestalt cache")
                await MainActor.run {
                    self?.errorMessage = String(localized: "Unable to read MobileGestalt cache.")
                    self?.isRunning = false
                }
                return
            }

            var newRows: [DeviceInfoRow] = []
            // CacheExtra keys are the base64 names; map to friendly titles.
            var titleMap: [String: String] = [:]
            for (key, title) in Self.dashboardKeys {
                titleMap[key] = title
            }
            if let cacheExtra = plist["CacheExtra"] as? [String: Any] {
                // Show every key present in the cache, using the
                // friendly title when known, raw key otherwise.
                for (key, v) in cacheExtra.sorted(by: { $0.key < $1.key }) {
                    let title = titleMap[key] ?? key
                    newRows.append(DeviceInfoRow(
                        key: title,
                        displayValue: Self.displayString(v)))
                }
            }
            if newRows.isEmpty {
                // Fallback: dump top-level keys (layout differs by OS).
                for (k, v) in plist.sorted(by: { $0.key < $1.key }) {
                    if k == "CacheExtra" { continue }
                    newRows.append(DeviceInfoRow(key: k, displayValue: Self.displayString(v)))
                }
            }

            await MainActor.run {
                self?.rows = newRows
                self?.isRunning = false
                gktlLog("[GKTL-Dashboard] finished with \(newRows.count) rows")
                self?.runOnRead?(newRows)
            }
        }
    }

    private nonisolated static func displayString(_ v: Any) -> String {
        if let s = v as? String { return s }
        if let d = v as? Data {
            return d.base64EncodedString().prefix(24) + "…(\(d.count)B)"
        }
        if let n = v as? NSNumber { return n.stringValue }
        return String(describing: v).prefix(40).description
    }
}

// MARK: - 3. Keychain Reachability Probe

/// Result of one keychain query attempt.
struct KeychainProbeResult: Identifiable {
    let scope: String        // e.g. "kSecMatchLimitAll, generic passwords"
    let status: OSStatus
    let count: Int
    let note: String
    var id: String { scope }

    var isReadable: Bool { status == errSecSuccess && count > 0 }

    /// True when the query executed with permission but found no items.
    /// errSecItemNotFound means the keychain let us look; the access group
    /// is just empty. That is NOT a sandbox block.
    var isReachableButEmpty: Bool { status == errSecItemNotFound }
}

@MainActor
final class KeychainProbeModel: ObservableObject {

    @Published private(set) var results: [KeychainProbeResult] = []
    @Published private(set) var isRunning = false

    func run() {
        guard !isRunning else { return }
        isRunning = true

        Task.detached(priority: .userInitiated) { [weak self] in
            var out: [KeychainProbeResult] = []

            // 1. Our own keychain (baseline — should always work).
            out.append(Self.query(
                scope: "This app's keychain (kSecClassGenericPassword, wide)",
                secClass: kSecClassGenericPassword
            ))
            // 2. All certificates.
            out.append(Self.query(
                scope: "All certificates (kSecClassCertificate, wide)",
                secClass: kSecClassCertificate
            ))
            // 3. All identities.
            out.append(Self.query(
                scope: "All identities (kSecClassIdentity, wide)",
                secClass: kSecClassIdentity
            ))
            // 4. Keys.
            out.append(Self.query(
                scope: "All keys (kSecClassKey, wide)",
                secClass: kSecClassKey
            ))
            // 5. Internet passwords — often granted to networked apps.
            out.append(Self.query(
                scope: "Internet passwords (kSecClassInternetPassword, wide)",
                secClass: kSecClassInternetPassword
            ))

            // Log every result to syslog for automated analysis.
            gktlLog("[GKTL-Keychain] === KEYCHAIN PROBE START ===")
            for r in out {
                gktlLog("[GKTL-Keychain] PROBE status=\(r.status) count=\(r.count) scope=\(r.scope) note=\(r.note)")
            }
            gktlLog("[GKTL-Keychain] === KEYCHAIN PROBE END ===")

            await MainActor.run {
                self?.results = out
                self?.isRunning = false
            }
        }
    }

    private nonisolated static func query(
        scope: String, secClass: CFString
    ) -> KeychainProbeResult {
        let q: [String: Any] = [
            kSecClass as String: secClass,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &item)
        let arr = item as? [[String: Any]]
        let count = arr?.count ?? 0
        // Log accessible attribute NAMES (not values) for analysis.
        if status == errSecSuccess, let arr {
            let names: [String] = arr.prefix(10).compactMap {
                ($0[kSecAttrLabel as String] as? String)
                    ?? ($0[kSecAttrServer as String] as? String)
                    ?? ($0[kSecAttrService as String] as? String)
            }
            if !names.isEmpty {
                gktlLog("[GKTL-Keychain] ITEMS sample=\(names.joined(separator: ", "))")
            }
        }
        return KeychainProbeResult(
            scope: scope,
            status: status,
            count: count,
            note: status == errSecSuccess
                ? "\(count) items visible"
                : (status == errSecItemNotFound
                    ? "Accessible but empty (no items in this access group)"
                    : Self.statusMessage(status))
        )
    }

    private nonisolated static func statusMessage(_ s: OSStatus) -> String {
        switch s {
        case errSecItemNotFound: return "errSecItemNotFound (no items in this access group)"
        case errSecMissingEntitlement: return "errSecMissingEntitlement (blocked — no keychain-access entitlement)"
        case errSecInteractionNotAllowed: return "errSecInteractionNotAllowed (blocked by sandbox)"
        case errSecNotAvailable: return "errSecNotAvailable (no valid trust domain)"
        default: return "OSStatus \(s)"
        }
    }
}
