import Foundation

struct GestaltBackup: Identifiable, Hashable {
    let url: URL
    let createdAt: Date
    let byteCount: Int64

    var id: URL { url }
    var name: String { url.deletingPathExtension().lastPathComponent }
}

enum GestaltBackupStore {
    /// Maximum number of backups to retain. When this limit is exceeded,
    /// the oldest backups are pruned automatically after a new backup is
    /// created.
    static let maxBackups = 30

    static func create(from data: Data) throws -> GestaltBackup {
        let directory = try backupDirectory()
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss-SSS"
        let url = directory
            .appendingPathComponent("MobileGestalt_\(formatter.string(from: Date()))")
            .appendingPathExtension("plist")
        try data.write(to: url, options: .atomic)
        let backup = try metadata(for: url)
        // Prune old backups to stay within maxBackups.
        pruneExcessBackups(in: directory)
        return backup
    }

    /// Removes the oldest backups until only `maxBackups` remain.
    /// Sorts by filename (which contains a timestamp) rather than
    /// file creation date, since creationDate can be unavailable on
    /// some file systems.
    private static func pruneExcessBackups(in directory: URL) {
        guard let allFiles = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return }

        let plists = allFiles
            .filter { $0.pathExtension == "plist" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        let excess = max(0, plists.count - maxBackups)
        for url in plists.prefix(excess) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    static func list() throws -> [GestaltBackup] {
        let directory = try backupDirectory()
        return try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.creationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        )
        .filter { $0.pathExtension == "plist" }
        .map { try metadata(for: $0) }
        .sorted { $0.createdAt > $1.createdAt }
    }

    static func data(for backup: GestaltBackup) throws -> Data {
        try Data(contentsOf: backup.url)
    }

    static func delete(_ backup: GestaltBackup) throws {
        try FileManager.default.removeItem(at: backup.url)
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

    private static func metadata(for url: URL) throws -> GestaltBackup {
        let values = try url.resourceValues(forKeys: [.creationDateKey, .fileSizeKey])
        return GestaltBackup(
            url: url,
            createdAt: values.creationDate ?? .distantPast,
            byteCount: Int64(values.fileSize ?? 0)
        )
    }
}

// MARK: - Gestalt Patch (shareable CacheExtra field patches)

/// On-disk content of a `.weskpatch` file. A patch records only the
/// CacheExtra key/value pairs the author chose to share — never the
/// full plist — so it is device-independent and safe to distribute.
struct GestaltPatchContent: Codable, Hashable {
    struct FieldValue: Codable, Hashable {
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
        // CR-2 fix: never derive the on-disk file name from user-
        // controlled `content.name`. A hostile patch file imported via
        // the system file picker could set name=".." (after the `/`
        // strip) and cause appendingPathComponent to escape the patch
        // directory — overwriting files in the parent Documents
        // folder. Use an opaque UUID filename; the display name lives
        // only inside the JSON payload and is shown to the user from
        // `GestaltPatch.name`.
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
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return }
        let patches = allFiles
            .filter { $0.pathExtension == pathExtension }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        let excess = max(0, patches.count - maxPatches)
        for url in patches.prefix(excess) {
            try? FileManager.default.removeItem(at: url)
        }
    }
}
