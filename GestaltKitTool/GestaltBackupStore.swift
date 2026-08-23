import Foundation
import os

struct GestaltBackup: Identifiable, Hashable {
    let url: URL
    let createdAt: Date
    let byteCount: Int64
    let isManual: Bool

    var id: URL { url }
    var name: String { url.deletingPathExtension().lastPathComponent }

    /// User-editable label stored in UserDefaults via BackupLabelStore.
    var label: String? { BackupLabelStore.label(for: name) }

    /// CacheExtra, pre-computed once during `list()` or `create()`
    /// so the backups list doesn't re-read the file on every SwiftUI
    /// body re-evaluation.
    var sourceProductType: String?

    init(url: URL, createdAt: Date, byteCount: Int64, isManual: Bool, sourceProductType: String? = nil) {
        self.url = url
        self.createdAt = createdAt
        self.byteCount = byteCount
        self.isManual = isManual
        self.sourceProductType = sourceProductType
    }
}

enum GestaltBackupStore {
    /// Maximum number of **automatic** backups to retain.
    static let maxAutoBackups = 30

    /// Filename prefix for automatic (pre-write) backups.
    private static let autoPrefix = "MobileGestalt_"
    /// Filename prefix for manual backups.
    private static let manualPrefix = "Manual_"

    // Use a queue to serialize all formatter access.
    private static let dateQueue = DispatchQueue(label: "com.wesk.gestalt.datefmt")
    private static let backupDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = SharedLocale.posix
        f.dateFormat = "yyyy-MM-dd_HH-mm-ss-SSS"
        return f
    }()

    /// Thread-safe wrapper that formats the date on a serial queue.
    private static func formatBackupDate(_ date: Date) -> String {
        dateQueue.sync { backupDateFormatter.string(from: date) }
    }

    static func create(from data: Data, isManual: Bool = false) throws -> GestaltBackup {
        let directory = try backupDirectory()
        let prefix = isManual ? manualPrefix : autoPrefix
        let url = directory
            .appendingPathComponent("\(prefix)\(formatBackupDate(Date()))")
            .appendingPathExtension("plist")
        try data.write(to: url, options: .atomic)
        var sourcePT: String?
        if let dict = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
           let cacheExtra = dict["CacheExtra"] as? [String: Any] {
            sourcePT = cacheExtra["0+nc/Udy4WNG8S+Q7a/s1A"] as? String
        }
        let values = (try? url.resourceValues(forKeys: [.creationDateKey, .fileSizeKey])) ?? URLResourceValues()
        let backup = GestaltBackup(
            url: url,
            createdAt: values.creationDate ?? Date(),
            byteCount: Int64(values.fileSize ?? Int(data.count)),
            isManual: isManual,
            sourceProductType: sourcePT
        )
        pruneExcessBackups(in: directory)
        return backup
    }

    /// Removes the oldest **automatic** backups until only `maxAutoBackups`
    /// remain. Manual backups (prefix `Manual_`) are never pruned.
    /// Sorts by filename (which contains a timestamp) rather than
    /// file creation date, since creationDate can be unavailable on
    /// some file systems.
    private static func pruneExcessBackups(in directory: URL) {
        guard let allFiles = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return }

        let autoBackups = allFiles
            .filter { $0.pathExtension == "plist" && $0.lastPathComponent.hasPrefix(autoPrefix) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        let excess = max(0, autoBackups.count - maxAutoBackups)
        for url in autoBackups.prefix(excess) {
            // Log prune failures to diagnostics rather than silently ignoring.
            do {
                try FileManager.default.removeItem(at: url)
            } catch {
                GKTLLog.backup.error("prune delete failed: \(error.localizedDescription)")
            }
        }
    }

    static func list() throws -> [GestaltBackup] {
        let directory = try backupDirectory()
        let urls = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.creationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        )
        .filter { $0.pathExtension == "plist" }

        // Cache sourceProductType to avoid per-row file reads during SwiftUI body re-evaluation.
        let backups: [GestaltBackup] = urls.map { url in
            let values = (try? url.resourceValues(forKeys: [.creationDateKey, .fileSizeKey])) ?? URLResourceValues()
            let isManual = url.lastPathComponent.hasPrefix(manualPrefix)
            // Read plist and extract ProductType
            var sourcePT: String?
            if let data = try? Data(contentsOf: url),
               let dict = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
               let cacheExtra = dict["CacheExtra"] as? [String: Any] {
                sourcePT = cacheExtra["0+nc/Udy4WNG8S+Q7a/s1A"] as? String
            }
            return GestaltBackup(
                url: url,
                createdAt: values.creationDate ?? .distantPast,
                byteCount: Int64(values.fileSize ?? 0),
                isManual: isManual,
                sourceProductType: sourcePT
            )
        }
        return backups.sorted { $0.createdAt > $1.createdAt }
    }

    static func data(for backup: GestaltBackup) throws -> Data {
        try Data(contentsOf: backup.url)
    }

    static func delete(_ backup: GestaltBackup) throws {
        try FileManager.default.removeItem(at: backup.url)
        // Clean up any user-assigned label.
        BackupLabelStore.setLabel(nil, for: backup.name)
    }

    private static func backupDirectory() throws -> URL {
        let documents = try FileManager.default.url(
            for: .documentDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = documents.appendingPathComponent("MobileGestalt Backups", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

}

// MARK: - Gestalt Patch (shareable CacheExtra field patches)

/// On-disk content of a `.weskpatch` file. A patch records only the
/// CacheExtra key/value pairs the author chose to share — never the
/// full plist — so it is device-independent and safe to distribute.
struct GestaltPatchContent: Codable, Hashable, Sendable {
    struct FieldValue: Codable, Hashable, Sendable {
        /// `PlistValueKind.rawValue`, used to round-trip the value type
        /// (string / integer / float / boolean / data / array / dictionary).
        let kind: String
        /// Type-preserving serialization produced by `PlistValueInfo.encode`.
        let encodedValue: String
    }

    static let formatVersion = 1
    let formatVersion: Int
    let name: String
    let author: String?
    let notes: String?
    let createdAt: Date
    /// CacheExtra key → typed field value.
    let cacheExtra: [String: FieldValue]
}

/// A patch loaded from disk, carrying both its file URL and decoded content.
struct GestaltPatch: Identifiable, Hashable {
    let url: URL
    let content: GestaltPatchContent

    var id: URL { url }
    var name: String { content.name }
    var notes: String? { content.notes }
    var author: String? { content.author }
    var createdAt: Date { content.createdAt }
    var fieldCount: Int { content.cacheExtra.count }
}

enum GestaltPatchStore {
    static let pathExtension = "weskpatch"
    static let maxPatches = 50

    static func create(_ content: GestaltPatchContent) throws -> GestaltPatch {
        let directory = try patchDirectory()
        // Use an opaque UUID filename to prevent path traversal via user-controlled names.
        // The display name lives only inside the JSON payload.
        let url = directory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(pathExtension)
        let data = try JSONEncoder().encode(content)
        try data.write(to: url, options: .atomic)
        pruneExcessPatches(in: directory)
        return GestaltPatch(url: url, content: content)
    }

    static func list() throws -> [GestaltPatch] {
        let directory = try patchDirectory()
        return try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        .filter { $0.pathExtension == pathExtension }
        .compactMap { url -> GestaltPatch? in
            guard let data = try? Data(contentsOf: url),
                  let content = try? JSONDecoder().decode(GestaltPatchContent.self, from: data) else {
                return nil
            }
            return GestaltPatch(url: url, content: content)
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    static func data(for patch: GestaltPatch) throws -> Data {
        try Data(contentsOf: patch.url)
    }

    static func delete(_ patch: GestaltPatch) throws {
        try FileManager.default.removeItem(at: patch.url)
    }

    private static func patchDirectory() throws -> URL {
        let documents = try FileManager.default.url(
            for: .documentDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = documents.appendingPathComponent("MobileGestalt Patches", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private static func pruneExcessPatches(in directory: URL) {
        guard let allFiles = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.creationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        // Alphabetical sort is random w.r.t. creation time. Sort by
        // file creation date to delete the *oldest* patches first.
        let patches = allFiles
            .filter { $0.pathExtension == pathExtension }
            .sorted { a, b in
                let dateA = (try? a.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantFuture
                let dateB = (try? b.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantFuture
                return dateA < dateB
            }
        let excess = max(0, patches.count - maxPatches)
        for url in patches.prefix(excess) {
            do {
                try FileManager.default.removeItem(at: url)
            } catch {
                GKTLLog.patch.error("prune patch delete failed: \(error.localizedDescription)")
            }
        }
    }
}
