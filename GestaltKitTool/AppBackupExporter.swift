//
//  AppBackupExporter.swift
//  GestaltKitTool
//
//  One-tap app backup and export.
//

import Combine
import Foundation
import os
import SwiftUI

// Files larger than 256 MB are skipped to avoid OOM.
private let maxInMemoryFileSize: Int64 = 256 * 1024 * 1024

// MARK: - Error Types

enum AppBackupError: LocalizedError {
    case partialDelete([String])

    var errorDescription: String? {
        switch self {
        case .partialDelete(let failures):
            return String(localized: "Some backups could not be deleted:")
                + "\n" + failures.joined(separator: "\n")
        }
    }
}

extension Error {
    /// Returns `true` if the underlying Cocoa error code is "file not found" (4).
    var isFileNotFound: Bool {
        let nsError = self as NSError
        return nsError.domain == NSCocoaErrorDomain && nsError.code == NSFileNoSuchFileError
    }
}

// MARK: - Backup Record

struct AppBackupRecord: Identifiable, Codable {
    let id: String          // UUID
    let appBundleId: String
    let appDisplayName: String
    let backupDate: Date
    let fileCount: Int
    let totalSize: Int64
    let backupPath: String  // Path within our container
    var label: String?
    private static let sizeFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .file
        return f
    }()
    var sizeFormatted: String {
        Self.sizeFormatter.string(fromByteCount: totalSize)
    }

    // (iOS 15+, thread-safe) instead of a static DateFormatter instance.
    var dateFormatted: String {
        backupDate.formatted(date: .abbreviated, time: .shortened)
    }
}

// MARK: - Export Progress

struct ExportProgress {
    var currentFile: String = ""
    var filesCopied: Int = 0
    var totalFiles: Int = 0
    var bytesCopied: Int64 = 0
    var isComplete: Bool = false
    var error: String?

    var fraction: Double {
        totalFiles > 0 ? Double(filesCopied) / Double(totalFiles) : 0
    }

    var percentText: String {
        String(format: "%.0f%%", fraction * 100)
    }
}

// MARK: - App Backup Manager

@MainActor
final class AppBackupManager: ObservableObject {

    @Published var backups: [AppBackupRecord] = []
    @Published var isExporting = false
    @Published var exportProgress = ExportProgress()
    @Published var errorMessage: String?

    private let fileAccess = BadQueryFileAccess.shared()
    private let backupsKey = UserDefaultsKeys.appBackups
    private let backupDirName = "AppBackups"

    init() {
        loadBackups()
    }

    // MARK: Storage

    private func loadBackups() {
        guard let data = UserDefaults.standard.data(forKey: backupsKey),
              let decoded = try? JSONDecoder().decode([AppBackupRecord].self, from: data) else {
            backups = []
            return
        }
        backups = decoded
    }

    private func saveBackups() {
        do {
            let data = try JSONEncoder().encode(backups)
            UserDefaults.standard.set(data, forKey: backupsKey)
        } catch {
            GKTLLog.backup.error("saveBackups encode failed: \(error.localizedDescription)")
        }
    }

    // MARK: Backup Directory

    /// Returns the backup root directory inside our container,
    /// with a fallback for contexts where the document directory may not be available.
    private var backupRoot: String {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        let baseDir = docs ?? FileManager.default.temporaryDirectory
        let backupDir = baseDir.appendingPathComponent(backupDirName)
        try? FileManager.default.createDirectory(at: backupDir, withIntermediateDirectories: true)
        return backupDir.path
    }

    /// Creates a backup directory for a specific backup ID.
    private func backupDirectory(for id: String) -> String {
        let dir = (backupRoot as NSString).appendingPathComponent(id)
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: One-Tap Backup

    /// Backs up an app's entire data container to our container.
    /// Uses bad_query to read files from the source sandbox, writes
    /// to our own Documents directory.
    func backupApp(_ app: AppContainer) {
        guard !isExporting else { return }
        isExporting = true
        exportProgress = ExportProgress()
        errorMessage = nil

        let backupId = UUID().uuidString
        let destDir = backupDirectory(for: backupId)
        let sourcePath = app.path
        let bundleId = app.bundleIdentifier ?? app.id
        let displayName = app.displayName

        let fileAccess = self.fileAccess

        // Use Task.detached for cooperative cancellation and better backpressure.
        Task.detached(priority: .userInitiated) { [weak self] in
            // Phase 1: Enumerate all files
            var listError: NSError?
            let entries = fileAccess.recursiveList(atPath: sourcePath, maxDepth: 10, error: &listError)

            if let listError {
                Task { @MainActor [weak self] in
                    self?.errorMessage = ErrorHandler.friendlyMessage(for: listError)
                    self?.isExporting = false
                }
                return
            }

            let totalFiles = entries.filter { !$0.isDirectory }.count
            Task { @MainActor [weak self] in
                self?.exportProgress.totalFiles = totalFiles
                self?.exportProgress.currentFile = String(localized: "Starting backup…")
            }

            // Normalize source path with trailing slash for safe prefix matching.
            let normalizedSource = sourcePath.hasSuffix("/") ? sourcePath : sourcePath + "/"

            // Phase 2: Copy files
            let fm = FileManager.default
            var copied = 0
            var skipped = 0
            var failedWrites = 0
            var totalSize: Int64 = 0

            for entry in entries {
                if entry.isDirectory {
                    let relative: String
                    if entry.fullPath.hasPrefix(normalizedSource) {
                        relative = String(entry.fullPath.dropFirst(normalizedSource.count))
                    } else {
                        relative = entry.name
                    }
                    let destPath = (destDir as NSString).appendingPathComponent(relative)
                    try? fm.createDirectory(atPath: destPath, withIntermediateDirectories: true)
                    continue
                }

                let fileAttrs = try? FileManager.default.attributesOfItem(atPath: entry.fullPath)
                let fileSize = (fileAttrs?[.size] as? NSNumber)?.int64Value ?? 0
                if fileSize > maxInMemoryFileSize {
                    skipped += 1
                    continue
                }

                // Read from source via sandbox extension
                guard let data = try? fileAccess.readFile(atPath: entry.fullPath) else {
                    skipped += 1
                    continue
                }

                let relative: String
                if entry.fullPath.hasPrefix(normalizedSource) {
                    relative = String(entry.fullPath.dropFirst(normalizedSource.count))
                } else {
                    relative = entry.name
                }
                let destPath = (destDir as NSString).appendingPathComponent(relative)

                // Ensure parent exists
                let parentDir = (destPath as NSString).deletingLastPathComponent
                do {
                    try fm.createDirectory(atPath: parentDir, withIntermediateDirectories: true)
                } catch {
                    failedWrites += 1
                    continue
                }

                do {
                    try data.write(to: URL(fileURLWithPath: destPath), options: .atomic)
                } catch {
                    failedWrites += 1
                    continue
                }

                copied += 1
                totalSize += Int64(data.count)

                // Update progress every 10 files
                if copied % 10 == 0 || copied == totalFiles {
                    let currentCopied = copied
                    let currentSize = totalSize
                    let fileName = entry.name

                    Task { @MainActor [weak self] in
                        self?.exportProgress.filesCopied = currentCopied
                        self?.exportProgress.bytesCopied = currentSize
                        self?.exportProgress.currentFile = fileName
                    }
                }
            }

            // Phase 3: Create backup record
            let record = AppBackupRecord(
                id: backupId,
                appBundleId: bundleId,
                appDisplayName: displayName,
                backupDate: Date(),
                fileCount: copied,
                totalSize: totalSize,
                backupPath: destDir,
                label: nil
            )

            // dispatching to MainActor, avoiding Swift 6 concurrent-capture
            // warnings for var references in Task closures.
            let finalCopied = copied
            let finalTotalSize = totalSize
            let finalSkipped = skipped
            let finalFailedWrites = failedWrites

            Task { @MainActor [weak self] in
                guard let self else { return }
                self.backups.insert(record, at: 0)
                self.saveBackups()
                self.exportProgress.isComplete = true
                self.exportProgress.filesCopied = finalCopied
                self.exportProgress.bytesCopied = finalTotalSize
                // Report skipped and failed writes
                if finalSkipped > 0 || finalFailedWrites > 0 {
                    var parts: [String] = []
                    if finalSkipped > 0 {
                        parts.append(String(format: String(localized: "%d files skipped"), finalSkipped))
                    }
                    if finalFailedWrites > 0 {
                        parts.append(String(format: String(localized: "%d files failed to write"), finalFailedWrites))
                    }
                    self.exportProgress.error = parts.joined(separator: ", ")
                }
                self.isExporting = false
            }
        }
    }

    // MARK: Selective Export

    /// Exports specific files from an app's container to our container,
    /// then returns the list of exported file URLs for sharing.
    /// bad_query XPC call + sandbox extension negotiation (50-500ms
    /// per file), which would freeze the UI when exporting multiple
    /// files.
    func exportFiles(paths: [String], appDisplayName: String, completion: @escaping ([URL]) -> Void) {
        let fileAccess = self.fileAccess
        let exportDir = (backupRoot as NSString).appendingPathComponent("Exports")
        try? FileManager.default.createDirectory(atPath: exportDir, withIntermediateDirectories: true)

        Task.detached(priority: .userInitiated) {
            var exportedURLs: [URL] = []
            for path in paths {
                let fileAttrs = try? FileManager.default.attributesOfItem(atPath: path)
                let fileSize = (fileAttrs?[.size] as? NSNumber)?.int64Value ?? 0
                if fileSize > maxInMemoryFileSize { continue }

                guard let data = try? fileAccess.readFile(atPath: path) else { continue }
                let fileName = (path as NSString).lastPathComponent
                let destPath = (exportDir as NSString).appendingPathComponent(fileName)
                do {
                    try data.write(to: URL(fileURLWithPath: destPath), options: .atomic)
                    exportedURLs.append(URL(fileURLWithPath: destPath))
                } catch {
                    continue
                }
            }
            DispatchQueue.main.async {
                completion(exportedURLs)
            }
        }
    }

    // MARK: Delete Backup

    func deleteBackup(_ record: AppBackupRecord) throws {
        do {
            try FileManager.default.removeItem(atPath: record.backupPath)
        } catch {
            if !error.isFileNotFound {
                throw error
            }
        }
        backups.removeAll { $0.id == record.id }
        saveBackups()
    }

    func deleteAllBackups() throws {
        var failures: [String] = []
        for record in backups {
            do {
                try FileManager.default.removeItem(atPath: record.backupPath)
            } catch {
                if !error.isFileNotFound {
                    failures.append("\(record.appDisplayName): \(ErrorHandler.friendlyMessage(for: error))")
                }
            }
        }
        backups.removeAll()
        saveBackups()
        if !failures.isEmpty {
            throw AppBackupError.partialDelete(failures)
        }
    }

    // MARK: Label

    func setLabel(_ label: String?, for record: AppBackupRecord) {
        if let idx = backups.firstIndex(where: { $0.id == record.id }) {
            backups[idx].label = label
            saveBackups()
        }
    }

    // MARK: Pruning

    /// Removes old backups if total count exceeds max, keeping newest.
    func prune(maxBackups: Int = DesignConstants.defaultMaxAppBackups) {
        guard backups.count > maxBackups else { return }
        let toRemove = backups.count - maxBackups
        for _ in 0..<toRemove {
            let record = backups.removeLast()
            try? FileManager.default.removeItem(atPath: record.backupPath)
        }
        saveBackups()
    }
}

// MARK: - Backup List View

struct AppBackupListView: View {
    @StateObject private var manager = AppBackupManager()
    @State private var showingDeleteAlert = false
    @State private var deleteError: String?

    var body: some View {
        Group {
            if manager.backups.isEmpty {
                emptyView
            } else {
                backupListView
            }
        }
        .navigationTitle(String(localized: "App Backups"))
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            if !manager.backups.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button(String(localized: "Delete All"), systemImage: "trash", role: .destructive) {
                            showingDeleteAlert = true
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
        }
        .alert(String(localized: "Delete All Backups?"), isPresented: $showingDeleteAlert) {
            Button(String(localized: "Delete"), role: .destructive) {
                do {
                    try manager.deleteAllBackups()
                } catch {
                    deleteError = ErrorHandler.friendlyMessage(for: error)
                }
            }
            Button(String(localized: "Cancel"), role: .cancel) {}
        } message: {
            Text(String(localized: "This will permanently remove all app backup data. This action cannot be undone."))
        }
        .alert(String(localized: "Delete Error"), isPresented: Binding(
            get: { deleteError != nil },
            set: { if !$0 { deleteError = nil } })
        ) {
            Button(String(localized: "OK"), role: .cancel) { deleteError = nil }
        } message: {
            Text(deleteError ?? "")
        }
    }

    private var emptyView: some View {
        VStack(spacing: 20) {
            Image(systemName: "internaldrive")
                .font(.system(size: DesignConstants.heroIconSize))
                .foregroundStyle(.secondary)
            Text(String(localized: "No App Backups"))
                .font(.title2.bold())
            Text(String(localized: "Back up any app's data container from the App Explorer. Backups are stored in GestaltKitTool's private container."))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var backupListView: some View {
        List {
            if manager.isExporting || manager.exportProgress.isComplete {
                Section {
                    ExportProgressView(progress: manager.exportProgress)
                }
                .onAppear {
                    if manager.exportProgress.isComplete && !manager.isExporting {
                        Task { @MainActor in
                            try? await Task.sleep(for: .seconds(5))
                            if manager.exportProgress.isComplete && !manager.isExporting {
                                manager.exportProgress.isComplete = false
                            }
                        }
                    }
                }
            }

            Section {
                ForEach(manager.backups) { record in
                    BackupRowView(record: record, manager: manager)
                        .contextMenu {
                            Button(String(localized: "Delete"), systemImage: "trash", role: .destructive) {
                                do {
                                    try manager.deleteBackup(record)
                                } catch {
                                    deleteError = ErrorHandler.friendlyMessage(for: error)
                                }
                            }
                        }
                }
            } header: {
                Text(verbatim: "\(manager.backups.count) \(String(localized: "backups"))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .listStyle(.insetGrouped)
    }
}

// MARK: - Backup Row

private struct BackupRowView: View {
    let record: AppBackupRecord
    @ObservedObject var manager: AppBackupManager
    @State private var deleteError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: "internaldrive")
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(record.appDisplayName)
                        .font(.body.bold())
                    Text(record.appBundleId)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text(record.sizeFormatted)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(verbatim: "\(record.fileCount) \(String(localized: "files"))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            HStack {
                Text(record.dateFormatted)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                if let label = record.label {
                    Text("· \(label)")
                        .font(.caption2)
                        .foregroundStyle(.tint)
                }
            }
        }
        .padding(.vertical, 4)
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) {
                do {
                    try manager.deleteBackup(record)
                } catch {
                    deleteError = ErrorHandler.friendlyMessage(for: error)
                }
            } label: {
                Label(String(localized: "Delete"), systemImage: "trash")
            }
        }
        .alert(String(localized: "Delete Error"), isPresented: Binding(
            get: { deleteError != nil },
            set: { if !$0 { deleteError = nil } })
        ) {
            Button(String(localized: "OK"), role: .cancel) { deleteError = nil }
        } message: {
            Text(deleteError ?? "")
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(record.appDisplayName), \(record.dateFormatted), \(record.sizeFormatted), \(record.fileCount) files")
    }
}

// MARK: - Export Progress View

struct ExportProgressView: View {
    let progress: ExportProgress

    var body: some View {
        VStack(spacing: 8) {
            if progress.isComplete {
                HStack {
                    Label(String(localized: "Backup Complete"), systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    if let skipMsg = progress.error {
                        Text(skipMsg)
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
            } else {
                HStack {
                    ProgressView(value: progress.fraction)
                    Text(progress.percentText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 40, alignment: .trailing)
                }
                HStack {
                    Text(progress.currentFile)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer()
                    Text("\(progress.filesCopied)/\(progress.totalFiles)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(ByteCountFormatter.string(fromByteCount: progress.bytesCopied, countStyle: .file))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Share Sheet

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
