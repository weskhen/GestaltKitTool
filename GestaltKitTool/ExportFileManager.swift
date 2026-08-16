//
//  ExportFileManager.swift
//  GestaltKitTool
//
//  Manages temporary file exports for ShareLink. Centralizes file
//  creation and stale-file cleanup to avoid code duplication across
//  FileExplorerView and SystemInspectorView.
//

import Foundation

enum ExportFileManager {
    /// Subdirectory under the system temp folder for GestaltKitTool exports.
    static let exportDir: URL = {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("GestaltKitTool_exports", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    /// Writes `data` to a temp file and returns its URL. Cleans up
    /// stale exports older than 1 hour on each call.
    static func makeExportURL(fileName: String, data: Data) -> URL {
        cleanOldExports(maxAge: 3600)
        // Sanitize the file name to prevent path traversal.
        let safeName = fileName
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "..", with: "_")
        let url = exportDir.appendingPathComponent(safeName)
        try? data.write(to: url)
        return url
    }

    /// Removes export files older than `maxAge` seconds.
    static func cleanOldExports(maxAge: TimeInterval) {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: exportDir,
            includingPropertiesForKeys: [.creationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        let cutoff = Date().addingTimeInterval(-maxAge)
        for file in files {
            if let creationDate = try? file.resourceValues(forKeys: [.creationDateKey]).creationDate,
               creationDate < cutoff {
                try? FileManager.default.removeItem(at: file)
            }
        }
    }
}
