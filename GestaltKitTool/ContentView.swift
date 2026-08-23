import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject private var viewModel: GestaltViewModel
    @EnvironmentObject private var languageManager: LanguageManager
    
    @AppStorage(UserDefaultsKeys.onboardingCompleted) private var onboardingCompleted = false

    var body: some View {
        Group {
            if !onboardingCompleted {
                OnboardingView {
                    onboardingCompleted = true
                }
            } else if GestaltAccess.isRunningSupportedOS() {
                TabView {
                    TweakWorkbench()
                        .tabItem { Label(String(localized: "Tweaks"), systemImage: "switch.2") }

                    ToolsTab()
                        .tabItem { Label(String(localized: "Tools"), systemImage: "wrench.and.screwdriver") }

                    FileExplorerView()
                        .tabItem { Label(String(localized: "Explorer"), systemImage: "folder.badge.gearshape") }

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
            Text(String(localized: "GestaltKitTool currently supports iOS 26.0–26.6.1 and iOS 27 beta 1–4."))
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
        }
        .padding(24)
    }
}

private struct TweakWorkbench: View {
    @EnvironmentObject private var viewModel: GestaltViewModel
    @State private var showsPresetSheet = false
    @State private var selectedTab: Int = 0
    
    @State private var modelNameValidation: ModelNameValidator.Result? = nil
    
    @State private var showsApplyConfirm = false
    
    @State private var showsApplyPreview = false
    
    @State private var showsDiagnosticsFromError = false

    var body: some View {
        NavigationStack {
            List {
                Section { deviceStatus }

                Section {
                    Picker("", selection: $selectedTab) {
                        Text(String(localized: "Tweaks")).tag(0)
                        Text(String(localized: "Presets")).tag(1)
                    }
                    .pickerStyle(.segmented)
                    .listRowInsets(EdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12))
                }

                if selectedTab == 0 {
                    if viewModel.plist != nil {
                        tweakSection(.region)
                        dynamicIslandSection
                        modelNameSection

                        ForEach(GestaltTweakCategory.allCases.filter { $0 != .region }) { category in
                            tweakSection(category)
                        }
                    }
                } else {
                    PresetQuickAccess()
                        .environmentObject(viewModel)
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
            
            .sheet(isPresented: $showsApplyPreview) {
                ApplyPreviewSheet(viewModel: viewModel) {
                    showsApplyPreview = false
                    showsApplyConfirm = true
                }
                .presentationDetents([.medium, .large])
            }
            
            .sheet(isPresented: $showsDiagnosticsFromError) {
                NavigationStack {
                    DiagnosticsView()
                        .navigationTitle(String(localized: "Diagnostics"))
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                Button(String(localized: "Done")) { showsDiagnosticsFromError = false }
                            }
                        }
                }
            }
            
            .confirmationDialog(
                String(localized: "Apply Changes?"),
                isPresented: $showsApplyConfirm,
                titleVisibility: .visible
            ) {
                Button(String(localized: "Apply & Respring")) {
                    viewModel.applySelectedTweaks()
                }
                Button(String(localized: "Cancel"), role: .cancel) {}
            } message: {
                Text(String(format: String(localized: "%d changes will be written to the MobileGestalt plist. An automatic backup will be created. After writing, your device will respring — all apps will close temporarily."), viewModel.stagedChangeCount))
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
        // Use Grid with 3 fixed-width columns for pixel-identical alignment across rows.
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 10) {
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
                                HStack(spacing: 12) {
                                    Button(String(localized: "Reload"), action: viewModel.load)
                                        .font(.caption)
                                    
                                    Button(String(localized: "Diagnostics…")) {
                                        showsDiagnosticsFromError = true
                                    }
                                        .font(.caption)
                                }
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
                // Explicit Optional<Int> typing for the .none tag.
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

    
    private var applyDisabledByModelName: Bool {
        guard viewModel.changesModelName else { return false }
        return modelNameValidation?.isValid == false
    }

    private var modelNameSection: some View {
        Section(String(localized: "Device Name")) {
            Toggle(String(localized: "Change model name in About"), isOn: $viewModel.changesModelName)
                .onChange(of: viewModel.changesModelName) { _, isOn in
                    if !isOn { modelNameValidation = nil }
                    else { modelNameValidation = ModelNameValidator.validate(viewModel.modelName) }
                }
            if viewModel.changesModelName {
                TextField(String(localized: "Model Name"), text: $viewModel.modelName)
                    .textInputAutocapitalization(.words)
                    .onChange(of: viewModel.modelName) { _, newValue in
                        modelNameValidation = ModelNameValidator.validate(newValue)
                    }
                
                if let result = modelNameValidation, !result.isValid {
                    Label(result.localizedMessage, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                Text(String(format: String(localized: "%d/%d characters"), viewModel.modelName.count, ModelNameValidator.maxLength))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
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
            if viewModel.isBusy {
                ProgressView()
                    .padding(.trailing, 8)
            }
            Button(String(localized: "Apply")) { showsApplyPreview = true }
                .buttonStyle(.borderedProminent)
                .disabled(viewModel.isBusy || applyDisabledByModelName)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }
}

// MARK: - Apply Diff Preview Sheet

private struct ApplyPreviewSheet: View {
    @ObservedObject var viewModel: GestaltViewModel
    let onConfirm: () -> Void

    var body: some View {
        NavigationStack {
            List {
                Section(String(localized: "Pending Changes")) {
                    if viewModel.pendingChangeEntries.isEmpty {
                        Text(String(localized: "No changes pending."))
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(viewModel.pendingChangeEntries) { entry in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(entry.category)
                                        .font(.caption2.weight(.semibold))
                                        .foregroundStyle(.secondary)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(Color.secondary.opacity(0.1), in: Capsule())
                                    Spacer()
                                }
                                Text(entry.field)
                                    .font(.subheadline.weight(.medium))
                                HStack(spacing: 8) {
                                    Text(entry.oldValue)
                                        .font(.caption)
                                        .foregroundStyle(.red)
                                        .lineLimit(1)
                                    Image(systemName: "arrow.right")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                    Text(entry.newValue)
                                        .font(.caption)
                                        .foregroundStyle(.green)
                                        .lineLimit(1)
                                }
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }

                Section {
                    Text(String(localized: "An automatic backup will be created before writing. After writing, your device will respring."))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle(String(localized: "Review Changes"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "Cancel"), role: .cancel) {}
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "Continue")) { onConfirm() }
                        .fontWeight(.semibold)
                        .disabled(viewModel.pendingChangeEntries.isEmpty)
                }
            }
        }
    }
}

// MARK: - Tools Tab

/// Dedicated Tools tab.
/// cognitive load on the main Tweak page. Houses Backup, Shared
/// Profiles, Advanced Editor, Status Report, and Danger Zone.
private struct ToolsTab: View {
    @EnvironmentObject private var viewModel: GestaltViewModel
    @State private var showsFactoryResetConfirm = false
    @State private var showsStatusReport = false
    @State private var backupToDelete: GestaltBackup?

    var body: some View {
        NavigationStack {
            List {
                
                // duplicated here. The Tweak tab's "Presets" segment provides
                // both quick-access and full management via PresetManagerView.

                
                Section {
                    NavigationLink {
                        BackupLibrary()
                    } label: {
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
                            Image(systemName: "square.stack.3d.up")
                                .font(.title2)
                                .foregroundStyle(Color.blue)
                                .frame(minWidth: 28, alignment: .center)
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(String(localized: "Shared Profiles"))
                                    .font(.body.weight(.semibold))
                                Text(String(localized: "Field-level configs"))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.vertical, 2)
                        .contentShape(Rectangle())
                    }
                    NavigationLink {
                        AdvancedGestaltEditor()
                    } label: {
                        Label(String(localized: "Advanced Field Editor"), systemImage: "list.bullet.rectangle")
                    }
                } header: {
                    Text(String(localized: "Configuration"))
                } footer: {
                    Text(String(localized: "Actions write to MobileGestalt.plist. Auto-backup before every write."))
                }

                
                Section {
                    NavigationLink {
                        SystemInspectorView()
                    } label: {
                        Label(String(localized: "System Inspector"), systemImage: "shield.lefthalf.filled")
                    }
                    NavigationLink {
                        AppBackupListView()
                    } label: {
                        Label(String(localized: "App Backups"), systemImage: "internaldrive")
                    }
                    NavigationLink {
                        SafeCleanupView()
                    } label: {
                        Label(String(localized: "Safe Cleanup"), systemImage: "sparkles")
                    }
                } header: {
                    Text(String(localized: "System Tools"))
                } footer: {
                    Text(String(localized: "System Inspector reads sensitive system files. App Backups stores full data container copies. Safe Cleanup clears caches and tmp directories."))
                }

                
                Section {
                    Button {
                        showsStatusReport = true
                    } label: {
                        Label(String(localized: "Status Report"), systemImage: "doc.text.magnifyingglass")
                    }
                    .disabled(viewModel.plist == nil)
                }

                
                Section {
                    if viewModel.isBusy {
                        HStack {
                            ProgressView()
                            Text(String(localized: "Working…"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    if viewModel.canUndoLastWrite {
                        Button {
                            viewModel.undoLastWrite()
                        } label: {
                            Label(String(localized: "Undo Last Write"), systemImage: "arrow.uturn.backward")
                        }
                        .disabled(viewModel.isBusy)
                    }
                    Button(role: .destructive) {
                        showsFactoryResetConfirm = true
                    } label: {
                        Label(String(localized: "Restore Factory Settings"), systemImage: "arrow.uturn.backward.circle")
                    }
                    .disabled(viewModel.plist == nil || viewModel.isBusy)
                } header: {
                    Text(String(localized: "Danger Zone"))
                } footer: {
                    Text(String(localized: "Undo restores the backup created before the most recent write. Factory Reset disables all tweaks. Neither reverts iPadOS CacheData patches."))
                }
            }
            .navigationTitle(String(localized: "Tools"))
            .navigationBarTitleDisplayMode(.large)
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
            .sheet(isPresented: $showsStatusReport) {
                StatusReportShareView(report: viewModel.generateStatusReport())
            }
        }
    }
}

// MARK: - Preset Quick Access

/// Inline preset list shown in the Tweak tab's "Presets" segment.
private struct PresetQuickAccess: View {
    @EnvironmentObject private var viewModel: GestaltViewModel
    @State private var presetName = ""
    @State private var showsSavedAlert = false
    // Avoid JSON-decoding on every body re-evaluation.
    @State private var userPresets: [TweakPreset] = []
    
    @State private var presetToLoad: TweakPreset?

    var body: some View {
        Section {
            // Save current tweaks as a new preset
            HStack {
                TextField(String(localized: "Preset name"), text: $presetName)
                    .textInputAutocapitalization(.words)
                Button {
                    guard !presetName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                    viewModel.savePreset(name: presetName)
                    presetName = ""
                    userPresets = PresetStore.loadUserPresets()
                    showsSavedAlert = true
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .font(.title3)
                }
                .disabled(presetName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            // Built-in presets
            let builtIns = TweakPreset.builtIn
            if builtIns.isEmpty && userPresets.isEmpty {
                
                EmptyStateView(
                    icon: "square.stack.3d.up",
                    title: String(localized: "No Presets"),
                    description: String(localized: "Configure tweaks above, then save a preset for quick reuse.")
                )
            } else {
                ForEach(builtIns + userPresets) { preset in
                    HStack {
                        Image(systemName: "square.stack.3d.up")
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(preset.name)
                                .font(.body)
                            Text(String(format: String(localized: "%d tweaks"), preset.tweaks.count))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button {
                            
                            presetToLoad = preset
                        } label: {
                            Label(String(localized: "Load"), systemImage: "arrow.down.circle")
                                .labelStyle(.iconOnly)
                                .font(.title3)
                                .frame(minWidth: 44, minHeight: 44)
                                .foregroundStyle(Color.accentColor)
                        }
                        .buttonStyle(.plain)
                    }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        if !preset.isBuiltIn {
                            Button(role: .destructive) {
                                PresetStore.deleteUserPreset(id: preset.id)
                                userPresets = PresetStore.loadUserPresets()
                            } label: {
                                Label(String(localized: "Delete"), systemImage: "trash")
                            }
                        }
                    }
                }
            }
        } header: {
            Text(String(localized: "Presets"))
        } footer: {
            
            NavigationLink {
                PresetManagerView()
                    .environmentObject(viewModel)
            } label: {
                Text(String(localized: "Manage All Presets…"))
                    .font(.caption)
            }
        }
        .alert(String(localized: "Preset Saved"), isPresented: $showsSavedAlert) {
            Button(String(localized: "OK"), role: .cancel) {}
        }
        .onAppear {
            userPresets = PresetStore.loadUserPresets()
        }
        .onReceive(NotificationCenter.default.publisher(for: PresetStore.didChangeNotification)) { _ in
            userPresets = PresetStore.loadUserPresets()
        }
        
        .sheet(item: $presetToLoad) { preset in
            PresetLoadPreviewSheet(
                preset: preset,
                viewModel: viewModel
            ) {
                viewModel.loadPreset(preset)
                presetToLoad = nil
            }
            .presentationDetents([.medium, .large])
        }
    }
}

// MARK: - Preset Load Preview Sheet

private struct PresetLoadPreviewSheet: View {
    let preset: TweakPreset
    @ObservedObject var viewModel: GestaltViewModel
    let onConfirm: () -> Void

    var body: some View {
        NavigationStack {
            List {
                Section(String(localized: "Preset")) {
                    LabeledContent(String(localized: "Name"), value: preset.name)
                    LabeledContent(String(localized: "Tweaks"), value: "\(preset.tweaks.count)")
                }

                let previews = viewModel.presetLoadPreview(preset)
                Section(String(localized: "Changes")) {
                    if previews.isEmpty {
                        Text(String(localized: "No changes — this preset matches your current configuration."))
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(previews) { preview in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(preview.tweakName)
                                    .font(.subheadline.weight(.medium))
                                HStack(spacing: 8) {
                                    Text(preview.currentValue)
                                        .font(.caption)
                                        .foregroundStyle(preview.isConflict ? .red : .secondary)
                                    Image(systemName: "arrow.right")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                    Text(preview.presetValue)
                                        .font(.caption)
                                        .foregroundStyle(preview.isConflict ? .green : .secondary)
                                }
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }

                Section {
                    Text(String(localized: "Loading this preset will replace your current tweak selections. Your MobileGestalt plist is not modified until you tap Apply."))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle(String(localized: "Load Preset"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "Cancel"), role: .cancel) {}
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "Load")) { onConfirm() }
                        .fontWeight(.semibold)
                }
            }
        }
    }
}

// MARK: - Preset Manager View (full screen, from Tools tab)

/// Full-screen preset management — accessed from Tools tab.
private struct PresetManagerView: View {
    @EnvironmentObject private var viewModel: GestaltViewModel
    @State private var presetName = ""
    // Avoid JSON-decoding on every body re-evaluation.
    @State private var userPresets: [TweakPreset] = []
    
    @State private var presetToLoad: TweakPreset?

    var body: some View {
        List {
            Section {
                HStack {
                    TextField(String(localized: "Preset name"), text: $presetName)
                        .textInputAutocapitalization(.words)
                    Button {
                        guard !presetName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                        viewModel.savePreset(name: presetName)
                        presetName = ""
                        userPresets = PresetStore.loadUserPresets()
                    } label: {
                        Label(String(localized: "Save"), systemImage: "plus.circle.fill")
                    }
                    .disabled(presetName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            } header: {
                Text(String(localized: "Create Preset"))
            } footer: {
                Text(String(localized: "Captures all currently selected tweaks."))
            }

            let builtIns = TweakPreset.builtIn
            Section(String(localized: "Built-in")) {
                ForEach(builtIns) { preset in
                    PresetRow(preset: preset) {
                        
                        presetToLoad = preset
                    }
                }
            }
            Section(String(localized: "Your Presets")) {
                if userPresets.isEmpty {
                    
                    EmptyStateView(
                        icon: "star",
                        title: String(localized: "No Saved Presets"),
                        description: String(localized: "Pick tweaks on the Tweak tab, then type a name above and tap Save.")
                    )
                } else {
                    ForEach(userPresets) { preset in
                        PresetRow(preset: preset) {
                            
                            presetToLoad = preset
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) {
                                PresetStore.deleteUserPreset(id: preset.id)
                                userPresets = PresetStore.loadUserPresets()
                            } label: {
                                Label(String(localized: "Delete"), systemImage: "trash")
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle(String(localized: "Presets"))
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            userPresets = PresetStore.loadUserPresets()
        }
        .onReceive(NotificationCenter.default.publisher(for: PresetStore.didChangeNotification)) { _ in
            userPresets = PresetStore.loadUserPresets()
        }
        
        .sheet(item: $presetToLoad) { preset in
            PresetLoadPreviewSheet(
                preset: preset,
                viewModel: viewModel
            ) {
                viewModel.loadPreset(preset)
                presetToLoad = nil
            }
            .presentationDetents([.medium, .large])
        }
    }
}

private struct PresetRow: View {
    let preset: TweakPreset
    let onLoad: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: "square.stack.3d.up")
                    .foregroundStyle(Color.accentColor)
                Text(preset.name)
                    .font(.body.weight(.semibold))
                Spacer()
                Button {
                    onLoad()
                } label: {
                    Text(String(localized: "Load"))
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            Text(String(format: String(localized: "%d tweaks"), preset.tweaks.count))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

private struct TweakToggle: View {
    let definition: GestaltTweakDefinition
    @Binding var isOn: Bool
    @State private var showRiskConfirm = false

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
        .onChange(of: isOn) { _, newValue in
            if newValue && definition.isRisky {
                showRiskConfirm = true
            }
        }
        .confirmationDialog(
            Text(String(localized: "Enable High-Risk Tweak?")),
            isPresented: $showRiskConfirm,
            titleVisibility: .visible
        ) {
            Button(String(localized: "Enable"), role: .destructive) {
                // User confirmed — keep isOn = true
            }
            Button(String(localized: "Cancel"), role: .cancel) {
                isOn = false  // Revert the toggle
            }
        } message: {
            
            // tweaks (e.g. iPadOS CacheData patches) vs. general risk.
            if definition.isIrreversible {
                Text(definition.detail)
                    + Text("\n\n")
                    + Text(String(localized: "⚠️ IRREVERSIBLE: This tweak modifies CacheData bytes that cannot be reverted even by Factory Reset or disabling the tweak. The only way to undo this change is to restore from a backup taken before it was applied."))
            } else {
                Text(definition.detail)
                    + Text("\n\n")
                    + Text(String(localized: "This modification may be irreversible. A backup will be created automatically when you apply, but some changes (e.g. CacheData patches) cannot be reverted even with Factory Reset. Proceed only if you understand the risks."))
            }
        }
    }
}

private struct BackupLibrary: View {
    @EnvironmentObject private var viewModel: GestaltViewModel
    @State private var backupToRestore: GestaltBackup?
    @State private var backupToPreview: GestaltBackup?
    @State private var editingLabelFor: GestaltBackup?
    @State private var showsBackupImporter = false
    @State private var editMode: EditMode = .inactive
    @State private var selectedBackups: Set<GestaltBackup> = []
    @State private var showsBatchDeleteConfirm = false
    @State private var backupToDelete: GestaltBackup?

    var body: some View {
        List(selection: $selectedBackups) {
            
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
                    
                    EmptyStateView(
                        icon: "archivebox",
                        title: String(localized: "No Backups"),
                        description: String(localized: "Create a backup before making changes so you can roll back at any time."),
                        ctaTitle: String(localized: "Back Up Current MobileGestalt"),
                        ctaAction: { viewModel.createBackup() },
                        ctaDisabled: viewModel.plist == nil || viewModel.isBusy
                    )
                } else {
                    ForEach(viewModel.backups) { backup in
                        BackupRow(
                            backup: backup,
                            restore: { backupToRestore = backup },
                            preview: { backupToPreview = backup },
                            editLabel: { editingLabelFor = backup }
                        )
                        .tag(backup)
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) {
                                backupToDelete = backup
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
                        if offsets.count == 1 {
                            backupToDelete = viewModel.backups[offsets.first!]
                        } else {
                            // UX: multi-select delete — populate the selection
                            // set and route through the batch-delete confirmation
                            // dialog instead of deleting without confirmation.
                            selectedBackups = Set(offsets.map { viewModel.backups[$0] })
                            showsBatchDeleteConfirm = true
                        }
                    }
                }
            }
        }
        .environment(\.editMode, $editMode)
        .navigationTitle(String(localized: "Backups"))
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
            
            if let backup = backupToRestore,
               let sourcePT = backup.sourceProductType,
               !sourcePT.isEmpty,
               sourcePT != DeviceIdentity.currentProductType {
                Text(String(format: String(localized: "⚠️ This backup was created on a different device model (%@). Your current device is %@. Restoring may overwrite device identity and cause unpredictable behavior. The current file will be backed up first."), sourcePT, DeviceIdentity.currentProductType))
            } else {
                Text(String(localized: "The current file will be backed up first. SpringBoard will refresh automatically after restoring."))
            }
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
        .sheet(isPresented: Binding(
            get: { backupToPreview != nil },
            set: { if !$0 { backupToPreview = nil } }
        )) {
            if let backupToPreview {
                BackupPreviewSheet(backup: backupToPreview)
            }
        }
        .sheet(isPresented: Binding(
            get: { editingLabelFor != nil },
            set: { if !$0 { editingLabelFor = nil } }
        )) {
            if let editingLabelFor {
                let current = editingLabelFor.label
                BackupLabelEditorSheet(backup: editingLabelFor, currentLabel: current) { newLabel in
                    viewModel.setBackupLabel(newLabel, for: editingLabelFor)
                }
            }
        }
        .confirmationDialog(
            String(localized: "Delete Backup?"),
            isPresented: Binding(
                get: { backupToDelete != nil },
                set: { if !$0 { backupToDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button(String(localized: "Delete"), role: .destructive) {
                if let backupToDelete { viewModel.delete(backupToDelete) }
                backupToDelete = nil
            }
            Button(String(localized: "Cancel"), role: .cancel) { backupToDelete = nil }
        } message: {
            Text(String(localized: "This backup cannot be recovered after deletion."))
        }
    }
}

private struct PatchLibrary: View {
    @EnvironmentObject private var viewModel: GestaltViewModel
    @State private var patchToApply: GestaltPatch?
    @State private var showsPatchImporter = false
    @State private var showsExporter = false
    @State private var patchToDelete: GestaltPatch?

    var body: some View {
        List {
            
            Section {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "square.and.arrow.down")
                        .font(.title2)
                        .foregroundStyle(Color.blue)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(String(localized: "Shared Profiles"))
                            .font(.headline)
                        Text(String(localized: "A shared profile is a device-independent set of CacheExtra fields. It merges onto the current plist without touching device identity. Safe to share across devices — perfect for spreading tweak combinations."))
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
                    
                    EmptyStateView(
                        icon: "square.and.arrow.down.on.square",
                        title: String(localized: "No Patches"),
                        description: String(localized: "Import a shared profile to apply a combination of CacheExtra fields. You can also export your own tweaks to share."),
                        ctaTitle: String(localized: "Import Patch"),
                        ctaAction: { showsPatchImporter = true },
                        ctaDisabled: viewModel.isBusy || viewModel.plist == nil
                    )
                } else {
                    ForEach(viewModel.patches) { patch in
                        PatchRow(patch: patch) {
                            patchToApply = patch
                        }
                    }
                    .onDelete { offsets in
                        if let first = offsets.first {
                            patchToDelete = viewModel.patches[first]
                        }
                    }
                }
            } header: {
                Text(String(localized: "Local Patches"))
            }
        }
        .navigationTitle(String(localized: "Shared Profiles"))
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
        .confirmationDialog(
            String(localized: "Delete Profile?"),
            isPresented: Binding(
                get: { patchToDelete != nil },
                set: { if !$0 { patchToDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button(String(localized: "Delete"), role: .destructive) {
                if let patchToDelete { viewModel.deletePatch(patchToDelete) }
                patchToDelete = nil
            }
            Button(String(localized: "Cancel"), role: .cancel) { patchToDelete = nil }
        } message: {
            Text(String(localized: "This profile cannot be recovered after deletion."))
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
                        Text(verbatim: "· \(author)")
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
    let preview: () -> Void
    let editLabel: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    // Integrity badge
                    if BackupMeta.isIntact(url: backup.url) {
                        Image(systemName: "checkmark.seal.fill")
                            .font(.caption2)
                            .foregroundStyle(.green)
                    } else {
                        Image(systemName: "xmark.seal.fill")
                            .font(.caption2)
                            .foregroundStyle(.red)
                    }
                    // Manual vs auto badge
                    if backup.isManual {
                        Text(String(localized: "Manual"))
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.blue)
                    }
                    Text(backup.createdAt, format: .dateTime.year().month().day().hour().minute().second())
                }
                // Show label if set
                if let label = backup.label, !label.isEmpty {
                    Text(label)
                        .font(.caption)
                        .foregroundStyle(.primary)
                }
                Text(ByteCountFormatter.string(fromByteCount: backup.byteCount, countStyle: .file))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            // Preview button
            Button {
                preview()
            } label: {
                Image(systemName: "doc.text.magnifyingglass")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(String(localized: "Preview Backup"))
            // Label edit button
            Button {
                editLabel()
            } label: {
                Image(systemName: "tag")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(String(localized: "Edit Label"))
            ShareLink(item: backup.url) {
                Image(systemName: "square.and.arrow.up")
            }
            .accessibilityLabel(String(localized: "Export Backup"))
            Button("Restore", action: restore)
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
            .controlSize(.small)
            .accessibilityLabel(String(localized: "Restore Backup"))
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

    private var keyInfo: CacheExtraKeyDictionary.Entry? {
        CacheExtraKeyDictionary.info(forKey: key)
    }

    var body: some View {
        let info = PlistValueInfo.info(for: value)
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                if let keyInfo {
                    HStack(spacing: 6) {
                        Text(LocalizedStringResource(stringLiteral: keyInfo.label))
                            .font(.body)
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        Text(LocalizedStringResource(stringLiteral: keyInfo.category))
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.accentColor.opacity(0.12))
                            .foregroundStyle(Color.accentColor)
                            .clipShape(Capsule())
                    }
                    Text(key)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                            Text(LocalizedStringResource(stringLiteral: keyInfo.description))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                } else {
                    // Unknown key — show raw key + value summary only.
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
                if let keyInfo = CacheExtraKeyDictionary.info(forKey: key) {
                    Section {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 6) {
                                Text(LocalizedStringResource(stringLiteral: keyInfo.label))
                                    .font(.headline)
                                Text(LocalizedStringResource(stringLiteral: keyInfo.category))
                                    .font(.caption2)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Color.accentColor.opacity(0.12))
                                    .foregroundStyle(Color.accentColor)
                                    .clipShape(Capsule())
                            }
                    Text(LocalizedStringResource(stringLiteral: keyInfo.description))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(key)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.tertiary)
                                .textSelection(.enabled)
                        }
                    }
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
                        .frame(minHeight: 140)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                }

                if let errorMessage {
                    Section {
                        
                        InlineErrorBanner(message: errorMessage)
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
            .navigationTitle(Text(navigationTitle))
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

    private var navigationTitle: LocalizedStringResource {
        if let label = CacheExtraKeyDictionary.info(forKey: key)?.label {
            return LocalizedStringResource(stringLiteral: label)
        }
        return LocalizedStringResource(stringLiteral: key)
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
                        
                        InlineErrorBanner(message: errorMessage)
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
    
    @AppStorage(UserDefaultsKeys.onboardingCompleted) private var onboardingCompleted = true
    @State private var showsOnboarding = false

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
                    Text("Tests bad_query availability, sandbox lease, container discovery, and file read operations.")
                }

                
                Section {
                    LabeledContent("App Name", value: "GestaltKitTool")
                    LabeledContent("Supported iOS", value: "26.0–26.6.1, 27 beta 1–4")
                    Button {
                        showsOnboarding = true
                    } label: {
                        Label("View Risk Declaration", systemImage: "exclamationmark.triangle")
                    }
                } header: {
                    Text("About")
                } footer: {
                    Text("GestaltKitTool modifies system-level plist files via a sandbox escape. Always create a backup before applying changes.")
                }

                
                Section {
                    FAQRow(
                        question: String(localized: "What is MobileGestalt?"),
                        answer: String(localized: "MobileGestalt is a system framework that stores device capability information in a plist file. Apps and services read this file to determine what features your device supports.")
                    )
                    FAQRow(
                        question: String(localized: "What is a respring?"),
                        answer: String(localized: "A respring restarts SpringBoard (the iOS home screen) without rebooting the entire device. It takes a few seconds and all apps will close temporarily.")
                    )
                    FAQRow(
                        question: String(localized: "How do I undo changes?"),
                        answer: String(localized: "Go to Tools → Backups, select a backup from before your changes, and tap Restore. You can also use 'Undo Last Write' in the Danger Zone section.")
                    )
                    FAQRow(
                        question: String(localized: "Why did my tweak revert after restart?"),
                        answer: String(localized: "Some CacheExtra keys are regenerated by system daemons after reboot. This is expected behavior for certain keys. Re-apply your tweaks after restart if needed.")
                    )
                } header: {
                    Text("FAQ")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.large)
            
            .sheet(isPresented: $showsOnboarding) {
                OnboardingView {
                    showsOnboarding = false
                }
            }
        }
    }
}

// MARK: - FAQ Row

private struct FAQRow: View {
    let question: String
    let answer: String
    @State private var isExpanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            Text(answer)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 2)
        } label: {
            Text(question)
                .font(.subheadline.weight(.medium))
        }
    }
}

// MARK: - Backup Preview Sheet

private struct BackupPreviewSheet: View {
    @Environment(\.dismiss) private var dismiss
    let backup: GestaltBackup

    @State private var previewText: String = ""
    @State private var isLoading = true

    var body: some View {
        NavigationStack {
            ScrollView {
                if isLoading {
                    ProgressView()
                        .padding()
                } else {
                    Text(previewText)
                        .font(.system(.caption, design: .monospaced))
                        .padding()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
            }
            .navigationTitle(String(localized: "Backup Preview"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(String(localized: "Done")) { dismiss() }
                }
            }
        }
        .task {
            await loadPreview()
        }
    }

    private func loadPreview() async {
        do {
            let data = try GestaltBackupStore.data(for: backup)
            var format = PropertyListSerialization.PropertyListFormat.binary
            if let dict = try PropertyListSerialization.propertyList(
                from: data,
                options: [],
                format: &format
            ) as? [String: Any] {
                let sortedKeys = dict.keys.sorted()
                var lines: [String] = []
                lines.append("File: \(backup.url.lastPathComponent)")
                lines.append("Size: \(ByteCountFormatter.string(fromByteCount: backup.byteCount, countStyle: .file))")
                lines.append("")
                for key in sortedKeys {
                    let value = dict[key]
                    let info = PlistValueInfo.info(for: value)
                    lines.append("\(key): \(info.summary)")
                }
                await MainActor.run {
                    previewText = lines.joined(separator: "\n")
                    isLoading = false
                }
            }
        } catch {
            await MainActor.run {
                previewText = "Error: \(ErrorHandler.friendlyMessage(for: error))"
                isLoading = false
            }
        }
    }
}

// MARK: - Backup Label Editor Sheet

private struct BackupLabelEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    let backup: GestaltBackup
    let currentLabel: String?
    let onSave: (String?) -> Void

    @State private var label: String

    init(backup: GestaltBackup, currentLabel: String?, onSave: @escaping (String?) -> Void) {
        self.backup = backup
        self.currentLabel = currentLabel
        self.onSave = onSave
        _label = State(initialValue: currentLabel ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(String(localized: "Label (optional)"), text: $label)
                } header: {
                    Text(String(localized: "Backup Label"))
                } footer: {
                    Text(String(localized: "Add a note to help identify this backup later."))
                }
                Section {
                    Text(backup.createdAt, format: .dateTime.year().month().day().hour().minute().second())
                        .foregroundStyle(.secondary)
                } header: {
                    Text(String(localized: "Backup Date"))
                }
            }
            .navigationTitle(String(localized: "Edit Label"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(String(localized: "Cancel")) { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(String(localized: "Save")) {
                        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
                        onSave(trimmed.isEmpty ? nil : trimmed)
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
        }
    }
}

// MARK: - Unified Inline Error Banner

/// Reusable inline error banner for form-level validation errors.
/// Provides consistent visual styling across all editor views.
struct InlineErrorBanner: View {
    let message: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "xmark.octagon.fill")
                .foregroundStyle(.red)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 4)
    }
}

#Preview {
    ContentView()
        .environmentObject(GestaltViewModel())
        .environmentObject(LanguageManager())
}
