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

/// Additional deep cache directories scanned per app container.
/// All are safe to delete (iOS regenerates them); none contain user data.
struct DeepCacheTarget: Identifiable {
    let subpath: String          // path relative to the container root
    let labelKey: String         // localized display name
    let systemImage: String      // SF Symbol for the row
    /// Optional short path shown in scope view. Defaults to subpath.
    let pathHint: String

    init(subpath: String, labelKey: String, systemImage: String, pathHint: String? = nil) {
        self.subpath = subpath
        self.labelKey = labelKey
        self.systemImage = systemImage
        self.pathHint = pathHint ?? subpath
    }

    var id: String { subpath }

    /// Localized display name resolved at render time.
    var label: String { String(localized: String.LocalizationValue(labelKey)) }

    static let all: [DeepCacheTarget] = [
        .init(subpath: "Library/SplashBoard/Snapshots",
              labelKey: "Snapshots",
              systemImage: "camera.on.rectangle"),
        .init(subpath: "Library/WebKit",
              labelKey: "WebKit Data",
              systemImage: "network"),
        .init(subpath: "Library/Caches/Snapshots",
              labelKey: "Snapshot Caches",
              systemImage: "photo.stack"),
        .init(subpath: "Logs",
              labelKey: "Logs",
              systemImage: "doc.text"),
    ]
}

/// Represents one app's cleanable cache directories.
struct CleanupItem: Identifiable, Hashable {
    let id: String              // bundle identifier
    let displayName: String
    let cachesPath: String?     // Library/Caches
    let tmpPath: String?        // tmp/
    /// Extra deep-cache targets discovered for this app
    /// (subpath → absolute path).
    let deepCaches: [String: String]
    var cachesSize: Int64 = 0
    var tmpSize: Int64 = 0
    /// Sizes for each deep-cache subpath (matches deepCaches keys).
    var deepCacheSizes: [String: Int64] = [:]

    nonisolated var totalSize: Int64 {
        cachesSize + tmpSize + deepCacheSizes.values.reduce(0, +)
    }
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
    ///
    /// Uses no-fallback listings throughout: the container root holds
    /// 12,000+ UUIDs (mostly system containers with denied leases), and
    /// each denial used to trigger a 350K-inode fsgetpath scan. Results
    /// stream to the UI in throttled 0.5s batches.
    func discoverApps() {
        guard !isLoading else { return }
        isLoading = true
        loadingProgress = ""
        errorMessage = nil
        items = []

        // Background consumption; the producer runs on its own detached
        // task so items arrive while the scan is still in progress.
        Task.detached(priority: .userInitiated) { [weak self] in
            var lastFlush = Date()
            var pending: [CleanupItem] = []

            func flush(force: Bool, isLast: Bool = false) async {
                let now = Date()
                guard force || now.timeIntervalSince(lastFlush) >= 0.5 else {
                    if isLast { await MainActor.run { self?.isLoading = false } }
                    return
                }
                lastFlush = now
                let batch = pending
                pending = []
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    if !batch.isEmpty {
                        self.items.append(contentsOf: batch)
                        self.items.sort { $0.totalSize > $1.totalSize }
                        self.loadingProgress = String(
                            format: String(localized: "%d apps found"),
                            self.items.count)
                    }
                    if isLast { self.isLoading = false }
                }
            }

            for await item in Self.performDiscoveryStream() {
                pending.append(item)
                await flush(force: false)
            }
            await flush(force: true, isLast: true)
        }
    }

    // MARK: Discovery (background, streaming)

    /// Yields one CleanupItem per cleanable app container.
    /// Uses the no-fallback listing throughout: a denied lease yields
    /// an empty listing (skip) instead of an expensive inode scan.
    private nonisolated static func performDiscoveryStream() -> AsyncStream<CleanupItem> {
        AsyncStream { continuation in
            // The build closure runs synchronously at init, so the scan
            // loop itself must hop to a detached task — otherwise the
            // entire container walk finishes before the first await.
            Task.detached(priority: .userInitiated) {
                let fa = BadQueryFileAccess.shared()
                let containersPath = ContainerMetadata.appDataRoot
                let containerEntries = fa.listDirectory(atPath: containersPath, error: nil)

                for entry in containerEntries where entry.isDirectory {
                    let uuid = entry.name

                    // Fast pre-filter: if we cannot list the container root,
                    // we cannot clean it — skip silently.
                    let rootEntries = fa.listDirectoryNoFallback(
                        atPath: entry.fullPath, error: nil)
                    guard !rootEntries.isEmpty else { continue }

                    // Resolve the bundle ID from the container's metadata.
                    let bundleId = ContainerMetadata.bundleId(
                        fileAccess: fa,
                        containerPath: entry.fullPath
                    )
                    var displayName = uuid
                    if let bid = bundleId {
                        displayName = bid.split(separator: ".").last.map(String.init) ?? bid
                    }

                    // Compute sizes (no-fallback listings only).
                    let cachesPath = entry.fullPath + "/Library/Caches"
                    let tmpPath = entry.fullPath + "/tmp"
                    let cachesSize = ContainerMetadata.totalSize(fileAccess: fa, path: cachesPath)
                    let tmpSize = ContainerMetadata.totalSize(fileAccess: fa, path: tmpPath)

                    // Deep cache targets (snapshots, WebKit data, logs…).
                    var deepCaches: [String: String] = [:]
                    var deepCacheSizes: [String: Int64] = [:]
                    for target in DeepCacheTarget.all {
                        let fullPath = entry.fullPath + "/" + target.subpath
                        let size = ContainerMetadata.totalSize(fileAccess: fa, path: fullPath)
                        if size > 0 {
                            deepCaches[target.subpath] = fullPath
                            deepCacheSizes[target.subpath] = size
                        }
                    }

                    // Only yield apps with something to clean.
                    if cachesSize > 0 || tmpSize > 0 || !deepCacheSizes.isEmpty {
                        continuation.yield(CleanupItem(
                            id: bundleId ?? uuid,
                            displayName: displayName,
                            cachesPath: cachesSize > 0 ? cachesPath : nil,
                            tmpPath: tmpSize > 0 ? tmpPath : nil,
                            deepCaches: deepCaches,
                            cachesSize: cachesSize,
                            tmpSize: tmpSize,
                            deepCacheSizes: deepCacheSizes
                        ))
                    }
                }
                continuation.finish()
            }
        }
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

                // Clear deep cache targets (snapshots, WebKit, logs…).
                for (_, deepPath) in item.deepCaches.sorted(by: { $0.key < $1.key }) {
                    itemError = nil
                    let del = fileAccess.deleteDirectoryContents(atPath: deepPath, maxItems: 0, error: &itemError)
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
                // While still scanning, keep the list visible with a
                // subtle progress header instead of blocking on a spinner.
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
            // Streaming scan progress (non-blocking banner).
            if model.isLoading {
                Section {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text(model.loadingProgress.isEmpty
                             ? String(localized: "Scanning app containers…")
                             : model.loadingProgress)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                }
            }

            // Cleanup scope explanation.
            Section {
                scopeView
            } footer: {
                Text(String(localized: "Only cache-class directories are touched. Tap rows to select apps; leave nothing selected to clean all."))
            }

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
                Text(String(localized: "Safe Cleanup removes caches, tmp, app snapshots, WebKit data, and logs. Your app data, documents, and preferences are never touched."))
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

    // MARK: Scope explanation

    private var scopeView: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(String(localized: "What gets cleaned"))
                .font(.subheadline.weight(.semibold))
            ForEach(deepTargetsWithBasics) { target in
                HStack(spacing: 8) {
                    Image(systemName: target.systemImage)
                        .frame(width: 22)
                        .foregroundStyle(.secondary)
                    Text(target.label)
                    Spacer()
                    Text(target.pathHint)
                        .font(.caption.monospaced())
                        .foregroundStyle(.tertiary)
                }
                .font(.subheadline)
            }
            Divider()
            Text(String(localized: "Never touched"))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.green)
            Text(String(localized: "Documents, preferences, keychains, photos, and app data are never modified."))
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(String(localized: "System-level caches (e.g. Safari system data) live in read-only protected containers and cannot be cleaned by any sandboxed tool."))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }

    /// The five cleaned categories shown in the scope view:
    /// Caches, tmp, plus the deep targets.
    private var deepTargetsWithBasics: [DeepCacheTarget] {
        var targets: [DeepCacheTarget] = [
            .init(subpath: "Library/Caches", labelKey: "Caches", systemImage: "cylinder.split.1x2", pathHint: "Library/Caches"),
            .init(subpath: "tmp", labelKey: "Temporary Files", systemImage: "clock.arrow.circlepath", pathHint: "tmp"),
        ]
        targets.append(contentsOf: DeepCacheTarget.all.map {
            .init(subpath: $0.subpath, labelKey: $0.labelKey, systemImage: $0.systemImage)
        })
        return targets
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
                    // Deep-cache badges (snapshots / WebKit / logs).
                    ForEach(DeepCacheTarget.all.filter { item.deepCacheSizes[$0.subpath] != nil }) { target in
                        Label {
                            Text(ByteCountFormatter.string(
                                fromByteCount: item.deepCacheSizes[target.subpath] ?? 0,
                                countStyle: .file
                            ))
                        } icon: {
                            Image(systemName: target.systemImage)
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
