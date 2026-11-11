//
//  ContainerMetadata.swift
//  GestaltKitTool
//
//  Shared utilities for reading iOS app container metadata and computing directory sizes.
//

import Foundation

// MARK: - ContainerMetadata

/// Shared helper for reading iOS app container metadata and computing
/// directory sizes.
///
/// All functions are `nonisolated` and safe to call from background queues.
/// `BadQueryFileAccess` is `@unchecked Sendable` (stateless singleton).
enum ContainerMetadata {

    // MARK: - Known Container Roots

    /// iOS app data container root.
    nonisolated static let appDataRoot = "/var/mobile/Containers/Data"

    /// The metadata plist filename used by MobileContainerManager.
    nonisolated static let metadataFilename = ".com.apple.mobile_container_manager.metadata.plist"

    // MARK: - Bundle ID Extraction

    /// Reads the `MCMMetadataIdentifier` (bundle ID) from a container's
    /// metadata plist. Returns nil if the file is missing, unreadable,
    /// or doesn't contain the expected key.
    static nonisolated func bundleId(
        fileAccess: BadQueryFileAccess,
        containerPath: String
    ) -> String? {
        let metadataPath = containerPath + "/" + metadataFilename
        guard let data = try? fileAccess.readFile(atPath: metadataPath) else { return nil }
        return bundleId(from: data)
    }

    /// Extracts `MCMMetadataIdentifier` from raw metadata plist data.
    static nonisolated func bundleId(from data: Data) -> String? {
        var format = PropertyListSerialization.PropertyListFormat.binary
        guard let plist = try? PropertyListSerialization.propertyList(
            from: data, options: [], format: &format
        ) as? [String: Any] else { return nil }
        return plist["MCMMetadataIdentifier"] as? String
    }

    // MARK: - Container Name Validation

    /// True when a directory name looks like an MCM container UUID
    /// (36 chars, 4 dashes). Shared by all scanner/cleanup loops.
    static nonisolated func isContainerUUID(_ name: String) -> Bool {
        name.count == 36 && name.filter { $0 == "-" }.count == 4
    }

    // MARK: - Container Resolution

    /// Resolves a bundle ID to its data container path by scanning
    /// `/var/mobile/Containers/Data` subdirectories for a matching
    /// metadata plist. Returns nil if not found.
    ///
    /// Uses the no-fallback listing: over 12k containers, a denied
    /// lease must mean "skip", never a 350K-inode fsgetpath scan.
    static nonisolated func resolveContainerPath(
        fileAccess: BadQueryFileAccess,
        bundleId: String
    ) -> String? {
        let entries = fileAccess.listDirectory(atPath: appDataRoot, error: nil)
        for entry in entries where entry.isDirectory {
            if let bid = self.bundleId(fileAccess: fileAccess, containerPath: entry.fullPath),
               bid == bundleId {
                return entry.fullPath
            }
        }
        return nil
    }

    /// Finds the system container (under /var/containers/Data/System)
    /// owned by `bundleId` — e.g. "com.apple.mobileactivationd".
    /// Single shared implementation (previously duplicated in
    /// ActivationReport and DeviceDashboard).
    static nonisolated func findSystemContainer(
        fileAccess: BadQueryFileAccess,
        ownerBundleId bundleId: String
    ) -> (uuid: String, fullPath: String)? {
        let entries = fileAccess.listDirectory(
            atPath: "/private/var/containers/Data/System", error: nil)
        for entry in entries where entry.isDirectory {
            guard isContainerUUID(entry.name) else { continue }
            if let bid = self.bundleId(
                fileAccess: fileAccess, containerPath: entry.fullPath),
               bid == bundleId {
                return (entry.name, entry.fullPath as String)
            }
        }
        return nil
    }

    // MARK: - Directory Size

    /// Computes the total size (in bytes) and file count of a directory
    /// tree up to `maxDepth` levels deep. Uses the no-fallback
    /// recursive listing — callers are bulk operations (safe cleanup,
    /// app data scan) where a denied lease must mean "skip this
    /// subtree", never a 350K-inode fsgetpath scan.
    static nonisolated func directorySize(
        fileAccess: BadQueryFileAccess,
        path: String,
        maxDepth: Int = 5
    ) -> (size: Int64, count: Int) {
        let entries = fileAccess.recursiveListNoFallback(atPath: path, maxDepth: maxDepth, error: nil)
        var totalSize: Int64 = 0
        var totalCount = 0
        for entry in entries where !entry.isDirectory {
            totalSize += entry.fileSize
            totalCount += 1
        }
        return (totalSize, totalCount)
    }

    /// Computes only the total size (in bytes) of a directory tree.
    /// Convenience wrapper around `directorySize`.
    static nonisolated func totalSize(
        fileAccess: BadQueryFileAccess,
        path: String,
        maxDepth: Int = 5
    ) -> Int64 {
        directorySize(fileAccess: fileAccess, path: path, maxDepth: maxDepth).size
    }

    // MARK: - Display Name

    /// Best-effort display name from a bundle ID. Uses the last segment
    /// of the dot-separated bundle ID (e.g. "com.tencent.xin" → "xin").
    static nonisolated func bestDisplayName(bundleId: String?) -> String {
        guard let bundleId, !bundleId.isEmpty else { return "Unknown" }
        return bundleId.split(separator: ".").last.map(String.init) ?? bundleId
    }
}
