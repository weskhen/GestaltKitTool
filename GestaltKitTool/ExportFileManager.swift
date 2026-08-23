//
//  ExportFileManager.swift
//  GestaltKitTool
//
//  Manages temporary file exports for ShareLink. Centralizes file
//  creation and stale-file cleanup to avoid code duplication across
//  FileExplorerView and SystemInspectorView.
//

import Foundation
import os

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
    ///
    /// If the write fails, throws so the caller can inform the user
    /// (e.g. disk full, permission denied).
    static func makeExportURL(fileName: String, data: Data) throws -> URL {
        cleanOldExports(maxAge: 3600)
        let safeName = fileName
            .replacingOccurrences(of: "\0", with: "")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "\\", with: "_")
            .replacingOccurrences(of: "..", with: "_")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let baseName: String
        if safeName.isEmpty {
            baseName = "export_\(Int(Date().timeIntervalSince1970))"
        } else {
            baseName = (safeName as NSString).lastPathComponent
        }
        // Avoid clobbering an existing export with the same name.
        var url = exportDir.appendingPathComponent(baseName)
        if FileManager.default.fileExists(atPath: url.path) {
            let ext = (baseName as NSString).pathExtension
            let stem = (baseName as NSString).deletingPathExtension
            var i = 2
            repeat {
                let suffix = ext.isEmpty ? "\(stem)_\(i)" : "\(stem)_\(i).\(ext)"
                url = exportDir.appendingPathComponent(suffix)
                i += 1
            } while FileManager.default.fileExists(atPath: url.path)
        }
        try data.write(to: url)
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
                do {
                    try FileManager.default.removeItem(at: file)
                } catch {
                    GKTLLog.browse.warning("cleanOldExports: \(error.localizedDescription)")
                }
            }
        }
    }
}
