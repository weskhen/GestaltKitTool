//
//  SystemContainerScanner.swift
//  GestaltKitTool
//
//  Enumerates /var/containers/Data/System containers and resolves
//  each one's owner bundle ID from its MCM metadata plist.
//  Read-only; backed by the verified worse_query escape.
//

import Combine
import Foundation

// MARK: - Model

/// A system container discovered under /var/containers/Data/System.
struct SystemContainer: Identifiable, Hashable {
    /// UUID directory name.
    let uuid: String
    /// Absolute path, e.g.
    /// /private/var/containers/Data/System/<UUID>
    let fullPath: String
    /// Owner bundle ID from MCMMetadataIdentifier
    /// (e.g. com.apple.mobileactivationd), "unknown" if unreadable.
    let ownerBundleID: String
    /// True when the owner is a high-value target (activation
    /// records, activation data, springboard…).
    var isSensitive: Bool {
        let o = ownerBundleID.lowercased()
        return o.contains("activation") || o.contains("springboard")
            || o.contains("accountsd") || o.contains("mdmd")
    }
    var id: String { uuid }
}

// MARK: - Scanner

/// Scans /var/containers/Data/System once and publishes the
/// container list. All heavy work runs off-main via Task.detached.
@MainActor
final class SystemContainerScanner: ObservableObject {

    @Published private(set) var containers: [SystemContainer] = []
    @Published private(set) var isScanning = false
    @Published private(set) var scanError: String?

    private let fileAccess = BadQueryFileAccess.shared()
    private(set) var hasScanned = false

    /// Entry names that are files (e.g. ".DS_Store") or
    /// non-UUID directories are skipped.

    // MARK: Scan

    func scan() {
        guard !isScanning else { return }
        isScanning = true
        scanError = nil

        let fileAccess = self.fileAccess

        Task.detached(priority: .userInitiated) { [weak self] in
            let result = Self.performScan(fileAccess: fileAccess)
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.containers = result.containers
                self.scanError = result.error
                self.isScanning = false
                self.hasScanned = true
            }
        }
    }

    /// Synchronous scan body — static so it can't touch
    /// @MainActor state directly.
    private nonisolated static func performScan(
        fileAccess: BadQueryFileAccess
    ) -> (containers: [SystemContainer], error: String?) {
        var listError: NSError?
        let entries = fileAccess.listDirectory(
            atPath: "/private/var/containers/Data/System",
            error: &listError
        )

        // Dedupe by name: fsgetpath fallback can return the same
        // inode twice via /var and /private/var spellings.
        var seen = Set<String>()
        var containers: [SystemContainer] = []

        for entry in entries where entry.isDirectory {
            guard ContainerMetadata.isContainerUUID(entry.name), !seen.contains(entry.name) else {
                continue
            }
            seen.insert(entry.name)

            let owner = ContainerMetadata.bundleId(
                fileAccess: fileAccess, containerPath: entry.fullPath
            ) ?? "unknown"

            containers.append(SystemContainer(
                uuid: entry.name,
                fullPath: entry.fullPath as String,
                ownerBundleID: owner
            ))
        }

        containers.sort { a, b in
            a.ownerBundleID.localizedCaseInsensitiveCompare(
                b.ownerBundleID
            ) == .orderedAscending
        }

        if containers.isEmpty, let err = listError as NSError? {
            return ([], err.localizedDescription)
        }
        return (containers, nil)
    }

    // MARK: Derived views

    /// Containers grouped by owner bundle ID, sorted by owner.
    var groupedByOwner: [(owner: String, containers: [SystemContainer])] {
        Dictionary(grouping: containers, by: \.ownerBundleID)
            .map { (owner: $0.key, containers: $0.value) }
            .sorted { $0.owner.localizedCaseInsensitiveCompare($1.owner) == .orderedAscending }
    }

    /// The container owned by com.apple.mobileactivationd, if
    /// present — holds data_ark.plist + activation_record.plist.
    var activationContainer: SystemContainer? {
        containers.first {
            $0.ownerBundleID == "com.apple.mobileactivationd"
        }
    }
}
