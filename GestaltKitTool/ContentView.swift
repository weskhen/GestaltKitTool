import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject private var viewModel: GestaltViewModel
    @EnvironmentObject private var languageManager: LanguageManager

    var body: some View {
        Group {
            if GestaltAccess.isRunningSupportedOS() {
                TabView {
                    TweakWorkbench()
                        .tabItem { Label(String(localized: "MobileGestalt"), systemImage: "switch.2") }

                    FileExplorerView()
                        .tabItem { Label(String(localized: "Explorer"), systemImage: "folder.badge.gearshape") }

                    SystemInspectorView()
                        .tabItem { Label(String(localized: "Inspector"), systemImage: "shield.lefthalf.filled") }

                    SettingsTab()
                        .tabItem { Label(String(localized: "Settings"), systemImage: "gearshape") }
                }
                .task { viewModel.load() }
            } else {
                UnsupportedOSView()
            }
        }
        .overlay {
            if viewModel.isRespringing {
                NeoSpringView()
            }
        }
        .alert(item: $viewModel.notice) { notice in
            Alert(
                title: Text(notice.title),
                message: Text(notice.message),
                dismissButton: .default(Text(String(localized: "OK")))
            )
        }
    }
}

private struct UnsupportedOSView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "iphone.slash")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            Text(String(localized: "Unsupported iOS Version"))
                .font(.title2.weight(.semibold))
            Text(String(localized: "GestaltKitTool currently supports only iOS 27 beta 1 through beta 4."))
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
        }
        .padding(24)
    }
}

private struct TweakWorkbench: View {
    @EnvironmentObject private var viewModel: GestaltViewModel
    @State private var showsFactoryResetConfirm = false

    var body: some View {
        NavigationStack {
            List {
                Section { deviceStatus }

                Section {
                    NavigationLink {
                        AdvancedGestaltEditor()
                    } label: {
                        Label(String(localized: "Advanced Field Editor"), systemImage: "list.bullet.rectangle")
                    }
                    NavigationLink {
                        BackupLibrary()
                    } label: {
                        // Pixel-aligned row layout: icon column (28pt),
                        // then title+subtitle VStack so both text rows
                        // share the same left edge.  Same treatment as
                        // the Patches row below keeps them aligned.
                        HStack(alignment: .center, spacing: 10) {
                            Image(systemName: "archivebox.fill")
                                .font(.title2)
                                .foregroundStyle(Color.orange)
                                .frame(minWidth: 28, alignment: .center)
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(String(localized: "Backup & Restore"))
                                    .font(.body.weight(.semibold))
                                Text(String(localized: "Full plist snapshot"))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.vertical, 2)
                        .contentShape(Rectangle())
                    }
                    NavigationLink {
                        PatchLibrary()
                    } label: {
                        HStack(alignment: .center, spacing: 10) {
                            Image(systemName: "square.and.arrow.down")
                                .font(.title2)
                                .foregroundStyle(Color.blue)
                                .frame(minWidth: 28, alignment: .center)
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(String(localized: "Patches"))
                                    .font(.body.weight(.semibold))
                                Text(String(localized: "Field-level patches"))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.vertical, 2)
                        .contentShape(Rectangle())
                    }
                    Button(role: .destructive) {
                        showsFactoryResetConfirm = true
                    } label: {
                        Label(String(localized: "Restore Factory Settings"), systemImage: "arrow.uturn.backward.circle")
                    }
                    .disabled(viewModel.plist == nil || viewModel.isBusy)
                } header: {
                    Text(String(localized: "Tools"))
                } footer: {
                    Text(String(localized: "Restore Factory Settings disables all tweaks by writing default values. A backup is created automatically before writing. iPadOS CacheData patches are not reversible — use backup restore for that."))
                }

                if viewModel.plist != nil {
                    tweakSection(.region)
                    dynamicIslandSection
                    modelNameSection

                    ForEach(GestaltTweakCategory.allCases.filter { $0 != .region }) { category in
                        tweakSection(category)
                    }

                }

            }
            .navigationTitle(String(localized: "MobileGestalt"))
            .navigationBarTitleDisplayMode(.large)
            .refreshable { viewModel.load() }
            .safeAreaInset(edge: .bottom) {
                if viewModel.hasStagedTweaks {
                    applyBar
                }
            }
            .confirmationDialog(
                String(localized: "Restore Factory Settings?"),
                isPresented: $showsFactoryResetConfirm,
                titleVisibility: .visible
            ) {
                Button(String(localized: "Restore Factory"), role: .destructive) {
                    viewModel.restoreFactorySettings()
                }
                Button(String(localized: "Cancel"), role: .cancel) {}
            } message: {
                Text(String(localized: "All tweaks will be disabled and written to the plist. A backup of the current state is created automatically. This does not revert iPadOS CacheData patches — use backup restore for that."))
            }
        }
    }

    private func tweakSection(_ category: GestaltTweakCategory) -> some View {
        let definitions = GestaltTweakCatalog.definitions.filter { $0.category == category }
        return Section(category.label) {
            ForEach(definitions) { definition in
                TweakToggle(
                    definition: definition,
                    isOn: Binding(
                        get: { viewModel.selectedTweaks.contains(definition.id) },
                        set: { viewModel.setTweak(definition.id, enabled: $0) }
                    )
                )
            }
            if category == .region {
                Toggle(
                    isOn: Binding(
                        get: { viewModel.stagesAIRegion },
                        set: { viewModel.setAIRegion(enabled: $0) }
                    )
                ) {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(String(localized: "Enable Siri AI (US Region)"))
                            if viewModel.requiresForcedAIEnable {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .font(.caption)
                                    .foregroundStyle(.orange)
                                    .accessibilityLabel(String(localized: "High Risk"))
                            }
                        }
                        if viewModel.requiresForcedAIEnable {
                            Text(String(localized: "Unsupported device: force enable with device identity spoofing. Face ID or system stability may be affected."))
                                .font(.caption)
                                .foregroundStyle(.orange)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var deviceStatus: some View {
        // ── ALIGNMENT FIX ────────────────────────────────────────────
        //
        // WHY THE OLD CODE MISALIGNED:
        //   Row 1 (Status)  used  Label("Current Device", systemImage: "iphone")
        //   Row 2 (System)  used  Label("System Version", systemImage: "info.circle")
        //   Row 3 (Build)   used  Text("Build")                       ← NO IMAGE
        //   Row 4 (iOS)     used  Text("iOS")                         ← NO IMAGE
        //
        // SwiftUI List cells have NO built-in left-column alignment
        // across rows when some cells use Label(image+text) and others
        // use bare Text.  The label column widths end up:
        //     Row 1: ~44pt  (22pt SF Symbol + text)
        //     Row 2: ~40pt  (20pt "info.circle" + text)
        //     Row 3: ~30pt  (Text-only "Build")
        //     Row 4: ~22pt  (Text-only "iOS")
        // → Values on the right start at 4 different X positions.
        //
        // FIX: Explicit Grid with 3 columns.
        //   Column 0 — SF Symbol icon, fixed 22pt width
        //   Column 1 — Label text, fixed width (taken from the longest
        //              label "System Version") via .frame(maxWidth:.infinity,
        //              alignment:.leading) + Grid 统一分配
        //   Column 2 — Value (right side), aligned .leading or .trailing
        //
        // This gives every row pixel-identical left- and right-edges
        // for both the label and value text.
        // ─────────────────────────────────────────────────────────────
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 10) {
            // ── Row 0: Device / Status ────────────────────────────────
            GridRow {
                Image(systemName: "iphone")
                    .font(.body.weight(.regular))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22, alignment: .center)
                Text(String(localized: "Current Device"))
                    .font(.body)
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if viewModel.plist == nil {
                    if viewModel.isBusy || !viewModel.hasAttemptedLoad {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text(String(localized: "Reading MobileGestalt…"))
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        .gridCellColumns(2) // value + no third column → span
                    } else {
                        HStack(spacing: 6) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(String(localized: "Unable to read MobileGestalt"))
                                    .font(.subheadline)
                                Button(String(localized: "Reload"), action: viewModel.load)
                                    .font(.caption)
                            }
                        }
                        .gridCellColumns(2)
                    }
                } else {
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Text(String(localized: "Connected"))
                            .foregroundStyle(.green)
                    }
                }
            }

            Divider()
                .gridCellUnsizedAxes(.horizontal)

            // ── Row 1: System Version + Support badge ─────────────────
            let build   = GestaltAccess.currentOSBuild()
            let version = "\(ProcessInfo.processInfo.operatingSystemVersion.majorVersion).\(ProcessInfo.processInfo.operatingSystemVersion.minorVersion).\(ProcessInfo.processInfo.operatingSystemVersion.patchVersion)"
            let supported = GestaltAccess.isRunningSupportedOS()

            GridRow {
                Image(systemName: "info.circle")
                    .font(.body.weight(.regular))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22, alignment: .center)
                Text(String(localized: "System Version"))
                    .font(.body)
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 4) {
                    Image(systemName: supported ? "checkmark.seal.fill" : "xmark.seal.fill")
                        .foregroundStyle(supported ? .green : .red)
                    Text(supported ? String(localized: "Supported") : String(localized: "Unsupported"))
                        .foregroundStyle(supported ? .green : .red)
                }
            }

            // ── Row 2: Build ──────────────────────────────────────────
            GridRow {
                Image(systemName: "hammer.fill")
                    .font(.body.weight(.regular))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22, alignment: .center)
                Text(String(localized: "Build"))
                    .font(.body)
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(build.isEmpty ? String(localized: "Unknown") : build)
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            // ── Row 3: iOS ────────────────────────────────────────────
            GridRow {
                Image(systemName: "apple.logo")
                    .font(.body.weight(.regular))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22, alignment: .center)
                Text(verbatim: "iOS")   // Product name — intentionally verbatim
                    .font(.body)
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(version)
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
        .listRowInsets(EdgeInsets(top: 12, leading: 14, bottom: 12, trailing: 14))
    }

    private var dynamicIslandSection: some View {
        // ── Effective options (C-2 fix) ─────────────────────────────
        //
        // If the device's REAL ArtworkDeviceSubType isn't one of the
        // canned options in `DynamicIslandOption.all` (e.g. 2778 for
        // iPhone 15 Pro, or a future model we haven't hard-coded),
        // SwiftUI prints:
        //
        //   Picker: the selection "Optional(2778)" is invalid and
        //   does not have an associated tag, this will give
        //   undefined results.
        //
        // and the Picker's binding silently becomes unresponsive.
        //
        // Fix: build a derived list that always contains an entry for
        // the CURRENT stored value if:
        //   a) dynamicIslandSubtype != nil, AND
        //   b) subtype does not already exist in DynamicIslandOption.all
        //
        // The synthetic entry is titled "Current" so users can tell it
        // apart from the hand-picked presets, and is placed first so
        // the user sees the currently-selected value immediately.
        var effective: [DynamicIslandOption] = []
        if let current = viewModel.dynamicIslandSubtype,
           !DynamicIslandOption.all.contains(where: { $0.subtype == current }) {
            effective.append(DynamicIslandOption(
                subtype: current,
                title: String(format: String(localized: "Current (%d)"), current)))
        }
        effective.append(contentsOf: DynamicIslandOption.all)

        return Section {
            Picker(String(localized: "Device Subtype"), selection: $viewModel.dynamicIslandSubtype) {
                // C-2: Explicit Optional<Int> typing.
                //      `.tag(nil)` alone would infer `tag(Never?)` which
                //      does NOT match a `Binding<Int?>` selection — SwiftUI
                //      silently ignores it and keeps complaining about
                //      "selection has no associated tag" for the .none case.
                Text(String(localized: "No Change"))
                    .tag(Optional<Int>.none)
                ForEach(effective) { option in
                    Text("\(option.subtype) · \(option.title)")
                        .tag(Optional<Int>.some(option.subtype))
                }
            }
        } header: {
            Text(String(localized: "Dynamic Island"))
        } footer: {
            Text(String(localized: "Selecting a subtype writes ArtworkDeviceSubType and the Dynamic Island support flag."))
        }
    }

    private var modelNameSection: some View {
        Section(String(localized: "Device Name")) {
            Toggle(String(localized: "Change model name in About"), isOn: $viewModel.changesModelName)
            if viewModel.changesModelName {
                TextField(String(localized: "Model Name"), text: $viewModel.modelName)
                    .textInputAutocapitalization(.words)
            }
        }
    }

    private var applyBar: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(String(format: String(localized: "%d pending changes"), viewModel.stagedChangeCount))
                    .font(.subheadline.weight(.semibold))
                Text(String(localized: "Automatic backup before writing"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(String(localized: "Apply")) { viewModel.applySelectedTweaks() }
                .buttonStyle(.borderedProminent)
                .disabled(viewModel.isBusy)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }
}

private struct TweakToggle: View {
    let definition: GestaltTweakDefinition
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(definition.title)
                    if definition.isRisky {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .accessibilityLabel(String(localized: "High Risk"))
                    }
                }
                Text(definition.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct BackupLibrary: View {
    @EnvironmentObject private var viewModel: GestaltViewModel
    @State private var backupToRestore: GestaltBackup?
    @State private var showsBackupImporter = false
    @State private var editMode: EditMode = .inactive
    @State private var selectedBackups: Set<GestaltBackup> = []
    @State private var showsBatchDeleteConfirm = false

    var body: some View {
        List(selection: $selectedBackups) {
            // ── Top banner: explain what Backups are vs Patches ──
            Section {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "archivebox.fill")
                        .font(.title2)
                        .foregroundStyle(Color.orange)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(String(localized: "Backup & Restore"))
                            .font(.headline)
                        Text(String(localized: "A backup is a full snapshot of this device's MobileGestalt plist, including device-identity fields. Use it to roll back before risky changes. Do not share across devices — restoring it on another device would overwrite its identity."))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }

            Section {
                Button {
                    viewModel.createBackup()
                } label: {
                    Label(String(localized: "Back Up Current MobileGestalt"), systemImage: "plus.circle.fill")
                }
                .disabled(viewModel.plist == nil || viewModel.isBusy)

                Button {
                    showsBackupImporter = true
                } label: {
                    Label(String(localized: "Import Backup"), systemImage: "square.and.arrow.down")
                }
                .disabled(viewModel.isBusy)
            } footer: {
                Text(String(localized: "Importing only adds a file to the backup library. It does not write immediately. The original plist is also backed up before every write."))
            }

            Section(String(localized: "Local Backups")) {
                if viewModel.backups.isEmpty {
                    Label(String(localized: "No Backups"), systemImage: "archivebox")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(viewModel.backups) { backup in
                        BackupRow(backup: backup) {
                            backupToRestore = backup
                        }
                        .tag(backup)
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) {
                                viewModel.delete(backup)
                            } label: {
                                Label(String(localized: "Delete"), systemImage: "trash")
                            }
                            ShareLink(
                                item: backup.url,
                                subject: Text(backup.url.lastPathComponent),
                                preview: SharePreview(
                                    String(localized: "Export Backup"),
                                    image: Image(systemName: "archivebox")
                                )
                            ) {
                                Label(String(localized: "Export Backup"), systemImage: "square.and.arrow.up")
                            }
                            .tint(.blue)
                        }
                    }
                    .onDelete { offsets in
                        for index in offsets { viewModel.delete(viewModel.backups[index]) }
                    }
                }
            }
        }
        .environment(\.editMode, $editMode)
        .navigationTitle(String(localized: "Restore"))
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                EditButton()
            }
            if !selectedBackups.isEmpty {
                ToolbarItem(placement: .bottomBar) {
                    Button(role: .destructive) {
                        showsBatchDeleteConfirm = true
                    } label: {
                        Label(String(format: String(localized: "Delete %d"), selectedBackups.count), systemImage: "trash")
                    }
                }
            }
        }
        .refreshable { viewModel.refreshBackups() }
        .onAppear { viewModel.refreshBackups() }
        .fileImporter(
            isPresented: $showsBackupImporter,
            allowedContentTypes: [.propertyList],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                if let url = urls.first { viewModel.importBackup(from: url) }
            case .failure(let error):
                viewModel.notice = GestaltNotice(kind: .error, message: error.localizedDescription)
            }
        }
        .confirmationDialog(
            String(localized: "Restore This MobileGestalt Backup?"),
            isPresented: Binding(
                get: { backupToRestore != nil },
                set: { if !$0 { backupToRestore = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button(String(localized: "Restore and Write"), role: .destructive) {
                if let backupToRestore { viewModel.restore(backupToRestore) }
                backupToRestore = nil
            }
            Button(String(localized: "Cancel"), role: .cancel) { backupToRestore = nil }
        } message: {
            Text(String(localized: "The current file will be backed up first. SpringBoard will refresh automatically after restoring."))
        }
        .confirmationDialog(
            String(format: String(localized: "Delete %d backups?"), selectedBackups.count),
            isPresented: $showsBatchDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button(String(localized: "Delete"), role: .destructive) {
                viewModel.deleteBackups(Array(selectedBackups))
                selectedBackups.removeAll()
                editMode = .inactive
            }
            Button(String(localized: "Cancel"), role: .cancel) {}
        } message: {
            Text(String(localized: "This action cannot be undone."))
        }
    }
}

private struct PatchLibrary: View {
    @EnvironmentObject private var viewModel: GestaltViewModel
    @State private var patchToApply: GestaltPatch?
    @State private var showsPatchImporter = false
    @State private var showsExporter = false

    var body: some View {
        List {
            // ── Top banner: explain what Patches are vs Backups ──
            Section {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "square.and.arrow.down")
                        .font(.title2)
                        .foregroundStyle(Color.blue)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(String(localized: "Patches"))
                            .font(.headline)
                        Text(String(localized: "A patch is a device-independent set of CacheExtra fields. It merges onto the current plist without touching device identity. Safe to share across devices — perfect for spreading tweak combinations."))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }

            Section {
                Button {
                    showsPatchImporter = true
                } label: {
                    Label(String(localized: "Import Patch"), systemImage: "square.and.arrow.down")
                }
                .disabled(viewModel.isBusy || viewModel.plist == nil)

                NavigationLink {
                    PatchExporter()
                } label: {
                    Label(String(localized: "Export Patch…"), systemImage: "square.and.arrow.up")
                }
                .disabled(viewModel.isBusy || viewModel.plist == nil)
            } header: {
                EmptyView()
            } footer: {
                Text(String(localized: "A patch contains only the CacheExtra fields the author chose to share. Importing applies it on top of the current plist and writes immediately. Export packages applied tweaks or hand-picked fields into a shareable .weskpatch."))
            }

            Section {
                if viewModel.patches.isEmpty {
                    Label(String(localized: "No Patches"), systemImage: "square.and.arrow.down.on.square")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(viewModel.patches) { patch in
                        PatchRow(patch: patch) {
                            patchToApply = patch
                        }
                    }
                    .onDelete { offsets in
                        for index in offsets { viewModel.deletePatch(viewModel.patches[index]) }
                    }
                }
            } header: {
                Text(String(localized: "Local Patches"))
            }
        }
        .navigationTitle(String(localized: "Patches"))
        .navigationBarTitleDisplayMode(.large)
        .refreshable { viewModel.refreshPatches() }
        .onAppear { viewModel.refreshPatches() }
        .fileImporter(
            isPresented: $showsPatchImporter,
            allowedContentTypes: [.json],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                if let url = urls.first { viewModel.importPatch(from: url) }
            case .failure(let error):
                viewModel.notice = GestaltNotice(kind: .error, message: error.localizedDescription)
            }
        }
        .confirmationDialog(
            String(localized: "Apply This Patch?"),
            isPresented: Binding(
                get: { patchToApply != nil },
                set: { if !$0 { patchToApply = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button(String(localized: "Apply and Write"), role: .destructive) {
                if let patchToApply { viewModel.applyPatch(patchToApply) }
                patchToApply = nil
            }
            Button(String(localized: "Cancel"), role: .cancel) { patchToApply = nil }
        } message: {
            Text(String(localized: "The patch's CacheExtra fields will be merged onto the current plist. A backup is created automatically before writing. SpringBoard will refresh after writing."))
        }
    }
}

// MARK: - Patch Exporter

/// Exports a shareable `.weskpatch` from the currently-loaded plist.
/// Users either pick a preset ("Use Applied Tweaks") or hand-select
/// CacheExtra keys from a searchable list.
private struct PatchExporter: View {
    @EnvironmentObject private var viewModel: GestaltViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var patchName: String = ""
    @State private var author: String = ""
    @State private var notes: String = ""
    @State private var searchText: String = ""
    @State private var selectedKeys: Set<String> = []
    @State private var showEmptyNameAlert = false

    var body: some View {
        List {
            Section {
                TextField(String(localized: "Name (required)"), text: $patchName)
                    .textInputAutocapitalization(.words)
                TextField(String(localized: "Author (optional)"), text: $author)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                VStack(alignment: .leading, spacing: 4) {
                    Text(String(localized: "Notes"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextEditor(text: $notes)
                        .frame(minHeight: 70)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(Color.primary.opacity(0.1))
                        )
                }
            } header: {
                Text(String(localized: "Patch Metadata"))
            }

            Section {
                Button {
                    applyAppliedTweaks()
                } label: {
                    Label(
                        String(format: String(localized: "Include Applied Tweaks (%d keys)"),
                               appliedTweakKeys.count),
                        systemImage: "wand.and.stars"
                    )
                }
                .disabled(appliedTweakKeys.isEmpty)

                if !selectedKeys.isEmpty {
                    Button(role: .destructive) {
                        selectedKeys.removeAll()
                    } label: {
                        Label(
                            String(format: String(localized: "Clear Selection (%d)"),
                                   selectedKeys.count),
                            systemImage: "checkmark.circle.badge.xmark"
                        )
                    }
                }
            } header: {
                Text(String(localized: "Presets"))
            } footer: {
                Text(String(localized: "The applied-tweaks preset selects every CacheExtra key referenced by a tweak toggle that is currently ON. You can also manually browse and pick arbitrary keys below."))
            }

            Section {
                if filteredCacheExtraKeys.isEmpty {
                    Label(String(localized: "No matching keys"), systemImage: "magnifyingglass")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(filteredCacheExtraKeys, id: \.self) { key in
                        CacheExtraKeyPickerRow(
                            key: key,
                            valueSummary: valueSummary(for: key),
                            isSelected: selectedKeys.contains(key)
                        ) {
                            if selectedKeys.contains(key) {
                                selectedKeys.remove(key)
                            } else {
                                selectedKeys.insert(key)
                            }
                        }
                    }
                }
            } header: {
                Text(String(format: String(localized: "CacheExtra Keys (%d)"),
                            filteredCacheExtraKeys.count))
            }
            .headerProminence(.increased)
        }
        .searchable(text: $searchText, prompt: String(localized: "Search keys…"))
        .navigationTitle(String(localized: "Export Patch"))
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(action: performExport) {
                    Text(String(localized: "Export"))
                        .bold()
                }
                .disabled(selectedKeys.isEmpty || patchName.trimmingCharacters(in: .whitespaces).isEmpty || viewModel.isBusy)
            }
        }
        .alert(String(localized: "Name Required"), isPresented: $showEmptyNameAlert) {
            Button(String(localized: "OK"), role: .cancel) {}
        } message: {
            Text(String(localized: "Please give this patch a name before exporting."))
        }
        .onChange(of: viewModel.notice) { _, new in
            // Auto-dismiss the exporter once the export notice appears
            // (success or error both surface through the main workbench
            // notice, so the user won't lose feedback).
            guard let new else { return }
            if new.kind == .backupCreated || new.kind == .error {
                dismiss()
            }
        }
    }

    // MARK: - Helpers

    /// Keys referenced by tweak toggles that are currently applied.
    private var appliedTweakKeys: Set<String> {
        let applied = viewModel.selectedTweaks
        let keys = GestaltTweakCatalog.definitions
            .filter { applied.contains($0.id) }
            .flatMap(\.values.keys)
        return Set(keys)
    }

    /// All CacheExtra keys from the current plist, filtered by search.
    private var filteredCacheExtraKeys: [String] {
        let all = viewModel.plist?.cacheExtra.keys.sorted() ?? []
        let needle = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return all }
        return all.filter { $0.localizedCaseInsensitiveContains(needle) }
    }

    private func valueSummary(for key: String) -> String {
        guard let value = viewModel.plist?.cacheExtra[key] else { return "" }
        let info = PlistValueInfo.info(for: value)
        return info.summary
    }

    private func applyAppliedTweaks() {
        selectedKeys.formUnion(appliedTweakKeys)
    }

    private func performExport() {
        let name = patchName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            showEmptyNameAlert = true
            return
        }
        let authorTrimmed = author.trimmingCharacters(in: .whitespacesAndNewlines)
        let notesTrimmed = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        viewModel.exportPatch(
            name: name,
            author: authorTrimmed.isEmpty ? nil : authorTrimmed,
            notes: notesTrimmed.isEmpty ? nil : notesTrimmed,
            keys: Array(selectedKeys)
        )
    }
}

private struct CacheExtraKeyPickerRow: View {
    let key: String
    let valueSummary: String
    let isSelected: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundColor(isSelected ? Color.accentColor : Color.secondary)
                    .font(.title3)
                VStack(alignment: .leading, spacing: 2) {
                    Text(key)
                        .font(.system(.body, design: .monospaced))
                        .lineLimit(1)
                    Text(valueSummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            .foregroundStyle(.primary)
        }
        .contentShape(Rectangle())
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}

private struct PatchRow: View {
    let patch: GestaltPatch
    let apply: () -> Void

    var body: some View {
        Button(action: apply) {
            VStack(alignment: .leading, spacing: 4) {
                Text(patch.name)
                    .font(.body)
                HStack(spacing: 6) {
                    Text(String(format: String(localized: "%d fields"), patch.fieldCount))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let author = patch.author, !author.isEmpty {
                        Text("· \(author)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(patch.createdAt, format: .dateTime.year().month().day())
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let notes = patch.notes, !notes.isEmpty {
                    Text(notes)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
        }
        .foregroundStyle(.primary)
    }
}

private struct BackupRow: View {
    let backup: GestaltBackup
    let restore: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(backup.createdAt, format: .dateTime.year().month().day().hour().minute().second())
                Text(ByteCountFormatter.string(fromByteCount: backup.byteCount, countStyle: .file))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            ShareLink(item: backup.url) {
                Image(systemName: "square.and.arrow.up")
            }
            .accessibilityLabel("Export Backup")
            Button("Restore", action: restore)
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
            .controlSize(.small)
            .accessibilityLabel("Restore Backup")
        }
    }
}

private struct AdvancedGestaltEditor: View {
    @EnvironmentObject private var viewModel: GestaltViewModel

    @State private var searchText = ""
    @State private var activeEditor: FieldEditorRoute?

    private var cacheExtraKeys: [String] {
        filtered(viewModel.plist?.cacheExtraKeys ?? [], section: .cacheExtra)
    }

    private var topLevelKeys: [String] {
        filtered(
            viewModel.plist?.topLevelKeys.filter { $0 != "CacheExtra" } ?? [],
            section: .topLevel
        )
    }

    var body: some View {
        List {
            if viewModel.plist != nil {
                KeySection(
                    title: "CacheExtra",
                    keys: cacheExtraKeys,
                    value: { value(for: PlistKey(section: .cacheExtra, key: $0)) },
                    select: {
                        activeEditor = .edit(
                            PlistKey(section: .cacheExtra, key: $0)
                        )
                    }
                )

                KeySection(
                    title: String(localized: "Top Level"),
                    keys: topLevelKeys,
                    value: { value(for: PlistKey(section: .topLevel, key: $0)) },
                    select: {
                        activeEditor = .edit(
                            PlistKey(section: .topLevel, key: $0)
                        )
                    }
                )
            }
        }
        .navigationTitle("Advanced Field Editor")
        .searchable(text: $searchText, prompt: "Search key or value")
        .toolbar {
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                Button {
                    activeEditor = .addCacheExtra
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("Add CacheExtra Field")
                .disabled(viewModel.plist == nil || viewModel.isBusy)

                Button("Save", action: viewModel.applyChanges)
                    .fontWeight(.semibold)
                    .disabled(!viewModel.isDirty || viewModel.isBusy)
            }
        }
        .sheet(item: $activeEditor) { editor in
            Group {
                switch editor {
                case .edit(let key):
                    ValueEditor(
                        key: key.key,
                        initialValue: value(for: key),
                        save: { update($0, for: key) },
                        delete: key.section == .cacheExtra
                            ? { deleteCacheExtraField(key.key) }
                            : nil
                    )
                case .addCacheExtra:
                    AddCacheExtraFieldEditor(save: addCacheExtraField)
                }
            }
            .presentationDetents([.medium, .large])
        }
    }

    private func filtered(_ keys: [String], section: PlistSection) -> [String] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return keys }

        return keys.filter { key in
            let reference = PlistKey(section: section, key: key)
            let info = PlistValueInfo.info(for: value(for: reference))
            return key.localizedCaseInsensitiveContains(query)
                || info.searchText.localizedCaseInsensitiveContains(query)
        }
    }

    private func value(for key: PlistKey) -> Any? {
        switch key.section {
        case .cacheExtra:
            viewModel.plist?.cacheExtra[key.key]
        case .topLevel:
            viewModel.plist?.value(forKey: key.key)
        }
    }

    private func update(_ value: Any, for key: PlistKey) {
        guard var plist = viewModel.plist else { return }
        switch key.section {
        case .cacheExtra:
            plist.setCacheExtra(value, forKey: key.key)
        case .topLevel:
            plist.setValue(value, forKey: key.key)
        }
        viewModel.plist = plist
        viewModel.isDirty = true
    }

    private func addCacheExtraField(key: String, value: Any) throws {
        guard var plist = viewModel.plist else { return }
        let normalizedKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedKey.isEmpty else {
            throw AddFieldError.emptyKey
        }
        guard plist.cacheExtra[normalizedKey] == nil else {
            throw AddFieldError.duplicateKey(normalizedKey)
        }

        plist.setCacheExtra(value, forKey: normalizedKey)
        viewModel.plist = plist
        viewModel.isDirty = true
    }

    private func deleteCacheExtraField(_ key: String) {
        guard var plist = viewModel.plist else { return }
        plist.removeCacheExtraValue(forKey: key)
        viewModel.plist = plist
        viewModel.isDirty = true
    }
}

private enum PlistSection: String {
    case cacheExtra
    case topLevel
}

private struct PlistKey: Identifiable {
    let section: PlistSection
    let key: String
    var id: String { "\(section.rawValue)/\(key)" }
}

private enum FieldEditorRoute: Identifiable {
    case edit(PlistKey)
    case addCacheExtra

    var id: String {
        switch self {
        case .edit(let key): "edit/\(key.id)"
        case .addCacheExtra: "add/cacheExtra"
        }
    }
}

private enum AddFieldError: LocalizedError {
    case emptyKey
    case duplicateKey(String)

    var errorDescription: String? {
        switch self {
        case .emptyKey:
            String(localized: "Key cannot be empty.")
        case .duplicateKey(let key):
            String(format: String(localized: "CacheExtra already contains the field: %@"), key)
        }
    }
}

private struct KeySection: View {
    let title: String
    let keys: [String]
    let value: (String) -> Any?
    let select: (String) -> Void

    var body: some View {
        Section(title) {
            if keys.isEmpty {
                Text("No Results")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(keys, id: \.self) { key in
                    Button { select(key) } label: {
                        KeyRow(key: key, value: value(key))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

private struct KeyRow: View {
    let key: String
    let value: Any?

    var body: some View {
        let info = PlistValueInfo.info(for: value)
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(key)
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(info.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
    }
}

private struct ValueEditor: View {
    @Environment(\.dismiss) private var dismiss

    let key: String
    let initialValue: Any?
    let save: (Any) -> Void
    let delete: (() -> Void)?

    @State private var kind: PlistValueKind
    @State private var text: String
    @State private var errorMessage: String?
    @State private var showsDeleteConfirmation = false

    init(
        key: String,
        initialValue: Any?,
        save: @escaping (Any) -> Void,
        delete: (() -> Void)? = nil
    ) {
        self.key = key
        self.initialValue = initialValue
        self.save = save
        self.delete = delete
        let kind = PlistValueKind.kind(of: initialValue)
        _kind = State(initialValue: kind)
        _text = State(initialValue: PlistValueInfo.encode(initialValue, as: kind))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Type") {
                    Picker("Type", selection: $kind) {
                        ForEach(PlistValueKind.allCases) { kind in
                            Text(kind.label).tag(kind)
                        }
                    }
                    .pickerStyle(.menu)
                }

                Section("Value") {
                    TextEditor(text: $text)
                        .font(.system(.body, design: .monospaced))
                        .frame(minHeight: 140)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                    }
                }

                if delete != nil {
                    Section {
                        Button("Delete Field", role: .destructive) {
                            showsDeleteConfirmation = true
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
            }
            .navigationTitle(key)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done", action: commit)
                        .fontWeight(.semibold)
                }
            }
            .confirmationDialog(
                "Delete CacheExtra Field?",
                isPresented: $showsDeleteConfirmation,
                titleVisibility: .visible
            ) {
                Button("Delete", role: .destructive) {
                    delete?()
                    dismiss()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("The field will be removed from the file after you return to the editor and tap Save.")
            }
        }
    }

    private func commit() {
        do {
            save(try PlistValueInfo.parse(text, as: kind))
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct AddCacheExtraFieldEditor: View {
    @Environment(\.dismiss) private var dismiss

    let save: (String, Any) throws -> Void

    @State private var key = ""
    @State private var kind: PlistValueKind = .string
    @State private var text = ""
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Field") {
                    LabeledContent("Location", value: "CacheExtra")
                    TextField("Key", text: $key)
                        .font(.system(.body, design: .monospaced))
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                }

                Section("Type") {
                    Picker("Type", selection: $kind) {
                        ForEach(PlistValueKind.allCases) { kind in
                            Text(kind.label).tag(kind)
                        }
                    }
                    .pickerStyle(.menu)
                }

                Section("Value") {
                    TextEditor(text: $text)
                        .font(.system(.body, design: .monospaced))
                        .frame(minHeight: 120)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Add Field")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Add", action: commit)
                        .fontWeight(.semibold)
                }
            }
        }
    }

    private func commit() {
        do {
            let value = try PlistValueInfo.parse(text, as: kind)
            try save(key, value)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct SettingsTab: View {
    @EnvironmentObject private var languageManager: LanguageManager

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker(selection: $languageManager.language) {
                        ForEach(AppLanguage.allCases) { language in
                            Text(language.label).tag(language)
                        }
                    } label: {
                        Label("Language", systemImage: "globe")
                    }
                    .onChange(of: languageManager.language) { _, newValue in
                        LanguageManager.applyToUserDefaults(newValue)
                    }
                } header: {
                    Text("Language")
                } footer: {
                    Text("Changes take effect on the next app launch.")
                }

                if languageManager.needsRestart {
                    Section {
                        Label {
                            Text("Restart the app for the new language to take effect.")
                                .foregroundStyle(.orange)
                        } icon: {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                        }
                    }
                }

                Section {
                    NavigationLink {
                        DiagnosticsView()
                    } label: {
                        Label("Diagnostics", systemImage: "stethoscope")
                    }
                } header: {
                    Text("Troubleshooting")
                } footer: {
                    Text("Test bad_query availability, sandbox lease, container discovery, and file read operations.")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.large)
        }
    }
}

#Preview {
    ContentView()
        .environmentObject(GestaltViewModel())
        .environmentObject(LanguageManager())
}
