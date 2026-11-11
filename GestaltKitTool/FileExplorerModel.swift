//
//  FileExplorerModel.swift
//  GestaltKitTool
//
//  Model layer for the cross-application File Explorer.
//  Enumerates installed app containers and provides browsing
//  capabilities via BadQueryFileAccess.
//

import Combine
import Foundation

// MARK: - BQFileEntry Identifiable & Sendable Conformance

extension BQFileEntry: Identifiable {
    public var id: String { fullPath }
}

// BQFileEntry is immutable after creation (all properties are readonly/copy),
// so it is safe to mark as Sendable for cross-actor sharing.
extension BQFileEntry: @unchecked Sendable {}

// BadQueryFileAccess is a stateless singleton — all methods are self-contained
// and do not mutate shared state. Safe for cross-actor use.
extension BadQueryFileAccess: @unchecked Sendable {}

// MARK: - App Container Discovery

/// Represents a discovered app data container on the device.
struct AppContainer: Identifiable, Hashable {
    let id: String          // UUID directory name
    let path: String        // Full path to the container
    let bundleIdentifier: String?  // Extracted from metadata if available
    let displayName: String  // Best-effort app name
    let containerType: ContainerType

    enum ContainerType: String, Hashable {
        case data       = "Data"
        case appGroup   = "AppGroup"
        case shared     = "Shared"
    }

    static func == (lhs: AppContainer, rhs: AppContainer) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

/// A bookmarked directory for quick access.
struct Favorite: Identifiable, Codable, Hashable {
    let id: String        // Use path as ID
    let path: String
    let name: String      // Display name (last path component or custom)
    let bookmarkedAt: Date

    init(path: String, name: String? = nil) {
        self.id = path
        self.path = path
        self.name = name ?? (path as NSString).lastPathComponent
        self.bookmarkedAt = Date()
    }
}

/// A search result found during recursive or global search.
struct SearchResult: Identifiable {
    let id: String        // fullPath
    let entry: BQFileEntry
    let relativePath: String  // Path relative to search root
    let containerName: String? // App container name (for global search)
}

/// A predefined quick-access path shown on the Explorer root page.
struct QuickPath: Identifiable {
    let id = UUID()
    let name: String
    let path: String
    let icon: String          // SF Symbol name
    let category: QuickPathCategory
    let description: String   // Description shown in info sheet

    enum QuickPathCategory: String, CaseIterable {
        case system    = "System"
        case user      = "User Data"
        case developer = "Developer"
        case local     = "Local Storage"

        var localizedLabel: String {
            switch self {
            case .system:    return String(localized: "System")
            case .user:      return String(localized: "User Data")
            case .developer: return String(localized: "Developer")
            case .local:     return String(localized: "Local Storage")
            }
        }
    }
}

// MARK: - Search Filters

/// Which container set a recursive search should walk. Mirrors Filza's
/// "Scope: Current App / All Apps" search scope selector.
enum SearchScope: String, CaseIterable, Identifiable {
    case auto       = "Auto"        // Follow navigationPath: empty → global, else → current container
    case global     = "All Apps"    // Always cross-container global
    case container  = "Current Container"

    var id: String { rawValue }

    var localizedLabel: String {
        switch self {
        case .auto:      return String(localized: "Auto")
        case .global:    return String(localized: "All Apps")
        case .container: return String(localized: "Current Container")
        }
    }
}

/// File-size qualifier. Applied AFTER the recursive search returns so we
/// don't need extra stat() calls — every `BQFileEntry` already carries the
/// byte size back from the bad_query directory listing.
enum SizeFilter: Int, CaseIterable, Identifiable {
    case any        = 0
    case lt100KB    = 1   //    < 100 KB
    case lt1MB      = 2   //    <   1 MB
    case lt100MB    = 3   //    < 100 MB
    case gt100MB    = 4   //    > 100 MB

    var id: Int { rawValue }

    var localizedLabel: String {
        switch self {
        case .any:     return String(localized: "Any Size")
        case .lt100KB: return String(localized: "< 100 KB")
        case .lt1MB:   return String(localized: "< 1 MB")
        case .lt100MB: return String(localized: "< 100 MB")
        case .gt100MB: return String(localized: "> 100 MB")
        }
    }

    /// Byte thresholds used for predicate matching. 1024-base matches
    /// Finder and iOS Files.app conventions.
    private var thresholdBytes: Int64 {
        switch self {
        case .any:     return 0
        case .lt100KB: return 100 * 1024
        case .lt1MB:   return 1024 * 1024
        case .lt100MB: return 100 * 1024 * 1024
        case .gt100MB: return 100 * 1024 * 1024
        }
    }

    func matches(_ sizeBytes: Int64) -> Bool {
        if sizeBytes < 0 { return true /* unknown size, pass through */ }
        switch self {
        case .any:                           return true
        case .lt100KB, .lt1MB, .lt100MB:     return sizeBytes < thresholdBytes
        case .gt100MB:                       return sizeBytes > thresholdBytes
        }
    }
}

/// File-type qualifier. Reuses `FileTypeRegistry.FileKind` so the chips
/// stay consistent with the per-file badges everywhere else in Explorer.
enum TypeFilter: Int, CaseIterable, Identifiable {
    case any        = 0
    case plist      = 1
    case image      = 2
    case database   = 3
    case archive    = 4   // .zip .tar .gz .bz2 .xz .7z .rar
    case text       = 5
    case json       = 6
    case xml        = 7
    case binary     = 8

    var id: Int { rawValue }

    var localizedLabel: String {
        switch self {
        case .any:     return String(localized: "Any Type")
        case .plist:   return String(localized: "Plist")
        case .image:   return String(localized: "Image")
        case .database:return String(localized: "Database")
        case .archive: return String(localized: "Archive")
        case .text:    return String(localized: "Text")
        case .json:    return String(localized: "JSON")
        case .xml:     return String(localized: "XML")
        case .binary:  return String(localized: "Binary")
        }
    }

    /// Returns true when the given extension / detected kind falls into
    /// this filter bucket. Falls back to extension-only guessing so we
    /// don't trigger magic-byte reads for every result.
    func matches(name: String, kind: FileKind?) -> Bool {
        switch self {
        case .any: return true
        case .plist:
            if let kind { return kind == .plist }
            return ["plist", "mobileconfig"].contains(
                (name as NSString).pathExtension.lowercased())
        case .image:
            if let kind { return kind == .image }
            let ext = (name as NSString).pathExtension.lowercased()
            return ["png", "jpg", "jpeg", "heic", "heif", "gif", "webp",
                    "tiff", "tif", "bmp", "svg"].contains(ext)
        case .database:
            if let kind { return kind == .database }
            let ext = (name as NSString).pathExtension.lowercased()
            return ["db", "sqlite", "sqlite3", "sqlitedb", "rdb",
                    "realm"].contains(ext)
        case .archive:
            let ext = (name as NSString).pathExtension.lowercased()
            return ["zip", "tar", "gz", "tgz", "bz2", "tbz2", "xz", "txz",
                    "7z", "rar", "lz4", "zst"].contains(ext)
        case .text:
            if let kind { return kind == .text }
            let ext = (name as NSString).pathExtension.lowercased()
            return ["txt", "log", "md", "cfg", "conf", "ini", "yaml",
                    "yml", "toml"].contains(ext)
        case .json:
            if let kind { return kind == .json }
            return (name as NSString).pathExtension.lowercased() == "json"
        case .xml:
            if let kind { return kind == .xml }
            let ext = (name as NSString).pathExtension.lowercased()
            return ["xml", "html", "xhtml", "entitlements"].contains(ext)
        case .binary:
            if let kind { return kind == .binary }
            return true // fallback bucket — binary is the catch-all last
        }
    }
}

/// File explorer model that uses BadQueryFileAccess to enumerate
/// and browse app sandbox directories across the device.
@MainActor
final class FileExplorerModel: ObservableObject {
    @Published var containers: [AppContainer] = []
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var currentEntries: [BQFileEntry] = []
    @Published var navigationPath: [String] = []  // Stack of directory paths
    @Published var filePreview: FilePreview?
    @Published var favorites: [Favorite] = []
    @Published var searchResults: [SearchResult] = []
    @Published var isSearching = false
    @Published var searchProgress = ""

    // Scroll position memory — remembers the last visible entry per directory.
    @Published var scrollRestoreTarget: String?
    private var _scrollPositionCache: [String: String] = [:]

    // MARK: - Archive state

    /// Aggregate size of all archive entries, recomputed when the
    /// archive listing is requested by the UI.
    @Published private(set) var archiveStatsTotalBytes: Int64 = 0
    @Published private(set) var archiveStatsCount: Int = 0
    /// Set by archive actions so the UI can show progress / toast.
    @Published var archiveLastMessage: String? = nil

    // Entry cache keyed by absolute directory path.
    // Provides atomic navigation rollback, O(1) navigateBack, and resilience to browse failures.
    private let maxCachedPaths = 200
    private var _entryCacheAccessOrder: [String] = []  // oldest first, newest last
    private var _entryCache: [String: [BQFileEntry]] = [:]

    /// Touch a cache key in the LRU order (move to end).
    private func _touchCacheKey(_ key: String) {
        _entryCacheAccessOrder.removeAll { $0 == key }
        _entryCacheAccessOrder.append(key)
    }

    /// Evict oldest entries when cache exceeds `maxCachedPaths`.
    private func _evictExcessCacheEntries() {
        while _entryCacheAccessOrder.count > maxCachedPaths {
            let oldest = _entryCacheAccessOrder.removeFirst()
            _entryCache.removeValue(forKey: oldest)
        }
    }

    private func clearCachesOnMemoryPressure() {
        _entryCache.removeAll()
        _entryCacheAccessOrder.removeAll()
        _scrollPositionCache.removeAll()
        gktlLog("[GKTL-Browse] memory pressure — cleared entry cache and scroll position cache")
    }

    /// Restore `currentEntries` from the cache for `path`.
    /// Returns true if cache hit. An empty array sentinel means "truly empty directory".
    @discardableResult
    private func _restoreCachedEntries(for path: String) -> Bool {
        // Use normalized path as cache key so /var/X and /private/var/X hit the same entry.
        let normKey = Self._normalizePath(path)
        if let cached = _entryCache[normKey] {
            _touchCacheKey(normKey)
            // Re-dedupe on restore as a safety net.
            var seen: Set<String> = []
            seen.reserveCapacity(cached.count)
            let cleanEntries = cached.filter { entry in
                let key = Self._normalizePath(entry.fullPath)
                return seen.insert(key).inserted
            }
            let removedDups = cached.count - cleanEntries.count
            if removedDups > 0 {
                gktlLog("[GKTL-Browse] restore-cache LATE-DEDUP removed=%d from cached entries for path=%@",
                      removedDups, String(path.suffix(36)))
                // Overwrite cache with clean version.
                _entryCache[normKey] = cleanEntries
            }
            currentEntries = cleanEntries
            errorMessage = nil
            isLoading = false
            return true
        }
        return false
    }

    // MARK: Empty-directory filter

    /// Drops directory entries confirmed empty via opendir+readdir.
    /// Runs on a background thread — touches no MainActor-isolated state.
    ///
    /// Conservative rule: if opendir() fails for any reason the entry is KEPT.
    /// Only directories confirmed empty by opendir are hidden.
    nonisolated private func _filterOutEmptyDirectories(
        _ entries: [BQFileEntry]
    ) -> [BQFileEntry] {
        // Safeguards: maxEntries skips filter for large dirs; maxTotalMs is a wall-clock budget.
        let SLOW_ENTRY_MS: Double = 200.0
        let MAX_ENTRIES: Int = 200
        let MAX_TOTAL_MS: Double = 500.0

        // Safeguard 1: too many entries → skip filter entirely.
        if entries.count > MAX_ENTRIES {
            gktlLog("[GKTL-Browse] empty-dir-filter SKIP entries.count=%d > %d (safeguard: avoid pathological slow scan)",
                  entries.count, MAX_ENTRIES)
            return entries
        }

        var filtered: [BQFileEntry] = []
        filtered.reserveCapacity(entries.count)
        let tStart = CFAbsoluteTimeGetCurrent()

        for entry in entries {
            // Safeguard 2: budget exhausted → bail early, keep rest.
            let elapsedMs = (CFAbsoluteTimeGetCurrent() - tStart) * 1000.0
            if elapsedMs >= MAX_TOTAL_MS {
                gktlLog("[GKTL-Browse] empty-dir-filter BUDGET-EXHAUSTED elapsed=%.0fms ≥ %.0fms — kept remaining %d entries unfiltered",
                      elapsedMs, MAX_TOTAL_MS, entries.count - filtered.count)
                filtered.append(contentsOf: entries[filtered.count..<entries.count])
                break
            }

            // Non-directories are always kept.
            guard entry.isDirectory else {
                filtered.append(entry)
                continue
            }

            let t0 = CFAbsoluteTimeGetCurrent()
            let result: Bool = entry.fullPath.withCString { fsRep -> Bool in
                guard let dir = opendir(fsRep) else {
                    return true   // can't inspect → treat as non-empty
                }
                defer { closedir(dir) }
                while let direntPtr = readdir(dir) {
                    let d_name = direntPtr.pointee.d_name
                    let b0 = d_name.0
                    if b0 == 0 { continue }
                    if b0 != 0x2E /* '.' */ { return true }
                    let b1 = d_name.1
                    if b1 == 0    { continue }        // "."
                    if b1 != 0x2E { return true }     // ".x…" real child
                    if d_name.2 == 0 { continue }     // ".."
                    return true                        // "..x" real child
                }
                return false   // only "." + ".." → EMPTY
            }
            let ms = (CFAbsoluteTimeGetCurrent() - t0) * 1000.0
            if ms >= SLOW_ENTRY_MS {
                let name = URL(fileURLWithPath: entry.fullPath).lastPathComponent
                gktlLog("[GKTL-Browse] empty-dir-filter SLOW-SCAN path=…%@ isEmpty=%d (%.0fms — >%.0fms threshold)",
                      String(name.suffix(40)), result ? 0 : 1, ms, SLOW_ENTRY_MS)
            }
            if result {
                filtered.append(entry)
            }
        }
        return filtered
    }

    // MARK: Empty-directory tap guard

    /// Returns true if `path` is a confirmed-empty directory.
    /// Conservative: any failure returns false → normal navigation proceeds.
    /// Prevents breadcrumb pollution and "infinite nesting" when tapping empty dirs.
    nonisolated private func _isEmptyDirectory(_ path: String) -> Bool {
        return path.withCString { fsRep -> Bool in
            guard let dir = opendir(fsRep) else {
                return false  // can't inspect → treat as non-empty
            }
            defer { closedir(dir) }
            while let direntPtr = readdir(dir) {
                let d_name = direntPtr.pointee.d_name
                let b0 = d_name.0
                if b0 == 0 { continue }
                if b0 != 0x2E /* '.' */ { return false }
                let b1 = d_name.1
                if b1 == 0    { continue }        // "."
                if b1 != 0x2E { return false }    // ".x…" real child
                if d_name.2 == 0 { continue }     // ".."
                return false                       // "..x" real child
            }
            return true  // only "." + ".." → EMPTY
        }
    }

    // MARK: Search filter state

    /// Controls which container set is searched. Mirrors Filza's scope
    /// segmented control. Default: `.auto` (empty nav → global, else →
    /// current container). The UI offers a Picker so users can force
    /// cross-container search even while inside a deep directory.
    @Published var searchScope: SearchScope = .auto

    /// Size qualifier chip. Applied AFTER the recursive search finishes
    /// (on the 500-row local result set — essentially free).
    @Published var sizeFilter: SizeFilter = .any

    /// Type qualifier chip. Same performance profile as size filter.
    @Published var typeFilter: TypeFilter = .any

    /// The "raw" unfiltered results returned by the last recursive
    /// search. We keep them so changing the filter chips doesn't require
    /// restarting the bad_query-powered directory enumeration. Filter
    /// changes just recompute `searchResults` from this array in O(N)
    /// on the 500-row cap.
    private var rawSearchResults: [SearchResult] = []

    /// Running tally of the raw result count as results stream in. Used
    /// by the "Searching 37/200 · 142 matches" progress line so users
    /// see the match count grow live, not only at completion. Also
    /// published to SwiftUI as `rawSearchCount` so the result-section
    /// header can display "Filtered 3 / 142" when size/type filters
    /// are reducing the visible set.
    @Published private(set) var rawSearchCount: Int = 0

    // MARK: Lifecycle — cross-tab background-task cancellation

    /// Raised by DiagnosticsView (via NotificationCenter) just
    /// before it runs the diagnostics suite so any lingering Explorer
    /// background work (discoverContainers / recursive search) does not
    /// contend with diagnostics on the ContainerManager XPC queue —
    /// which previously caused Diagnostics to appear hung for 10–30 s
    /// while ContainerManager was also processing thousands of
    /// fsgetpath-based directory entries.
    private let discoverCancelledLock = NSLock()
    private nonisolated(unsafe) var discoverCancelledFlag: Bool = false
    private var observer: NSObjectProtocol?
    private var memoryObserver: NSObjectProtocol?

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        if let memoryObserver { NotificationCenter.default.removeObserver(memoryObserver) }
    }

    /// Returns YES if discoverContainers has been requested to stop by
    /// a cross-tab cancellation notification. Used only in background
    /// loops; the search code uses the generation-token mechanism.
    private nonisolated func isDiscoverCancelled() -> Bool {
        discoverCancelledLock.lock()
        defer { discoverCancelledLock.unlock() }
        return discoverCancelledFlag
    }

    /// Called once a new discoverContainers run begins so the prior
    /// cancelled state (from a Diagnostics run that raced) doesn't
    /// immediately stop a freshly-started container discovery.
    private nonisolated func resetDiscoverCancelled() {
        discoverCancelledLock.lock()
        defer { discoverCancelledLock.unlock() }
        discoverCancelledFlag = false
    }

    /// Cross-tab cancellation "raise the flag". Called from the
    /// notification observer. The observer closure is now wrapped in
    /// `Task { @MainActor in }` (per Swift 6 Strict Concurrency), so
    /// we must bounce through a nonisolated shim — NSLock.lock() is
    /// marked unavailable-from-async in Swift 6 language mode even
    /// when the Task executes synchronously on the main actor.
    private nonisolated func raiseDiscoverCancelled() {
        discoverCancelledLock.lock()
        defer { discoverCancelledLock.unlock() }
        discoverCancelledFlag = true
    }

    /// Applies the currently selected size / type filters to
    /// `rawSearchResults` and publishes the result into `searchResults`.
    /// O(N) over the filtered max-500 array; callable from the main
    /// thread only since it mutates @Published.
    func recomputeFilteredResults() {
        let size = sizeFilter
        let type = typeFilter
        searchResults = rawSearchResults.filter { result in
            // Size — use entry.fileSize (populated by bad_query listing).
            guard size.matches(result.entry.fileSize) else { return false }
            // Type — use extension-based classification; skip magic bytes
            // in post-filter stage to keep recomputeFilteredResults O(N) fast.
            let name = result.entry.name
            let ext = (name as NSString).pathExtension
            let kind: FileKind? = ext.isEmpty ? nil : FileTypeRegistry.classify(extension: ext)
            return type.matches(name: name, kind: kind)
        }
    }

    /// Exposed so the FileExplorerView Cancel button can cancel the
    /// running recursive search. Also clears the debounce task inside
    /// the view, but this method handles the model side: bump the
    /// generation token so background workers compare-fail on next
    /// directory iteration and exit fast, reset flags + progress, and
    /// broadcast empty results.
    func cancelSearch() {
        // Bump generation so background workers exit fast.
        _ = nextSearchGeneration()
        isSearching = false
        searchProgress = ""
        rawSearchResults = []
        rawSearchCount = 0
        searchResults = []
    }

    // The searchGeneration is incremented on every new search. Background
    // tasks capture their generation number and bail out if it no longer
    // matches the current generation, preventing stale results from
    // overwriting newer ones.
    private nonisolated(unsafe) var _searchGeneration: Int = 0
    private let searchLock = NSLock()
    /// Incremented when a new search starts or the current search is cancelled.
    /// Background tasks read this to detect cancellation.
    /// nonisolated: accessed from background threads, protected by searchLock.
    nonisolated var searchGeneration: Int {
        searchLock.lock()
        defer { searchLock.unlock() }
        return _searchGeneration
    }
    /// Atomically increments and returns the new generation.
    nonisolated private func nextSearchGeneration() -> Int {
        searchLock.lock()
        _searchGeneration += 1
        let gen = _searchGeneration
        searchLock.unlock()
        return gen
    }

    private let fileAccess = BadQueryFileAccess.shared()
    private let favoritesKey = "com.wesk.vtool.explorer.favorites"

    init() {
        loadFavorites()

        // Cross-tab cancellation handshake. DiagnosticsModel posts
        // this notification the moment "Run All Diagnostics" is tapped
        // so any Explorer background work (container discovery,
        // recursive search) is stopped cleanly — both releases the
        // process-wide sandbox-extension quota (so lease acquisition
        // during diagnostic tests doesn't starve) and eliminates the
        // symptom where Diagnostics appeared to be "hung" while both
        // tabs contended on the ContainerManager XPC serial queue.
        let name = Notification.Name("GKTCancelBackgroundExplorerTasks")
        observer = NotificationCenter.default.addObserver(
            forName: name,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            // (Swift 6 Strict Concurrency fix): DispatchQueue.main
            // (GCD) is NOT equivalent to the MainActor executor as a
            // language-level guarantee. MainActor.assumeIsolated would
            // assert-fail if ever called outside the true MainActor
            // isolation domain. Task { @MainActor in } is the standard
            // Concurrency bridge — the runtime performs the correct hop
            // onto the MainActor executor regardless of which thread the
            // notification closure actually fires on.
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.cancelSearch()
                // Nonisolated shim — NSLock is not available from
                // Swift 6 async contexts (even synchronous MainActor
                // Task bodies). See raiseDiscoverCancelled().
                self.raiseDiscoverCancelled()
                self.isLoading = false
            }
        }

        memoryObserver = NotificationCenter.default.addObserver(
            forName: MemoryPressureMonitor.didReceiveWarning,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.clearCachesOnMemoryPressure()
            }
        }
    }

    // MARK: - Favorites

    private func loadFavorites() {
        guard let data = UserDefaults.standard.data(forKey: favoritesKey),
              let decoded = try? JSONDecoder().decode([Favorite].self, from: data) else {
            favorites = []
            return
        }
        favorites = decoded
    }

    private func saveFavorites() {
        if let data = try? JSONEncoder().encode(favorites) {
            UserDefaults.standard.set(data, forKey: favoritesKey)
        }
    }

    func isFavorited(path: String) -> Bool {
        favorites.contains { $0.path == path }
    }

    func toggleFavorite(path: String, name: String? = nil) {
        if let index = favorites.firstIndex(where: { $0.path == path }) {
            favorites.remove(at: index)
        } else {
            favorites.append(Favorite(path: path, name: name))
        }
        saveFavorites()
    }

    func removeFavorite(at index: Int) {
        guard index < favorites.count else { return }
        favorites.remove(at: index)
        saveFavorites()
    }

    /// The current directory path if browsing, for the bookmark button state.
    var currentDirectoryPath: String? {
        navigationPath.last
    }

    // Standard container root directories on iOS.
    // Use /var/... (no /private prefix) — ContainerManager uses these forms.
    private let appDataRoot = "/var/mobile/Containers/Data/Application"
    private let appGroupRoot = "/var/mobile/Containers/Shared/AppGroup"

    /// Predefined quick-access paths shown on the Explorer root page.
    /// Only includes paths accessible via bad_query sandbox escape:
    ///   /var/containers/Data/System (iOS 27)
    ///   /var/containers/Shared/SystemGroup/* (iOS 27)
    ///   /var/mobile/Containers/Data/Application/*
    ///   /var/mobile/Containers/Data/InternalDaemon/*
    ///   /var/mobile/Containers/Data/PluginKitPlugin/*
    ///   /var/mobile/Containers/Shared/AppGroup/* (iOS 27)
    let quickPaths: [QuickPath] = [
        // System (iOS 27 system containers)
        QuickPath(name: String(localized: "System Data"), path: "/var/containers/Data/System", icon: "gearshape.2.fill", category: .system,
                  description: String(localized: "System data containers (iOS 27). Contains daemon sandboxes and system service data directories.")),
        QuickPath(name: String(localized: "System Groups"), path: "/var/containers/Shared/SystemGroup", icon: "square.stack.3d.up.fill", category: .system,
                  description: String(localized: "Shared system group containers. Each subdirectory is a system group's shared data area, identified by a systemgroup.* identifier.")),
        QuickPath(name: String(localized: "MobileGestalt Cache"), path: "/var/containers/Shared/SystemGroup/systemgroup.com.apple.mobilegestaltcache", icon: "cpu", category: .system,
                  description: String(localized: "The MobileGestalt system group container. Contains the device identity and capability cache plist that GestaltKitTool reads and modifies.")),

        // App Data (app sandboxes)
        QuickPath(name: String(localized: "App Data"), path: "/var/mobile/Containers/Data/Application", icon: "app.dashed", category: .user,
                  description: String(localized: "All app data containers on the device. Each UUID subdirectory is one app's private sandbox (Documents, Library, tmp, etc.).")),
        QuickPath(name: String(localized: "App Groups"), path: "/var/mobile/Containers/Shared/AppGroup", icon: "person.2.badge.gearshape", category: .user,
                  description: String(localized: "App group containers. Shared data areas for apps that belong to the same group (e.g., main app + extensions).")),
        QuickPath(name: String(localized: "Internal Daemon"), path: "/var/mobile/Containers/Data/InternalDaemon", icon: "gearshape.arrow.triangle.2.circlepath", category: .user,
                  description: String(localized: "Internal daemon data containers. Private sandboxes for system daemon processes.")),
        QuickPath(name: String(localized: "PluginKit Plugins"), path: "/var/mobile/Containers/Data/PluginKitPlugin", icon: "puzzlepiece.extension", category: .user,
                  description: String(localized: "PluginKit plugin data containers. Sandboxes for system extensions and plugins (keyboards, share extensions, widgets, etc.).")),

        // Developer (accessible container directories)
        QuickPath(name: String(localized: "Bundle Containers"), path: "/var/containers/Bundle/Application", icon: "shippingbox.fill", category: .developer,
                  description: String(localized: "Installed app bundle containers. Each UUID directory contains the .app bundle (executable, resources, Info.plist, frameworks).")),

        // Local Storage (app's own sandbox — Documents, Archive)
        QuickPath(name: String(localized: "Archive"), path: ArchiveManager.archiveRootPath, icon: "archivebox.fill", category: .local,
                  description: String(localized: "GestaltKitTool's copy-style archive. Snapshots of files/directories read via bad_query are stored here (Documents/GestaltKitTool Archive). Source files are NOT moved or deleted — bad_query provides read-only access, so Archive copies instead of moving.")),
    ]

    var groupedQuickPaths: [(QuickPath.QuickPathCategory, [QuickPath])] {
        QuickPath.QuickPathCategory.allCases.map { cat in
            (cat, quickPaths.filter { $0.category == cat })
        }
    }

    // MARK: - Container Discovery

    /// iOS container roots (/var/mobile/Containers/Data/Application,
    /// /var/mobile/Containers/Shared/AppGroup, /var/containers/Shared/
    /// SystemGroup) contain only directories named as UUIDs or
    /// systemgroup.* / group.* identifiers. When stat is blocked by the
    /// sandbox (isDirectory == false, fileSize == 0), a name that matches
    /// this shape is still a directory; anything else is a stray file
    /// (e.g. "_ATXDataStore.db") and must be excluded.
    private nonisolated static func isContainerDirectoryName(_ name: String) -> Bool {
        // UUID form: 8-4-4-4-12 lowercase/uppercase hex.
        if name.count == 36 {
            let chars = Array(name)
            let dashPositions: Set<Int> = [8, 13, 18, 23]
            for (idx, ch) in chars.enumerated() {
                if dashPositions.contains(idx) {
                    if ch != "-" { return false }
                } else if !ch.isHexDigit {
                    return false
                }
            }
            return true
        }
        if name.hasPrefix("systemgroup.") || name.hasPrefix("group.") {
            return name.count > "systemgroup.".count
        }
        return false
    }

    /// Enumerates all app data containers by listing the Application
    /// directory. Each UUID subdirectory is one app's sandbox.
    ///
    /// Two-phase approach:
    ///   Phase 1: List directories only (fsgetpath, fast) → show immediately
    ///   Phase 2: Resolve display names one-by-one in background → update incrementally
    func discoverContainers() {
        guard !isLoading else { return }
        isLoading = true
        errorMessage = nil

        let fileAccess = self.fileAccess
        let appDataRoot = self.appDataRoot
        let appGroupRoot = self.appGroupRoot

        // Use async, not sync, to avoid deadlock when the main
        // queue is busy waiting for this background work.
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }

            // Clear any prior cancelled state. The flag is raised by
            // DiagnosticsModel cross-tab notification, which fires for
            // any concurrent Run All Diagnostics — if the user then goes
            // *back* to Explorer and taps Refresh, we want the fresh run
            // to proceed normally.
            self.resetDiscoverCancelled()
            var cancelled = false; // thread-local copy, refreshed periodically

            // Phase 1: Quick directory listing — no file reads.
            nonisolated(unsafe) var found: [AppContainer] = []

            var dataError: NSError?
            let dataEntries = fileAccess.listDirectory(atPath: appDataRoot, error: &dataError)
            // The previous heuristic (skip only when extension
            // non-empty AND fileSize > 0) let files whose stat failed
            // (fileSize == 0) slip through — e.g. ATX database files
            // like "_ATXDataStore.db" / ".db-shm" that live in the
            // container roots. They became fake AppContainers with
            // DUPLICATE ids across the data & appgroup roots → SwiftUI
            // "ID occurs multiple times" → infinite re-render → memory
            // blow-up, and tapping them read a multi-MB .db fully into
            // memory.
            //
            // iOS guarantees container roots contain only directories
            // named as UUIDs (or systemgroup.* identifiers). So accept
            // an entry only when it is (a) confirmed a directory by
            // stat, or (b) named like a UUID/systemgroup even if stat
            // was blocked. Everything else is a stray file — skip.
            for (i, entry) in dataEntries.enumerated() {
                if i & 0xF == 0 { cancelled = self.isDiscoverCancelled() }
                if cancelled { break }
                if entry.name.hasPrefix(".") { continue }
                if entry.isDirectory == false
                    && !Self.isContainerDirectoryName(entry.name) {
                    continue
                }
                found.append(AppContainer(
                    id: "data-\(entry.name)",
                    path: entry.fullPath,
                    bundleIdentifier: nil,
                    displayName: "Container \(entry.name.prefix(8))…",
                    containerType: .data
                ))
            }

            var groupError: NSError?
            if !cancelled {
                let groupEntries = fileAccess.listDirectory(atPath: appGroupRoot, error: &groupError)
                for (i, entry) in groupEntries.enumerated() {
                    if i & 0xF == 0 { cancelled = self.isDiscoverCancelled() }
                    if cancelled { break }
                    if entry.name.hasPrefix(".") { continue }
                    if entry.isDirectory == false
                        && !Self.isContainerDirectoryName(entry.name) {
                        continue
                    }
                    found.append(AppContainer(
                        id: "appgroup-\(entry.name)",
                        path: entry.fullPath,
                        bundleIdentifier: nil,
                        displayName: "AppGroup \(entry.name.prefix(8))…",
                        containerType: .appGroup
                    ))
                }
            }

            // Sort by display name
            found.sort { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }

            // Show immediately — user sees the list right away

            // Use async instead of sync to avoid potential deadlock.
            // snapshot `cancelled` into a let BEFORE the @Sendable
            // closure — capturing the mutable var was a data race (and a
            // hard error under Swift 6 concurrency checking).
            let cancelledNow = cancelled

            // Surface listing errors to the user instead of silently
            // showing an empty container list.
            let combinedError: String? = {
                if cancelledNow { return nil }
                let dataMsg = dataError?.localizedDescription
                let groupMsg = groupError?.localizedDescription
                if dataMsg != nil && groupMsg != nil {
                    return "\(dataMsg!) ; \(groupMsg!)"
                }
                return dataMsg ?? groupMsg
            }()

            Task { @MainActor [weak self] in
                guard let self else { return }
                self.containers = cancelledNow ? [] : found
                if let combinedError, found.isEmpty {
                    self.errorMessage = combinedError
                }
                self.isLoading = false
            }

            // MARK: - Phase 2: Resolve display names concurrently in background
            // Resolve ALL containers (not just the first 50) so that
            // Bundle ID search works across the full list.
            //
            // Concurrency limit 2 + 5ms spacing: each resolve call opens a new
            // bad_query lease (one XPC + one sandbox_extension). 8-way concurrency
            // over 200 containers would emit ~1600 XPC calls in ~200ms, risking
            // sandbox_extension quota exhaustion. Throttled to ~1s total.
            if cancelled { return }
            let resolveQueue = OperationQueue()
            resolveQueue.maxConcurrentOperationCount = 2
            resolveQueue.qualityOfService = .userInitiated

            // Batched name updates to avoid per-container @Published mutations.
            //
            // Now each resolve op only appends to a lock-protected
            // buffer; the polling loop below flushes the buffer to the
            // main actor at most every 250 ms as ONE merged update.
            nonisolated(unsafe) var pendingNameUpdates: [AppContainer] = []
            let nameUpdateLock = NSLock()

            for (offset, container) in found.enumerated() {
                resolveQueue.addOperation { [weak self] in
                    // Check the cross-tab cancelled flag at the
                    // START of each resolve operation — once Diagnostics
                    // has taken over, we want to stop leaking sandbox
                    // extensions on name resolution, which would otherwise
                    // prolong the Diagnostics hang.
                    if (self?.isDiscoverCancelled() ?? true) { return }

                    // Throttle after the first N operations so that
                    // containers in the tens (light devices) resolve
                    // instantly; hundreds throttle.
                    if offset > 24 {
                        usleep(5_000) // 5 ms → max 200 leases/sec @ concurrency 2
                    }
                    let bundleId = Self.extractBundleId(fileAccess: fileAccess, containerPath: container.path)
                    let displayName = Self.bestDisplayName(fileAccess: fileAccess, containerPath: container.path, bundleId: bundleId)

                    // Skip if display name didn't improve
                    if displayName.hasPrefix("Container ") || displayName.hasPrefix("AppGroup ") {
                        return
                    }

                    let updated = AppContainer(
                        id: container.id,
                        path: container.path,
                        bundleIdentifier: bundleId,
                        displayName: displayName,
                        containerType: container.containerType
                    )
                    nameUpdateLock.lock()
                    pendingNameUpdates.append(updated)
                    nameUpdateLock.unlock()
                }
            }

            // If a Diagnostics run cancels us while Phase 2 work items
            // are still queued, cancel them immediately so we don't issue
            // leases the Diagnostics run needs. OperationQueue.cancelAll
            // doesn't stop already-executing ops, but each op's entry
            // block checks isDiscoverCancelled so we'll drain quickly.
            //
            // the same loop now doubles as the batched-update
            // flusher: every 250 ms it drains the pendingNameUpdates
            // buffer and applies it as ONE main-actor mutation.
            var lastFlushTime = Date().addingTimeInterval(-1)
            func flushNameUpdates(_ batch: [AppContainer]) {
                guard !batch.isEmpty else { return }
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    guard !self.isDiscoverCancelled() else { return }
                    var updatesById = Dictionary(
                        batch.map { ($0.id, $0) },
                        uniquingKeysWith: { _, latest in latest }
                    )
                    self.containers = self.containers.map {
                        updatesById.removeValue(forKey: $0.id) ?? $0
                    }
                }
            }
            while resolveQueue.operationCount > 0 {
                if self.isDiscoverCancelled() {
                    resolveQueue.cancelAllOperations()
                    break
                }
                usleep(20_000)
                let now = Date()
                if now.timeIntervalSince(lastFlushTime) >= 0.25 {
                    lastFlushTime = now
                    nameUpdateLock.lock()
                    let batch = pendingNameUpdates
                    pendingNameUpdates.removeAll()
                    nameUpdateLock.unlock()
                    flushNameUpdates(batch)
                }
            }
            // Final flush of anything still buffered.
            nameUpdateLock.lock()
            let finalBatch = pendingNameUpdates
            pendingNameUpdates.removeAll()
            nameUpdateLock.unlock()
            flushNameUpdates(finalBatch)
        }
    }

    // MARK: - Directory Browsing

    func browseDirectory(at path: String) {
        // browseDirectory's own guard only cares about
        // duplicate-in-flight browse work. Navigation-stack
        // invariant checks (no adjacent equal paths, etc.) are the
        // sole responsibility of the callers that mutate
        // navigationPath (navigateInto / navigateToIndex /
        // enterContainer / enterQuickPath), each of which runs
        // preFlightBrowseDestination before mutating the stack.
        //
        // Rollback regime: callers are responsible for
        // calling _forceRollbackStalePrePushedNavigation() BEFORE
        // setting their own marker. browseDirectory must not call
        // it internally — if it did, it would immediately undo the
        // marker the caller just set (navigateInto: .popLast,
        // enterContainer: .resetAll, etc.), which would pop the
        // freshly-pushed nav entry before the browse even started,
        // producing the "title matches parent but content shows
        // child" symptom that users reported as infinite nesting.
        guard !path.isEmpty else {
            gktlLog("[GKTL-Browse] browseDirectory REJECTED empty path (nav=%d)", navigationPath.count)
            return
        }
        guard !(isLoading && _pendingBrowsePath == path) else {
            gktlLog("[GKTL-Browse] browseDirectory REJECTED already-loading identical path=%@ (nav=%d)", path, navigationPath.count)
            return
        }

        errorMessage = nil
        isLoading = true
        _pendingBrowsePath = path

        let fileAccess = self.fileAccess

        // Previous implementation dispatched listDirectory to a
        // SECOND nested .userInitiated queue and used a semaphore to wait.
        // That's wasteful (extra thread + semaphore syscall per entry)
        // and more importantly meant the timeout was measuring WAIT TIME
        // not WORK TIME — if GCD was busy with discoverContainers work
        // items the nested dispatch_async could take multiple seconds
        // just to START, causing spurious timeouts.
        //
        // Now: run listDirectory directly in this async block, and
        // enforce timeout by dispatching a watchdog block to the main
        // thread. If listDirectory finishes before the watchdog fires,
        // we cancel it. No nested dispatch, no semaphore, no race.
        let workId = UUID().uuidString
        _pendingBrowseWorkID = workId
        let timeoutMs: Int64 = 5000
        let workIdShort = String(workId.suffix(4))

        // Watchdog — fires after timeoutMs on main thread. If the
        // browse work is still pending (same workId), treat as timed
        // out and publish error state.
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(Int(timeoutMs))) {
            [weak self] in
            guard let self else { return }
            let currentId = self._pendingBrowseWorkID ?? "<nil>"
            guard self._pendingBrowseWorkID == workId else {
                return
            }
            gktlLog("[GKTL-Browse] watchdog TIMEOUT path=%@ mine=…%@ matches → rollback after %lldms nav=%d",
                  path, workIdShort, timeoutMs, self.navigationPath.count)
            self._pendingBrowseWorkID = nil
            self._applyBrowseResult(path: path, entries: [], error: nil,
                                    timedOut: true, workId: workId,
                                    pendingEntry: self.pendingReadOnBrowseFailure)
        }

        Task.detached(priority: .userInitiated) { [weak self] in
            autoreleasepool {
                var browseError: NSError?
                let tListStart = CFAbsoluteTimeGetCurrent()
                let entries = fileAccess.listDirectory(
                    atPath: path, error: &browseError
                )
                let tListEnd = CFAbsoluteTimeGetCurrent()
                let listMs = (tListEnd - tListStart) * 1000.0
                let inCount = entries.count
                if let e = browseError {
                    gktlLog("[GKTL-Browse] listDirectory ERR path=%@ workId=…%@ code=%ld domain=%@ desc=%@ n=%d (%.1fms)",
                          path, workIdShort, Int64(e.code), e.domain, e.localizedDescription, inCount, listMs)
                } else {
                    // Success — no log (high-frequency normal path).
                }

                // (background-thread empty-dir filter):
                // Run on worker thread BEFORE hopping back to main.
                // Per-child opendir/readdir is small O(1) work (we
                // bail after the first non-"."/".." entry), but in
                // bulk (hundreds of sub-directories) it could still
                // stall the main runloop — doing it here keeps the
                // UI responsive. The filter never drops entries on
                // opendir failure (EPERM/…) so we never hide content
                // the user might legitimately need to see.
                let tFiltStart = CFAbsoluteTimeGetCurrent()
                let filtered = (self?._filterOutEmptyDirectories(entries)
                                ?? entries)
                let tFiltEnd = CFAbsoluteTimeGetCurrent()
                let filtMs = (tFiltEnd - tFiltStart) * 1000.0
                let outCount = filtered.count
                let dropped = inCount - outCount
                // Only log when notable (dropped > 0 or slow).
                if dropped > 0 || filtMs > 80.0 {
                    gktlLog("[GKTL-Browse] empty-dir-filter path=%@ workId=…%@ in=%d out=%d dropped=%d (%.1fms%@)",
                          path, workIdShort, inCount, outCount, dropped, filtMs,
                          filtMs > 400.0 ? " — SLOW (>400ms, consider disabling)" : "")
                }

                DispatchQueue.main.async {
                    guard let self else {
                        gktlLog("[GKTL-Browse] completion self already nil → DROP for path=%@ workId=…%@",
                              path, workIdShort)
                        return
                    }
                    let currentId = self._pendingBrowseWorkID ?? "<nil>"
                    guard self._pendingBrowseWorkID == workId else {
                        gktlLog("[GKTL-Browse] completion STALE-DROP path=%@ mine=…%@ current=…%@ nav=%d → user navigated away during browse",
                              path, workIdShort, String(currentId.suffix(4)), self.navigationPath.count)
                        return
                    }
                    self._pendingBrowseWorkID = nil
                    self._applyBrowseResult(path: path,
                                            entries: filtered,
                                            error: browseError,
                                            timedOut: false,
                                            workId: workId,
                                            pendingEntry: self.pendingReadOnBrowseFailure)
                }
            }
        }
    }

    // Shared handler for browse completion: handles timeout, browse
    // errors, empty speculative browse → readFile fallback, then sets
    // the final currentEntries/isLoading state. Extracted to avoid
    // duplicating the 3-way fallback logic between the normal path
    // and the timeout watchdog path.
    // Accepts `path` parameter so the handler can populate
    // the entry-cache on success + restore cached parent entries on
    // rollback (never again shows an empty parent listing on nested
    // browse failure — eliminates KeyboardInputScene crash window).
    private func _applyBrowseResult(path: String,
                                    entries: [BQFileEntry],
                                    error: Error?,
                                    timedOut: Bool,
                                    workId: String,
                                    pendingEntry: BQFileEntry?) {
        // The workId guard accepts nil (already claimed by caller) or an exact
        // match. The caller's own strict guard in browseDirectory's watchdog /
        // completion blocks is the real line of defense; this guard is
        // redundant-defensive only.
        let workIdShort = String(workId.suffix(4))
        let currentId = _pendingBrowseWorkID ?? "<nil>"
        guard _pendingBrowseWorkID == nil || _pendingBrowseWorkID == workId
            else {
            gktlLog("[GKTL-Browse] apply STALE-GUARD-DROP path=%@ workId mismatch mine=%@ cur=%@ timedOut=%d err=%d nEntries=%d pendingEntry=%d nav=%d",
                  path, workIdShort, String(currentId.suffix(4)), timedOut ? 1 : 0,
                  error != nil ? 1 : 0, entries.count, pendingEntry != nil ? 1 : 0,
                  navigationPath.count)
            return
        }
        // Clear the pending-path guard so subsequent taps work.
        _pendingBrowsePath = nil

        // Cache-aware rollback:
        //   - Rollback nav entries on failure markers as before.
        //   - NEW: after rollback, if navigationPath has a LAST, restore
        //     currentEntries from cache for that new (rolled-back) last.
        //   - If navigationPath is empty, fall back to root listing via
        //     browseDirectory(ROOT) only on cache miss (usually empty).
        //   - Never leave currentEntries = [] when we have a cached
        //     parent state; that blank window causes SwiftUI's
        //     NavigationStack to attach Searchable/KeyboardInputScene
        //     to a transient empty state → handler 0 drop crash.
        func rollbackPrePushedNavigationIfNeeded() {
            let oldNavLen = navigationPath.count
            let markerDesc: String
            switch _pendingPrePushedNavigation {
            case .none:
                markerDesc = "none"
            case .popLast(let expected):
                markerDesc = "popLast(expected=\(URL(fileURLWithPath: expected).lastPathComponent))"
                if navigationPath.last == expected {
                    let oldCount = navigationPath.count
                    let removed = navigationPath.last ?? "?"
                    navigationPath.removeLast()
                    gktlLog("[GKTL-Nav] rollback-popLast old=%d new=%d removed=…%@",
                          oldCount, navigationPath.count, String(removed.suffix(24)))
                }
            case .resetAll:
                markerDesc = "resetAll"
                let oldCount = navigationPath.count
                navigationPath.removeAll()
                gktlLog("[GKTL-Nav] rollback-resetAll old=%d new=0", oldCount)
            }
            _pendingPrePushedNavigation = .none
            let newNavLen = navigationPath.count
            gktlLog("[GKTL-Browse] rollback marker=%@ navLen %d→%d path=%@ workId=…%@",
                  markerDesc, oldNavLen, newNavLen, path, workIdShort)
            // Rollback is atomic — immediately restore entries
            // for the rolled-back-to path from cache. Users see the
            // PREVIOUS directory content instantly, no flicker, no
            // re-browse, no blank spinner.
            if let parent = navigationPath.last {
                let cacheHit = _restoreCachedEntries(for: parent)
                gktlLog("[GKTL-Browse] rollback → cache%@ parent=…%@ workId=…%@",
                      cacheHit ? "HIT" : "MISS (re-browse)",
                      String(parent.suffix(28)), workIdShort)
                if !cacheHit {
                    // Cache miss: parent directory never browsed or
                    // was evicted. Run a fresh browse to repopulate.
                    browseDirectory(at: parent)
                }
            } else {
                currentEntries = []
                isLoading = false
                gktlLog("[GKTL-Browse] rollback → nav is empty → currentEntries=[] done.")
            }
        }

        // For pending entries (unknown-type taps), navigationPath
        // was NOT pushed before browse. We handle it here:
        //  - Success with entries → push navigation + show entries
        //  - Success but empty → treat as empty directory ()
        //  - Timeout / error → readFile (was never in nav stack)
        // This eliminates the "child title + parent content" mismatch.

        if timedOut {
            if let pending = pendingEntry {
                pendingReadOnBrowseFailure = nil
                gktlLog("[GKTL-Browse] timedOut PATH=FALLBACK pending=%@ workId=…%@ → readFile",
                      String(pending.fullPath.suffix(28)), workIdShort)
                // navigationPath was never pushed; just read.
                rollbackPrePushedNavigationIfNeeded()
                readFile(pending)
                return
            }
            errorMessage = "Directory listing timed out. The path may be inaccessible."
            gktlLog("[GKTL-Browse] timedOut ERR path=%@ workId=…%@ → rollback+show error", path, workIdShort)
            rollbackPrePushedNavigationIfNeeded()
            // rollback() already restored cached parent entries
            // (or re-browsed on miss) — never overwrite with []. This
            // was the #1 cause of "infinite nesting" complaints: users
            // returned to parent level but saw zero rows → thought they
            // were in an empty sub-directory → tapped breadcrumbs
            // repeatedly, each time setting [] again.
            return
        }
        if let error = error {
            if let pending = pendingEntry {
                pendingReadOnBrowseFailure = nil
                gktlLog("[GKTL-Browse] apply-err →readFile pending=%@ err=%@ workId=…%@",
                      String(pending.fullPath.suffix(28)), error.localizedDescription, workIdShort)
                // navigationPath was never pushed; just read.
                rollbackPrePushedNavigationIfNeeded()
                readFile(pending)
                return
            }
            let friendly = ErrorHandler.friendlyMessage(for: error as NSError)
            errorMessage = friendly
            gktlLog("[GKTL-Browse] apply-err path=%@ err=%@ (friendly=%@) workId=…%@ → rollback",
                  path, error.localizedDescription, friendly, workIdShort)
            rollbackPrePushedNavigationIfNeeded()
            // same note as timedOut branch — rollback restored.
            return
        }
        // Success path
        // Removed `currentEntries.isEmpty` guard. The prior
        // version only pushed navigation for unknown-type taps when the
        // parent directory was empty, which is wrong — users browse
        // INTO unknown-type entries from NON-EMPTY parent directories
        // too (e.g. a file whose lstat failed but is actually a
        // directory). The existence of `pendingEntry` is the correct
        // signal: it is set ONLY by handleEntryTap's unknown-type
        // path (where we deliberately DID NOT push before browse),
        // regardless of whether currentEntries is empty.
        if let pending = pendingEntry {
            pendingReadOnBrowseFailure = nil
            // browse succeeded (error==nil, timedOut==false).
            // Treat empty listings as empty directories, not files.
            // listDirectory() on a file returns ENOTDIR; a successful empty
            // listing means a valid directory with no children.
            //
            // File-fallback now happens ONLY in the error/timeout
            // branches above (lines 861-888), where listDirectory
            // genuinely rejected the path as non-directory.
            let beforeLen = navigationPath.count
            if navigationPath.last != pending.fullPath {
                navigationPath.append(pending.fullPath)
            }
        }
        // Entries successfully collected. Clear any rollback
        // marker so a subsequent failure (for a LATER browse) doesn't
        // accidentally pop a perfectly-valid navigation entry.
        _pendingPrePushedNavigation = .none
        // defensive dedupe by fullPath before publishing to the
        // UI. The ObjC layer (bad_query_list_directory) already dedupes
        // APFS snapshot-inode aliases, but any future source of
        // duplicated entries would make ForEach(id: \.fullPath) log
        // "ID occurs multiple times" and render undefined rows — a
        // cheap O(n) pass here makes that impossible.
        //
        // (Duplicate-entry bug, root cause: path normalization):
        // User reported duplicate directory entries with identical contents.
        // Root cause: previous dedupe used raw `entry.fullPath` string,
        //   1. /var/mobile/... vs /private/var/mobile/...  (symlink)
        //   2. /foo/bar vs /foo//bar                       (// collapse)
        //   3. /foo/bar vs /foo/bar/                       (trailing /)
        //   4. /foo/Bar vs /foo/bar                        (APFS case-insensitive)
        // fsgetpath (Phase 3) is notorious for mixing these forms.
        // Fix: normalize via NSString.standardizedPath (handles 1-3)
        // + lowercase (handles 4 on case-insensitive APFS, which is
        // the default for iOS user data volumes).
        var seenPaths = Set<String>()
        seenPaths.reserveCapacity(entries.count)
        var dupSamples: [String] = []  // log first 3 dups for diagnostics
        var deduped: [BQFileEntry] = []
        deduped.reserveCapacity(entries.count)
        for entry in entries {
            // reuse _normalizePath for consistency.
            // Handles /var vs /private/var, trailing /, case-insensitivity.
            let key = Self._normalizePath(entry.fullPath)
            if seenPaths.insert(key).inserted {
                deduped.append(entry)
            } else {
                if dupSamples.count < 3 {
                    dupSamples.append(entry.fullPath)
                }
            }
        }
        let dupsRemoved = entries.count - deduped.count
        if dupsRemoved > 0 {
            gktlLog("[GKTL-Browse] publish DUPS-REMOVED=%d samples=%@",
                  dupsRemoved, dupSamples)
        }
        // Check for same-name-different-path entries. This catches the case
        // where two entries have different fullPath (so dedupe keeps both)
        // but the same display name — e.g. /Library/Caches and /System/Library/Caches.
        // These are DIFFERENT directories with the same name — the UI
        // shows them as duplicate-looking rows. Log so we can confirm
        // whether this is the user's complaint.
        var nameMap: [String: [String]] = [:]
        for entry in deduped {
            let name = entry.name.lowercased()
            nameMap[name, default: []].append(entry.fullPath)
        }
        let sameNameDupes = nameMap.filter { $0.value.count > 1 }
        if !sameNameDupes.isEmpty {
            for (name, paths) in sameNameDupes.prefix(3) {
                gktlLog("[GKTL-Browse] publish SAME-NAME-DIRS name=%@ paths=%@",
                      name, paths.map { String($0.suffix(48)) })
            }
        }
        // Cache BEFORE publishing using NORMALIZED path as key.
        // This ensures /var/mobile/Library and /private/var/Library share the same cache entry.
        let normKey = Self._normalizePath(path)
        _entryCache[normKey] = deduped
        _touchCacheKey(normKey)
        _evictExcessCacheEntries()
        currentEntries = deduped
        pendingReadOnBrowseFailure = nil
        isLoading = false
        // warning above still logs when duplicates are found.
    }

    func navigateInto(_ entry: BQFileEntry) {
        // Save scroll position before navigating deeper.
        if let currentDir = navigationPath.last {
            _scrollPositionCache[Self._normalizePath(currentDir)] = scrollRestoreTarget
        }
        // navigateInto pushes a directory onto the nav stack before browse
        // only if browseDirectory actually accepts the work. The push must
        // happen after preFlight acceptance to avoid marker leaks.
        //
        // ORDER:
        //   1. snapshot the target path
        //   2. preFlightBrowseDestination(target) — guard + invariant
        //      (returns false if browsing this target is not accepted,
        //      in which case we must not mutate navigationPath)
        //   3. _forceRollbackStalePrePushedNavigation — clean up any
        //      stray marker left by a prior cancelled browse so the
        //      NEW marker below is the only active one
        //   4. only THEN push path / set marker / call browse
        let target = entry.fullPath

        // Block entry into confirmed-empty directories. Users
        // reported that tapping an empty dir pollutes the breadcrumb
        // trail AND can trigger the "infinite nesting" anomaly when
        // combined with stale markers. Empty dirs contain nothing to
        // browse anyway, so refuse the navigation entirely. opendir
        // failure (EPERM/…) returns false → navigation proceeds
        // normally (conservative: don't block on uncertain info).
        if _isEmptyDirectory(target) {
            gktlLog("[GKTL-Browse] navigateInto EMPTY-DIR-BLOCK target=…%@ (dir is empty, no entry)",
                  String(target.suffix(28)))
            // Show the user a friendly message instead of silently doing nothing.
            errorMessage = "Directory is empty."
            return
        }

        // Fix: corrupted breadcrumb stack where sibling directories were pushed as nested children.
        //
        //   stack: [AppGroup/024C7A15…, Library/Assistant,
        //           Library/BulletinBoard, Library/IdentityServices, …]
        //    NOT-A-CHILD at every idx ≥ 1
        //    RAW-DUPES (BulletinBoard appeared twice)
        //
        // Root cause: navigateInto unconditionally appended `target`
        // to navigationPath WITHOUT verifying that target is actually
        // a child of the current stack top. When listDirectory returns
        // symlink-resolved absolute paths (e.g. a symlink inside the
        // AppGroup container pointing to /var/mobile/Library), the
        // entry.fullPath is the symlink TARGET, not the container-
        // relative path. Blindly appending produced a stack with no
        // parent-child relationship between consecutive entries.
        //
        // Rebase the stack before appending so that target is
        // always a truthful child of the new top. Three cases:
        //   (a) target is already in stack → truncate to target
        //       (breadcrumb-like jump, prevents RAW-DUPES)
        //   (b) target's ancestor is in stack → truncate to ancestor
        //       then append target (cross-level jump within tree)
        //   (c) no ancestor in stack → reset to [target]
        //       (cross-container jump via symlink)
        //
        // Path comparison uses _normalizePath() to handle /var vs
        // /private/var, trailing slashes, and APFS case-insensitivity.
        let targetNorm = Self._normalizePath(target)
        var newStack = navigationPath
        var rebaseReason: String? = nil

        // Case (a): target already in stack → truncate (jump).
        if let existingIdx = newStack.firstIndex(where: { Self._normalizePath($0) == targetNorm }) {
            if existingIdx == newStack.count - 1 {
                // target is already the current top — nothing to do.
                gktlLog("[GKTL-Nav] navigateInto SKIP target==navTop (already there) target=…%@",
                      String(target.suffix(24)))
                return
            }
            newStack = Array(newStack.prefix(existingIdx + 1))
            rebaseReason = "jump-existing-idx=\(existingIdx)"
        }
        // Case (b)/(c): target is NOT the current top. Check if it's
        // a child of the current top; if not, find deepest ancestor.
        else if let currentTop = newStack.last {
            let topNorm = Self._normalizePath(currentTop)
            let topPrefix = topNorm.hasSuffix("/") ? topNorm : topNorm + "/"
            if !targetNorm.hasPrefix(topPrefix) {
                // target is NOT a child of current top. Find deepest
                // ancestor of target that IS in the stack.
                var foundAncestorIdx: Int? = nil
                for (idx, stackPath) in newStack.enumerated().reversed() {
                    let spNorm = Self._normalizePath(stackPath)
                    let spPrefix = spNorm.hasSuffix("/") ? spNorm : spNorm + "/"
                    if targetNorm.hasPrefix(spPrefix) {
                        foundAncestorIdx = idx
                        break
                    }
                }
                if let idx = foundAncestorIdx {
                    // Case (b): truncate to ancestor, will append target below.
                    newStack = Array(newStack.prefix(idx + 1))
                    rebaseReason = "rebase-to-ancestor-idx=\(idx)"
                } else {
                    // Case (c): no ancestor in stack → rebuild a minimal
                    // parent chain so the breadcrumb shows context.
                    //
                    // (breadcrumb optimization): Previously this just
                    // reset to [target], so browsing sibling dirs under
                    // /var/mobile/Library showed only "Assistant" with no
                    // parent context. Now we build a chain of ancestors
                    // (parent, grandparent, …) up to a reasonable depth,
                    // so breadcrumb shows "Library › Assistant" instead
                    // of just "Assistant".
                    //
                    // Depth limit prevents absurdly long chains for deep
                    // paths like /a/b/c/d/e/f/g — 3 levels is enough
                    // context for users to know where they are.
                    let MAX_PARENT_DEPTH = 3
                    var chain: [String] = []
                    var current = target
                    for _ in 0..<MAX_PARENT_DEPTH {
                        let parent = (current as NSString).deletingLastPathComponent
                        if parent.isEmpty || parent == "/" || parent == current {
                            break
                        }
                        chain.insert(parent, at: 0)
                        current = parent
                    }
                    newStack = chain
                    rebaseReason = "reset-with-parents depth=\(chain.count)"
                }
            }
            // else: target IS a child of current top → normal append, no rebase.
        } else {
            // Empty stack → just set [target].
            newStack = []
            rebaseReason = "empty-stack-root"
        }

        if let reason = rebaseReason {
            gktlLog("[GKTL-Nav] navigateInto-REBASE reason=%@ oldNavLen=%d newNavLen=%d target=…%@",
                  reason, navigationPath.count, newStack.count, String(target.suffix(24)))
        }

        // preFlight against the NEW (possibly rebased) stack so the
        // "navPath.last == target" guard doesn't self-reject.
        guard Self.preFlightBrowseDestination(target,
                                              isLoading: isLoading,
                                              pendingPath: _pendingBrowsePath,
                                              navigationPath: newStack) else {
            return
        }
        _forceRollbackStalePrePushedNavigation()
        let beforeLen = navigationPath.count
        navigationPath = newStack
        // Only append if target is not already the last entry (after
        // a "jump-existing" rebase, target IS already the last entry).
        if navigationPath.last != target {
            navigationPath.append(target)
        }
        _pendingPrePushedNavigation = .popLast(target)
        browseDirectory(at: target)
    }

    // MARK: - Path Normalization Helper

    /// Normalizes a filesystem path for comparison purposes.
    /// Handles:
    ///   - // collapse, trailing / removal, . / .. resolution
    ///     (via NSString.standardizingPath)
    ///   - /private prefix stripping (iOS symlinks /var → /private/var)
    ///   - case-insensitivity (iOS default APFS is case-insensitive)
    ///
    /// Used by:
    ///   - navigateInto (stack rebase validation)
    ///   - handleSearchResultTap
    ///   - _applyBrowseResult dedupe (future refactor)
    nonisolated static func _normalizePath(_ path: String) -> String {
        var normalized = (path as NSString).standardizingPath
        if normalized.hasPrefix("/private/") {
            normalized = String(normalized.dropFirst("/private".count))
        }
        return normalized.lowercased()
    }

    // Smart tap handler for entries where isDirectory might be unknown
    // (lstat failed — no lease available). Tries to browse as a directory
    // first; if that yields no entries, falls back to reading as a file.
    //
    // Navigation stack safety: never push to navigationPath before browse
    // confirms the path is a directory. _applyBrowseResult pushes only
    // when entries are actually returned.
    //
    // New behavior:
    //  1. Known directory → push immediately (safe, we're confident)
    //  2. Known file → readFile immediately (no navigation push)
    //  3. Unknown type → DO NOT push. Browse first; _applyBrowseResult
    //     pushes navigation only when entries are actually returned,
    //     and falls back to readFile without ever having pushed.
    func handleEntryTap(_ entry: BQFileEntry) {
        // Fast path: we know the type with certainty
        if entry.isDirectory {
            navigateInto(entry)
            return
        }

        // If we have metadata, it's definitely a file
        if entry.modificationDate != nil {
            readFile(entry)
            return
        }

        // Unknown type — try browse first, fall back to read
        // DON'T append to navigationPath here. Let
        // _applyBrowseResult push it only on success.
        // Also: guard against double-tap during in-progress browse.
        if isLoading { return }
        // Clean up any stale marker before browse. The
        // unknown-type path doesn't set its own marker (no pre-push),
        // but if a previous caller left a stray marker, the
        // rollbackPrePushedNavigationIfNeeded() inside
        // _applyBrowseResult would pop the WRONG entry on failure.
        _forceRollbackStalePrePushedNavigation()
        pendingReadOnBrowseFailure = entry
        browseDirectory(at: entry.fullPath)
    }

    /// Safe entry point for search-result taps (used by View layer).
    /// Mirrors handleEntryTap semantics but accepts raw path + entry
    /// so search results — which may come from a different directory
    /// than the one currently shown — follow the same navigation
    /// safety regime (rollback stale markers, no double-push,
    /// browse-first for unknown types).
    ///
    /// (Breadcrumb nesting bug, root-caused via log analysis):
    //  User-reported symptom: breadcrumb showed false nesting (e.g.
    //  `AggregateDictionary > Accounts > AddressBook`) for three SIBLING
    //  this function unconditionally `navigationPath.append(target)`
    //  for every search-result tap, even when target is a sibling of
    //  the current top. Previously had no search-result-tap
    //  API at all, so the bug is unique to GestaltKitTool.
    //
    //  Truncate navigationPath to target's parent (if present),
    //  then append target. This keeps breadcrumb truthful:
    //    Library > AggregateDictionary       (search → tap AggregateDictionary)
    //    Library > Accounts                  (search → tap Accounts)
    //    Library > AddressBook               (search → tap AddressBook)
    //  If target's parent is NOT in the stack, reset to [target]
    //  (root-level entry from search).
    func handleSearchResultTap(_ entry: BQFileEntry) {
        if entry.isDirectory {
            // Known directory — push with full safety checks.
            let target = entry.fullPath

            // Block entry into confirmed-empty directories from
            // search results too. Same rationale as navigateInto.
            if _isEmptyDirectory(target) {
                gktlLog("[GKTL-Browse] searchTap EMPTY-DIR-BLOCK target=…%@ (dir is empty, no entry)",
                      String(target.suffix(28)))
                errorMessage = "Directory is empty."
                return
            }

            let parent = (target as NSString).deletingLastPathComponent
            let parentNorm = Self._normalizePath(parent)

            // Truncate stack to parent if parent is already present.
            // This produces truthful breadcrumbs: Library > AggregateDictionary
            // (one entry) instead of stacking siblings as fake children.
            //
            // Use _normalizePath for comparison so /var/mobile/Library
            // and /private/var/mobile/Library are treated as the same path
            // (iOS symlinks /var → /private/var; fsgetpath may return either).
            var newStack: [String] = navigationPath
            if !parent.isEmpty {
                if let parentIdx = newStack.firstIndex(where: { Self._normalizePath($0) == parentNorm }) {
                    // Truncate to include the parent, drop everything after.
                    newStack = Array(newStack.prefix(parentIdx + 1))
                } else {
                    // Parent not in stack — build parent chain
                    // (same as navigateInto) so breadcrumb shows context.
                    let MAX_PARENT_DEPTH = 3
                    var chain: [String] = []
                    var current = target
                    for _ in 0..<MAX_PARENT_DEPTH {
                        let p = (current as NSString).deletingLastPathComponent
                        if p.isEmpty || p == "/" || p == current { break }
                        chain.insert(p, at: 0)
                        current = p
                    }
                    newStack = chain
                }
            } else {
                newStack = []
            }

            // preFlight against the NEW (truncated) stack so the
            // "navPath.last == target" guard doesn't self-reject.
            guard Self.preFlightBrowseDestination(target,
                                                  isLoading: isLoading,
                                                  pendingPath: _pendingBrowsePath,
                                                  navigationPath: newStack) else {
                gktlLog("[GKTL-Browse] searchTap preFlight REJECT target=…%@ oldNav=%d newNav=%d",
                      String(target.suffix(28)), navigationPath.count, newStack.count)
                return
            }
            let oldDepth = navigationPath.count
            navigationPath = newStack
            navigationPath.append(target)
            _pendingPrePushedNavigation = .popLast(target)
            browseDirectory(at: target)
            return
        }
        if entry.modificationDate != nil {
            readFile(entry)
            return
        }
        // Unknown type: browse first, push only on success.
        if isLoading { return }
        _forceRollbackStalePrePushedNavigation()
        pendingReadOnBrowseFailure = entry
        browseDirectory(at: entry.fullPath)
    }

    // When handleEntryTap suspects an entry might be a directory,
    // it calls browseDirectory. If browse returns empty/error, this
    // property holds the pending entry so browseDirectory can fall
    // back to readFile.
    var pendingReadOnBrowseFailure: BQFileEntry?

    // Nonce for the in-flight browseDirectory call. Used to
    // discard stale timeout-watchdog / completion callbacks when the
    // user navigates away or taps a different entry while a browse
    // is still running.
    private var _pendingBrowseWorkID: String?
    // Track the path currently being browsed to guard against
    // duplicate taps that would otherwise pollute navigationPath and
    // produce the "infinite same-named directory" symptom.
    private var _pendingBrowsePath: String?
    // Some call sites (navigateInto, navigateToIndex, container tap from View) push navigationPath before calling
    // browseDirectory because they're confident the target is a real
    // directory. If the browse fails (e.g. the target directory does
    // not actually exist but stat marked it isDirectory=true via our
    // heuristic), we must pop the entry we already pushed — otherwise
    // the breadcrumb shows a child name while currentEntries still
    // shows the parent's contents, and the user taps again stacking
    // duplicate entries forever.
    //
    // String case: the path that was already pushed onto the nav
    // stack before browseDirectory was called. If browse fails or
    // returns empty and navigationPath.last == this value, we pop.
    //
    // Bool case (true): caller replaced navigationPath wholesale
    // (container tap / quick-path tap sets it to [singleRoot]). If
    // browse fails, reset navigationPath to [] instead of leaving a
    // dangling single-entry stack that doesn't match currentEntries.
    private enum PrePushedNavigation { case none; case popLast(String); case resetAll }
    private var _pendingPrePushedNavigation: PrePushedNavigation = .none

    func navigateBack() {
        // the toolbar back button renders while
        // !navigationPath.isEmpty, but between render and tap an async
        // path (timeout watchdog, error handler, NavigationStack swipe
        // gesture) may already have emptied the array — removeLast()
        // on an empty RangeReplaceableCollection traps. Guard it.
        guard !navigationPath.isEmpty else { return }
        let oldCount = navigationPath.count
        let removed = navigationPath.last ?? "?"
        navigationPath.removeLast()
        // Restore scroll position for the directory we're returning to.
        if let target = navigationPath.last {
            scrollRestoreTarget = _scrollPositionCache[Self._normalizePath(target)]
        }
        if let target = navigationPath.last {
            // Prefer cache — O(1) instant restore, 0 XPC.
            // Only fall back to browseDirectory on cache miss. This
            // eliminates 100% of the "tap back → spinner for 3s →
            // timeout → blank" race window that was showing the
            // KeyboardInputScene handler 0 crash.
            if !_restoreCachedEntries(for: target) {
                browseDirectory(at: target)
            }
        } else {
            navigationPath.removeAll()
            currentEntries = []
        }
    }

    func navigateToRoot() {
        navigationPath.removeAll()
        currentEntries = []
    }

    // MARK: - Browse Pre-flight
    //
    // Guards against infinite navigation stacking:
    //   1. Duplicate tap while same path is loading → ignore.
    //   2. Target equals navigationPath.last → would create duplicate IDs.
    //   3. Navigating to root / empty path → meaningless.
    // Also rolls back stray pre-pushed markers from cancelled browses.
    static private func preFlightBrowseDestination(
        _ target: String,
        isLoading: Bool,
        pendingPath: String?,
        navigationPath: [String]
    ) -> Bool {
        if target.isEmpty {
            gktlLog("[GKTL-Browse] preFlight REJECT target=EMPTY isLoading=%d pending=%@ nav=%d",
                  isLoading ? 1 : 0, pendingPath ?? "<nil>", navigationPath.count)
            return false
        }
        if isLoading && pendingPath == target {
            gktlLog("[GKTL-Browse] preFlight REJECT target=…%@ reason=ALREADY-LOADING pendingPath matches nav=%d",
                  String(target.suffix(28)), navigationPath.count)
            return false
        }
        if let last = navigationPath.last, last == target {
            gktlLog("[GKTL-Browse] preFlight REJECT target=…%@ reason=SAME-AS-NAVLAST nav=%d",
              String(target.suffix(28)), navigationPath.count)
            return false
        }
        return true
    }

    /// Navigate to a specific index in the path stack (breadcrumb tap).
    func navigateToIndex(_ index: Int) {
        // Clip the nav stack FIRST to the desired prefix.
        // The preflight checks the CLIPPED state — we are NOT adding
        // a new entry here, only truncating. So the invariant
        // "navPath.last != target" doesn't apply; we skip the
        // standard preflight and call browse directly.
        let oldCount = navigationPath.count
        let truncated = Array(navigationPath.prefix(index + 1))
        navigationPath = truncated
        // Restore scroll position for the breadcrumb target.
        if let target = truncated.last {
            scrollRestoreTarget = _scrollPositionCache[Self._normalizePath(target)]
        }
        if let target = truncated.last {
            // Fast path — 90% of breadcrumb taps are for
            // directories the user has ALREADY browsed. Hit cache first
            // (0 XPC, instant). If hit, no marker is needed — we're
            // atomically jumping to a known-good state.
            if _restoreCachedEntries(for: target) {
                // Clean up any stale marker from a prior in-flight browse
                // that is now obsolete because we jumped elsewhere.
                _forceRollbackStalePrePushedNavigation()
                return
            }
            // Slow path — cache miss → need to browse. Proceed with the
            // marker regime so a FAILURE pops the (now-wrong) truncated
            // last entry and restores the next-parent state.
            guard Self.preFlightBrowseDestination(
                target,
                isLoading: isLoading,
                pendingPath: _pendingBrowsePath,
                // Pass path WITHOUT the target we just set — so the
                // "navPath.last != target" check doesn't
                // self-reject.
                navigationPath: Array(truncated.dropLast())
            ) else {
                return
            }
            // Roll back any stale marker BEFORE setting our
            // own. browseDirectory no longer does this internally, so
            // every marker-setting caller must clean up first.
            _forceRollbackStalePrePushedNavigation()
            _pendingPrePushedNavigation = .popLast(target)
            browseDirectory(at: target)
        } else {
            currentEntries = []
        }
    }

    /// Enter a root container from the container list.
    func enterContainer(_ containerPath: String) {
        guard !containerPath.isEmpty else { return }
        // For container taps we're replacing the whole stack → no
        // duplicate-with-last check because the stack becomes empty
        // before insertion.
        if isLoading && _pendingBrowsePath == containerPath { return }
        _forceRollbackStalePrePushedNavigation()
        navigationPath = [containerPath]
        _pendingPrePushedNavigation = .resetAll
        browseDirectory(at: containerPath)
    }

    /// Enter a quick-path shortcut. Same semantics as enterContainer.
    func enterQuickPath(_ quickPath: String) {
        guard !quickPath.isEmpty else { return }
        if isLoading && _pendingBrowsePath == quickPath { return }
        _forceRollbackStalePrePushedNavigation()
        navigationPath = [quickPath]
        _pendingPrePushedNavigation = .resetAll
        browseDirectory(at: quickPath)
    }

    /// Called BEFORE setting a new _pendingPrePushedNavigation.
    /// If the previous marker is still in .none we're good;
    /// otherwise it means the LAST browse completed without ever
    /// running its rollback (its _applyBrowseResult either wasn't
    /// called because of guard-return OR the browse silently
    /// dropped its callback). Apply the rollback now to keep the
    /// nav stack honest.
    /// Also atomically restores currentEntries from cache
    /// for the rolled-back-to path, so the listing state never
    /// lags the breadcrumb state by even one render cycle. This is
    /// the final piece needed to eliminate the "nav shows /Library
    /// but content still shows /Documents" mismatch window that
    /// manifested as duplicate ID rows, handler 0 drops, and
    /// KeyboardInputScene FBScene assertion failures.
    private func _forceRollbackStalePrePushedNavigation() {
        let markerBefore = _pendingPrePushedNavigation
        switch markerBefore {
        case .none: return
        case .popLast(let expected):
            if navigationPath.last == expected {
                let oldCount = navigationPath.count
                let removed = navigationPath.last ?? "?"
                navigationPath.removeLast()
                gktlLog("[GKTL-Nav] stale-popLast old=%d new=%d removed=…%@ markerExpected=…%@",
                      oldCount, navigationPath.count,
                      String(removed.suffix(24)), String(expected.suffix(24)))
            }
        case .resetAll:
            let oldCount = navigationPath.count
            navigationPath.removeAll()
            gktlLog("[GKTL-Nav] stale-resetAll old=%d new=0", oldCount)
        }
        _pendingPrePushedNavigation = .none
        // Post-rollback state sync. Matches the same logic
        // used inline inside rollbackPrePushedNavigationIfNeeded() in
        // _applyBrowseResult.
        if let parent = navigationPath.last {
            if !_restoreCachedEntries(for: parent) {
                browseDirectory(at: parent)
            }
        } else {
            currentEntries = []
            isLoading = false
        }
    }

    // MARK: - File Reading

    func readFile(_ entry: BQFileEntry) {
        errorMessage = nil
        isLoading = true

        let fileAccess = self.fileAccess
        let fullPath = entry.fullPath

        // Size guard: refuse to read files larger than a threshold to
        // avoid OOM. 8 MB is a reasonable upper bound for in-app preview.
        let maxPreviewBytes: Int64 = 8 * 1024 * 1024
        if entry.fileSize > maxPreviewBytes {
            errorMessage = String(
                format: String(localized: "File is too large to preview (%.1f MB). Limit is %.0f MB."),
                Double(entry.fileSize) / 1_048_576.0,
                Double(maxPreviewBytes) / 1_048_576.0
            )
            isLoading = false
            return
        }

        Task.detached(priority: .userInitiated) {
            do {
                let data = try fileAccess.readFile(atPath: fullPath)
                let preview = FilePreview(entry: entry, data: data)
                DispatchQueue.main.async { [weak self] in
                    self?.filePreview = preview
                    self?.isLoading = false
                }
            } catch {
                DispatchQueue.main.async { [weak self] in
                    self?.errorMessage = ErrorHandler.friendlyMessage(for: error)
                    self?.isLoading = false
                }
            }
        }
    }

    // MARK: - Recursive Search

    /// Maximum depth for recursive search within a directory.
    private static let maxSearchDepth = 6
    /// Maximum results to collect before stopping.
    private static let maxSearchResults = 500

    /// Recursively search within a directory for files matching `query`.
    /// Results are published incrementally to `searchResults`.
    func searchInCurrentDirectory(_ query: String) {
        guard !query.isEmpty else {
            rawSearchResults = []
            rawSearchCount = 0
            recomputeFilteredResults()
            isSearching = false
            searchProgress = ""
            return
        }
        guard let rootPath = currentDirectoryPath else { return }

        let gen = nextSearchGeneration()
        isSearching = true
        rawSearchResults = []
        rawSearchCount = 0
        recomputeFilteredResults()
        searchProgress = String(localized: "Searching…")

        let fileAccess = self.fileAccess
        let q = query
        let currentGen = gen
        let maxDepth = Self.maxSearchDepth
        let maxResults = Self.maxSearchResults
        let asciiQueryOpt: [UInt8]? = q.utf8.allSatisfy { $0 < 0x80 }
            ? Array(q.utf8).map { $0 | 0x20 }
            : nil

        Task.detached(priority: .userInitiated) { [weak self] in
            nonisolated(unsafe) var results: [SearchResult] = []
            Self.recursiveSearch(
                fileAccess: fileAccess,
                path: rootPath,
                query: q,
                asciiQuery: asciiQueryOpt,
                depth: 0,
                maxDepth: maxDepth,
                maxResults: maxResults,
                relativeRoot: rootPath,
                containerName: nil,
                results: &results,
                isCancelled: { [weak self] in self?.searchGeneration != currentGen }
            )

            Task { @MainActor [weak self] in
                guard let self else { return }
                guard self.searchGeneration == currentGen else { return }
                self.rawSearchResults = results
                self.rawSearchCount = results.count
                self.recomputeFilteredResults()
                self.isSearching = false
                let suffix = results.count >= Self.maxSearchResults
                    ? String(localized: " (cap reached — use a narrower query)")
                    : ""
                if results.isEmpty {
                    self.searchProgress = String(localized: "No results")
                } else {
                    let format = String(localized: "Found %lld result%@",
                                        defaultValue: "Found %lld result%@",
                                        comment: "Search result summary; %lld = count, %@ = plural 's' or empty")
                    self.searchProgress = String(format: format, Int64(results.count),
                                                  results.count == 1 ? "" : "s")
                    + suffix
                }
            }
        }
    }

    /// Global search across all discovered app containers.
    func searchAllContainers(_ query: String) {
        guard !query.isEmpty else {
            rawSearchResults = []
            rawSearchCount = 0
            recomputeFilteredResults()
            isSearching = false
            searchProgress = ""
            return
        }

        let gen = nextSearchGeneration()
        isSearching = true
        rawSearchResults = []
        rawSearchCount = 0
        recomputeFilteredResults()
        searchProgress = String(
            format: String(localized: "Searching %d containers…"),
            containers.count
        )

        let fileAccess = self.fileAccess
        let q = query
        let containersToSearch = containers
        let currentGen = gen
        let maxDepth = Self.maxSearchDepth
        let maxResults = Self.maxSearchResults

        let searchQueue = OperationQueue()
        searchQueue.maxConcurrentOperationCount = 2
        searchQueue.qualityOfService = .userInitiated

        let lock = NSLock()
        var allResults: [SearchResult] = []
        let totalCount = containersToSearch.count
        var completedCount = 0

        let asciiQueryOpt: [UInt8]? = q.utf8.allSatisfy { $0 < 0x80 }
            ? Array(q.utf8).map { $0 | 0x20 }
            : nil
        let perContainerMax = maxResults

        for container in containersToSearch {
            searchQueue.addOperation { [weak self] in
                guard self?.searchGeneration == currentGen else { return }

                nonisolated(unsafe) var containerResults: [SearchResult] = []
                Self.recursiveSearch(
                    fileAccess: fileAccess,
                    path: container.path,
                    query: q,
                    asciiQuery: asciiQueryOpt,
                    depth: 0,
                    maxDepth: maxDepth,
                    maxResults: perContainerMax,
                    relativeRoot: container.path,
                    containerName: container.displayName,
                    results: &containerResults,
                    isCancelled: { self?.searchGeneration != currentGen }
                )

                var reachedCap = false
                lock.lock()
                let remainingSlots = maxResults - allResults.count
                if !containerResults.isEmpty && remainingSlots > 0 {
                    allResults.append(
                        contentsOf: containerResults.prefix(remainingSlots)
                    )
                }
                completedCount += 1
                let finishedCount = completedCount
                let snapshot = allResults
                let rawCount = allResults.count
                reachedCap = allResults.count >= maxResults
                lock.unlock()

                Task { @MainActor [weak self] in
                    guard let self else { return }
                    guard self.searchGeneration == currentGen else { return }
                    // show growing match count live ("· 142 matches")
                    let fmt = String(localized: "Searching %d/%d containers · %lld matches")
                    self.searchProgress = String(format: fmt,
                                                  finishedCount,
                                                  totalCount,
                                                  Int64(rawCount))
                    if !snapshot.isEmpty {
                        self.rawSearchResults = snapshot
                        self.rawSearchCount = rawCount
                        self.recomputeFilteredResults()
                    }
                }

                guard !reachedCap else {
                    searchQueue.cancelAllOperations()
                    return
                }
            }
        }

        Task.detached(priority: .userInitiated) {
            searchQueue.waitUntilAllOperationsAreFinished()

            let finalResults = lock.withLock { allResults }
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard self.searchGeneration == currentGen else { return }
                self.rawSearchResults = finalResults
                self.rawSearchCount = finalResults.count
                self.recomputeFilteredResults()
                self.isSearching = false
                let suffix = finalResults.count >= maxResults
                    ? String(localized: " (cap reached — use a narrower query)")
                    : ""
                if finalResults.isEmpty {
                    self.searchProgress = String(localized: "No results")
                } else {
                    let format = String(localized: "Found %lld result%@",
                                        defaultValue: "Found %lld result%@",
                                        comment: "Search result summary; %lld = count, %@ = plural 's' or empty")
                    self.searchProgress = String(format: format, Int64(finalResults.count),
                                                  finalResults.count == 1 ? "" : "s")
                    + suffix
                }
            }
        }
    }

    /// Clear search state.
    func clearSearch() {
        cancelSearch()
    }

    // MARK: - Recursive Search (static, background-safe)

    private nonisolated static func recursiveSearch(
        fileAccess: BadQueryFileAccess,
        path: String,
        query: String,
        asciiQuery: [UInt8]?,
        depth: Int,
        maxDepth: Int,
        maxResults: Int,
        relativeRoot: String,
        containerName: String?,
        results: inout [SearchResult],
        isCancelled: () -> Bool
    ) {
        guard !isCancelled(), depth <= maxDepth, results.count < maxResults else { return }

        var listError: NSError?
        // No-fallback: recursive search walks every container subtree;
        // a denied lease must mean "skip", never a 350K-inode scan.
        let entries = fileAccess.listDirectoryNoFallback(atPath: path, error: &listError)
        if entries.isEmpty { return }

        // If caller gave us a prebuilt ASCII needle, we use the
        // allocation-free inline path. Otherwise fall back to Foundation's
        // `localizedCaseInsensitiveContains` once per file name.
        // Using the prebuilt buffer avoids ~10k redundant allocations on
        // a typical 200-container global search.

        for entry in entries {
            if isCancelled() || results.count >= maxResults { return }

            // Check if the file name matches
            let matches: Bool
            if let needle = asciiQuery, entry.name.utf8.allSatisfy({ $0 < 0x80 }) {
                matches = Self.asciiCaseInsensitiveContainsInline(
                    haystackUTF8: entry.name.utf8,
                    needle: needle
                )
            } else {
                matches = entry.name.localizedCaseInsensitiveContains(query)
            }

            if matches {
                let relPath = String(entry.fullPath.dropFirst(relativeRoot.count))
                results.append(SearchResult(
                    id: entry.fullPath,
                    entry: entry,
                    relativePath: relPath.isEmpty ? entry.name : relPath,
                    containerName: containerName
                ))
            }

            // Recurse into subdirectories
            if entry.isDirectory && depth < maxDepth {
                recursiveSearch(
                    fileAccess: fileAccess,
                    path: entry.fullPath,
                    query: query,
                    asciiQuery: asciiQuery,
                    depth: depth + 1,
                    maxDepth: maxDepth,
                    maxResults: maxResults,
                    relativeRoot: relativeRoot,
                    containerName: containerName,
                    results: &results,
                    isCancelled: isCancelled
                )
            }
        }
    }

    /// True-case-insensitive contains for pure ASCII byte strings.
    /// Normalizes A-Z → a-z by OR-ing with 0x20 on both sides.
    ///
    /// NOTE: This helper allocates two new [UInt8] (`haystack.map` +
    /// `needle.map`) and is kept only as a readable reference / tests.
    /// The hot path uses `asciiCaseInsensitiveContainsInline` below,
    /// which avoids any allocation.
    private nonisolated static func asciiCaseInsensitiveContains(
        haystack: [UInt8],
        needle: [UInt8]
    ) -> Bool {
        guard !needle.isEmpty else { return true }
        guard haystack.count >= needle.count else { return false }
        let n = needle.map { $0 | 0x20 }
        let h = haystack.map { $0 | 0x20 }
        let maxStart = h.count - n.count
        outer: for start in 0...maxStart {
            for j in 0..<n.count {
                if h[start &+ j] != n[j] { continue outer }
            }
            return true
        }
        return false
    }

    /// Allocation-free ASCII case-insensitive contains.
    ///
    /// Accepts a haystack as `String.UTF8View` (no copy) and a prebuilt
    /// needle buffer already lowercased with `$0 | 0x20`. Performs the
    /// A–Z → a–z normalization on the haystack on the fly inside a
    /// single-pass copy into a small buffer sized exactly to the file
    /// name (iOS file names are typically < 120 bytes).
    private nonisolated static func asciiCaseInsensitiveContainsInline(
        haystackUTF8: String.UTF8View,
        needle: [UInt8]
    ) -> Bool {
        guard !needle.isEmpty else { return true }
        let needleCount = needle.count

        // Build a small byte buffer of the haystack and count in one
        // pass. On a typical iOS short filename (20–80 bytes) this is
        // ~2x cheaper than counting UTF8 bytes first (scan 1) and then
        // copying (scan 2). Using reserveCapacity + append avoids any
        // reallocations. String.UTF8 underestimatedCount is 0 but we
        // provide a guess based on the needle.
        var buf: [UInt8] = []
        buf.reserveCapacity(needleCount * 4)  // generous enough for ~100 char names
        var iter = haystackUTF8.makeIterator()
        while let byte = iter.next() { buf.append(byte) }

        let hayCount = buf.count
        guard hayCount >= needleCount else { return false }
        let maxStart = hayCount - needleCount

        outer: for start in 0...maxStart {
            for j in 0..<needleCount {
                // Needle is already lowercased; lowercase hay on the fly
                let hByte = buf[start &+ j] | 0x20
                if hByte != needle[j] { continue outer }
            }
            return true
        }
        return false
    }

    // MARK: - Private Helpers (static, safe for background threads)

    /// Attempts to read the app's metadata plist to extract the bundle ID.
    /// The actual filename on iOS is ".com.apple.mobile_container_manager.metadata.plist"
    /// (note "container_manager" not "container").
    /// Uses a single sandbox lease — fails fast if the file is inaccessible.
    private nonisolated static func extractBundleId(fileAccess: BadQueryFileAccess, containerPath: String) -> String? {
        ContainerMetadata.bundleId(fileAccess: fileAccess, containerPath: containerPath)
    }

    /// Best-effort display name: uses bundle ID last component as the name.
    /// The previous approach of scanning Bundle containers for Info.plist
    /// was too expensive (O(N×M) file reads) and caused the UI to hang.
    private nonisolated static func bestDisplayName(fileAccess: BadQueryFileAccess, containerPath: String, bundleId: String?) -> String {
        if let bundleId {
            // Use the last segment of the bundle ID as the display name.
            // e.g. "com.tencent.xin" → "xin"
            return bundleId.split(separator: ".").last.map(String.init) ?? bundleId
        }
        // No bundle ID — use UUID prefix.
        let uuid = (containerPath as NSString).lastPathComponent
        let shortUuid = String(uuid.prefix(8))
        return "Container \(shortUuid)…"
    }
}

// MARK: - File Preview

struct FilePreview: Identifiable, Equatable {
    let id = UUID()
    let entry: BQFileEntry
    let data: Data

    static func == (lhs: FilePreview, rhs: FilePreview) -> Bool {
        lhs.id == rhs.id
    }

    /// Attempts to decode the data as UTF-8, then UTF-16 (with BOM
    /// detection and a printable-ratio heuristic to reject the wrong
    /// endianness, which silently decodes into CJK garbage).
    /// UTF-8 is only accepted when the result contains no NUL — a
    /// NUL-bearing payload is actually UTF-16/32, not UTF-8 text.
    var textPreview: String? {
        if let s = String(data: data, encoding: .utf8), !s.contains("\0") {
            return s
        }
        // BOM checks first.
        if data.count >= 2 {
            let b0 = data[data.startIndex], b1 = data[data.index(after: data.startIndex)]
            if b0 == 0xFE && b1 == 0xFF {
                return String(data: data, encoding: .utf16BigEndian)
            }
            if b0 == 0xFF && b1 == 0xFE {
                return String(data: data, encoding: .utf16LittleEndian)
            }
        }
        // No BOM: try both endiannesses and keep the one that decodes
        // to mostly-printable ASCII/Latin text.
        func printableScore(_ s: String) -> Int {
            var n = 0
            for ch in s {
                if ch.isASCII && (ch.isLetter || ch.isNumber || ch.isPunctuation || ch == " " || ch.isNewline) { n += 1 }
                else if ch.unicodeScalars.count > 1 || !ch.isASCII { n -= 2 }
            }
            return n
        }
        let be = String(data: data, encoding: .utf16BigEndian)
        let le = String(data: data, encoding: .utf16LittleEndian)
        if let be, let le {
            return printableScore(be) >= printableScore(le) ? be : le
        }
        return be ?? le
    }

    /// Returns a hex dump of the first 4KB with offset + ASCII sidebar.
    var hexPreview: String {
        let previewData = Array(data.prefix(4096))
        var lines: [String] = []
        var offset = 0
        for chunk in previewData.chunked(into: 16) {
            // Offset column
            let offsetStr = String(format: "%08x", offset)
            // Hex column
            let hexParts = chunk.map { String(format: "%02x", $0) }
            var hexLine = hexParts.joined(separator: " ")
            // Pad if last row is short
            if chunk.count < 16 {
                let padCount = (16 - chunk.count) * 3 - 1
                hexLine += String(repeating: " ", count: max(0, padCount))
            }
            // ASCII column
            let ascii = chunk.map { byte -> String in
                if byte >= 0x20 && byte <= 0x7E {
                    return String(format: "%c", byte)
                } else {
                    return "."
                }
            }.joined()
            lines.append("\(offsetStr)  \(hexLine)  |\(ascii)|")
            offset += 16
        }
        return lines.joined(separator: "\n")
    }

    /// Parsed SQLite tables if the data is a valid SQLite database.
    /// Keys are table names, values are row dictionaries. Empty
    /// tables are omitted.
    var sqliteTables: [String: [[String: String]]]? {
        guard detectedType == .database else { return nil }
        let parser = SQLiteParser(data: data)
        var result: [String: [[String: String]]] = [:]
        for table in parser.parseTables() {
            if table.hasPrefix("sqlite_") { continue }
            let (_, rows) = parser.parseTable(table)
            guard !rows.isEmpty else { continue }
            result[table] = rows
        }
        return result.isEmpty ? nil : result
    }

    /// Parsed plist dictionary if the data is a valid property list.
    var plistDictionary: [String: Any]? {
        guard detectedType == .plist else { return nil }
        var format = PropertyListSerialization.PropertyListFormat.binary
        return try? PropertyListSerialization.propertyList(
            from: data, options: [], format: &format
        ) as? [String: Any]
    }

    /// Parsed JSON object if the data is valid JSON.
    var jsonObject: Any? {
        guard detectedType == .json else { return nil }
        return try? JSONSerialization.jsonObject(with: data, options: [])
    }

    /// Formatted JSON string (pretty-printed).
    var formattedJSON: String? {
        guard detectedType == .json else { return nil }
        guard let obj = try? JSONSerialization.jsonObject(with: data, options: []),
              let data = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Detects the file type based on content and extension.
    var detectedType: FilePreview.FileType {
        let kind = FileTypeRegistry.classify(fileName: entry.name, data: data)
        switch kind {
        case .plist:   return .plist
        case .json:    return .json
        case .database: return .database
        case .text:    return .text
        case .image:   return .image
        case .xml:     return .xml
        case .binary:  return .binary
        }
    }

    enum FileType: String {
        case plist = "Property List"
        case json = "JSON"
        case database = "SQLite Database"
        case text = "Text"
        case image = "Image"
        case xml = "XML"
        case binary = "Binary Data"
    }
}

// MARK: - Array Chunk Helper

extension Array {
    nonisolated func chunked(into size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}

// MARK: - Archive Operations (copy-style archive)

extension FileExplorerModel {

    /// Whether the current directory or a specific entry lives inside
    /// the Archive folder (prevents archiving the archive).
    func isArchivedPath(_ path: String) -> Bool {
        ArchiveManager.isPathInsideArchive(path)
    }

    /// True if the Archive quick-path shows a "new" state we can use
    /// to highlight the new feature the first time users land.
    var archiveQuickPath: QuickPath? {
        quickPaths.first { $0.category == .local }
    }

    /// Copies a single file/directory entry (BQFileEntry) into the
    /// archive. Runs on a background queue because large directory
    /// trees can take seconds (each file needs one bad_query read).
    func archiveEntryAsync(
        _ entry: BQFileEntry,
        progressHandler: ((_ copiedBytes: Int64, _ totalEstimate: Int64) -> Void)? = nil,
        completion: ((Result<(archivedPath: String, bytesWritten: Int64), Error>) -> Void)? = nil
    ) {
        let fa = fileAccess
        let estimatedSize = entry.fileSize
        let archiveMsg = String(
            format: String(localized: "Archiving %@…"),
            entry.name
        )
        archiveLastMessage = archiveMsg
        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                let result = try ArchiveManager.archiveEntry(
                    entry,
                    fileAccess: fa,
                    onByteCopied: progressHandler
                )
                Task { @MainActor [weak self] in
                    let ok = String(
                        format: String(localized: "Archived %@ (%d files, %@)"),
                        entry.name,
                        1, // simplified: bytes covers content but file count is for preview only
                        ByteCountFormatter.string(fromByteCount: result.bytesWritten, countStyle: .file)
                    )
                    self?.archiveLastMessage = ok
                    self?.refreshArchiveStats()
                    completion?(.success(result))
                }
            } catch {
                Task { @MainActor [weak self] in
                    self?.archiveLastMessage = error.localizedDescription
                    completion?(.failure(error))
                }
            }
        }
    }

    /// Deletes an archive entry by its short name (last path component
    /// shown in the Archive directory listing).
    func deleteArchivedItem(named name: String, completion: ((Result<Void, Error>) -> Void)? = nil) {
        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                try ArchiveManager.deleteArchivedItem(named: name)
                Task { @MainActor [weak self] in
                    let ok = String(
                        format: String(localized: "Deleted archive entry %@"),
                        name
                    )
                    self?.archiveLastMessage = ok
                    self?.refreshArchiveStats()
                    completion?(.success(()))
                }
            } catch {
                Task { @MainActor [weak self] in
                    self?.archiveLastMessage = error.localizedDescription
                    completion?(.failure(error))
                }
            }
        }
    }

    /// Recomputes the aggregate byte count + entry count shown next to
    /// the Archive quick-path. Called on archive add/remove and once
    /// at init time so the UI has a fresh value.
    func refreshArchiveStats() {
        Task.detached(priority: .background) { [weak self] in
            guard let entries = try? ArchiveManager.listArchiveEntries() else {
                Task { @MainActor in
                    self?.archiveStatsCount = 0
                    self?.archiveStatsTotalBytes = 0
                }
                return
            }
            var total: Int64 = 0
            for e in entries {
                if e.metadata.totalByteSize >= 0 {
                    total += e.metadata.totalByteSize
                }
            }
            Task { @MainActor [weak self] in
                self?.archiveStatsCount = entries.count
                self?.archiveStatsTotalBytes = total
            }
        }
    }

    /// True if an entry with the same name already exists in the
    /// archive. Used by the View to decide between "Overwrite?" /
    /// "Rename?" options on tap.
    func hasArchiveCollision(for entry: BQFileEntry) -> Bool {
        ArchiveManager.hasArchivedItem(named: entry.name)
    }
}
