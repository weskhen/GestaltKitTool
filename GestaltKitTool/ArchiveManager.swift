//
//  ArchiveManager.swift
//  GestaltKitTool
//
//  Copy-style archive (not move/delete, since bad_query is read-only).
//  Inspired by FilzaSlop 1.0.3's Archive feature — but GestaltKitTool's
//  underlying bad_query sandbox escape provides READ-ONLY access, so we
//  cannot truly "move" source files (no write/delete lease on the origin
//  container). We instead copy a snapshot to the app's own Documents
//  folder, which is always writable.
//
//  "Restore" means copy the archive snapshot back to the Export temp
//  directory so it can be shared. True restore-to-original-location is
//  also impossible without a write-capable escape.
//

import Foundation

enum ArchiveError: LocalizedError {
    case noSuchFile(String)
    case readFailed(String, Error)
    case writeFailed(String, Error)
    case directoryEnumerationFailed(String)
    case sourceIsDirectoryButCouldNotList(String)
    case nameCollision(String)
    case cancel

    var errorDescription: String? {
        switch self {
        case .noSuchFile(let p):
            return "Source file not found: \(p)"
        case .readFailed(let p, let e):
            return "Failed to read \(p): \(e.localizedDescription)"
        case .writeFailed(let p, let e):
            return "Failed to write \(p): \(e.localizedDescription)"
        case .directoryEnumerationFailed(let p):
            return "Failed to enumerate directory: \(p)"
        case .sourceIsDirectoryButCouldNotList(let p):
            return "Source is a directory but contents could not be listed: \(p)"
        case .nameCollision(let p):
            return "An item with this name already exists in the archive: \(p). Delete or rename the existing archive entry first."
        case .cancel:
            return "Cancelled"
        }
    }
}

/// Metadata saved alongside each archived entry so we know where it
/// originally came from and when it was snapshotted.
struct ArchivedItemMetadata: Codable, Hashable {
    let originalPath: String
    let archivedAt: Date
    let isDirectory: Bool
    let totalByteSize: Int64
}

enum ArchiveManager {

    // MARK: - Paths

    /// The archive folder lives in the app's Documents directory, which
    /// is always writable. Each archive entry (file or directory tree)
    /// gets its own subdirectory under here.
    static let archiveRoot: URL = {
        let fm = FileManager.default
        let docs = (try? fm.url(for: .documentDirectory,
                                in: .userDomainMask,
                                appropriateFor: nil,
                                create: true))
            ?? fm.temporaryDirectory.appendingPathComponent("GestaltKitTool_Docs_fallback",
                                                            isDirectory: true)
        let dir = docs.appendingPathComponent("GestaltKitTool Archive", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true,
                                attributes: [.posixPermissions: 0o700])
        return dir
    }()

    /// Absolute filesystem path used by the Explorer so users can drill
    /// into the archive like any other directory.
    static var archiveRootPath: String {
        archiveRoot.path
    }

    private static let metadataFileName = ".gktl_archive_metadata.json"

    // MARK: - Helpers

    /// Filename used for the top-level archive folder. Because the
    /// archive is rooted in the app Documents dir, the Explorer will
    /// show this as a directory entry.
    static let archiveFolderName = "GestaltKitTool Archive"

    /// Returns true if `path` points to (or lives under) the archive
    /// directory. Used to avoid archiving the archive itself.
    static func isPathInsideArchive(_ path: String) -> Bool {
        let normalized = (path as NSString).standardizingPath
        let archiveNorm = (archiveRootPath as NSString).standardizingPath
        return normalized == archiveNorm
            || normalized.hasPrefix(archiveNorm + "/")
    }

    // MARK: - Public API

    /// Archive a single file or directory tree by COPYING it from the
    /// source (read via BadQueryFileAccess) into the archive root.
    ///
    /// - Parameters:
    ///   - entry: A BQFileEntry returned by a directory listing.
    ///   - fileAccess: BadQueryFileAccess instance for reading.
    ///   - onByteCopied: Optional progress callback (bytes, totalEstimate).
    ///   - cancelled: Checked between file chunks to abort early.
    /// - Returns: The final archived path (inside archiveRoot) and the
    ///   count of bytes written.
    @discardableResult
    static func archiveEntry(
        _ entry: BQFileEntry,
        fileAccess: BadQueryFileAccess,
        onByteCopied: ((_ copied: Int64, _ totalEstimate: Int64) -> Void)? = nil,
        cancelled: () -> Bool = { false }
    ) throws -> (archivedPath: String, bytesWritten: Int64) {
        try archiveEntry(
            originalPath: entry.fullPath,
            name: entry.name,
            isDirectory: entry.isDirectory,
            estimatedSize: entry.fileSize,
            fileAccess: fileAccess,
            onByteCopied: onByteCopied,
            cancelled: cancelled
        )
    }

    /// Low-level variant that works without a BQFileEntry (e.g. for
    /// synthetic entries like the Archive folder itself).
    @discardableResult
    static func archiveEntry(
        originalPath: String,
        name: String,
        isDirectory: Bool,
        estimatedSize: Int64,
        fileAccess: BadQueryFileAccess,
        onByteCopied: ((_ copied: Int64, _ totalEstimate: Int64) -> Void)? = nil,
        cancelled: () -> Bool = { false }
    ) throws -> (archivedPath: String, bytesWritten: Int64) {
        if isPathInsideArchive(originalPath) {
            throw ArchiveError.nameCollision(name)
        }
        if cancelled() { throw ArchiveError.cancel }

        let safeName = sanitizeName(name)
        let destination = archiveRoot.appendingPathComponent(safeName, isDirectory: isDirectory)
        let fm = FileManager.default

        // Collision: user is trying to archive the same-named item twice.
        // Offer to overwrite — the caller decides. For the initial simple
        // integration we error out and tell the user to delete first.
        if fm.fileExists(atPath: destination.path) {
            throw ArchiveError.nameCollision(safeName)
        }

        var totalBytes: Int64 = 0

        if isDirectory {
            // Recursively copy the directory tree. Size estimate may be
            // off; we pass the known size as-is and let the progress
            // handler decide how to display it.
            try fm.createDirectory(at: destination,
                                   withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: 0o700])
            try copyDirectoryRecursive(
                fromPath: originalPath,
                toURL: destination,
                fileAccess: fileAccess,
                totalBytes: &totalBytes,
                totalEstimate: max(0, estimatedSize),
                onByteCopied: onByteCopied,
                cancelled: cancelled
            )
        } else {
            // Single file.
            try copySingleFile(
                fromPath: originalPath,
                toURL: destination,
                fileAccess: fileAccess,
                totalBytes: &totalBytes,
                totalEstimate: max(0, estimatedSize),
                onByteCopied: onByteCopied
            )
            if cancelled() {
                try? fm.removeItem(at: destination)
                throw ArchiveError.cancel
            }
        }

        // Write metadata alongside.
        let meta = ArchivedItemMetadata(
            originalPath: originalPath,
            archivedAt: Date(),
            isDirectory: isDirectory,
            totalByteSize: totalBytes
        )
        writeMetadata(meta, for: destination)

        return (destination.path, totalBytes)
    }

    /// True if an archive entry exists under the archive root with this
    /// name (collision check before archiving).
    static func hasArchivedItem(named name: String) -> Bool {
        let safe = sanitizeName(name)
        return FileManager.default.fileExists(
            atPath: archiveRoot.appendingPathComponent(safe).path
        )
    }

    /// List top-level archive entries with their metadata.
    static func listArchiveEntries() throws -> [(name: String, metadata: ArchivedItemMetadata, url: URL)] {
        let fm = FileManager.default
        let contents = try fm.contentsOfDirectory(
            at: archiveRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        var result: [(name: String, metadata: ArchivedItemMetadata, url: URL)] = []
        for url in contents {
            let name = url.lastPathComponent
            if let meta = readMetadata(for: url) {
                result.append((name: name, metadata: meta, url: url))
            } else {
                // Items without metadata are stray files. Still show them
                // so the user can clean them up manually.
                let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                let placeholder = ArchivedItemMetadata(
                    originalPath: url.path,
                    archivedAt: (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date(),
                    isDirectory: isDir,
                    totalByteSize: -1
                )
                result.append((name: name, metadata: placeholder, url: url))
            }
        }
        // Sort newest first.
        result.sort { $0.metadata.archivedAt > $1.metadata.archivedAt }
        return result
    }

    /// Delete an archived entry (file or directory) by name.
    static func deleteArchivedItem(named name: String) throws {
        let safe = sanitizeName(name)
        let url = archiveRoot.appendingPathComponent(safe)
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return }
        try fm.removeItem(at: url)
        // Also remove metadata if it lives outside (currently it's a
        // dot-file alongside — removal above would've taken it only if
        // the target was a directory). For single-file archives, the
        // metadata file is a sibling, so we delete it explicitly.
        let metaURL = url.deletingLastPathComponent()
            .appendingPathComponent(".\(safe).\(metadataFileName)")
        try? fm.removeItem(at: metaURL)
    }

    /// "Restore" = copy the archived snapshot to the Export temp dir so
    /// it can be shared with ShareLink. True restore to the original
    /// location is impossible with bad_query's read-only lease.
    @discardableResult
    static func restoreArchivedItemToExport(named name: String) throws -> URL {
        let safe = sanitizeName(name)
        let sourceURL = archiveRoot.appendingPathComponent(safe)
        let fm = FileManager.default
        guard fm.fileExists(atPath: sourceURL.sourceURL_fm_pathFix) else {
            throw ArchiveError.noSuchFile(sourceURL.path)
        }
        let exportDir = ExportFileManager.exportDir
        let dest = exportDir.appendingPathComponent(safe)
        try? fm.removeItem(at: dest)
        try fm.copyItem(at: sourceURL, to: dest)
        return dest
    }

    // MARK: - Private

    private static func sanitizeName(_ name: String) -> String {
        name
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "..", with: "_")
    }

    private static func copySingleFile(
        fromPath: String,
        toURL: URL,
        fileAccess: BadQueryFileAccess,
        totalBytes: inout Int64,
        totalEstimate: Int64,
        onByteCopied: ((Int64, Int64) -> Void)?
    ) throws {
        let data: Data
        do {
            data = try fileAccess.readFile(atPath: fromPath)
        } catch {
            throw ArchiveError.readFailed(fromPath, error)
        }
        do {
            try data.write(to: toURL, options: Data.WritingOptions.atomic)
        } catch {
            throw ArchiveError.writeFailed(toURL.path, error)
        }
        totalBytes += Int64(data.count)
        onByteCopied?(totalBytes, totalEstimate)
    }

    private static func copyDirectoryRecursive(
        fromPath: String,
        toURL: URL,
        fileAccess: BadQueryFileAccess,
        totalBytes: inout Int64,
        totalEstimate: Int64,
        onByteCopied: ((Int64, Int64) -> Void)?,
        cancelled: () -> Bool
    ) throws {
        var nsError: NSError?
        let children = fileAccess.listDirectory(atPath: fromPath, error: &nsError)
        if nsError != nil {
            throw ArchiveError.sourceIsDirectoryButCouldNotList(fromPath)
        }
        if children.count == 0 {
            // Empty dir — nothing more to copy.
            return
        }
        let fm = FileManager.default
        for child in children {
            if cancelled() { throw ArchiveError.cancel }
            if child.name.hasPrefix(".") { continue }
            let childSourcePath = (fromPath as NSString).appendingPathComponent(child.name)
            let childDestURL = toURL.appendingPathComponent(child.name, isDirectory: child.isDirectory)
            if child.isDirectory {
                try fm.createDirectory(at: childDestURL,
                                       withIntermediateDirectories: true,
                                       attributes: [.posixPermissions: 0o700])
                try copyDirectoryRecursive(
                    fromPath: childSourcePath,
                    toURL: childDestURL,
                    fileAccess: fileAccess,
                    totalBytes: &totalBytes,
                    totalEstimate: totalEstimate,
                    onByteCopied: onByteCopied,
                    cancelled: cancelled
                )
            } else {
                try copySingleFile(
                    fromPath: childSourcePath,
                    toURL: childDestURL,
                    fileAccess: fileAccess,
                    totalBytes: &totalBytes,
                    totalEstimate: totalEstimate,
                    onByteCopied: onByteCopied
                )
            }
        }
    }

    // MARK: - Metadata persistence

    private static func metadataURL(for archivedURL: URL) -> URL {
        // We put metadata as a sibling dot-file so that the entry itself
        // (file or folder) is what the user sees in the Explorer.
        let parent = archivedURL.deletingLastPathComponent()
        let base = archivedURL.lastPathComponent
        return parent.appendingPathComponent(".\(base).\(metadataFileName)")
    }

    private static func writeMetadata(_ meta: ArchivedItemMetadata, for archivedURL: URL) {
        let url = metadataURL(for: archivedURL)
        if let data = try? JSONEncoder().encode(meta) {
            try? data.write(to: url, options: .atomic)
        }
    }

    private static func readMetadata(for archivedURL: URL) -> ArchivedItemMetadata? {
        let url = metadataURL(for: archivedURL)
        guard let data = try? Data(contentsOf: url),
              let meta = try? JSONDecoder().decode(ArchivedItemMetadata.self, from: data)
        else { return nil }
        return meta
    }
}

// Helper added to avoid a naming collision with the stdlib `URL.path`
// inside an expression chain where the compiler got confused.
private extension URL {
    var sourceURL_fm_pathFix: String { path }
}
