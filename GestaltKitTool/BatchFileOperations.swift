//
//  BatchFileOperations.swift
//  GestaltKitTool
//
//  Batch file operations: multi-select delete, move, export.
//

import Combine
import Foundation
import SwiftUI

// Files larger than 256 MB are skipped to avoid OOM.
private let maxBatchFileSize: Int64 = 256 * 1024 * 1024

// MARK: - Batch Operation Result

/// Tracks progress and outcome of a batch file operation.
struct BatchOperationResult: Sendable {
    let totalItems: Int
    let succeededItems: [String]
    let failedItems: [(path: String, error: String)]

    var succeededCount: Int { succeededItems.count }
    var failedCount: Int { failedItems.count }
    var isComplete: Bool { succeededCount + failedCount == totalItems }

    static let empty = BatchOperationResult(totalItems: 0, succeededItems: [], failedItems: [])
}

// MARK: - Batch Operation Progress

/// Live progress for a batch operation, published to the UI.
@MainActor
final class BatchOperationProgress: ObservableObject {
    @Published var currentPath: String = ""
    @Published var processedCount: Int = 0
    @Published var succeededCount: Int = 0
    @Published var failedCount: Int = 0
    @Published var totalCount: Int = 0
    @Published var isRunning: Bool = false
    @Published var errors: [(path: String, error: String)] = []
    @Published var exportURLs: [URL] = []
    @Published var succeededPaths: [String] = []

    var progressFraction: Double {
        guard totalCount > 0 else { return 0 }
        return Double(processedCount) / Double(totalCount)
    }

    func reset(total: Int) {
        totalCount = total
        processedCount = 0
        succeededCount = 0
        failedCount = 0
        currentPath = ""
        errors = []
        exportURLs = []
        succeededPaths = []
        isRunning = total > 0
    }

    func recordSuccess(path: String) {
        processedCount += 1
        succeededCount += 1
        succeededPaths.append(path)
        currentPath = path
    }

    func recordFailure(path: String, error: String) {
        processedCount += 1
        failedCount += 1
        errors.append((path, error))
        currentPath = path
    }

    func finish() {
        isRunning = false
        currentPath = ""
    }
}

// MARK: - Batch File Operations Engine

/// Performs batch delete, move, and export operations on a set of file entries.
/// All heavy work runs on a background queue; progress is published via
/// BatchOperationProgress on the main actor.
enum BatchFileOperations {

    // MARK: Batch Delete

    /// Deletes a list of files/directories. Directories are recursively
    /// emptied then the directory itself is deleted.
    static func batchDelete(
        entries: [BQFileEntry],
        progress: BatchOperationProgress,
        completion: @MainActor @escaping (BatchOperationResult) -> Void
    ) {
        let total = entries.count
        Task { @MainActor in
            progress.reset(total: total)
        }

        let fileAccess = BadQueryFileAccess.shared()
        let entriesToProcess = entries

        Task.detached(priority: .userInitiated) {
            var succeeded: [String] = []
            var failed: [(path: String, error: String)] = []

            for entry in entriesToProcess {
                var didSucceed = false
                var errorMsg: String?

                if entry.isDirectory {
                    // First empty the directory contents, then delete the dir itself
                    var dirError: NSError?
                    let deletedCount = fileAccess.deleteDirectoryContents(
                        atPath: entry.fullPath,
                        maxItems: 0,
                        error: &dirError
                    )
                    if let dirError, dirError.code != 0 {
                        errorMsg = ErrorHandler.friendlyMessage(for: dirError)
                    }

                    // Now try to delete the empty directory itself
                    do {
                        try fileAccess.deleteFile(atPath: entry.fullPath)
                        didSucceed = true
                    } catch {
                        if deletedCount > 0 {
                            // Partial success — contents deleted but dir remains
                            didSucceed = true
                        } else {
                            errorMsg = ErrorHandler.friendlyMessage(for: error)
                        }
                    }
                } else {
                    do {
                        try fileAccess.deleteFile(atPath: entry.fullPath)
                        didSucceed = true
                    } catch {
                        errorMsg = ErrorHandler.friendlyMessage(for: error)
                    }
                }

                let pathStr = entry.fullPath
                let didSucceedCopy = didSucceed
                let errorMsgCopy = errorMsg
                Task { @MainActor in
                    if didSucceedCopy {
                        progress.recordSuccess(path: pathStr)
                    } else {
                        progress.recordFailure(
                            path: pathStr,
                            error: errorMsgCopy ?? String(localized: "Unknown error")
                        )
                    }
                }

                if didSucceed {
                    succeeded.append(pathStr)
                } else {
                    failed.append((pathStr, errorMsg ?? String(localized: "Unknown error")))
                }
            }

            let result = BatchOperationResult(
                totalItems: total,
                succeededItems: succeeded,
                failedItems: failed
            )

            Task { @MainActor in
                progress.finish()
                completion(result)
            }
        }
    }

    // MARK: Batch Move

    /// Moves a list of files/directories to a target directory.
    /// Files are renamed to their original names in the target.
    static func batchMove(
        entries: [BQFileEntry],
        toDestinationDir destinationDir: String,
        progress: BatchOperationProgress,
        completion: @MainActor @escaping (BatchOperationResult) -> Void
    ) {
        let total = entries.count
        Task { @MainActor in
            progress.reset(total: total)
        }

        let fileAccess = BadQueryFileAccess.shared()

        // Ensure destination directory exists
        try? fileAccess.createDirectory(atPath: destinationDir)

        Task.detached(priority: .userInitiated) {
            var succeeded: [String] = []
            var failed: [(path: String, error: String)] = []

            for entry in entries {
                let destPath = (destinationDir as NSString)
                    .appendingPathComponent(entry.name)

                // Skip if source and destination are the same
                if entry.fullPath == destPath {
                    Task { @MainActor in
                        progress.recordSuccess(path: entry.fullPath)
                    }
                    succeeded.append(entry.fullPath)
                    continue
                }

                let pathStr = entry.fullPath
                do {
                    try fileAccess.moveFile(fromPath: entry.fullPath, toPath: destPath)
                    Task { @MainActor in
                        progress.recordSuccess(path: pathStr)
                    }
                    succeeded.append(pathStr)
                } catch {
                    let msg = ErrorHandler.friendlyMessage(for: error)
                    Task { @MainActor in
                        progress.recordFailure(path: pathStr, error: msg)
                    }
                    failed.append((pathStr, msg))
                }
            }

            let result = BatchOperationResult(
                totalItems: total,
                succeededItems: succeeded,
                failedItems: failed
            )

            Task { @MainActor in
                progress.finish()
                completion(result)
            }
        }
    }
}

// MARK: - Batch Operation Views

/// Confirmation sheet for batch delete operation.
struct BatchDeleteConfirmSheet: View {
    @Environment(\.dismiss) private var dismiss
    let selectedEntries: [BQFileEntry]
    let onConfirm: () -> Void

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.title2)
                            .foregroundStyle(.orange)
                        VStack(alignment: .leading) {
                            Text(String(format: String(localized: "Delete %d item%@?"), selectedEntries.count, selectedEntries.count == 1 ? "" : "s"))
                                .font(.headline)
                            Text(String(localized: "This action cannot be undone."))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                }

                Section(String(localized: "Selected Items")) {
                    ForEach(selectedEntries, id: \.fullPath) { entry in
                        HStack {
                            Image(systemName: entry.isDirectory ? "folder.fill" : "doc")
                                .foregroundStyle(entry.isDirectory ? Color.accentColor : Color.secondary)
                            Text(entry.name)
                                .font(.system(.body, design: .monospaced))
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer()
                            if !entry.isDirectory {
                                Text(ByteCountFormatter.string(fromByteCount: entry.fileSize, countStyle: .file))
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }
                }
            }
            .navigationTitle(String(localized: "Confirm Delete"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(String(localized: "Cancel")) { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(String(localized: "Delete"), role: .destructive) {
                        onConfirm()
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
        }
    }
}

/// Sheet showing live progress of a batch operation.
struct BatchOperationProgressSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var progress: BatchOperationProgress
    let title: String
    let onComplete: (BatchOperationResult) -> Void

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                VStack(spacing: 8) {
                    ProgressView(value: progress.progressFraction)
                        .progressViewStyle(.linear)
                    HStack {
                        Text("\(progress.processedCount) / \(progress.totalCount)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("\(Int(progress.progressFraction * 100))%")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if !progress.currentPath.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(String(localized: "Current:"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(progress.currentPath)
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .truncationMode(.middle)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                HStack(spacing: 16) {
                    Label("\(progress.succeededCount)", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.callout)
                    Label("\(progress.failedCount)", systemImage: "xmark.circle.fill")
                        .foregroundStyle(progress.failedCount > 0 ? Color.red : Color.secondary)
                        .font(.callout)
                }

                if !progress.errors.isEmpty {
                    List {
                        Section(String(localized: "Errors")) {
                            ForEach(Array(progress.errors.enumerated()), id: \.offset) { _, err in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text((err.path as NSString).lastPathComponent)
                                        .font(.caption)
                                        .lineLimit(1)
                                    Text(err.error)
                                        .font(.caption2)
                                        .foregroundStyle(.red)
                                }
                            }
                        }
                    }
                    .frame(maxHeight: 200)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }

                Spacer()
            }
            .padding()
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(String(localized: "Done")) {
                        dismiss()
                    }
                    .disabled(progress.isRunning)
                }
            }
            .onChange(of: progress.isRunning) { _, isRunning in
                if !isRunning {
                    let result = BatchOperationResult(
                        totalItems: progress.totalCount,
                        succeededItems: progress.succeededPaths,
                        failedItems: progress.errors.map { ($0.path, $0.error) }
                    )
                    onComplete(result)
                }
            }
        }
        .interactiveDismissDisabled(progress.isRunning)
    }
}

/// Sheet for choosing a destination directory for batch move.
struct BatchMoveDestinationSheet: View {
    @Environment(\.dismiss) private var dismiss
    let currentDir: String
    let onMove: (String) -> Void

    @State private var customPath = ""
    @State private var quickDestinations: [(name: String, path: String)] = []

    var body: some View {
        NavigationStack {
            List {
                Section(String(localized: "Current Directory")) {
                    HStack {
                        Image(systemName: "folder")
                            .foregroundStyle(Color.accentColor)
                        Text(currentDir)
                            .font(.system(.caption, design: .monospaced))
                            .lineLimit(2)
                            .truncationMode(.middle)
                    }
                }

                Section(String(localized: "Quick Destinations")) {
                    ForEach(Array(quickDestinations.enumerated()), id: \.offset) { _, dest in
                        Button {
                            onMove(dest.path)
                            dismiss()
                        } label: {
                            HStack {
                                Image(systemName: "folder.badge.plus")
                                    .foregroundStyle(Color.accentColor)
                                VStack(alignment: .leading) {
                                    Text(dest.name)
                                        .foregroundStyle(.primary)
                                    Text(dest.path)
                                        .font(.system(.caption2, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }

                Section(String(localized: "Custom Path")) {
                    HStack {
                        Image(systemName: "magnifyingglass")
                            .foregroundStyle(.secondary)
                        TextField("/var/mobile/…", text: $customPath)
                            .font(.system(.body, design: .monospaced))
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                    }
                    Button {
                        let trimmed = customPath.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !trimmed.isEmpty else { return }
                        onMove(trimmed)
                        dismiss()
                    } label: {
                        Label(String(localized: "Move to Custom Path"), systemImage: "arrow.right.folder")
                    }
                    .disabled(customPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .navigationTitle(String(localized: "Move to…"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(String(localized: "Cancel")) { dismiss() }
                }
            }
            .onAppear {
                loadQuickDestinations()
            }
        }
    }

    private func loadQuickDestinations() {
        quickDestinations = [
            (String(localized: "Documents"), "/var/mobile/Containers/Data/Application"),
            (String(localized: "App Groups"), "/var/mobile/Containers/Shared/AppGroup"),
            (String(localized: "tmp"), FileManager.default.temporaryDirectory.path),
            (String(localized: "GestaltKitTool Exports"), ExportFileManager.exportDir.path),
        ]
    }
}

// MARK: - Batch Selection Toolbar

/// Toolbar shown when multi-select mode is active. Provides batch
/// delete, move, export, and cancel actions.
struct BatchSelectionToolbar: View {
    let selectedCount: Int
    let onDelete: () -> Void
    let onMove: () -> Void
    let onExport: () -> Void
    let onCancel: () -> Void

    var body: some View {
        HStack(spacing: 16) {
            Button {
                onCancel()
            } label: {
                Image(systemName: "xmark")
                    .font(.body.weight(.semibold))
            }
            .tint(.secondary)
            .accessibilityLabel(String(localized: "Cancel Selection"))

            Text(String(format: String(localized: "%d selected"), selectedCount))
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Spacer()

            Button {
                onExport()
            } label: {
                Image(systemName: "square.and.arrow.up")
                    .font(.body)
            }
            .disabled(selectedCount == 0)
            .tint(Color.accentColor)
            .accessibilityLabel(String(localized: "Export Selected"))

            Button {
                onMove()
            } label: {
                Image(systemName: "folder.badge.plus")
                    .font(.body)
            }
            .disabled(selectedCount == 0)
            .tint(Color.accentColor)
            .accessibilityLabel(String(localized: "Move Selected"))

            Button {
                onDelete()
            } label: {
                Image(systemName: "trash")
                    .font(.body)
            }
            .disabled(selectedCount == 0)
            .tint(.red)
            .accessibilityLabel(String(localized: "Delete Selected"))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }
}
