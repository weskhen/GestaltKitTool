//
//  FileExplorerView.swift
//  GestaltKitTool
//
//  Cross-application sandbox file explorer.
//  Uses bad_query path traversal to browse and read data from
//  other apps' containers on the device.
//

import Combine
import SwiftUI
import UIKit

struct FileExplorerView: View {
    @StateObject private var model = FileExplorerModel()
    @State private var searchText = ""
    @State private var searchDebounceTask: Task<Void, Never>?

    // C-10: Use a single enum-based sheet manager instead of 4 chained
    // .sheet(item:) modifiers, which conflict with each other.
    @State private var activeSheet: ExplorerSheet?

    /// Active confirmation dialog type.
    enum ArchiveAction: Identifiable {
        case archive(BQFileEntry)      // Copy to archive
        case overwriteArchive(BQFileEntry) // Name collision → overwrite?
        case deleteFromArchive(String) // Name of archive entry to delete
        case restoreFromArchive(String) // Name to restore to export dir

        var id: String {
            switch self {
            case .archive(let e):      "archive/\(e.fullPath)"
            case .overwriteArchive(let e): "overwrite/\(e.fullPath)"
            case .deleteFromArchive(let n): "del/\(n)"
            case .restoreFromArchive(let n): "rest/\(n)"
            }
        }
    }

    enum ExplorerSheet: Identifiable {
        case filePreview(FilePreview)
        case fileDetail(BQFileEntry)
        case quickPathDetail(QuickPath)
        case containerDetail(AppContainer)

        var id: String {
            switch self {
            case .filePreview(let p): "preview/\(p.id)"
            case .fileDetail(let e): "detail/\(e.fullPath)"
            case .quickPathDetail(let q): "qp/\(q.id)"
            case .containerDetail(let c): "container/\(c.id)"
            }
        }
    }

    /// Tracks whether the current list view is showing entries inside
    /// the Archive folder — used to swap contextual actions from
    /// "Archive this" to "Restore from archive / Delete archive entry".
    private var isBrowsingArchive: Bool {
        model.isArchivedPath(model.currentDirectoryPath ?? "")
    }

    var body: some View {
        NavigationStack {
            Group {
                if model.navigationPath.isEmpty {
                    if !searchText.isEmpty && model.isSearching {
                        // Global search in progress on root page
                        searchResultsView
                    } else if !searchText.isEmpty && !model.searchResults.isEmpty {
                        // Global search results on root page
                        searchResultsView
                    } else {
                        containerListView
                    }
                } else {
                    if !searchText.isEmpty && (!model.searchResults.isEmpty || model.isSearching) {
                        // Recursive search results in directory browser
                        directorySearchResultsView
                    } else {
                        directoryBrowserView
                    }
                }
            }
            .navigationTitle("Explorer")
            .navigationBarTitleDisplayMode(.large)
            .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .automatic), prompt: searchTextPrompt)
            // OPT-C: Scope segmented control — the iOS-standard search
            // scope bar rendered directly below the search field text.
            // This replaces the "Auto detect from nav" implicit logic with
            // an explicit user choice that also matches Filza 3.0's "Scope"
            // selector.
            .searchScopes($model.searchScope) {
                ForEach(SearchScope.allCases) { scope in
                    Text(scope.localizedLabel).tag(scope)
                }
            }
            // OPT-C: Cancel button — exposed as a navigation bar trailing
            // action while search is active so users can abort a long-
            // running cross-container enumeration without having to
            // backspace the query.
            .toolbar {
                if model.isSearching {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button(role: .cancel) {
                            model.cancelSearch()
                            searchDebounceTask?.cancel()
                            searchText = ""
                        } label: {
                            Text("Cancel")
                                .font(.body.weight(.semibold))
                        }
                    }
                }
            }
            // OPT-C: Size / Type filter chips — sit just below the search
            // bar (using safeAreaInset top so they attach to the nav bar
            // drawing area, not the list content area). Only visible while
            // a search is active; clearing the search hides them.
            .safeAreaInset(edge: .top, spacing: 0) {
                if !searchText.isEmpty {
                    filterChips
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(.bar) // match navigation bar visual
                        .overlay(alignment: .bottom) {
                            Divider()
                        }
                }
            }
            .onChange(of: searchText) { _, newValue in
                onSearchTextChange(newValue)
            }
            // OPT-C: Changing scope while a query is non-empty triggers a
            // fresh recursive search (Auto / All Apps / Current Container
            // all enumerate different directory roots).
            .onChange(of: model.searchScope) { _, _ in
                if !searchText.isEmpty {
                    onSearchTextChange(searchText)
                }
            }
            // OPT-C: Changing type or size filters does NOT re-run the
            // bad_query directory enumeration. We just post-filter the
            // existing 500-row `rawSearchResults` buffer — essentially
            // instant, zero additional I/O.
            .onChange(of: model.sizeFilter) { _, _ in
                model.recomputeFilteredResults()
            }
            .onChange(of: model.typeFilter) { _, _ in
                model.recomputeFilteredResults()
            }
            .onDisappear {
                model.cancelSearch()
                searchDebounceTask?.cancel()
            }
            .toolbar {
                if !model.navigationPath.isEmpty {
                    ToolbarItem(placement: .navigationBarLeading) {
                        Button {
                            model.navigateBack()
                        } label: {
                            Image(systemName: "chevron.left")
                        }
                    }
                    // Bookmark button — only shown when browsing a directory
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button {
                            if let path = model.currentDirectoryPath {
                                model.toggleFavorite(path: path, name: (path as NSString).lastPathComponent)
                            }
                        } label: {
                            Image(systemName: model.isFavorited(path: model.currentDirectoryPath ?? "") ? "bookmark.fill" : "bookmark")
                        }
                        .disabled(model.currentDirectoryPath == nil)
                    }
                }
                if !model.containers.isEmpty || !model.navigationPath.isEmpty {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button {
                            model.discoverContainers()
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                }
            }
        }
        .task {
            if model.containers.isEmpty {
                model.discoverContainers()
            }
        }
        // C-10: Single sheet manager — only one sheet can be presented at a time.
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .filePreview(let preview):
                FilePreviewSheet(preview: preview)
            case .fileDetail(let entry):
                FileDetailSheet(entry: entry)
            case .quickPathDetail(let qp):
                QuickPathDetailSheet(quickPath: qp)
            case .containerDetail(let container):
                ContainerDetailSheet(container: container)
            }
        }
        // Observe model.filePreview and present it via the single sheet manager.
        .onChange(of: model.filePreview) { _, newPreview in
            if let preview = newPreview {
                activeSheet = .filePreview(preview)
            }
        }
        .alert(String(localized: "Error"), isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
        // Archive status toast + confirmation dialog are attached via
        // separate view methods to keep the type-checker happy (the
        // inline .overlay-if-let + transition + animation +
        // .confirmationDialog chain triggered "expression too complex"
        // on Swift 5 / Swift 6 strict concurrency builds).
        .archiveToastOverlay(message: model.archiveLastMessage, onTimeout: {
            model.archiveLastMessage = nil
        })
        .confirmationDialog(
            String(localized: "Archive"),
            isPresented: archiveActionPresented,
            titleVisibility: .visible,
            presenting: pendingArchiveAction
        ) { action in
            switch action {
            case .archive(let entry):
                Button(String(localized: "Copy to Archive")) {
                    model.archiveEntryAsync(entry)
                }
                Button(String(localized: "Cancel"), role: .cancel) { }

            case .overwriteArchive(let entry):
                Button(String(localized: "Overwrite existing archive entry"),
                       role: .destructive) {
                    model.deleteArchivedItem(named: entry.name) { _ in
                        model.archiveEntryAsync(entry)
                    }
                }
                Button(String(localized: "Cancel"), role: .cancel) { }

            case .deleteFromArchive(let name):
                Button(String(localized: "Delete"), role: .destructive) {
                    model.deleteArchivedItem(named: name)
                }
                Button(String(localized: "Cancel"), role: .cancel) { }

            case .restoreFromArchive(let name):
                Button(String(localized: "Restore to Export folder")) {
                    do {
                        let url = try ArchiveManager.restoreArchivedItemToExport(named: name)
                        model.archiveLastMessage = String(
                            format: String(localized: "Restored %@ to Export folder"),
                            name
                        )
                        try openRestoredFile(url: url, name: name)
                    } catch {
                        model.archiveLastMessage = error.localizedDescription
                    }
                }
                Button(String(localized: "Cancel"), role: .cancel) { }
            }
        }
        .task {
            model.refreshArchiveStats()
        }
    }

    /// After restore-to-export, try to show the restored copy in the
    /// file preview sheet. Kept as a separate helper to avoid nesting
    /// KVC-bridge code inside a ViewBuilder, which confuses Swift 6.
    private func openRestoredFile(url: URL, name: String) throws {
        let data = try Data(contentsOf: url)
        let entry = BQFileEntryBuilder.fileEntry(
            name: name,
            fullPath: url.path,
            isDirectory: false,
            size: Int64(url.fileSizeEstimate),
            mtime: Date()
        )
        activeSheet = .filePreview(FilePreview(entry: entry, data: data))
    }

    // MARK: - Archive action helpers (CR-30)

    @State private var pendingArchiveAction: ArchiveAction?

    /// Derived Bool binding used by `.confirmationDialog(isPresented:)`.
    /// Kept separate from `pendingArchiveAction` so the sheet can use the
    /// `presenting:` form without hitting a SwiftUI API mismatch.
    private var archiveActionPresented: Binding<Bool> {
        Binding(
            get: { pendingArchiveAction != nil },
            set: { if !$0 { pendingArchiveAction = nil } }
        )
    }

    /// Entry point used by the row's contextual "Archive" button.
    /// Checks for collisions and routes to the right confirmation.
    private func requestArchive(_ entry: BQFileEntry) {
        if model.hasArchiveCollision(for: entry) {
            pendingArchiveAction = .overwriteArchive(entry)
        } else {
            pendingArchiveAction = .archive(entry)
        }
    }
}

// MARK: - Minimal BQFileEntry factory for synthesized entries

enum BQFileEntryBuilder {
    /// Returns a BQFileEntry with the supplied fields. Uses KVC to set
    /// readonly properties — the ObjC class has no initializer exposed
    /// to Swift that accepts values, and the @synthesize ivars are
    /// writable via setValue:forKey:.
    static func fileEntry(
        name: String,
        fullPath: String,
        isDirectory: Bool,
        size: Int64,
        mtime: Date?
    ) -> BQFileEntry {
        let entry = BQFileEntry()
        entry.setValue(name, forKey: "name")
        entry.setValue(fullPath, forKey: "fullPath")
        entry.setValue(NSNumber(value: isDirectory), forKey: "isDirectory")
        entry.setValue(NSNumber(value: size), forKey: "fileSize")
        if let mtime { entry.setValue(mtime, forKey: "modificationDate") }
        return entry
    }
}

private extension URL {
    /// Rough size estimate used by the restore → preview bridge. 0 if
    /// the resource cannot be read (preview still works, header shows
    /// the correct size once the sheet reads the file).
    var fileSizeEstimate: Int {
        (try? resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
    }
}

// MARK: - Archive Toast

private struct ArchiveToast: View {
    let message: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "archivebox.fill")
                .foregroundStyle(Color.accentColor)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.primary)
                .lineLimit(2)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(Color.accentColor.opacity(0.25), lineWidth: 0.5)
                )
                .shadow(color: .black.opacity(0.08), radius: 14, x: 0, y: 6)
        )
        .frame(maxWidth: 520)
        .padding(.horizontal, 16)
    }
}

// MARK: - Archive-specific View modifiers

extension View {
    /// Floating auto-hiding archive status toast. Kept as a modifier so
    /// FileExplorerView.body stays simple enough for the Swift 6 type-
    /// checker to digest in one pass.
    @ViewBuilder
    func archiveToastOverlay(
        message: String?,
        onTimeout: @escaping () -> Void
    ) -> some View {
        overlay(alignment: .bottom) {
            if let msg = message {
                ArchiveToast(message: msg)
                    .padding(.bottom, 24)
                    .transition(.opacity)
                    .onAppear {
                        let captured = msg
                        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                            onTimeout()
                            // Prevent double-dismiss race: if caller
                            // set a new message in the meantime we
                            // should not nil it out. ArchiveToast still
                            // shows latest value so UI is consistent.
                            _ = captured
                        }
                    }
            }
        }
        .animation(.easeInOut(duration: 0.25), value: message == nil)
    }

}

// MARK: - FileExplorerView: subviews

extension FileExplorerView {

    // MARK: - Container List (Root)

    private var containerListView: some View {
        List {
            // Favorites
            if !filteredFavorites.isEmpty {
                Section {
                    ForEach(filteredFavorites) { fav in
                        FavoriteRow(favorite: fav) {
                            enterPath(fav.path)
                        }
                    }
                } header: {
                    HStack {
                        Text("Favorites")
                        Spacer()
                        Text("\(filteredFavorites.count)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            // Quick Access Paths
            ForEach(filteredQuickPaths, id: \.0.rawValue) { category, paths in
                Section {
                    ForEach(paths) { qp in
                        QuickPathRow(quickPath: qp) {
                            enterPath(qp.path)
                        } onInfo: {
                            activeSheet = .quickPathDetail(qp)
                        }
                    }
                } header: {
                    Text(category.rawValue)
                }
            }

            // App Sandboxes
            if searchText.isEmpty {
                Section {
                    if model.isLoading && model.containers.isEmpty {
                        HStack {
                            ProgressView()
                            Text("Scanning app containers…")
                                .foregroundStyle(.secondary)
                        }
                    } else if model.containers.isEmpty {
                        Label("No app containers found.", systemImage: "tray")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(model.containers) { container in
                            AppContainerRow(container: container) {
                                enterContainer(container)
                            } onInfo: {
                                activeSheet = .containerDetail(container)
                            }
                        }
                    }
                } header: {
                    Text("App Sandboxes")
                } footer: {
                    Text("Each entry is another app's private data container. bad_query bypasses the sandbox to list and read these directories.")
                }
            } else if !filteredContainers.isEmpty {
                // Search results for app containers
                Section {
                    ForEach(filteredContainers) { container in
                        AppContainerRow(container: container) {
                            enterContainer(container)
                        } onInfo: {
                            activeSheet = .containerDetail(container)
                        }
                    }
                } header: {
                    Text("App Sandboxes")
                }
            }

            // Custom Path — hide when searching
            if searchText.isEmpty {
                Section {
                    customPathEntry
                } header: {
                    Text("Custom Path")
                } footer: {
                    Text("Enter any absolute path on the device to browse it directly.")
                }
            }

            // No search results
            if !searchText.isEmpty && filteredQuickPaths.isEmpty && filteredContainers.isEmpty && filteredFavorites.isEmpty {
                Section {
                    Label("No results found.", systemImage: "magnifyingglass")
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var customPathEntry: some View {
        CustomPathRow { path in
            enterPath(path)
        }
    }

    private func enterContainer(_ container: AppContainer) {
        // CR-16: Use the Model's enterContainer helper so the Model
        // can properly track the pre-pushed navigation state and roll
        // it back if the browse fails (prevents "infinite same-named
        // directory" stacking when a container directory doesn't
        // actually exist).
        model.enterContainer(container.path)
    }

    private func enterPath(_ path: String) {
        // CR-16: Same semantics as enterContainer — let the Model own
        // both the nav-stack mutation and any rollback needed on
        // browse failure.
        model.enterQuickPath(path)
    }

    // MARK: - Search

    private var searchTextPrompt: String {
        model.navigationPath.isEmpty ? "Search paths & apps" : "Search files"
    }

    /// Debounced search trigger — waits 300ms after the user stops typing.
    private func onSearchTextChange(_ newValue: String) {
        searchDebounceTask?.cancel()

        if newValue.isEmpty {
            model.clearSearch()
            return
        }

        searchDebounceTask = Task {
            try? await Task.sleep(nanoseconds: 200_000_000)
            if Task.isCancelled { return }
            if newValue.isEmpty { return }

            await MainActor.run {
                // OPT-C: Honour the explicit scope selected by the user
                // (Filza 3.0 "Scope" selector semantics):
                //   .auto — fallback to legacy behaviour (empty nav → global,
                //           non-empty nav → current directory)
                //   .global — always cross-container
                //   .container — always within the deepest container we can
                //                find on the current navigation path
                switch model.searchScope {
                case .global:
                    model.searchAllContainers(newValue)
                case .container:
                    model.searchInCurrentDirectory(newValue)
                case .auto:
                    if model.navigationPath.isEmpty {
                        model.searchAllContainers(newValue)
                    } else {
                        model.searchInCurrentDirectory(newValue)
                    }
                }
            }
        }
    }

    // MARK: - Filter Chips (OPT-C)

    /// Two segmented menu-style chips for size + type.
    ///
    /// Layout fix — DO NOT use `Picker(.menu) + overlay(label)`: the
    /// menu-style Picker draws the **currently selected option text**
    /// inside its button even with `.labelsHidden()` active, and then
    /// the overlay draws the same caption text a second time, producing
    /// a visible "double UI / ghost text" effect (the user-reported
    /// "Any Size" and "Any Type"重影).
    ///
    /// Instead we wrap the Picker inside a `Menu { } label: { }` so the
    /// Picker becomes a pure content source (it never draws a button of
    /// its own), and the button visual is rendered once, exclusively by
    /// the `label:` closure. This is the standard SwiftUI idiom for
    /// fully customising a menu's button appearance.
    @ViewBuilder
    private var filterChips: some View {
        HStack(spacing: 8) {
            // Size chip
            Menu {
                Picker("Size", selection: $model.sizeFilter) {
                    ForEach(SizeFilter.allCases) { f in
                        Text(f.localizedLabel).tag(f)
                    }
                }
            } label: {
                chipLabel(
                    systemImage: "ruler",
                    title: model.sizeFilter.localizedLabel
                )
            }
            .menuStyle(.borderlessButton)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 2)

            // Type chip
            Menu {
                Picker("Type", selection: $model.typeFilter) {
                    ForEach(TypeFilter.allCases) { f in
                        Text(f.localizedLabel).tag(f)
                    }
                }
            } label: {
                chipLabel(
                    systemImage: "doc.text.magnifyingglass",
                    title: model.typeFilter.localizedLabel
                )
            }
            .menuStyle(.borderlessButton)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 2)

            // Reset filters button — only shown when a filter is active.
            if model.sizeFilter != .any || model.typeFilter != .any {
                Button {
                    model.sizeFilter = .any
                    model.typeFilter = .any
                } label: {
                    Image(systemName: "slider.horizontal.2.gobackward")
                        .foregroundStyle(.tint)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Reset filters")
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    /// Shared chip label view — one icon + one title text + one chevron.
    /// Guaranteed to render exactly once per chip, eliminating double-UI
    /// ghosting caused by overlaying text on top of a menu Picker that
    /// already draws the selected state text itself.
    private func chipLabel(systemImage: String, title: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: systemImage)
                .foregroundStyle(.secondary)
            Text(title)
                .font(.caption.weight(.medium))
                .lineLimit(1)
            Image(systemName: "chevron.up.chevron.down")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Empty directory placeholder (with per-directory semantics)

    /// Renders when `model.currentEntries.isEmpty` so the user is told
    /// *why* they're seeing nothing instead of a bare "Empty directory".
    ///
    /// User-reported issue summary: "sandbox dirs like Library/Caches,
    /// Library/Preferences always look empty — does showing them even
    /// make sense?"
    ///
    /// Answer: YES they have meaning even when empty. Many standard iOS
    /// sandbox subdirectories are lazily populated (Preferences stays
    /// empty until the app writes its first UserDefaults plist; Caches
    /// stays empty until the app caches network responses, etc.).
    /// Knowing a directory EXISTS and is EMPTY tells you something
    /// useful about app state (e.g. "no defaults written yet" = fresh
    /// install / first launch). The placeholder explains this instead
    /// of just "Empty directory".
    ///
    /// Additionally, if browsing was genuinely limited (inode scan
    /// limit / sandbox rejection) the earlier code changes already fix
    /// enumeration; the soft hint at the bottom covers any residual edge
    /// cases so the user knows to try Search instead.
    @ViewBuilder
    private var emptyDirectoryPlaceholder: some View {
        let path = model.currentDirectoryPath ?? ""
        let hint = Self.sandboxDirectoryHint(for: path)
        VStack(alignment: .leading, spacing: 8) {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(String(localized: "This directory is empty"))
                        .font(.body.weight(.medium))
                    Text(String(localized: "No files or subdirectories were found at this path."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: "tray")
                    .foregroundStyle(.secondary)
            }

            if let hint {
                Divider()
                    .padding(.vertical, 4)
                VStack(alignment: .leading, spacing: 3) {
                    Label(hint.title, systemImage: hint.icon)
                        .font(.caption.weight(.semibold))
                    Text(hint.body)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            // Generic "how to verify" tip — keeps the user from thinking
            // "the tool is broken" when they expected content.
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "lightbulb.max")
                    .foregroundStyle(.yellow)
                    .font(.caption)
                Text(String(localized: "Tip: use the Search tab with a keyword (e.g. the app's bundle ID) to find files the directory view might miss."))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 4)
        }
        .padding(.vertical, 8)
    }

    /// Returns a short per-directory explanation for standard iOS
    /// sandbox subdirectories so the empty view actually teaches the
    /// user something about the filesystem.
    ///
    /// Nonstandard paths return `nil` → only the generic "empty dir"
    /// cell + the generic tip are shown.
    private static func sandboxDirectoryHint(for path: String)
        -> (title: String, icon: String, body: String)?
    {
        let comps = (path as NSString).pathComponents
        let last = comps.last ?? ""
        let parent = comps.dropLast().last ?? ""

        switch (last, parent) {
        case ("Documents", _):
            return (
                title: String(localized: "Documents folder"),
                icon: "doc.richtext",
                body:  String(localized: "Apps store user-generated files here (iCloud on iOS shares this). Empty = the app has not saved any user documents yet. Backups typically include this folder.")
            )
        case ("Library", _):
            return (
                title: String(localized: "Library folder"),
                icon: "books.vertical",
                body:  String(localized: "The app's 'system' data root. Contains Preferences, Caches, Cookies, Application Support, etc. Subdirectories are created lazily — seeing Library with only a few children is normal on freshly-installed apps.")
            )
        case ("Preferences", "Library"):
            return (
                title: String(localized: "Preferences — UserDefaults plists"),
                icon: "gearshape",
                body:  String(localized: "Each time the app calls `UserDefaults.synchronize` (or the periodic autosave runs), a plist named <bundleID>.plist is written here. Empty = the app has not persisted any defaults yet — e.g. it's a fresh install and no settings screen was opened. MobileGestalt writes go to a different path (system group, not this folder).")
            )
        case ("Caches", "Library"):
            return (
                title: String(localized: "Library / Caches"),
                icon: "square.stack.3d.up",
                body:  String(localized: "Network responses, image thumbnails, rebuildable data go here. The OS can purge this folder when disk is low (apps must recreate contents). Empty = no cached data written yet, or the OS purged it.")
            )
        case ("tmp", _):
            return (
                title: String(localized: "tmp / scratch directory"),
                icon: "trash.slash",
                body:  String(localized: "Short-lived temporary files. iOS can delete contents here when the app is not running. Empty means nothing is currently being extracted, downloaded or decoded.")
            )
        case ("Application Support", "Library"):
            return (
                title: String(localized: "Library / Application Support"),
                icon: "wrench.and.screwdriver",
                body:  String(localized: "Non-user-facing runtime files: databases, downloaded assets, in-app purchases receipt cache. Empty = the app uses a different persistence location or nothing persists yet. Files here are backed up unless marked with .nosync.")
            )
        case ("Cookies", "Library"):
            return (
                title: String(localized: "Library / Cookies"),
                icon: "person.crop.circle.badge.clock",
                body:  String(localized: "HTTPCookieStorage persistently saved cookies (binary plist). Empty = the app has not made any cookie-setting network requests yet, or uses a non-persistent cookie session.")
            )
        case ("Saved Application State", "Library"):
            return (
                title: String(localized: "Saved Application State"),
                icon: "arrow.triangle.2.circlepath",
                body:  String(localized: "UIKit state restoration data. Written when the app is backgrounded. Empty on apps that opt out of state restoration, or immediately after a force-quit.")
            )
        default:
            // Detect containers that are actually just empty app data roots
            // but don't match a well-known subdir.
            if path.contains("/Containers/Data/Application/") {
                return (
                    title: String(localized: "App container root"),
                    icon: "app.dashed",
                    body:  String(localized: "Top-level container for a single app's sandbox. Files you see here are the ones created by the app: Documents, Library, tmp. Empty subdirectories mean the app hasn't exercised that code path yet.")
                )
            }
            return nil
        }
    }

    // MARK: - Search Results View (Root — Global)

    private var searchResultsView: some View {
        List {
            if model.isSearching {
                Section {
                    HStack {
                        ProgressView()
                        Text(model.searchProgress)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if !model.searchResults.isEmpty {
                Section {
                    ForEach(model.searchResults) { result in
                        SearchResultRow(result: result, onTap: {
                            // CR-16 v4: Global-search result taps must go
                            // through handleSearchResultTap (not enterPath →
                            // enterQuickPath) because:
                            //   1. Results may be FILES, not directories —
                            //      enterQuickPath would reset the nav stack
                            //      to a file path and show an empty listing.
                            //   2. Results may come from arbitrary subdir
                            //      depth — enterQuickPath would flatten the
                            //      breadcrumb trail losing context.
                            //   3. handleSearchResultTap does full preflight
                            //      + browse-first for unknown types.
                            let entry = result.entry
                            Task { @MainActor in
                                model.handleSearchResultTap(entry)
                                searchText = ""
                                model.clearSearch()
                            }
                        }, onInfo: {
                            activeSheet = .fileDetail(result.entry)
                        })
                    }
                } header: {
                    HStack {
                        Text("Search Results")
                        Spacer()
                        // OPT-C: When filters are active, show both the
                        // post-filter count and the pre-filter raw count
                        // so users understand "3 shown of 142 matches"
                        // instead of wondering why "cap was 500" they only
                        // see 3 rows. Matches Filza 3.0's header counter.
                        if !model.isSearching {
                            let filtered = model.searchResults.count
                            let raw = model.rawSearchCount
                            let label: String = {
                                if raw == 0 || filtered == raw {
                                    return "\(filtered)"
                                }
                                return "\(filtered) / \(raw)"
                            }()
                            Text(label)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            // Also show filtered quick paths & containers (instant filter)
            if !filteredQuickPaths.isEmpty || !filteredContainers.isEmpty {
                Section {
                    ForEach(filteredQuickPaths, id: \.0.rawValue) { category, paths in
                        ForEach(paths) { qp in
                            QuickPathRow(quickPath: qp) {
                                enterPath(qp.path)
                            } onInfo: {
                                activeSheet = .quickPathDetail(qp)
                            }
                        }
                    }
                    ForEach(filteredContainers) { container in
                        AppContainerRow(container: container) {
                            enterContainer(container)
                        } onInfo: {
                            activeSheet = .containerDetail(container)
                        }
                    }
                } header: {
                    Text("Matches")
                }
            }

            if !model.isSearching && model.searchResults.isEmpty && filteredQuickPaths.isEmpty && filteredContainers.isEmpty {
                Section {
                    Label("No results found.", systemImage: "magnifyingglass")
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - Search Results View (Directory — Recursive)

    private var directorySearchResultsView: some View {
        List {
            // Breadcrumb navigation (keep visible during search)
            Section {
                BreadcrumbView(pathStack: model.navigationPath) { index in
                    model.navigateToIndex(index)
                }
            }

            if model.isSearching {
                Section {
                    HStack {
                        ProgressView()
                        Text(model.searchProgress.isEmpty ? "Searching…" : model.searchProgress)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if !model.searchResults.isEmpty {
                Section {
                    ForEach(model.searchResults) { result in
                        SearchResultRow(result: result, onTap: {
                            // C-11: Defer navigation to avoid mutating state
                            // during view update. Use Task to schedule after
                            // the current update cycle.
                            let entry = result.entry
                            Task { @MainActor in
                                // CR-16 v4: Route ALL search-result taps
                                // through the Model's handleSearchResultTap
                                // so they receive the full navigation-safety
                                // regime (preflight, stale-marker rollback,
                                // browse-first for unknown types, no direct
                                // View-level mutation of pendingReadOnBrowse).
                                model.handleSearchResultTap(entry)
                                searchText = ""
                                model.clearSearch()
                            }
                        }, onInfo: {
                            activeSheet = .fileDetail(result.entry)
                        })
                    }
                } header: {
                    HStack {
                        Text("Search Results")
                        Spacer()
                        if !model.isSearching {
                            let filtered = model.searchResults.count
                            let raw = model.rawSearchCount
                            let label: String = {
                                if raw == 0 || filtered == raw {
                                    return "\(filtered)"
                                }
                                return "\(filtered) / \(raw)"
                            }()
                            Text(label)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            if !model.isSearching && model.searchResults.isEmpty {
                Section {
                    Label("No matching files found.", systemImage: "magnifyingglass")
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - Instant Filter (in-memory)

    /// Filtered file entries for the directory browser (instant, single-level).
    private var filteredEntries: [BQFileEntry] {
        guard !searchText.isEmpty else { return model.currentEntries }
        return model.currentEntries.filter {
            $0.name.localizedCaseInsensitiveContains(searchText)
        }
    }

    /// Filtered quick paths for the root page.
    private var filteredQuickPaths: [(QuickPath.QuickPathCategory, [QuickPath])] {
        guard !searchText.isEmpty else { return model.groupedQuickPaths }
        return model.groupedQuickPaths.map { cat, paths in
            (cat, paths.filter { $0.name.localizedCaseInsensitiveContains(searchText) || $0.path.localizedCaseInsensitiveContains(searchText) })
        }.filter { !$0.1.isEmpty }
    }

    /// Filtered app containers for the root page.
    private var filteredContainers: [AppContainer] {
        guard !searchText.isEmpty else { return model.containers }
        return model.containers.filter { c in
            c.displayName.localizedCaseInsensitiveContains(searchText) ||
            (c.bundleIdentifier?.localizedCaseInsensitiveContains(searchText) ?? false) ||
            c.id.localizedCaseInsensitiveContains(searchText)
        }
    }

    /// Filtered favorites for the root page.
    private var filteredFavorites: [Favorite] {
        guard !searchText.isEmpty else { return model.favorites }
        return model.favorites.filter {
            $0.name.localizedCaseInsensitiveContains(searchText) || $0.path.localizedCaseInsensitiveContains(searchText)
        }
    }

    // MARK: - Directory Browser

    private var directoryBrowserView: some View {
        ScrollViewReader { proxy in
            List {
                // Breadcrumb navigation
                Section {
                    BreadcrumbView(pathStack: model.navigationPath) { index in
                        model.navigateToIndex(index)
                    }
                }

                Section {
                    if model.isLoading {
                        HStack {
                            ProgressView()
                            Text("Loading…")
                                .foregroundStyle(.secondary)
                        }
                    } else if model.currentEntries.isEmpty {
                        emptyDirectoryPlaceholder
                    } else if filteredEntries.isEmpty && !searchText.isEmpty {
                        Label("No matching files.", systemImage: "magnifyingglass")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(filteredEntries, id: \.fullPath) { entry in
                            FileEntryRow(
                                entry: entry,
                                onTap: {
                                    // CR-7: Use handleEntryTap for smart routing —
                                    // entries where lstat failed (no metadata) might
                                    // be directories. handleEntryTap tries browse
                                    // first and falls back to read if the directory
                                    // is empty/inaccessible.
                                    model.handleEntryTap(entry)
                                },
                                onInfo: {
                                    activeSheet = .fileDetail(entry)
                                },
                                onArchive: isBrowsingArchive || model.isArchivedPath(entry.fullPath)
                                    ? nil
                                    : { requestArchive(entry) },
                                onRestoreFromArchive: isBrowsingArchive
                                    ? { pendingArchiveAction = .restoreFromArchive(entry.name) }
                                    : nil,
                                onDeleteFromArchive: isBrowsingArchive
                                    ? { pendingArchiveAction = .deleteFromArchive(entry.name) }
                                    : nil
                            )
                            .id(entry.fullPath)
                            // CR-27: Track the last appeared entry as scroll
                            // restore target. Defer to next runloop to avoid
                            // "Publishing changes from within view updates" warning.
                            .onAppear {
                                let path = entry.fullPath
                                DispatchQueue.main.async {
                                    model.scrollRestoreTarget = path
                                }
                            }
                        }
                    }
                }
            }
            // CR-27: Restore scroll position when currentEntries changes
            // (e.g. navigateBack cache restore, or new browse result).
            .onChange(of: model.currentEntries) { _, _ in
                if let target = model.scrollRestoreTarget {
                    // Defer to next runloop so List finishes layout first.
                    DispatchQueue.main.async {
                        withAnimation(.easeOut(duration: 0.15)) {
                            proxy.scrollTo(target, anchor: .top)
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Favorite Row

private struct FavoriteRow: View {
    let favorite: Favorite
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                Image(systemName: "bookmark.fill")
                    .font(.body)
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 24)

                VStack(alignment: .leading, spacing: 2) {
                    Text(favorite.name)
                        .font(.body)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(favorite.path)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Search Result Row

private struct SearchResultRow: View {
    let result: SearchResult
    let onTap: () -> Void
    let onInfo: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 10) {
                Image(systemName: result.entry.isDirectory ? "folder.fill" : fileIcon)
                    .font(.body)
                    .foregroundStyle(result.entry.isDirectory ? Color.accentColor : fileColor)

                VStack(alignment: .leading, spacing: 2) {
                    Text(result.entry.name)
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    // Show relative path (shows which subfolder it's in)
                    Text(result.relativePath)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    if let containerName = result.containerName {
                        Text(containerName)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                if !result.entry.isDirectory {
                    Text(formatSize(result.entry.fileSize))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }

                Button(action: onInfo) {
                    Image(systemName: "info.circle")
                        .font(.body)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(String(localized: "Details"))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var fileIcon: String {
        let ext = (result.entry.name as NSString).pathExtension
        return FileTypeRegistry.icon(for: FileTypeRegistry.classify(extension: ext) ?? .binary)
    }

    private var fileColor: Color {
        let ext = (result.entry.name as NSString).pathExtension
        return FileTypeRegistry.color(for: FileTypeRegistry.classify(extension: ext) ?? .binary)
    }

    private func formatSize(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

// MARK: - Quick Path Row

private struct QuickPathRow: View {
    let quickPath: QuickPath
    let onTap: () -> Void
    let onInfo: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                Image(systemName: quickPath.icon)
                    .font(.body)
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 24)

                VStack(alignment: .leading, spacing: 2) {
                    Text(quickPath.name)
                        .font(.body)
                        .foregroundStyle(.primary)
                    Text(quickPath.path)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer()

                // Info button
                Button(action: onInfo) {
                    Image(systemName: "info.circle")
                        .font(.body)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(String(localized: "Details"))

                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Breadcrumb View

private struct BreadcrumbView: View {
    let pathStack: [String]
    let onTap: (Int) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(pathStack.indices, id: \.self) { index in
                    if index > 0 {
                        Image(systemName: "chevron.right")
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.tertiary)
                    }
                    Button {
                        onTap(index)
                    } label: {
                        Text(displayName(for: index))
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(index == pathStack.count - 1 ? .primary : .secondary)
                            .lineLimit(1)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 2)
        }
        // CR-24: Breadcrumb RENDER log removed (high-frequency).
        // Only keep automated anomaly diagnostics (NOT-A-CHILD, etc.)
        .onChange(of: pathStack) { _, newStack in
            // CR-20 diagnostics: catch impossible-looking breadcrumbs
            // (e.g. duplicates, a parent path that isn't a prefix of
            // the next child, empty entries). These are tell-tale
            // signs of a corrupted navigationPath.
            for i in 0..<newStack.count {
                let path = newStack[i]
                if path.isEmpty {
                    gktlLog("[GKTL-CRUMB] ⚠️ EMPTY-ENTRY at index=%d", i)
                }
                if i > 0 {
                    let parent = newStack[i-1]
                    let expectedPrefix = parent + "/"
                    if !path.hasPrefix(expectedPrefix) && path != parent {
                        gktlLog("[GKTL-CRUMB] ⚠️ NOT-A-CHILD idx=%d: parent=…%@ NOT prefix of child=…%@",
                              i,
                              String(parent.suffix(36)),
                              String(path.suffix(36)))
                    }
                }
            }
            let unique = Set(newStack)
            if unique.count != newStack.count {
                gktlLog("[GKTL-CRUMB] ⚠️ RAW-DUPES unique=%d vs stack=%d",
                      unique.count, newStack.count)
            }
        }
    }

    /// Builds a single-line human-readable short-form of the
    /// breadcrumb stack, e.g. "Library > MobileInstallation > tmp".
    /// Used purely for diagnostic logs.
    private static func abbreviateStack(_ paths: [String]) -> String {
        guard !paths.isEmpty else { return "<empty-stack>" }
        return paths.map { full in
            let url = URL(fileURLWithPath: full)
            var name = url.lastPathComponent
            if name.isEmpty { name = "/" }
            // If lastPathComponent alone is ambiguous (e.g. UUIDs or
            // the very common root "/private/var"), include the
            // parent as well so log readers can spot wrong stacks.
            let parent = url.deletingLastPathComponent().path
            if parent == "/" || parent.isEmpty {
                return name
            }
            // For the root entry (index 0 caller context) show
            // grandparent-lastPath/lastPath if name looks like a UUID
            // or generic "Data".
            if name.range(of: #"^[0-9A-Fa-f-]{8,}$"#, options: .regularExpression) != nil {
                let gp = URL(fileURLWithPath: parent).lastPathComponent
                if !gp.isEmpty { return "\(gp)/\(name)" }
            }
            return name
        }.joined(separator: " › ")
    }

    private func displayName(for index: Int) -> String {
        let path = pathStack[index]
        if index == 0 {
            // Root entry — show a short label
            let last = (path as NSString).lastPathComponent
            if last.isEmpty || last == "/" {
                return "/"
            }
            return last
        }
        return (path as NSString).lastPathComponent
    }
}

// MARK: - App Container Row

private struct AppContainerRow: View {
    let container: AppContainer
    let onTap: () -> Void
    let onInfo: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                Image(systemName: container.containerType == .appGroup ? "square.stack.3d.up" : "app.fill")
                    .font(.title3)
                    .foregroundStyle(Color.accentColor)

                VStack(alignment: .leading, spacing: 3) {
                    Text(container.displayName)
                        .font(.body)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let bundleId = container.bundleIdentifier {
                        Text(bundleId)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Text(container.id.prefix(8) + "…")
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }

                Spacer()

                // Info button
                Button(action: onInfo) {
                    Image(systemName: "info.circle")
                        .font(.body)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(String(localized: "Details"))

                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Custom Path Row

private struct CustomPathRow: View {
    @State private var path = ""
    @State private var validationError: String?
    let onBrowse: (String) -> Void

    private var trimmedPath: String {
        path.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Basic front-end validation: must start with "/" and contain no
    /// null bytes or control characters. This catches typos before
    /// sending the path to the sandbox layer.
    private func validate(_ p: String) -> String? {
        guard !p.isEmpty else { return nil }
        if !p.hasPrefix("/") {
            return String(localized: "Path must start with /")
        }
        if p.contains("\0") {
            return String(localized: "Path contains invalid characters")
        }
        if p.rangeOfCharacter(from: CharacterSet.controlCharacters) != nil {
            return String(localized: "Path contains control characters")
        }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("/var/…", text: $path)
                    .font(.system(.body, design: .monospaced))
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .submitLabel(.go)
                    .onSubmit {
                        let trimmed = trimmedPath
                        guard !trimmed.isEmpty else { return }
                        if let err = validate(trimmed) {
                            validationError = err
                            return
                        }
                        validationError = nil
                        onBrowse(trimmed)
                    }
            }
            if let validationError {
                Text(validationError)
                    .font(.caption2)
                    .foregroundStyle(.red)
            }
        }
    }
}

// MARK: - File Entry Row

private struct FileEntryRow: View {
    let entry: BQFileEntry
    let onTap: () -> Void
    let onInfo: () -> Void
    /// Optional: invoked when the user selects "Copy to Archive"
    /// from the contextual menu (non-Archive view) or "Restore /
    /// Delete" (when browsing inside Archive). Passing nil hides
    /// archive-related actions.
    var onArchive: (() -> Void)? = nil
    var onRestoreFromArchive: (() -> Void)? = nil
    var onDeleteFromArchive: (() -> Void)? = nil

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 10) {
                Image(systemName: entry.isDirectory ? "folder.fill" : fileIcon)
                    .font(.body)
                    .foregroundStyle(entry.isDirectory ? Color.accentColor : fileColor)

                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.name)
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    if !entry.isDirectory {
                        Text(formatSize(entry.fileSize))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }

                Spacer()

                if let modDate = entry.modificationDate {
                    Text(modDate, format: .dateTime.month(.abbreviated).day().hour().minute())
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }

                // Info button
                Button(action: onInfo) {
                    Image(systemName: "info.circle")
                        .font(.body)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(String(localized: "Details"))

                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            if let onArchive {
                Button {
                    onArchive()
                } label: {
                    Label(String(localized: "Copy to Archive"), systemImage: "archivebox")
                }
            }
            if let onRestoreFromArchive {
                Button {
                    onRestoreFromArchive()
                } label: {
                    Label(String(localized: "Restore (copy to Export)"), systemImage: "square.and.arrow.up")
                }
            }
            if let onDeleteFromArchive {
                Button(role: .destructive) {
                    onDeleteFromArchive()
                } label: {
                    Label(String(localized: "Delete from Archive"), systemImage: "trash")
                }
            }
        }
    }

    private var fileIcon: String {
        let ext = (entry.name as NSString).pathExtension
        return FileTypeRegistry.icon(for: FileTypeRegistry.classify(extension: ext) ?? .binary)
    }

    private var fileColor: Color {
        let ext = (entry.name as NSString).pathExtension
        return FileTypeRegistry.color(for: FileTypeRegistry.classify(extension: ext) ?? .binary)
    }

    private func formatSize(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

// MARK: - File Preview Sheet

private struct FilePreviewSheet: View {
    @Environment(\.dismiss) private var dismiss
    let preview: FilePreview
    @State private var displayMode: DisplayMode = .auto
    @State private var exportedFileURL: URL?

    enum DisplayMode: String, CaseIterable {
        case auto, parsed, text, hex
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    infoHeader
                    Divider()
                    contentDisplay
                }
                .padding()
            }
            .navigationTitle(preview.entry.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    HStack(spacing: 12) {
                        if let exportedFileURL {
                            ShareLink(item: exportedFileURL) {
                                Image(systemName: "square.and.arrow.up")
                            }
                            .accessibilityLabel(String(localized: "Export"))
                        }

                        Picker("Mode", selection: $displayMode) {
                            ForEach(DisplayMode.allCases, id: \.self) { mode in
                                Text(mode.rawValue.capitalized).tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 180)
                    }
                }
            }
            .task {
                guard exportedFileURL == nil else { return }
                let url = ExportFileManager.makeExportURL(
                    fileName: preview.entry.name,
                    data: preview.data
                )
                exportedFileURL = url
            }
        }
    }

    private var infoHeader: some View {
        VStack(alignment: .leading, spacing: 6) {
            LabeledContent("Path") {
                Text(preview.entry.fullPath)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .multilineTextAlignment(.trailing)
            }
            LabeledContent("Size") {
                Text(ByteCountFormatter.string(fromByteCount: Int64(preview.data.count), countStyle: .file))
            }
            LabeledContent("Type") {
                Text(FileTypeRegistry.classify(
                    fileName: preview.entry.name,
                    data: preview.data
                ).localizedLabel)
            }
        }
    }

    @ViewBuilder
    private var contentDisplay: some View {
        switch displayMode {
        case .auto:
            autoDisplay
        case .parsed:
            parsedDisplay
        case .text:
            textDisplay
        case .hex:
            hexDisplay
        }
    }

    // Auto mode: pick the best representation based on file type.
    @ViewBuilder
    private var autoDisplay: some View {
        switch preview.detectedType {
        case .plist:
            if let dict = preview.plistDictionary {
                PlistDisplayView(dict: dict)
            } else if let text = preview.textPreview {
                Text(text)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                hexDisplay
            }
        case .json:
            if let json = preview.formattedJSON {
                Text(json)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                textDisplay
            }
        case .text, .xml:
            textDisplay
        case .image:
            imageDisplay
        case .database:
            VStack(spacing: 8) {
                Image(systemName: "cylinder.split.1x2.fill")
                    .font(.largeTitle)
                    .foregroundStyle(.brown)
                Text("SQLite database — binary content shown in hex mode.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 20)
        case .binary:
            hexDisplay
        }
    }

    // Parsed mode: structured view (plist tree / JSON pretty / image).
    @ViewBuilder
    private var parsedDisplay: some View {
        switch preview.detectedType {
        case .plist:
            if let dict = preview.plistDictionary {
                PlistDisplayView(dict: dict)
            } else {
                Text("Unable to parse as property list.")
                    .foregroundStyle(.secondary)
            }
        case .json:
            if let json = preview.formattedJSON {
                Text(json)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text("Unable to parse as JSON.")
                    .foregroundStyle(.secondary)
            }
        case .image:
            imageDisplay
        default:
            Text("No structured view available for this file type.")
                .foregroundStyle(.secondary)
        }
    }

    private var textDisplay: some View {
        Text(preview.textPreview ?? "[Unable to decode as text]")
            .font(.system(.caption, design: .monospaced))
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var hexDisplay: some View {
        Text(preview.hexPreview)
            .font(.system(.caption2, design: .monospaced))
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var imageDisplay: some View {
        VStack(spacing: 8) {
            if let uiImage = UIImage(data: preview.data) {
                Image(uiImage: uiImage)
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: 400)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                Label("Unable to render image", systemImage: "photo.badge.exclamationmark")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - File Detail Sheet

private struct FileDetailSheet: View {
    @Environment(\.dismiss) private var dismiss
    let entry: BQFileEntry

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 14) {
                        Image(systemName: entry.isDirectory ? "folder.fill" : fileTypeIcon)
                            .font(.system(size: 40))
                            .foregroundStyle(entry.isDirectory ? Color.accentColor : fileTypeColor)

                        VStack(alignment: .leading, spacing: 4) {
                            Text(entry.name)
                                .font(.headline)
                                .lineLimit(2)
                                .truncationMode(.middle)
                            Text(entry.isDirectory ? "Directory" : "File")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .padding(.vertical, 4)
                }

                // Path
                Section("Path") {
                    Text(entry.fullPath)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .lineLimit(3)
                        .truncationMode(.middle)
                }

                // Metadata
                Section("Metadata") {
                    LabeledContent("Type") {
                        Text(entry.isDirectory ? "Directory" : fileTypeLabel)
                    }
                    if !entry.isDirectory {
                        LabeledContent("Size") {
                            Text(formatSize(entry.fileSize))
                        }
                    }
                    if let modDate = entry.modificationDate {
                        LabeledContent("Modified") {
                            Text(modDate, format: .dateTime.year().month(.abbreviated).day().hour().minute())
                        }
                    }
                    LabeledContent("Extension") {
                        let ext = (entry.name as NSString).pathExtension
                        Text(ext.isEmpty ? "—" : ext)
                            .font(.system(.caption, design: .monospaced))
                    }
                }

                // Description
                Section("About") {
                    Text(fileDescription)
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .navigationTitle(entry.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    // MARK: - File Type Info

    private var fileTypeIcon: String {
        let ext = (entry.name as NSString).pathExtension.lowercased()
        switch ext {
        case "dylib": return "building.columns.fill"
        case "framework": return "shippingbox.fill"
        default:
            return FileTypeRegistry.icon(for: FileTypeRegistry.classify(extension: ext) ?? .binary)
        }
    }

    private var fileTypeColor: Color {
        let ext = (entry.name as NSString).pathExtension.lowercased()
        switch ext {
        case "dylib", "framework": return .indigo
        default:
            return FileTypeRegistry.color(for: FileTypeRegistry.classify(extension: ext) ?? .binary)
        }
    }

    private var fileTypeLabel: String {
        let ext = (entry.name as NSString).pathExtension.lowercased()
        switch ext {
        case "dylib": return String(localized: "Dynamic Library")
        case "framework": return String(localized: "Framework Bundle")
        default:
            return FileTypeRegistry.detailedLabel(for: ext)
        }
    }

    private var fileDescription: String {
        if entry.isDirectory {
            return String(localized: "A directory (folder). Tap to navigate into it and view its contents.")
        }

        let ext = (entry.name as NSString).pathExtension.lowercased()
        switch ext {
        case "plist":
            return String(localized: "An Apple property list file. Contains structured key-value data, typically used for application settings, preferences, and configuration. Can be in binary or XML format.")
        case "json":
            return String(localized: "A JSON (JavaScript Object Notation) data file. Contains structured data in a human-readable text format, commonly used for app data export, API responses, and configuration.")
        case "sqlite", "db":
            return String(localized: "An SQLite database file. Contains structured data in tables, indexes, and schemas. May store app data, caches, or metadata. Binary format — view in hex mode for raw inspection.")
        case "txt":
            return String(localized: "A plain text file. Contains unformatted text data, readable directly. May include logs, notes, or configuration data.")
        case "log":
            return String(localized: "A log file. Contains timestamped application or system events, useful for debugging and diagnostics. Plain text format.")
        case "png", "jpg", "jpeg", "heic":
            return String(localized: "An image file. Contains raster graphics data. Can be previewed directly in the file viewer. Common formats include PNG, JPEG, and HEIC (Apple's high-efficiency format).")
        case "xml":
            return String(localized: "An XML (eXtensible Markup Language) file. Contains structured text data with tags, used for configuration, data interchange, and property lists in text format.")
        case "dylib":
            return String(localized: "A dynamic library (shared object). Contains compiled machine code loaded at runtime. Binary format — view in hex mode for raw inspection.")
        case "framework":
            return String(localized: "A framework bundle directory. Contains a dynamic library and associated resources (headers, plists). Tap to browse its contents.")
        default:
            return String(localized: "A file in the device filesystem. Tap to preview its contents. The file type is not specifically recognized — it may be shown as text or binary data.")
        }
    }

    private func formatSize(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

// MARK: - Quick Path Detail Sheet

private struct QuickPathDetailSheet: View {
    @Environment(\.dismiss) private var dismiss
    let quickPath: QuickPath

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 14) {
                        Image(systemName: quickPath.icon)
                            .font(.system(size: 40))
                            .foregroundStyle(Color.accentColor)

                        VStack(alignment: .leading, spacing: 4) {
                            Text(quickPath.name)
                                .font(.headline)
                            Text(quickPath.category.rawValue)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .padding(.vertical, 4)
                }

                Section("Path") {
                    Text(quickPath.path)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .lineLimit(3)
                        .truncationMode(.middle)
                }

                Section("About") {
                    Text(quickPath.description)
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .navigationTitle(quickPath.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

// MARK: - Container Detail Sheet

private struct ContainerDetailSheet: View {
    @Environment(\.dismiss) private var dismiss
    let container: AppContainer

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 14) {
                        Image(systemName: container.containerType == .appGroup ? "square.stack.3d.up" : "app.fill")
                            .font(.system(size: 40))
                            .foregroundStyle(Color.accentColor)

                        VStack(alignment: .leading, spacing: 4) {
                            Text(container.displayName)
                                .font(.headline)
                                .lineLimit(2)
                                .truncationMode(.middle)
                            Text(containerTypeLabel)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .padding(.vertical, 4)
                }

                Section("Path") {
                    Text(container.path)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .lineLimit(3)
                        .truncationMode(.middle)
                }

                Section("Metadata") {
                    LabeledContent("Container ID") {
                        Text(container.id)
                            .font(.system(.caption, design: .monospaced))
                    }
                    LabeledContent("Type") {
                        Text(containerTypeLabel)
                    }
                    if let bundleId = container.bundleIdentifier {
                        LabeledContent("Bundle ID") {
                            Text(bundleId)
                                .font(.system(.caption, design: .monospaced))
                                .lineLimit(2)
                                .truncationMode(.middle)
                        }
                    }
                }

                Section("About") {
                    Text(containerDescription)
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .navigationTitle(container.displayName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private var containerTypeLabel: String {
        switch container.containerType {
        case .data: return String(localized: "App Data Container")
        case .appGroup: return String(localized: "App Group Container")
        case .shared: return String(localized: "Shared Container")
        }
    }

    private var containerDescription: String {
        switch container.containerType {
        case .data:
            return String(localized: "An app's private data container. Contains the app's Documents, Library, tmp, and other private directories. This is where the app stores its user data, preferences, caches, and runtime files.")
        case .appGroup:
            return String(localized: "A shared app group container. Used by apps and extensions that belong to the same group to share data. Contains shared Documents, Library, and other directories accessible to all group members.")
        case .shared:
            return String(localized: "A shared container accessible by multiple apps or system services.")
        }
    }
}
