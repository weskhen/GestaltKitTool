//
//  SafeCleanup.swift
//  GestaltKitTool
//
//  Safe cleanup: clears Library/Caches and tmp/ directories for all app containers.
//  Only removes cache and temporary files — never touches Documents, Library/Preferences, or app bundles.
//

import Combine
import SwiftUI

// MARK: - Cleanup Item

/// Represents one app's cleanable cache directories.
struct CleanupItem: Identifiable, Hashable {
    let id: String              // bundle identifier
    let displayName: String
    let cachesPath: String?     // Library/Caches
    let tmpPath: String?        // tmp/
    var cachesSize: Int64 = 0
    var tmpSize: Int64 = 0

    nonisolated var totalSize: Int64 { cachesSize + tmpSize }
    nonisolated var sizeFormatted: String {
        ByteCountFormatter.string(fromByteCount: totalSize, countStyle: .file)
    }

    // Pre-computed to reduce allocation during list rendering.
    nonisolated var cachesSizeFormatted: String {
        ByteCountFormatter.string(fromByteCount: cachesSize, countStyle: .file)
    }
    nonisolated var tmpSizeFormatted: String {
        ByteCountFormatter.string(fromByteCount: tmpSize, countStyle: .file)
    }
}

// MARK: - Cleanup Progress

struct CleanupProgress {
    var currentApp: String = ""
    var appsCleaned: Int = 0
    var totalApps: Int = 0
    var bytesFreed: Int64 = 0
    var itemsDeleted: Int = 0
    var isComplete: Bool = false
    var error: String?

    var fraction: Double {
        totalApps > 0 ? Double(appsCleaned) / Double(totalApps) : 0
    }
    var percentText: String { String(format: "%.0f%%", fraction * 100) }
    var bytesFormatted: String {
        ByteCountFormatter.string(fromByteCount: bytesFreed, countStyle: .file)
    }
}

// MARK: - Safe Cleanup Model

@MainActor
final class SafeCleanupModel: ObservableObject {

    @Published var items: [CleanupItem] = []
    @Published var isLoading = false
    @Published var loadingProgress = ""
    @Published var isCleaning = false
    @Published var progress = CleanupProgress()
    @Published var errorMessage: String?

    /// Selected app IDs for cleanup. Empty = all apps.
    @Published var selectedIds: Set<String> = []

    private let fileAccess = BadQueryFileAccess.shared()

    var totalCleanableSize: Int64 {
        items.reduce(0) { $0 + $1.totalSize }
    }
    var totalCleanableFormatted: String {
        ByteCountFormatter.string(fromByteCount: totalCleanableSize, countStyle: .file)
    }

    /// Discovers all apps and computes their cache sizes.
    func discoverApps() {
        isLoading = true
        loadingProgress = ""
        errorMessage = nil

        Task {
            let discovered = await performDiscovery()
            self.items = discovered
            self.isLoading = false
        }
    }

    // MARK: Discovery (background)

    private nonisolated func performDiscovery() async -> [CleanupItem] {
        let fa = BadQueryFileAccess.shared()

        // Enumerate app data containers.
        let containersPath = ContainerMetadata.appDataRoot
        let containerEntries = fa.listDirectory(atPath: containersPath, error: nil)

        var results: [CleanupItem] = []
        var idx = 0

        for entry in containerEntries where entry.isDirectory {
            idx += 1
            let uuid = entry.name

            // duplicated inline metadata parsing.
            let bundleId = ContainerMetadata.bundleId(
                fileAccess: fa,
                containerPath: entry.fullPath
            )
            var displayName = uuid

            if let bid = bundleId {
                displayName = bid.split(separator: ".").last.map(String.init) ?? bid
            }

            // Compute Caches size.
            let cachesPath = entry.fullPath + "/Library/Caches"
            let tmpPath = entry.fullPath + "/tmp"

            let cachesSize = ContainerMetadata.totalSize(
                fileAccess: fa, path: cachesPath, maxDepth: 5
            )
            let tmpSize = ContainerMetadata.totalSize(
                fileAccess: fa, path: tmpPath, maxDepth: 5
            )

            // Skip apps with nothing to clean.
            if cachesSize > 0 || tmpSize > 0 {
                let item = CleanupItem(
                    id: bundleId ?? uuid,
                    displayName: displayName,
                    cachesPath: cachesSize > 0 ? cachesPath : nil,
                    tmpPath: tmpSize > 0 ? tmpPath : nil,
                    cachesSize: cachesSize,
                    tmpSize: tmpSize
                )
                results.append(item)
            }

            // Update loading progress periodically.
            if idx % 20 == 0 {
                let prog = "\(idx) containers scanned"
                await MainActor.run {
                    self.loadingProgress = prog
                }
            }
        }

        // Sort by size descending.
        results.sort { $0.totalSize > $1.totalSize }
        return results
    }

    // MARK: Cleanup execution

    func runCleanup() {
        guard !isCleaning else { return }

        let targets = selectedIds.isEmpty
            ? items
            : items.filter { selectedIds.contains($0.id) }

        guard !targets.isEmpty else { return }

        isCleaning = true
        progress = CleanupProgress(totalApps: targets.count)
        errorMessage = nil

        let fileAccess = self.fileAccess

        // Run the heavy deletion work on a background queue to avoid
        // blocking the MainActor (UI would freeze during large cache clears).
        Task.detached(priority: .userInitiated) { [weak self] in
            var freed: Int64 = 0
            var deleted: Int = 0
            var cleaned = 0

            for item in targets {
                let sizeBefore = item.totalSize

                var itemDeletedCount = 0
                var itemError: NSError?

                // Clear Caches.
                if let cachesPath = item.cachesPath {
                    let del = fileAccess.deleteDirectoryContents(atPath: cachesPath, maxItems: 0, error: &itemError)
                    if del >= 0 { itemDeletedCount += Int(del) }
                    // If error, don't count freed bytes for this path.
                }

                // Clear tmp.
                if let tmpPath = item.tmpPath {
                    itemError = nil  // reset for tmp check
                    let del = fileAccess.deleteDirectoryContents(atPath: tmpPath, maxItems: 0, error: &itemError)
                    if del >= 0 { itemDeletedCount += Int(del) }
                }

                deleted += itemDeletedCount

                // something from this app (not just because sizeBefore > 0).
                if itemDeletedCount > 0 && sizeBefore > 0 {
                    freed += sizeBefore
                }
                cleaned += 1

                // so the UI shows accurate counters.
                let currentCleaned = cleaned
                let currentFreed = freed
                let currentDeleted = deleted
                let appName = item.displayName
                Task { @MainActor [weak self] in
                    self?.progress.currentApp = appName
                    self?.progress.appsCleaned = currentCleaned
                    self?.progress.bytesFreed = currentFreed
                    self?.progress.itemsDeleted = currentDeleted
                }
            }

            let finalCleaned = cleaned
            let finalFreed = freed
            let finalDeleted = deleted
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.progress.appsCleaned = finalCleaned
                self.progress.bytesFreed = finalFreed
                self.progress.itemsDeleted = finalDeleted
                self.progress.isComplete = true
                self.progress.error = nil
                self.isCleaning = false

                // `guard !self.isCleaning` right after setting
                // isCleaning = false, which always passed. The intent
                // was to re-discover apps to refresh sizes. Just do it.
                self.discoverApps()
            }
        }
    }
}

// MARK: - Safe Cleanup View

struct SafeCleanupView: View {
    @StateObject private var model = SafeCleanupModel()

    var body: some View {
        Group {
            if model.isLoading && model.items.isEmpty {
                loadingView
            } else if model.items.isEmpty && !model.isLoading {
                emptyView
            } else {
                contentView
            }
        }
        .navigationTitle(String(localized: "Safe Cleanup"))
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            if !model.items.isEmpty && !model.isCleaning {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        model.runCleanup()
                    } label: {
                        Text(String(localized: "Clean"))
                            .fontWeight(.semibold)
                    }
                    .disabled(model.isCleaning || model.isLoading)
                }
            }
        }
        .onAppear {
            if model.items.isEmpty {
                model.discoverApps()
            }
        }
    }

    // MARK: Loading

    private var loadingView: some View {
        VStack(spacing: 16) {
            ProgressView()
                .scaleEffect(1.5)
            Text(model.loadingProgress.isEmpty
                 ? String(localized: "Scanning app containers…")
                 : model.loadingProgress)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Empty

    private var emptyView: some View {
        VStack(spacing: 20) {
            Image(systemName: "sparkles")
                .font(.system(size: DesignConstants.heroIconSize))
                .foregroundStyle(.secondary)
            Text(String(localized: "Nothing to Clean"))
                .font(.title2.bold())
            Text(String(localized: "No app cache or temporary files were found. Your device is already clean."))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Button {
                model.discoverApps()
            } label: {
                Label(String(localized: "Rescan"), systemImage: "arrow.clockwise")
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Content

    private var contentView: some View {
        List {
            // Progress section.
            if model.isCleaning || model.progress.isComplete {
                Section {
                    CleanupProgressView(progress: model.progress)
                }
            }

            // Summary.
            Section {
                LabeledContent {
                    Text(model.totalCleanableFormatted)
                        .font(.headline)
                        .foregroundStyle(.orange)
                } label: {
                    Label(String(localized: "Total Cleanable"), systemImage: "trash.circle")
                }
                .listRowSeparator(.hidden)

                LabeledContent {
                    Text(verbatim: "\(model.items.count) \(String(localized: "apps"))")
                        .foregroundStyle(.secondary)
                } label: {
                    Label(String(localized: "Apps with Cache"), systemImage: "app.badge")
                }
            } header: {
                Text(String(localized: "Summary"))
            } footer: {
                Text(String(localized: "Safe Cleanup only removes Library/Caches and tmp/ directories. Your app data, documents, and preferences are never touched."))
            }

            // Per-app list.
            Section {
                ForEach(model.items) { item in
                    CleanupRowView(item: item, isSelected: model.selectedIds.contains(item.id))
                        .contentShape(Rectangle())
                        .onTapGesture {
                            if model.selectedIds.contains(item.id) {
                                model.selectedIds.remove(item.id)
                            } else {
                                model.selectedIds.insert(item.id)
                            }
                        }
                }
            } header: {
                HStack {
                    Text(String(localized: "Apps"))
                    Spacer()
                    if !model.selectedIds.isEmpty {
                        Button(String(localized: "Clear Selection")) {
                            model.selectedIds.removeAll()
                        }
                        .font(.caption)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
    }
}

// MARK: - Cleanup Row

private struct CleanupRowView: View {
    let item: CleanupItem
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: isSelected ? "checkmark.circle.fill" : "app.dashed")
                .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                .font(.body)

            VStack(alignment: .leading, spacing: 3) {
                Text(item.displayName)
                    .font(.body)
                    .lineLimit(1)
                if !item.id.isEmpty {
                    Text(item.id)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                HStack(spacing: 8) {
                    if item.cachesSize > 0 {
                        Label {
                            Text(item.cachesSizeFormatted)
                        } icon: {
                            Image(systemName: "cylinder.split.1x2")
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    if item.tmpSize > 0 {
                        Label {
                            Text(item.tmpSizeFormatted)
                        } icon: {
                            Image(systemName: "clock.arrow.circlepath")
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }
            }

            Spacer()

            Text(item.sizeFormatted)
                .font(.system(.subheadline, design: .monospaced))
                .foregroundStyle(.orange)
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Progress View

private struct CleanupProgressView: View {
    let progress: CleanupProgress

    var body: some View {
        VStack(spacing: 8) {
            if progress.isComplete {
                HStack {
                    Label(String(localized: "Cleanup Complete"), systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Spacer()
                    Text(progress.bytesFormatted)
                        .font(.headline)
                        .foregroundStyle(.green)
                }
                HStack {
                    Text(String(format: String(localized: "%d apps cleaned"), progress.appsCleaned))
                    Spacer()
                    Text(String(format: String(localized: "%d items deleted"), progress.itemsDeleted))
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            } else {
                HStack {
                    ProgressView(value: progress.fraction)
                    Text(progress.percentText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 40, alignment: .trailing)
                }
                HStack {
                    Text(progress.currentApp)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer()
                    Text("\(progress.appsCleaned)/\(progress.totalApps)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(String(format: String(localized: "%@ freed so far"), progress.bytesFormatted))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 4)
    }
}
